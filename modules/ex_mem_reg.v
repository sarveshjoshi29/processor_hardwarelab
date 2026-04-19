`timescale 1ns/1ps
// ============================================================================
// EX/MEM Pipeline Register
// ============================================================================
// Holds the outputs of the EX stage for use in the MEM stage.
// On flush (e.g., during division stall), inserts a NOP bubble.
// On stall, holds current values.
// ============================================================================
module ex_mem_reg (
    input         clk,
    input         reset_n,      // active-low reset
    input         stall,        // system-level stall (active-high freeze)
    input         flush,        // 1 = insert NOP bubble (e.g., div stall)

    // ---- Data inputs from EX ----
    input  [31:0] alu_result_i,
    input  [31:0] reg_write_data_i,  // forwarded rs2 (for stores)
    input  [31:0] pc_i,

    // ---- Control inputs from EX ----
    input         mem_write_i,
    input         mem_to_reg_i,
    input         reg_write_en_i,
    input  [ 4:0] rd_i,
    input  [ 2:0] funct3_i,
    input         branch_taken_i,

    // ---- RV32A atomic inputs ----
    input         atomic_lr_i,
    input         atomic_sc_i,

    // ---- Data outputs to MEM ----
    output reg [31:0] alu_result_o,
    output reg [31:0] reg_write_data_o,
    output reg [31:0] pc_o,

    // ---- Control outputs to MEM ----
    output reg        mem_write_o,
    output reg        mem_to_reg_o,
    output reg        reg_write_en_o,
    output reg [ 4:0] rd_o,
    output reg [ 2:0] funct3_o,
    output reg        branch_taken_o,

    // ---- RV32A atomic outputs ----
    output reg        atomic_lr_o,
    output reg        atomic_sc_o
);

always @(posedge clk or negedge reset_n) begin
    if (!reset_n || flush) begin
        // Reset or flush: insert NOP bubble
        alu_result_o     <= 32'b0;
        reg_write_data_o <= 32'b0;
        pc_o             <= 32'b0;
        mem_write_o      <= 1'b0;
        mem_to_reg_o     <= 1'b0;
        reg_write_en_o   <= 1'b0;
        rd_o             <= 5'b0;
        funct3_o         <= 3'b0;
        branch_taken_o   <= 1'b0;
        atomic_lr_o      <= 1'b0;
        atomic_sc_o      <= 1'b0;
    end
    else if (!stall) begin
        alu_result_o     <= alu_result_i;
        reg_write_data_o <= reg_write_data_i;
        pc_o             <= pc_i;
        mem_write_o      <= mem_write_i;
        mem_to_reg_o     <= mem_to_reg_i;
        reg_write_en_o   <= reg_write_en_i;
        rd_o             <= rd_i;
        funct3_o         <= funct3_i;
        branch_taken_o   <= branch_taken_i;
        atomic_lr_o      <= atomic_lr_i;
        atomic_sc_o      <= atomic_sc_i;
    end
end

endmodule
