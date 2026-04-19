// csr_perf.v
`timescale 1ns/1ps
// ============================================================================
// Hardware Performance Counter CSR Unit — Phase 5
// ============================================================================
// Per-core performance counters mapped to CSR addresses 0xC00–0xC06.
// Supports CSRRW, CSRRS, CSRRC (and immediate variants).
//
// Counters:
//   0xC00 cycle    — total clock cycles since reset
//   0xC01 time     — alias for cycle
//   0xC02 instret  — instructions retired
//   0xC03 icmiss   — I-cache misses (custom)
//   0xC04 dcmiss   — D-cache misses (custom)
//   0xC05 brmiss   — branch mispredicts (custom)
//   0xC06 stalls   — pipeline stall cycles (custom)
//
// Read port: combinational (old value returned for rd)
// Write port: clocked, gated by wen
// ============================================================================
module csr_perf (
    input         clk,
    input         reset,

    // ---- Event inputs (active-high pulses) ----
    input         evt_cycle,         // 1 every cycle (tie to 1'b1)
    input         evt_instret,       // 1 when an instruction retires
    input         evt_icache_miss,   // rising edge of icache miss
    input         evt_dcache_miss,   // rising edge of dcache miss
    input         evt_br_mispredict, // branch mispredict pulse
    input         evt_stall,         // pipeline stall this cycle

    // ---- CSR read port (combinational) ----
    input  [11:0] csr_addr,
    output reg [31:0] csr_rdata,

    // ---- CSR write port (clocked) ----
    input         csr_wen,           // 1 = write CSR this cycle
    input  [1:0]  csr_op,            // 01=RW, 10=RS(set), 11=RC(clear)
    input  [31:0] csr_wdata          // write data (rs1 or zimm)
);

`include "opcode.vh"

// ---- Counter registers ----
reg [31:0] ctr_cycle;
reg [31:0] ctr_instret;
reg [31:0] ctr_icmiss;
reg [31:0] ctr_dcmiss;
reg [31:0] ctr_brmiss;
reg [31:0] ctr_stalls;

// ---- Combinational read ----
always @(*) begin
    case (csr_addr)
        CSR_CYCLE,
        CSR_TIME:    csr_rdata = ctr_cycle;
        CSR_INSTRET: csr_rdata = ctr_instret;
        CSR_ICMISS:  csr_rdata = ctr_icmiss;
        CSR_DCMISS:  csr_rdata = ctr_dcmiss;
        CSR_BRMISS:  csr_rdata = ctr_brmiss;
        CSR_STALLS:  csr_rdata = ctr_stalls;
        default:     csr_rdata = 32'h0;
    endcase
end

// ---- Compute new value for CSR writes ----
// The old value is read combinationally above; the new value depends on csr_op.
wire [31:0] csr_new_val = (csr_op == 2'b01) ? csr_wdata                  // RW
                        : (csr_op == 2'b10) ? (csr_rdata | csr_wdata)     // RS
                        : (csr_op == 2'b11) ? (csr_rdata & ~csr_wdata)    // RC
                        : csr_rdata;

// ---- Sequential update: event counting + CSR writes ----
always @(posedge clk or posedge reset) begin
    if (reset) begin
        ctr_cycle   <= 32'h0;
        ctr_instret <= 32'h0;
        ctr_icmiss  <= 32'h0;
        ctr_dcmiss  <= 32'h0;
        ctr_brmiss  <= 32'h0;
        ctr_stalls  <= 32'h0;
    end
    else begin
        // ---- Increment from events (always active) ----
        ctr_cycle   <= ctr_cycle   + {31'b0, evt_cycle};
        ctr_instret <= ctr_instret + {31'b0, evt_instret};
        ctr_icmiss  <= ctr_icmiss  + {31'b0, evt_icache_miss};
        ctr_dcmiss  <= ctr_dcmiss  + {31'b0, evt_dcache_miss};
        ctr_brmiss  <= ctr_brmiss  + {31'b0, evt_br_mispredict};
        ctr_stalls  <= ctr_stalls  + {31'b0, evt_stall};

        // ---- CSR write overrides the increment ----
        if (csr_wen) begin
            case (csr_addr)
                CSR_CYCLE,
                CSR_TIME:    ctr_cycle   <= csr_new_val;
                CSR_INSTRET: ctr_instret <= csr_new_val;
                CSR_ICMISS:  ctr_icmiss  <= csr_new_val;
                CSR_DCMISS:  ctr_dcmiss  <= csr_new_val;
                CSR_BRMISS:  ctr_brmiss  <= csr_new_val;
                CSR_STALLS:  ctr_stalls  <= csr_new_val;
                default: ;
            endcase
        end
    end
end

endmodule
