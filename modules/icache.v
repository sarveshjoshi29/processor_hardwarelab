`timescale 1ns/1ps
// ============================================================================
// L1 Instruction Cache — 256B Direct-Mapped, Read-Only
// ============================================================================
// Geometry  : 16 sets × 16-byte lines (4 words), direct-mapped
// Address   : tag[31:8] | index[7:4] | word_off[3:2] | byte_off[1:0]
// Interface : Registered output (1-cycle hit latency, identical to sync IMEM).
//             Asserts icache_stall on miss; deasserts the cycle after fill.
// Miss path : IDLE → FETCH (wait mem_ready) → IDLE
// ============================================================================
module icache #(
    parameter MEM_CYCLES = 4   // unused here; latency is in instr_mem
)(
    input         clk,
    input         reset,

    // IF stage interface
    input  [31:0] fetch_pc,     // byte address of instruction to fetch
    input         pipeline_stall, // 1 = pipeline frozen (e.g. D-cache miss)
    output [31:0] instr,        // instruction word (registered, 1-cycle hit)
    output        icache_stall, // 1 = miss — stall entire pipeline

    // Main memory fill port (cache-line granularity)
    output reg        mem_req,  // request a cache-line fill
    output reg [31:0] mem_addr, // cache-line-aligned byte address
    input     [127:0] mem_rdata,// {word@addr+12, word@addr+8, word@addr+4, word@addr}
    input             mem_ready // pulses 1 cycle when fill data is valid
);

// ---- Cache arrays: 16 lines ----
// tag_arr / data_arr are never reset (contents are guarded by `valid`),
// so they are forced to distributed RAM to avoid thousands of FFs and
// to stop Vivado from hunting for an impossible BRAM mapping during
// place/route.
reg         valid    [0:15];
(* ram_style = "distributed" *)
reg  [23:0] tag_arr  [0:15];
(* ram_style = "distributed" *)
reg [127:0] data_arr [0:15];

// ---- Address fields ----
wire  [1:0] woff = fetch_pc[3:2];   // word offset within line
wire  [3:0] idx  = fetch_pc[7:4];   // set index (4 bits for 16 sets)
wire [23:0] ptag = fetch_pc[31:8];  // tag (24 bits)

// ---- Hit detection (combinational) ----
wire hit = valid[idx] && (tag_arr[idx] == ptag);

// ---- Instruction word mux (combinational from cache line) ----
wire [31:0] word_comb =
    (woff == 2'b00) ? data_arr[idx][31:0]   :
    (woff == 2'b01) ? data_arr[idx][63:32]  :
    (woff == 2'b10) ? data_arr[idx][95:64]  :
                      data_arr[idx][127:96];

// ---- Registered output — matches synchronous IMEM timing ----
// Captured on every hit cycle; pipeline stalls on miss so this stays stable.
reg [31:0] instr_r;
always @(posedge clk or posedge reset) begin
    if (reset)
        instr_r <= 32'h0;
    else if (hit && !pipeline_stall)
        instr_r <= word_comb;
end
assign instr = instr_r;

// ---- Stall: asserted while the line is not yet in cache ----
// Drops the cycle after mem_ready fires (valid/data written by posedge).
assign icache_stall = !hit;

// ============================================================================
// Fill state machine
// ============================================================================
localparam IDLE  = 1'b0;
localparam FETCH = 1'b1;
reg state;

// Extract tag and data arrays writes into a pure synchronous block
always @(posedge clk) begin
    if (state == FETCH && mem_ready) begin
        tag_arr[idx]  <= ptag;
        data_arr[idx] <= mem_rdata;
    end
end

integer j;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        for (j = 0; j < 16; j = j + 1)
            valid[j] <= 1'b0;
        mem_req  <= 1'b0;
        mem_addr <= 32'b0;
        state    <= IDLE;
    end else begin
        case (state)
            IDLE: begin
                if (!hit) begin
                    // Miss — request the cache line
                    mem_req  <= 1'b1;
                    mem_addr <= {fetch_pc[31:4], 4'b0};
                    state    <= FETCH;
                end
            end

            FETCH: begin
                if (mem_ready) begin
                    // Refill: write line into cache
                    valid[idx]    <= 1'b1;
                    mem_req       <= 1'b0;
                    state         <= IDLE;
                    // hit becomes 1 combinationally after this posedge;
                    // icache_stall drops; pipeline advances next cycle.
                end
            end
        endcase
    end
end

endmodule
