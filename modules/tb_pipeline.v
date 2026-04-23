`timescale 1ns / 1ps
// ============================================================================
// Testbench — 5-Stage RV32IM Pipeline (Phase 4: L1 Caches)
// ============================================================================
// Memory (instr_mem + data_mem) and caches are now instantiated INSIDE pipe.
// This testbench only needs: clk, reset, and monitoring outputs.
// ============================================================================

module tb_pipeline;

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
// MONITORING WIRES (outputs of pipe)
////////////////////////////////////////////////////////////
wire [31:0] inst_fetch_pc;
wire [31:0] inst_word_out;     // instruction in IF/ID
wire        dmem_write_ready;  // store committed (gated: no cache-miss duplicates)
wire [31:0] dmem_write_data;
wire [ 3:0] dmem_write_byte;
wire        exception;
wire [31:0] pc_out;

////////////////////////////////////////////////////////////
// DUT : 5-STAGE PIPELINE CPU (caches + memory inside)
////////////////////////////////////////////////////////////
pipe DUT (
   .clk             (clk),
   .reset           (reset),
   .stall           (1'b0),
   .exception       (exception),
   .pc_out          (pc_out),
   .inst_fetch_pc   (inst_fetch_pc),
   .inst_word_out   (inst_word_out),
   .dmem_write_ready(dmem_write_ready),
   .dmem_write_data (dmem_write_data),
   .dmem_write_byte (dmem_write_byte)
);

////////////////////////////////////////////////////////////
// SIMULATION TIMEOUT
////////////////////////////////////////////////////////////
initial begin
   $dumpfile("pipeline_waveforms.vcd");
   $dumpvars(0, tb_pipeline);
   #50000;
   $finish;
end

////////////////////////////////////////////////////////////
// TERMINAL OUTPUT
////////////////////////////////////////////////////////////
reg [31:0] ctr;

initial begin
   ctr = 32'b0;
   #1;
   $display("time: %17t ,result = %10d", 0, 0);
end

always @(posedge clk) begin
   ctr <= ctr + 1;

   if (dmem_write_ready) begin
      $display("time: %17t ,result = %0d, instruction = %h",
               $time, dmem_write_data, inst_word_out);
   end
   else if (inst_word_out == 32'h00008067 || inst_word_out == 32'h00000067) begin
      $display("-------------------------------------------");
      $display("TIME: %0t | End of Program Reached! Number of cycles = %0d ", $time, ctr);
      $display("-------------------------------------------");
      $finish;
   end
   else begin
      $display("next_pc = %08h , instruction = %h", inst_fetch_pc, inst_word_out);
   end
end

endmodule
