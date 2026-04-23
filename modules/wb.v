`timescale 1ns/1ps
// ============================================================================
// Stage 5: Write-Back (WB)
// ============================================================================
// Selects between ALU result and loaded memory data for register writeback.
// For loads, formats the raw DMEM word using funct3 and byte offset:
//   LB/LBU  : sign/zero-extend 8-bit slice
//   LH/LHU  : sign/zero-extend 16-bit slice
//   LW      : full 32-bit word
// ============================================================================
module wb (
    // ---- From MEM/WB register ----
    input  [31:0] alu_result_i,
    input  [31:0] mem_read_data_i,
    input         mem_to_reg_i,      // 1 = write load data, 0 = write ALU result
    input  [ 2:0] funct3_i,
    input  [ 1:0] byte_offset_i,     // byte offset within the word for LB/LH

    // ---- To register file ----
    output [31:0] wb_data_o
);

`include "opcode.vh"

reg [31:0] load_data;

always @(*) begin
    case (funct3_i)
        LB: begin
            case (byte_offset_i)
                2'b00: load_data = {{24{mem_read_data_i[7]}},  mem_read_data_i[7:0]};
                2'b01: load_data = {{24{mem_read_data_i[15]}}, mem_read_data_i[15:8]};
                2'b10: load_data = {{24{mem_read_data_i[23]}}, mem_read_data_i[23:16]};
                2'b11: load_data = {{24{mem_read_data_i[31]}}, mem_read_data_i[31:24]};
                default: load_data = 32'b0;
            endcase
        end
        LBU: begin
            case (byte_offset_i)
                2'b00: load_data = {24'b0, mem_read_data_i[7:0]};
                2'b01: load_data = {24'b0, mem_read_data_i[15:8]};
                2'b10: load_data = {24'b0, mem_read_data_i[23:16]};
                2'b11: load_data = {24'b0, mem_read_data_i[31:24]};
                default: load_data = 32'b0;
            endcase
        end
        LH:  load_data = byte_offset_i[1]
                       ? {{16{mem_read_data_i[31]}}, mem_read_data_i[31:16]}
                       : {{16{mem_read_data_i[15]}}, mem_read_data_i[15:0]};
        LHU: load_data = byte_offset_i[1]
                       ? {16'b0, mem_read_data_i[31:16]}
                       : {16'b0, mem_read_data_i[15:0]};
        LW:  load_data = mem_read_data_i;
        default: load_data = mem_read_data_i;
    endcase
end

assign wb_data_o = mem_to_reg_i ? load_data : alu_result_i;

endmodule
