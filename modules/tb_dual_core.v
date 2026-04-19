`timescale 1ns / 1ps
// ============================================================================
// Testbench — Dual-Core RV32IMA (Phase 4.5)
// ============================================================================
// Both cores share instruction memory (core 0 @ 0x000, core 1 @ 0x200).
// Monitors store outputs from both cores.
// ============================================================================

`include "dual_core_top.v"

module tb_dual_core;

////////////////////////////////////////////////////////////
// CLOCK & RESET
////////////////////////////////////////////////////////////
reg clk;
reg reset;

// 100 MHz clock
initial begin
   clk = 0;
   forever #5 clk = ~clk;
end

// Reset sequence (active high)
initial begin
   reset = 1;
   #20;
   reset = 0;
end

////////////////////////////////////////////////////////////
// MONITORING WIRES
////////////////////////////////////////////////////////////
wire        c0_exception;
wire [31:0] c0_pc_out, c0_inst_fetch_pc, c0_inst_word_out;
wire        c0_dmem_write_ready;
wire [31:0] c0_dmem_write_data;
wire [ 3:0] c0_dmem_write_byte;

wire        c1_exception;
wire [31:0] c1_pc_out, c1_inst_fetch_pc, c1_inst_word_out;
wire        c1_dmem_write_ready;
wire [31:0] c1_dmem_write_data;
wire [ 3:0] c1_dmem_write_byte;

////////////////////////////////////////////////////////////
// DUT : DUAL-CORE RV32IMA
////////////////////////////////////////////////////////////
dual_core_top #(
    .RESET_C0 (32'h0000_0000),
    .RESET_C1 (32'h0000_0200)
) DUT (
   .clk              (clk),
   .reset            (reset),
   .stall            (1'b0),

   .c0_exception     (c0_exception),
   .c0_pc_out        (c0_pc_out),
   .c0_inst_fetch_pc (c0_inst_fetch_pc),
   .c0_inst_word_out (c0_inst_word_out),
   .c0_dmem_write_ready(c0_dmem_write_ready),
   .c0_dmem_write_data (c0_dmem_write_data),
   .c0_dmem_write_byte (c0_dmem_write_byte),

   .c1_exception     (c1_exception),
   .c1_pc_out        (c1_pc_out),
   .c1_inst_fetch_pc (c1_inst_fetch_pc),
   .c1_inst_word_out (c1_inst_word_out),
   .c1_dmem_write_ready(c1_dmem_write_ready),
   .c1_dmem_write_data (c1_dmem_write_data),
   .c1_dmem_write_byte (c1_dmem_write_byte)
);

////////////////////////////////////////////////////////////
// SIMULATION TIMEOUT
////////////////////////////////////////////////////////////
initial begin
   $dumpfile("dual_core_waveforms.vcd");
   $dumpvars(0, tb_dual_core);
   #20000000;
   $display("TIMEOUT: simulation exceeded 200000 time units");
   $finish;
end

////////////////////////////////////////////////////////////
// TERMINAL OUTPUT — monitor both cores
////////////////////////////////////////////////////////////
reg [31:0] ctr;
reg c0_done, c1_done;

initial begin
   ctr = 32'b0;
   c0_done = 1'b0;
   c1_done = 1'b0;
end

always @(posedge clk) begin
   ctr <= ctr + 1;

   // Core 0 stores
   if (c0_dmem_write_ready) begin
      $display("C0 time: %17t ,result = %0d, instruction = %h",
               $time, c0_dmem_write_data, c0_inst_word_out);
   end

   // Core 1 stores
   if (c1_dmem_write_ready) begin
      $display("C1 time: %17t ,result = %0d, instruction = %h",
               $time, c1_dmem_write_data, c1_inst_word_out);
   end


   // Core 0 end-of-program
   if (!c0_done && (c0_inst_word_out == 32'h0000006f || c0_inst_word_out == 32'h00008067 || c0_inst_word_out == 32'h00000067 || c0_inst_word_out == 32'hffdff06f )) begin
      $display("--- Core 0 finished at time %0t, cycles = %0d ---", $time, ctr);
      c0_done <= 1'b1;
   end

   // Core 1 end-of-program
   if (!c1_done && (c1_inst_word_out == 32'h0000006f || c1_inst_word_out == 32'h00008067 || c1_inst_word_out == 32'h00000067 || c1_inst_word_out == 32'hffdff06f)) begin
      $display("--- Core 1 finished at time %0t, cycles = %0d ---", $time, ctr);
      c1_done <= 1'b1;
   end

   // Both cores done
   if (c0_done && c1_done) begin
      $display("============================================");
      $display("Both cores finished. Total cycles = %0d", ctr);
      $display("============================================");
      $finish;
   end
end

endmodule
