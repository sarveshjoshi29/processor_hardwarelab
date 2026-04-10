`timescale 1ns/1ps
// ============================================================================
// Stage 4: Memory Access (MEM)
// ============================================================================
// Handles data memory reads and writes.
// For stores: generates byte-enable strobes and replicates write data.
// For loads: passes raw DMEM data to MEM/WB register for formatting in WB.
// ============================================================================
module mem_stage (
    // ---- From EX/MEM register ----
    input  [31:0] alu_result_i,       // effective address (for loads/stores)
    input  [31:0] reg_write_data_i,   // rs2 value (data to store)
    input         mem_write_i,        // 1 = store instruction
    input         mem_to_reg_i,       // 1 = load instruction
    input  [ 2:0] funct3_i,           // LB/LH/LW/LBU/LHU or SB/SH/SW

    // ---- From data memory ----
    input  [31:0] dmem_read_data_i,

    // ---- To data memory ----
    output [31:0] dmem_addr_o,
    output [31:0] dmem_write_data_o,
    output [ 3:0] dmem_write_byte_o,
    output        dmem_write_en_o,
    output        dmem_read_en_o,

    // ---- To MEM/WB register ----
    output [31:0] mem_read_data_o,
    output [ 1:0] byte_offset_o       // byte offset for load formatting in WB
);

`include "opcode.vh"

// ---- Address and read/write enables ----
assign dmem_addr_o    = alu_result_i;
assign dmem_write_en_o = mem_write_i;
assign dmem_read_en_o  = mem_to_reg_i;
assign mem_read_data_o = dmem_read_data_i;
assign byte_offset_o   = alu_result_i[1:0];

// ---- Store data replication and byte-enable generation ----
reg [31:0] write_data;
reg [ 3:0] write_byte;

always @(*) begin
    case (funct3_i)
        SB: begin
            write_data = {4{reg_write_data_i[7:0]}};
            case (alu_result_i[1:0])
                2'b00: write_byte = 4'b0001;
                2'b01: write_byte = 4'b0010;
                2'b10: write_byte = 4'b0100;
                2'b11: write_byte = 4'b1000;
                default: write_byte = 4'b0000;
            endcase
        end
        SH: begin
            write_data = {2{reg_write_data_i[15:0]}};
            write_byte = alu_result_i[1] ? 4'b1100 : 4'b0011;
        end
        SW: begin
            write_data = reg_write_data_i;
            write_byte = 4'b1111;
        end
        default: begin
            write_data = reg_write_data_i;
            write_byte = 4'b0000;
        end
    endcase
end

assign dmem_write_data_o = write_data;
assign dmem_write_byte_o = write_byte;

endmodule
