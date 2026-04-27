// bus_arbiter.v
`timescale 1ns/1ps
// ============================================================================
// Bus Arbiter — Dual-Core → Shared Memory Multiplexer
// ============================================================================
// Arbitrates four independent memory port types between two cores:
//   1. IC fill  (I-cache miss → instr_mem read)
//   2. DC fill  (D-cache miss → data_mem read)
//   3. DC wb    (D-cache dirty eviction → data_mem write)
//   4. Atomic   (lr.w / sc.w → data_mem word-level port)
//
// Each port type uses a lock-based arbiter:
//   IDLE: accept new request (core 0 priority on tie)
//   BUSY: hold grant until memory asserts ready
//   DONE: 1-cycle cooldown, then back to IDLE
//
// Core 0 has strict priority on simultaneous requests.
// ============================================================================
module bus_arbiter (
    input         clk,
    input         reset,

    // ========================================================================
    // Core 0 — I-cache fill port
    // ========================================================================
    input         c0_ic_req,
    input  [31:0] c0_ic_addr,
    output [127:0] c0_ic_rdata,
    output        c0_ic_ready,

    // Core 1 — I-cache fill port
    input         c1_ic_req,
    input  [31:0] c1_ic_addr,
    output [127:0] c1_ic_rdata,
    output        c1_ic_ready,

    // Shared instr_mem port
    output        mem_ic_req,
    output [31:0] mem_ic_addr,
    input  [127:0] mem_ic_rdata,
    input         mem_ic_ready,

    // ========================================================================
    // Core 0 — D-cache fill port (read)
    // ========================================================================
    input         c0_dc_fill_req,
    input  [31:0] c0_dc_fill_addr,
    output [127:0] c0_dc_fill_rdata,
    output        c0_dc_fill_ready,

    // Core 1 — D-cache fill port (read)
    input         c1_dc_fill_req,
    input  [31:0] c1_dc_fill_addr,
    output [127:0] c1_dc_fill_rdata,
    output        c1_dc_fill_ready,

    // Shared data_mem fill port
    output        mem_dc_fill_req,
    output [31:0] mem_dc_fill_addr,
    input  [127:0] mem_dc_fill_rdata,
    input         mem_dc_fill_ready,

    // ========================================================================
    // Core 0 — D-cache writeback port (write)
    // ========================================================================
    input         c0_dc_wb_req,
    input  [31:0] c0_dc_wb_addr,
    input  [127:0] c0_dc_wb_wdata,
    output        c0_dc_wb_ready,

    // Core 1 — D-cache writeback port (write)
    input         c1_dc_wb_req,
    input  [31:0] c1_dc_wb_addr,
    input  [127:0] c1_dc_wb_wdata,
    output        c1_dc_wb_ready,

    // Shared data_mem writeback port
    output        mem_dc_wb_req,
    output [31:0] mem_dc_wb_addr,
    output [127:0] mem_dc_wb_wdata,
    input         mem_dc_wb_ready,

    // ========================================================================
    // Core 0 — Atomic port (lr.w / sc.w)
    // ========================================================================
    input         c0_atomic_req,
    input         c0_atomic_we,
    input  [31:0] c0_atomic_addr,
    input  [31:0] c0_atomic_wdata,
    output [31:0] c0_atomic_rdata,
    output        c0_atomic_ready,

    // Core 1 — Atomic port
    input         c1_atomic_req,
    input         c1_atomic_we,
    input  [31:0] c1_atomic_addr,
    input  [31:0] c1_atomic_wdata,
    output [31:0] c1_atomic_rdata,
    output        c1_atomic_ready,

    // Shared data_mem atomic port
    output        mem_atomic_req,
    output        mem_atomic_we,
    output [31:0] mem_atomic_addr,
    output [31:0] mem_atomic_wdata,
    input  [31:0] mem_atomic_rdata,
    input         mem_atomic_ready,

    // ========================================================================
    // Snoop helper: which core owns the active writeback transaction
    // ========================================================================
    output reg    dc_wb_grant   // 0 = core 0 writeback, 1 = core 1 writeback
);

// ============================================================================
// Arbiter state machine (shared for each port type)
// ============================================================================
localparam ARB_IDLE = 2'd0,
           ARB_BUSY = 2'd1,
           ARB_DONE = 2'd2;

// ============================================================================
// 1. I-Cache Fill Arbiter
// ============================================================================
reg [1:0] ic_arb_state;
reg       ic_grant;  // 0 = core 0 owns, 1 = core 1 owns

always @(posedge clk or posedge reset) begin
    if (reset) begin
        ic_arb_state <= ARB_IDLE;
        ic_grant     <= 1'b0;
    end else begin
        case (ic_arb_state)
            ARB_IDLE: begin
                if (c0_ic_req) begin
                    ic_grant     <= 1'b0;
                    ic_arb_state <= ARB_BUSY;
                end
                else if (c1_ic_req) begin
                    ic_grant     <= 1'b1;
                    ic_arb_state <= ARB_BUSY;
                end
            end
            ARB_BUSY: begin
                if (mem_ic_ready)
                    ic_arb_state <= ARB_DONE;
            end
            ARB_DONE: begin
                ic_arb_state <= ARB_IDLE;
            end
        endcase
    end
end

// Forward request to memory only during IDLE→BUSY transition (1 cycle)
// After that, memory latches the address internally.
assign mem_ic_req  = (ic_arb_state == ARB_IDLE) &&
                     (c0_ic_req || c1_ic_req);
assign mem_ic_addr = (ic_arb_state == ARB_IDLE)
                   ? (c0_ic_req ? c0_ic_addr : c1_ic_addr)
                   : 32'b0;

// Route data and ready back to the granted core
assign c0_ic_rdata = mem_ic_rdata;
assign c1_ic_rdata = mem_ic_rdata;
assign c0_ic_ready = mem_ic_ready && !ic_grant;
assign c1_ic_ready = mem_ic_ready &&  ic_grant;

// ============================================================================
// 2. D-Cache Fill Arbiter
// ============================================================================
reg [1:0] dc_fill_arb_state;
reg       dc_fill_grant;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        dc_fill_arb_state <= ARB_IDLE;
        dc_fill_grant     <= 1'b0;
    end else begin
        case (dc_fill_arb_state)
            ARB_IDLE: begin
                if (c0_dc_fill_req) begin
                    dc_fill_grant     <= 1'b0;
                    dc_fill_arb_state <= ARB_BUSY;
                end
                else if (c1_dc_fill_req) begin
                    dc_fill_grant     <= 1'b1;
                    dc_fill_arb_state <= ARB_BUSY;
                end
            end
            ARB_BUSY: begin
                if (mem_dc_fill_ready)
                    dc_fill_arb_state <= ARB_DONE;
            end
            ARB_DONE: begin
                dc_fill_arb_state <= ARB_IDLE;
            end
        endcase
    end
end

assign mem_dc_fill_req  = (dc_fill_arb_state == ARB_IDLE) &&
                          (c0_dc_fill_req || c1_dc_fill_req);
assign mem_dc_fill_addr = (dc_fill_arb_state == ARB_IDLE)
                        ? (c0_dc_fill_req ? c0_dc_fill_addr : c1_dc_fill_addr)
                        : 32'b0;

assign c0_dc_fill_rdata = mem_dc_fill_rdata;
assign c1_dc_fill_rdata = mem_dc_fill_rdata;
assign c0_dc_fill_ready = mem_dc_fill_ready && !dc_fill_grant;
assign c1_dc_fill_ready = mem_dc_fill_ready &&  dc_fill_grant;

// ============================================================================
// 3. D-Cache Writeback Arbiter (registered data path)
// ============================================================================
// The 128-bit wb_wdata is registered on the IDLE→BUSY transition to cut
// combinational fanout and reduce routing pressure on the Artix-7 fabric.
reg [1:0]   dc_wb_arb_state;
reg [31:0]  dc_wb_addr_r;
reg [127:0] dc_wb_wdata_r;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        dc_wb_arb_state <= ARB_IDLE;
        dc_wb_grant     <= 1'b0;
        dc_wb_addr_r    <= 32'b0;
        dc_wb_wdata_r   <= 128'b0;
    end else begin
        case (dc_wb_arb_state)
            ARB_IDLE: begin
                if (c0_dc_wb_req) begin
                    dc_wb_grant     <= 1'b0;
                    dc_wb_addr_r    <= c0_dc_wb_addr;
                    dc_wb_wdata_r   <= c0_dc_wb_wdata;
                    dc_wb_arb_state <= ARB_BUSY;
                end
                else if (c1_dc_wb_req) begin
                    dc_wb_grant     <= 1'b1;
                    dc_wb_addr_r    <= c1_dc_wb_addr;
                    dc_wb_wdata_r   <= c1_dc_wb_wdata;
                    dc_wb_arb_state <= ARB_BUSY;
                end
            end
            ARB_BUSY: begin
                if (mem_dc_wb_ready)
                    dc_wb_arb_state <= ARB_DONE;
            end
            ARB_DONE: begin
                dc_wb_arb_state <= ARB_IDLE;
            end
        endcase
    end
end

assign mem_dc_wb_req   = (dc_wb_arb_state == ARB_BUSY);
assign mem_dc_wb_addr  = dc_wb_addr_r;
assign mem_dc_wb_wdata = dc_wb_wdata_r;

assign c0_dc_wb_ready = mem_dc_wb_ready && !dc_wb_grant;
assign c1_dc_wb_ready = mem_dc_wb_ready &&  dc_wb_grant;

// ============================================================================
// 4. Atomic Port Arbiter
// ============================================================================
reg [1:0] atomic_arb_state;
reg       atomic_grant;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        atomic_arb_state <= ARB_IDLE;
        atomic_grant     <= 1'b0;
    end else begin
        case (atomic_arb_state)
            ARB_IDLE: begin
                if (c0_atomic_req) begin
                    atomic_grant     <= 1'b0;
                    atomic_arb_state <= ARB_BUSY;
                end
                else if (c1_atomic_req) begin
                    atomic_grant     <= 1'b1;
                    atomic_arb_state <= ARB_BUSY;
                end
            end
            ARB_BUSY: begin
                if (mem_atomic_ready)
                    atomic_arb_state <= ARB_DONE;
            end
            ARB_DONE: begin
                atomic_arb_state <= ARB_IDLE;
            end
        endcase
    end
end

assign mem_atomic_req   = (atomic_arb_state == ARB_IDLE) &&
                          (c0_atomic_req || c1_atomic_req);
assign mem_atomic_we    = (atomic_arb_state == ARB_IDLE)
                        ? (c0_atomic_req ? c0_atomic_we : c1_atomic_we)
                        : 1'b0;
assign mem_atomic_addr  = (atomic_arb_state == ARB_IDLE)
                        ? (c0_atomic_req ? c0_atomic_addr : c1_atomic_addr)
                        : 32'b0;
assign mem_atomic_wdata = (atomic_arb_state == ARB_IDLE)
                        ? (c0_atomic_req ? c0_atomic_wdata : c1_atomic_wdata)
                        : 32'b0;

assign c0_atomic_rdata = mem_atomic_rdata;
assign c1_atomic_rdata = mem_atomic_rdata;
assign c0_atomic_ready = mem_atomic_ready && !atomic_grant;
assign c1_atomic_ready = mem_atomic_ready &&  atomic_grant;

endmodule
