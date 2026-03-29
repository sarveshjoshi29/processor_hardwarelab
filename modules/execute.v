`timescale 1ns/1ps

////////////////////////////////////////////////////////////// Stage 2: Execute////////////////////////////////////////////////////////////
module execute
#(
	parameter [31:0] RESET = 32'h0000_0000
)
(
	input clk,
	input reset,
	

	// -----------------------------	// FROM ID/EX	// -----------------------------
	input  [31:0] reg_rdata1,
	input  [31:0] reg_rdata2,
	input  [31:0] execute_imm,
	input  [31:0] pc,
	input  [31:0] fetch_pc,
	input     	immediate_sel,
	input     	mem_write,
	input     	jal,
	input     	jalr,
	input     	lui,
	input     	alu,
	input     	branch,
	input     	arithsubtype,
	input     	mem_to_reg,
	input     	stall_read,

	input  [4:0]  dest_reg_sel,
	input  [2:0]  alu_op,
	input  [1:0]  dmem_raddr,

	// -----------------------------	// FROM WB	// -----------------------------
	input  wb_branch_i,
	input  wb_branch_nxt_i,

	// -----------------------------	// EX → PIPE	// -----------------------------
	output [31:0] alu_operand1,
	output [31:0] alu_operand2,
	output [31:0] write_address,
	output    	branch_stall,

	output reg [31:0] next_pc,
	output reg    	branch_taken,

	// -----------------------------  // EX → WB	// -----------------------------
	output [31:0] wb_result,
	output    	wb_mem_write,
	output    	wb_alu_to_reg,
	output [4:0]  wb_dest_reg_sel,
	output    	wb_branch,
	output    	wb_branch_nxt,
	output    	wb_mem_to_reg,
	output [1:0]  wb_read_address,
	output [2:0]  mem_alu_operation
);

`include "opcode.vh"

////////////////////////////////////////////////////////////// LOCAL INTERNAL SIGNALS/////////////////////////////////
reg  [31:0] ex_result;
wire [32:0] ex_result_subs;
wire [32:0] ex_result_subu;

////////////////////////////////////////////////////////////// Operand selection///////////////////////////////////////////////////////
assign alu_operand1 = reg_rdata1;
assign alu_operand2 = immediate_sel? execute_imm : reg_rdata2;

////////////////////////////////////////////////////////////// Subtractions////////////////////////////////////////////////////////////
assign ex_result_subs =
	{alu_operand1[31], alu_operand1} -
	{alu_operand2[31], alu_operand2};
assign ex_result_subu = alu_operand1 - alu_operand2;

////////////////////////////////////////////////////////////// Address & branch stall////////////////////////////////////////
assign write_address = alu_operand1 + execute_imm;
assign branch_stall  = wb_branch_nxt_i || wb_branch_i;

////////////////////////////////////////////////////////////// Next PC logic////////////////////////////////////////////////////////////
always @(*) begin
    next_pc      = pc + 4;
    branch_taken = !branch_stall;
    case (1'b1)
        jal  :begin  next_pc = (pc - 4) + execute_imm; 
			branch_taken = 1'b1;
		end 
        jalr :begin  next_pc = alu_operand1 + execute_imm;
			branch_taken = 1'b1;
		end // jalr uses register, no PC fix needed
        branch: begin
            case (alu_op)
                BEQ:  begin
                    next_pc = (ex_result_subs == 0) ? (pc - 4) + execute_imm : fetch_pc + 4;
                    if (ex_result_subs != 0) branch_taken = 1'b0;
                end
                BNE:  begin
                    next_pc = (ex_result_subs != 0) ? (pc - 4) + execute_imm : fetch_pc + 4;
                    if (ex_result_subs == 0) branch_taken = 1'b0;
                end
                BLT:  begin
                    next_pc = ex_result_subs[32] ? (pc - 4) + execute_imm : fetch_pc + 4;
                    if (!ex_result_subs[32]) branch_taken = 1'b0;
                end
                BGE:  begin
                    next_pc = (!ex_result_subs[32]) ? (pc - 4) + execute_imm : fetch_pc + 4;                
                    if (ex_result_subs[32]) branch_taken = 1'b0;
                end
                BLTU: begin
                    next_pc = ex_result_subu[32] ? (pc - 4) + execute_imm : fetch_pc + 4;
                    if (!ex_result_subu[32]) branch_taken = 1'b0;
                end
                BGEU: begin
                    next_pc = (!ex_result_subu[32]) ? (pc - 4) + execute_imm : fetch_pc + 4;                                                                                                         
                    if (ex_result_subu[32]) branch_taken = 1'b0;
                end
                default: next_pc = fetch_pc + 4;
            endcase
        end
        default: begin       
            next_pc      = fetch_pc + 4;
            branch_taken = 1'b0;
        end
    endcase
end

////////////////////////////////////////////////////////////// ALU result logic////////////////////////////////////////////////////////////
always @(*) begin
	case (1'b1)
    	mem_write: ex_result = alu_operand2;
		jal, 
    	jalr:  	ex_result = pc;
    	lui:   	ex_result = execute_imm;
		alu: begin
        	case (alu_op)  
            	ADD : ex_result = arithsubtype ? alu_operand1 - alu_operand2 : alu_operand1 + alu_operand2;
				SLL : ex_result = alu_operand1 << alu_operand2;
            	SLT : ex_result = ex_result_subs[32];
            	SLTU: ex_result = ex_result_subu[32];
				XOR : ex_result = alu_operand1 ^ alu_operand2;
            	SR  : ex_result = arithsubtype ? $signed(alu_operand1) >>> alu_operand2 : alu_operand1 >> alu_operand2;
				OR  : ex_result = alu_operand1 | alu_operand2;
            	AND : ex_result = alu_operand1 & alu_operand2;
            	default: ex_result = 'h0;
			endcase
    	end
    	default: ex_result = 'h0;
	endcase
end

////////////////////////////////////////////////////////////// EX → WB pipeline register/////////////////////////////////////////
ex_mem_wb_reg u_ex_mem_wb (
	.clk        	(clk),
	.reset_n    	(reset),
	.stall_n    	(stall_read),
	.ex_result  	(ex_result),
	.mem_write  	(mem_write && !branch_stall),
	.alu_to_reg 	((alu | lui | jal | jalr | mem_to_reg ) && !branch_stall),
	.dest_reg_sel   (dest_reg_sel),
	.branch_taken   (branch_taken),
	.mem_to_reg 	(mem_to_reg),
	.read_address   (dmem_raddr),
	.alu_operation  (alu_op),

	.ex_mem_result    	(wb_result),
	.ex_mem_mem_write 	(wb_mem_write),
	.ex_mem_alu_to_reg	(wb_alu_to_reg),
	.ex_mem_dest_reg_sel  (wb_dest_reg_sel),
	.ex_mem_branch    	(wb_branch),
	.ex_mem_branch_nxt	(wb_branch_nxt),
	.ex_mem_mem_to_reg	(wb_mem_to_reg),
	.ex_mem_read_address  (wb_read_address),
	.ex_mem_alu_operation (mem_alu_operation)
);
endmodule

module ex_mem_wb_reg (
	input     	clk,
	input     	reset_n,
	input     	stall_n,

	// Data
	input  [31:0] ex_result,

	// Control inputs from EX/MEM
	input     	mem_write,
	input     	alu_to_reg,
	input  [4:0]  dest_reg_sel,
	input     	branch_taken,
	input     	mem_to_reg,
	input  [1:0]  read_address,
	input  [2:0]  alu_operation,

	// Outputs to WB
	output reg [31:0] ex_mem_result,
	output reg    	ex_mem_mem_write,
	output reg    	ex_mem_alu_to_reg,
	output reg [4:0]  ex_mem_dest_reg_sel,
	output reg    	ex_mem_branch,
	output reg    	ex_mem_branch_nxt,
	output reg    	ex_mem_mem_to_reg,
	output reg [1:0]  ex_mem_read_address,
	output reg [2:0]  ex_mem_alu_operation
);

always @(posedge clk or negedge reset_n) begin
	if (!reset_n) begin
    	ex_mem_result     	<= 32'h0;
		ex_mem_mem_write  	<= 1'b0;
    	ex_mem_alu_to_reg 	<= 1'b0;
    	ex_mem_dest_reg_sel   <= 5'h0;
    	ex_mem_branch     	<= 1'b0;
		ex_mem_branch_nxt 	<= 1'b0;
    	ex_mem_mem_to_reg 	<= 1'b0;
    	ex_mem_read_address   <= 2'h0;
    	ex_mem_alu_operation  <= 3'h0;
	end
	else if (!stall_n) begin
    	ex_mem_result     	<= ex_result;
    	ex_mem_mem_write  	<= mem_write;
		ex_mem_alu_to_reg 	<= alu_to_reg;
    	ex_mem_dest_reg_sel   <= dest_reg_sel;
    	ex_mem_branch     	<= branch_taken;
    	ex_mem_branch_nxt 	<= ex_mem_branch;
		ex_mem_mem_to_reg 	<= mem_to_reg;
    	ex_mem_read_address   <= read_address;
    	ex_mem_alu_operation  <= alu_operation;
	end
end
endmodule