`timescale 1ns / 1ps

module top_fpga #(
	parameter IMEMSIZE = 4096,
	parameter DMEMSIZE = 4096
)(
	input  wire clk,    	// fast board clock (e.g. 100 MHz)
	input  wire reset,  	// active-low reset
 
 
output [15:0] led
);
// pipe outputs 
wire [31:0] internal_pc;
wire [31:0] i_addr;
wire        d_read_en;
wire [31:0] d_read_addr;
wire        d_write_en;
wire [31:0] d_write_addr;
wire [31:0] d_write_data;
wire [3:0]  d_write_byte;




wire [15:0] pc_disp = internal_pc[15:0];
wire exception;
	////////////////////////////////////////////////////////////
	// Slow clock generator (clock divider)
	////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////
// 100 MHz → 1 Hz clock divider (Nexys A7)
////////////////////////////////////////////////////////////
reg [25:0] clk_cnt;   	// enough for 50 million
reg    	slow_clk;

always @(posedge clk or posedge reset) begin
	if (reset) begin
    	clk_cnt  <= 26'd0;
    	slow_clk <= 1'b0;
	end else begin
    	if (clk_cnt == 26'd49_999_999) begin
        	clk_cnt  <= 26'd0;
        	slow_clk <= ~slow_clk;   // toggle every 0.5 sec
    	end else begin
        	clk_cnt <= clk_cnt + 1'b1;
    	end
	end
end


	////////////////////////////////////////////////////////////
	// PIPE ↔ MEMORY WIRES
	////////////////////////////////////////////////////////////
	wire [31:0] inst_mem_read_data;
	wire    	inst_mem_is_valid;

	wire [31:0] dmem_read_data;
	wire    	dmem_write_valid;
	wire    	dmem_read_valid;

	assign inst_mem_is_valid = 1'b1;
	assign dmem_write_valid  = 1'b1;
	assign dmem_read_valid   = 1'b1;
assign led = pc_disp;

////////////////////////////////////////////////////////////
// PIPELINE CPU
////////////////////////////////////////////////////////////

// feed slow clock here
pipe pipe_u (
	.clk(slow_clk),
	.reset(reset),
	.stall(1'b0),
	.exception(exception),

	.inst_mem_is_valid(inst_mem_is_valid),
	.inst_mem_read_data(inst_mem_read_data),

	.dmem_read_data_temp(dmem_read_data),
	.dmem_write_valid(dmem_write_valid),
	.dmem_read_valid(dmem_read_valid),
	.inst_fetch_pc(internal_pc),
    .inst_mem_address(i_addr),
    .dmem_read_ready(d_read_en),
    .dmem_read_address(d_read_addr),
    .dmem_write_ready(d_write_en),
    .dmem_write_addr(d_write_addr),
    .dmem_write_data(d_write_data),
    .dmem_write_byte(d_write_byte)
	
// TODO: Might have a few more port signals
);


////////////////////////////////////////////////////////////
// INSTRUCTION MEMORY  (matches instr_mem.v)
////////////////////////////////////////////////////////////
instr_mem IMEM (
	.clk(slow_clk),
	.pc(i_addr),
	.instr(inst_mem_read_data),
	.reset(reset)
);


////////////////////////////////////////////////////////////
// DATA MEMORY  (matches data_mem.v)
////////////////////////////////////////////////////////////
data_mem DMEM (
    .clk(slow_clk),
    .re(d_read_en),           
    .raddr(d_read_addr),
    .rdata(dmem_read_data),
    .we(d_write_en),
    .waddr(d_write_addr),
    .wdata(d_write_data),
    .wstrb(d_write_byte)
);




endmodule
