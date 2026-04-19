`timescale 1ns/1ps
// ============================================================================
// Stage 2: Execute (EX) — with RV32M Extension
// ============================================================================
// Changes from Phase 1:
//   - Added RV32M multiply (single-cycle) and divide (multi-cycle) support
//   - Multiplier uses `*` operators for DSP48 inference
//   - Divider is an iterative 32-cycle module with div_busy stall
//   - New `muldiv` input flag from ID/EX register
//   - New `div_busy` output to hazard unit
// Phase 3 changes:
//   - `pc` is now actual instruction PC (not PC+4)
//   - Branch targets use pc+imm (was (pc-4)+imm)
//   - Return address for JAL/JALR is pc+4 (was pc)
//   - AUIPC uses pc+imm (was (pc-4)+imm)
//   - Removed `fetch_pc` input (no longer needed)
//   - Added `predicted_taken`, `predicted_target` inputs for mispredict detection
//   - New `mispredict` output
// ============================================================================
module execute
#(
    parameter [31:0] RESET = 32'h0000_0000
)
(
    input             clk,
    input             reset,

    // ---- From ID/EX register ----
    input  [31:0] reg_rdata1,        // register file rs1 value
    input  [31:0] reg_rdata2,        // register file rs2 value
    input  [31:0] execute_imm,       // sign-extended immediate
    input  [31:0] pc,                // actual PC of this instruction
    input         immediate_sel,     // 1 = use immediate as ALU operand B
    input         mem_write,         // 1 = store instruction
    input         jal,
    input         jalr,
    input         lui,
    input         auipc,
    input         alu,
    input         branch,
    input         arithsubtype,
    input         muldiv,            // 1 = RV32M multiply/divide instruction
    input         mem_to_reg,        // 1 = load instruction
    input  [4:0]  dest_reg_sel,      // rd address
    input  [2:0]  alu_op,            // funct3
    input  [4:0]  rs1_addr,          // rs1 register address (for forwarding unit)
    input  [4:0]  rs2_addr,          // rs2 register address (for forwarding unit)

    // ---- Forwarded values from hazard unit ----
    input  [1:0]  forward_a,        // 00=reg, 01=EX/MEM, 10=MEM/WB
    input  [1:0]  forward_b,        // 00=reg, 01=EX/MEM, 10=MEM/WB
    input  [31:0] ex_mem_fwd_data,  // ALU result from EX/MEM register
    input  [31:0] mem_wb_fwd_data,  // writeback data from MEM/WB register

    // ---- RV32A atomic inputs ----
    input         atomic_lr,         // 1 = lr.w instruction
    input         atomic_sc,         // 1 = sc.w instruction

    // ---- Branch prediction inputs ----
    input         predicted_taken,   // prediction from BTB/BHT
    input  [31:0] predicted_target,  // predicted target from BTB

    // ---- Outputs to pipeline ----
    output reg [31:0] next_pc,       // resolved next PC (always correct)
    output reg        branch_taken,  // 1 = branch/jump taken

    // ---- Outputs to EX/MEM register ----
    output [31:0] ex_alu_result,     // ALU result
    output [31:0] ex_store_data,     // forwarded rs2 value (for stores)
    output [31:0] ex_pc,             // PC passthrough
    output        ex_mem_write,      // store flag
    output        ex_mem_to_reg,     // load flag
    output        ex_reg_write_en,   // will this instruction write rd?
    output [4:0]  ex_rd,             // destination register
    output [2:0]  ex_funct3,         // funct3 passthrough

    // ---- Divider stall signal ----
    output        div_busy,          // 1 = divider is computing, stall pipeline
    output        div_done,          // 1 = divider result ready (1-cycle pulse)

    // ---- RV32A atomic outputs ----
    output        ex_atomic_lr,      // passthrough to EX/MEM
    output        ex_atomic_sc,      // passthrough to EX/MEM

    // ---- Branch prediction output ----
    output        mispredict          // 1 = branch prediction was wrong
);

`include "opcode.vh"

// ============================================================================
// Forwarding muxes — select actual operand values
// ============================================================================
reg [31:0] fwd_rs1, fwd_rs2;

always @(*) begin
    case (forward_a)
        2'b01:   fwd_rs1 = ex_mem_fwd_data;  // forward from EX/MEM
        2'b10:   fwd_rs1 = mem_wb_fwd_data;  // forward from MEM/WB
        default: fwd_rs1 = reg_rdata1;        // no forwarding
    endcase

    case (forward_b)
        2'b01:   fwd_rs2 = ex_mem_fwd_data;
        2'b10:   fwd_rs2 = mem_wb_fwd_data;
        default: fwd_rs2 = reg_rdata2;
    endcase
end

// ---- ALU operands after forwarding + immediate selection ----
wire [31:0] alu_operand1 = fwd_rs1;
wire [31:0] alu_operand2 = immediate_sel ? execute_imm : fwd_rs2;

// ---- Subtraction results for branches and SLT ----
wire [32:0] ex_result_subs = {alu_operand1[31], alu_operand1} -
                              {alu_operand2[31], alu_operand2};
wire [32:0] ex_result_subu = alu_operand1 - alu_operand2;

// ============================================================================
// RV32M — Single-Cycle Multiplier (DSP48 inference)
// ============================================================================
wire signed [32:0] mul_op_a = (alu_op == MULHU)
                            ? {1'b0, fwd_rs1}                      // unsigned
                            : {fwd_rs1[31], fwd_rs1};              // signed

wire signed [32:0] mul_op_b = (alu_op == MULHU || alu_op == MULHSU)
                            ? {1'b0, fwd_rs2}                      // unsigned
                            : {fwd_rs2[31], fwd_rs2};              // signed

wire signed [65:0] mul_product = mul_op_a * mul_op_b;

reg [31:0] mul_result;
always @(*) begin
    case (alu_op)
        MUL:     mul_result = mul_product[31:0];    // lower 32 bits
        MULH:    mul_result = mul_product[63:32];   // upper 32 bits (signed × signed)
        MULHSU:  mul_result = mul_product[63:32];   // upper 32 bits (signed × unsigned)
        MULHU:   mul_result = mul_product[63:32];   // upper 32 bits (unsigned × unsigned)
        default: mul_result = 32'h0;
    endcase
end

// ============================================================================
// RV32M — Multi-Cycle Iterative Divider
// ============================================================================
wire        div_start;
wire [31:0] div_quotient;
wire [31:0] div_remainder;
wire        div_signed_op = (alu_op == DIV) || (alu_op == REM);
wire        is_div_op     = muldiv && (alu_op[2] == 1'b1);  // funct3[2]=1 → DIV/DIVU/REM/REMU

// Start divider when a new div instruction arrives and divider is idle.
// Suppress restart on the cycle div_done=1 (result just became available).
assign div_start = is_div_op && !div_busy && !div_done;

divider u_divider (
    .clk        (clk),
    .reset      (reset),
    .start      (div_start),
    .signed_op  (div_signed_op),
    .dividend   (fwd_rs1),
    .divisor    (fwd_rs2),
    .busy       (div_busy),
    .done       (div_done),
    .quotient   (div_quotient),
    .remainder  (div_remainder)
);

reg [31:0] div_result;
always @(*) begin
    case (alu_op)
        DIV,  DIVU: div_result = div_quotient;
        REM,  REMU: div_result = div_remainder;
        default:    div_result = 32'h0;
    endcase
end

// ============================================================================
// ALU result mux
// ============================================================================
reg [31:0] alu_result;

always @(*) begin
    case (1'b1)
        lui:      alu_result = execute_imm;
        auipc:    alu_result = pc + execute_imm;              // rd = PC + imm20
        jal,
        jalr:     alu_result = pc + 32'd4;                   // return address = PC + 4
        (alu && muldiv && !is_div_op): begin
            // RV32M multiply — single cycle
            alu_result = mul_result;
        end
        (alu && muldiv && is_div_op): begin
            // RV32M divide — result available when div_done
            alu_result = div_result;
        end
        (alu && !muldiv): begin
            case (alu_op)
                ADD:     alu_result = arithsubtype ? alu_operand1 - alu_operand2
                                                   : alu_operand1 + alu_operand2;
                SLL:     alu_result = alu_operand1 << alu_operand2[4:0];
                SLT:     alu_result = {31'b0, ex_result_subs[32]};
                SLTU:    alu_result = {31'b0, ex_result_subu[32]};
                XOR:     alu_result = alu_operand1 ^ alu_operand2;
                SR:      if (arithsubtype)
                             alu_result = $signed(alu_operand1) >>> alu_operand2[4:0];
                         else
                             alu_result = alu_operand1 >> alu_operand2[4:0];
                OR:      alu_result = alu_operand1 | alu_operand2;
                AND:     alu_result = alu_operand1 & alu_operand2;
                default: alu_result = 32'h0;
            endcase
        end
        // RV32A: lr.w/sc.w address = rs1 (no immediate offset)
        atomic_lr,
        atomic_sc: alu_result = fwd_rs1;
        // LOAD/STORE: compute address = rs1 + immediate
        mem_to_reg,
        mem_write: alu_result = fwd_rs1 + execute_imm;
        default:   alu_result = 32'h0;
    endcase
end

// ============================================================================
// Branch / Jump resolution
// ============================================================================
always @(*) begin
    next_pc      = pc + 32'd4;         // default: next sequential PC
    branch_taken = 1'b0;

    case (1'b1)
        jal: begin
            next_pc      = pc + execute_imm;
            branch_taken = 1'b1;
        end
        jalr: begin
            next_pc      = fwd_rs1 + execute_imm;  // uses forwarded rs1
            branch_taken = 1'b1;
        end
        branch: begin
            case (alu_op)
                BEQ: begin
                    if (ex_result_subs == 0) begin
                        next_pc      = pc + execute_imm;
                        branch_taken = 1'b1;
                    end
                end
                BNE: begin
                    if (ex_result_subs != 0) begin
                        next_pc      = pc + execute_imm;
                        branch_taken = 1'b1;
                    end
                end
                BLT: begin
                    if (ex_result_subs[32]) begin
                        next_pc      = pc + execute_imm;
                        branch_taken = 1'b1;
                    end
                end
                BGE: begin
                    if (!ex_result_subs[32]) begin
                        next_pc      = pc + execute_imm;
                        branch_taken = 1'b1;
                    end
                end
                BLTU: begin
                    if (ex_result_subu[32]) begin
                        next_pc      = pc + execute_imm;
                        branch_taken = 1'b1;
                    end
                end
                BGEU: begin
                    if (!ex_result_subu[32]) begin
                        next_pc      = pc + execute_imm;
                        branch_taken = 1'b1;
                    end
                end
                default: ; // no branch
            endcase
        end
        default: ; // not a branch/jump
    endcase
end

// ============================================================================
// Mispredict detection
// ============================================================================
// Mispredict if: direction mismatch OR (both taken but target mismatch)
assign mispredict = (predicted_taken != branch_taken) ||
                    (predicted_taken && branch_taken && (predicted_target != next_pc));

// ============================================================================
// Output assignments to EX/MEM register
// ============================================================================
assign ex_alu_result   = alu_result;
assign ex_store_data   = fwd_rs2;    // forwarded rs2 for stores
assign ex_pc           = pc;
assign ex_mem_write    = mem_write;
assign ex_mem_to_reg   = mem_to_reg;
assign ex_reg_write_en = alu | lui | auipc | jal | jalr | mem_to_reg | atomic_lr | atomic_sc;
assign ex_rd           = dest_reg_sel;
assign ex_funct3       = alu_op;
assign ex_atomic_lr    = atomic_lr;
assign ex_atomic_sc    = atomic_sc;

endmodule
