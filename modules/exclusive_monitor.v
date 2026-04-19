// exclusive_monitor.v
`timescale 1ns/1ps
// ============================================================================
// Global Exclusive Monitor — LR/SC Reservation Tracker for Dual-Core
// ============================================================================
// 2 entries (one per core). Each entry: valid + reserved word address.
//
// LR.W : Sets reservation for the requesting core at the given address.
// SC.W : Checks reservation. If valid and address matches, SC succeeds (fail=0).
//        Otherwise SC fails (fail=1). Reservation is always cleared on SC.
//
// Invalidation:
//   - Cross-core atomic write (sc.w from other core) to same address
//   - Cross-core D-cache writeback that covers the reserved address
//   - A new LR from the same core replaces its old reservation
// ============================================================================
module exclusive_monitor (
    input         clk,
    input         reset,

    // ---- Core 0 atomic interface ----
    input         c0_lr_valid,      // 1 = core 0 is executing lr.w this cycle
    input         c0_sc_valid,      // 1 = core 0 is executing sc.w this cycle
    input  [31:0] c0_addr,          // word-aligned address for lr/sc
    output        c0_sc_fail,       // 1 = sc.w failed for core 0

    // ---- Core 1 atomic interface ----
    input         c1_lr_valid,
    input         c1_sc_valid,
    input  [31:0] c1_addr,
    output        c1_sc_fail,

    // ---- Snoop port: D-cache writebacks (one per cycle after arbitration) ----
    input         snoop_valid,      // 1 = a writeback is happening
    input  [31:0] snoop_addr,       // cache-line-aligned address being written back
    input         snoop_core_id     // 0 = from core 0, 1 = from core 1
);

// ---- Reservation registers ----
reg        resv_valid [0:1];
reg [29:0] resv_addr  [0:1];   // word address = byte_addr[31:2]

// ---- SC fail: combinational check ----
// SC succeeds only if reservation is valid AND address matches.
// Simultaneous SC from both cores to the same address: core 0 wins.
wire c0_sc_ok = resv_valid[0] && (resv_addr[0] == c0_addr[31:2]);
wire c1_sc_ok = resv_valid[1] && (resv_addr[1] == c1_addr[31:2]);
wire simultaneous_sc = c0_sc_valid && c1_sc_valid && c0_sc_ok && c1_sc_ok
                     && (c0_addr[31:2] == c1_addr[31:2]);
assign c0_sc_fail = !c0_sc_ok;
assign c1_sc_fail = !c1_sc_ok || simultaneous_sc;  // core 0 priority

// ---- Writeback snoop: does the writeback cache line overlap a reservation? ----
// Cache line = 16 bytes = 4 words. Line-aligned addr[31:4] matches if
// the reserved word address[29:2] (= byte_addr[31:4]) matches the snoop line.
wire snoop_hits_c0 = resv_valid[0] && (resv_addr[0][29:2] == snoop_addr[31:4]);
wire snoop_hits_c1 = resv_valid[1] && (resv_addr[1][29:2] == snoop_addr[31:4]);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        resv_valid[0] <= 1'b0;
        resv_valid[1] <= 1'b0;
        resv_addr[0]  <= 30'b0;
        resv_addr[1]  <= 30'b0;
    end
    else begin
        // ---- Core 0 LR: set reservation ----
        if (c0_lr_valid) begin
            resv_valid[0] <= 1'b1;
            resv_addr[0]  <= c0_addr[31:2];
        end

        // ---- Core 1 LR: set reservation ----
        if (c1_lr_valid) begin
            resv_valid[1] <= 1'b1;
            resv_addr[1]  <= c1_addr[31:2];
        end

        // ---- Core 0 SC: always clear core 0's reservation ----
        // NOTE: SC has priority over LR — if both fire same cycle, SC clear wins
        //       (last non-blocking assignment in the same always block wins)
        if (c0_sc_valid)
            resv_valid[0] <= 1'b0;

        // ---- Core 1 SC: always clear core 1's reservation ----
        if (c1_sc_valid)
            resv_valid[1] <= 1'b0;

        // ---- Cross-core invalidation from SC ----
        // If core 0 does a successful SC, invalidate core 1 if same address
        if (c0_sc_valid && !c0_sc_fail &&
            resv_valid[1] && (resv_addr[1] == c0_addr[31:2]))
            resv_valid[1] <= 1'b0;

        if (c1_sc_valid && !c1_sc_fail &&
            resv_valid[0] && (resv_addr[0] == c1_addr[31:2]))
            resv_valid[0] <= 1'b0;

        // ---- Snoop invalidation from D-cache writebacks ----
        // Writeback from core 0 can invalidate core 1's reservation (and vice versa)
        if (snoop_valid && !snoop_core_id && snoop_hits_c1)
            resv_valid[1] <= 1'b0;
        if (snoop_valid && snoop_core_id && snoop_hits_c0)
            resv_valid[0] <= 1'b0;
    end
end

endmodule
