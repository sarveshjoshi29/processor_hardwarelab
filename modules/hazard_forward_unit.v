`timescale 1ns/1ps
// ============================================================================
// Hazard Detection & Forwarding Unit
// ============================================================================
// This module is the "brain" of the 5-stage pipeline's data-hazard resolution.
//
// 1. FORWARDING (eliminates most stalls):
//    - EX→EX  : Result produced in MEM stage (EX/MEM register) forwarded to
//               EX-stage operand inputs.  1-cycle-old result.
//    - MEM→EX : Result produced in WB stage (MEM/WB register) forwarded to
//               EX-stage operand inputs.  2-cycle-old result.
//    Priority: EX→EX wins over MEM→EX (younger instruction has fresher data).
//
// 2. LOAD-USE HAZARD DETECTION (requires 1-cycle stall):
//    If the instruction in EX is a LOAD and the instruction in ID reads that
//    register, we CANNOT forward because the data isn't available until after
//    the MEM stage. We must:
//      a) Stall IF and ID (hold PC and IF/ID register).
//      b) Insert a bubble into EX (zero-out EX control signals via ID/EX flush).
//
// 3. BRANCH FLUSH:
//    On a branch mispredict detected in EX, flush the IF/ID and ID/EX registers
//    (2-cycle penalty for the two instructions fetched after the branch).
//    NOTE: The 2-cycle flush uses flush_delay in pipeline.v; hazard unit only
//    signals the first-cycle flush via flush_if_id = branch_taken.
//
// Forwarding mux encoding (2-bit):
//    2'b00 = no forwarding, use register file value
//    2'b01 = forward from EX/MEM (1-cycle-old ALU result)
//    2'b10 = forward from MEM/WB (2-cycle-old writeback value)
// ============================================================================
module hazard_forward_unit (
    // ---------------------------------------------------------------
    // Source register addresses from ID/EX (the instruction in EX)
    // Used for forwarding mux selection
    // ---------------------------------------------------------------
    input      [4:0] id_ex_rs1,          // rs1 address of instruction in EX
    input      [4:0] id_ex_rs2,          // rs2 address of instruction in EX

    // ---------------------------------------------------------------
    // Source register addresses from IF/ID (the instruction in ID)
    // Used for load-use hazard detection
    // ---------------------------------------------------------------
    input      [4:0] if_id_rs1,          // rs1 address of instruction in ID
    input      [4:0] if_id_rs2,          // rs2 address of instruction in ID

    // ---------------------------------------------------------------
    // ID/EX stage: instruction currently in EX (for load-use detection)
    // ---------------------------------------------------------------
    input      [4:0] id_ex_rd,           // destination register of instruction in EX
    input            id_ex_mem_to_reg,   // 1 = instruction in EX is a LOAD

    // ---------------------------------------------------------------
    // EX/MEM stage: instruction in MEM (forwarding source)
    // ---------------------------------------------------------------
    input      [4:0] ex_mem_rd,          // destination register
    input            ex_mem_reg_write,   // 1 = this instruction writes a register

    // ---------------------------------------------------------------
    // MEM/WB stage: instruction in WB (forwarding source)
    // ---------------------------------------------------------------
    input      [4:0] mem_wb_rd,          // destination register
    input            mem_wb_reg_write,   // 1 = this instruction writes a register

    // ---------------------------------------------------------------
    // Divider busy signal from EX stage (RV32M)
    // ---------------------------------------------------------------
    input            div_busy,           // 1 = multi-cycle divider is computing

    // ---------------------------------------------------------------
    // Branch mispredict signal from EX stage (drives 1st flush cycle;
    // pipeline.v adds flush_delay for the 2nd cycle)
    // ---------------------------------------------------------------
    input            branch_taken,       // 1 = branch mispredict detected in EX

    // ---------------------------------------------------------------
    // OUTPUTS
    // ---------------------------------------------------------------

    // Forwarding mux selects for EX-stage operands
    output reg [1:0] forward_a,          // mux select for ALU operand A (rs1)
    output reg [1:0] forward_b,          // mux select for ALU operand B (rs2)

    // Hazard stall signals
    output           stall_if,           // 1 = freeze PC and IF/ID register
    output           stall_id,           // 1 = freeze ID/EX register
    output           flush_id_ex,        // 1 = insert bubble into EX stage (load-use only)
    output           flush_if_id         // 1 = insert bubble into ID stage
);

// ============================================================================
// FORWARDING LOGIC
// ============================================================================
// Priority: EX/MEM (younger) wins over MEM/WB (older) when both match.
// x0 is never forwarded — it is hardwired to zero.
// ============================================================================
always @(*) begin
    // ---- Default: no forwarding ----
    forward_a = 2'b00;
    forward_b = 2'b00;

    // ---- Forward A (rs1) ----
    // EX/MEM forwarding (highest priority — most recent producer)
    if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs1)) begin
        forward_a = 2'b01;
    end
    // MEM/WB forwarding (lower priority — older producer)
    else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs1)) begin
        forward_a = 2'b10;
    end

    // ---- Forward B (rs2) ----
    if (ex_mem_reg_write && (ex_mem_rd != 5'd0) && (ex_mem_rd == id_ex_rs2)) begin
        forward_b = 2'b01;
    end
    else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_ex_rs2)) begin
        forward_b = 2'b10;
    end
end

// ============================================================================
// LOAD-USE HAZARD DETECTION
// ============================================================================
wire load_use_hazard;
assign load_use_hazard = id_ex_mem_to_reg              // instruction in EX is a load
                       && (id_ex_rd != 5'd0)           // x0 doesn't count
                       && ( (id_ex_rd == if_id_rs1)    // ID reads rs1 = load's rd
                          ||(id_ex_rd == if_id_rs2) ); // or reads rs2 = load's rd

// ============================================================================
// STALL & FLUSH OUTPUTS
// ============================================================================
// Load-use: stall IF & ID for 1 cycle, bubble into EX
// Branch mispredict: flush IF/ID and ID/EX (2nd cycle handled by flush_delay)
// ============================================================================

// div_busy freezes the entire pipeline (IF, ID, EX all stalled — no flush needed)
assign stall_if   = load_use_hazard || div_busy;
assign stall_id   = load_use_hazard || div_busy;
assign flush_id_ex = (load_use_hazard && !div_busy) || branch_taken;
assign flush_if_id = branch_taken;

endmodule
