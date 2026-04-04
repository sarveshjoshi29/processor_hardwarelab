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
reg [31:0] prev_fetch_pc;
reg [63:0] instr_type;

initial begin
   ctr = 32'b0;
   prev_fetch_pc = 32'hFFFFFFFF;
   #1;
   $display("\n============================================================");
   $display("   🚀 STARTING RISC-V PIPELINE SIMULATION");
   $display("============================================================\n");
end

always @(posedge clk) begin
   if (!reset) begin
      ctr <= ctr + 1;

      // Decode the instruction type for the current cycle
      if (inst_word_out === 32'hxxxxxxxx) begin
         instr_type = "UNKNOWN";
      end else begin
         case (inst_word_out[6:0])
            7'b0110111: instr_type = "LUI";
            7'b0010111: instr_type = "AUIPC";
            7'b1101111: instr_type = "JAL";
            7'b1100111: instr_type = "JALR";
            7'b1100011: instr_type = "BRANCH";
            7'b0000011: instr_type = "LOAD";
            7'b0100011: instr_type = "STORE";
            7'b0010011: instr_type = "ARITHI";
            7'b0110011: instr_type = (inst_word_out[31:25] == 7'b0000001) ? "MULDIV" : "ARITHR";
            default: instr_type = "UNKNOWN";
         endcase
         if (inst_word_out == 32'h00000000 || inst_word_out == 32'h00000013) begin
            instr_type = "NOP";
         end
      end

      // ALWAYS display the current instruction being processed in this cycle
      $display("[%9t] ➡️  PROCESS      | Cycle: %-5d | Fetch PC: 0x%08h | Instr: 0x%08h (%0s)", 
               $time, ctr, inst_fetch_pc, inst_word_out, instr_type);

      // Log Memory Writes (These reflect actual computed side effects)
      if (dmem_write_ready) begin
         $display("[%9t] 💾 MEMORY WRITE | Cycle: %-5d | Data Written: %10d (0x%08h) | Instr: %08h", 
                  $time, ctr, dmem_write_data, dmem_write_data, inst_word_out);
      end
      
      // End Of Program Condition (Return instruction 'ret' / 'jalr x0, 0(x1)')
      if (inst_word_out == 32'h00008067 || inst_word_out == 32'h00000067) begin
         $display("\n============================================================");
         $display("   ✅ SIMULATION COMPLETED SUCCESSFULLY!");
         $display("------------------------------------------------------------");
         $display("   ⏱️  Total Clock Cycles : %0d", ctr);
         $display("   ⏳ Final Sim Time      : %0t", $time);
         $display("============================================================\n");
         $finish;
      end
      
      prev_fetch_pc <= inst_fetch_pc;
   end
end

endmodule
