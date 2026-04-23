`timescale 1ns/1ps
// ============================================================================
// MEM/WB Pipeline Register
// ============================================================================
// Holds the outputs of the MEM stage for use in the WB stage.
// On reset, zeroes all outputs (NOP/safe state).
// On system stall, holds current values.
// ============================================================================
module mem_wb_reg (
    input         clk,
    input         reset_n,      // active-low reset

    input         stall,        // system-level stall (active-high freeze)

    // ---- Data inputs from MEM ----
    input  [31:0] alu_result_i,
    input  [31:0] mem_read_data_i,
    input  [31:0] pc_i,

    // ---- Control inputs from MEM ----
    input         mem_to_reg_i,
    input         reg_write_en_i,
    input  [ 4:0] rd_i,
    input  [ 2:0] funct3_i,
    input  [ 1:0] byte_offset_i,

    // ---- Data outputs to WB ----
    output reg [31:0] alu_result_o,
    output reg [31:0] mem_read_data_o,
    output reg [31:0] pc_o,

    // ---- Control outputs to WB ----
    output reg        mem_to_reg_o,
    output reg        reg_write_en_o,
    output reg [ 4:0] rd_o,
    output reg [ 2:0] funct3_o,
    output reg [ 1:0] byte_offset_o
);

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        alu_result_o    <= 32'b0;
        mem_read_data_o <= 32'b0;
        pc_o            <= 32'b0;
        mem_to_reg_o    <= 1'b0;
        reg_write_en_o  <= 1'b0;
        rd_o            <= 5'b0;
        funct3_o        <= 3'b0;
        byte_offset_o   <= 2'b0;
    end
    else if (!stall) begin
        alu_result_o    <= alu_result_i;
        mem_read_data_o <= mem_read_data_i;
        pc_o            <= pc_i;
        mem_to_reg_o    <= mem_to_reg_i;
        reg_write_en_o  <= reg_write_en_i;
        rd_o            <= rd_i;
        funct3_o        <= funct3_i;
        byte_offset_o   <= byte_offset_i;
    end
end

endmodule
