`timescale 1ns/1ps
// ============================================================================
// L1 Data Cache — 1KB Direct-Mapped, Write-Back / Write-Allocate
// ============================================================================
// Geometry  : 64 sets × 16-byte lines (4 words), direct-mapped
// Address   : tag[31:10] | index[9:4] | word_off[3:2] | byte_off[1:0]
// Write policy  : write-back  (dirty lines evicted to memory only when replaced)
// Allocate policy: write-allocate (write miss → fetch line, then apply write)
//
// FSM states:
//   IDLE      — check hit/miss each cycle
//   WRITEBACK — evict dirty line to memory, then transition to FETCH
//   FETCH     — fill new line from memory, apply pending write if needed
//
// dcache_stall = 1 whenever the CPU must wait (miss in progress or state≠IDLE).
// ============================================================================
module dcache #(
    parameter MEM_CYCLES = 4   // unused here; latency lives in data_mem
)(
    input         clk,
    input         reset,

    // MEM-stage interface
    input         req,          // 1 = memory access this cycle
    input         we,           // 1 = write, 0 = read
    input  [ 3:0] be,           // byte enables (SB/SH/SW)
    input  [31:0] addr,         // byte address
    input  [31:0] wdata,        // write data (word)
    output [31:0] rdata,        // read data (combinational from cache line)
    output        dcache_stall, // 1 = miss in progress

    // Main memory fill port (cache-line read on miss)
    output reg        fill_req,
    output reg [31:0] fill_addr,  // cache-line-aligned
    input     [127:0] fill_rdata, // {word@addr+12, ..., word@addr}
    input             fill_ready,

    // Main memory writeback port (dirty eviction)
    output reg         wb_req,
    output reg [31:0]  wb_addr,   // cache-line-aligned
    output reg [127:0] wb_wdata,  // dirty line to write
    input              wb_ready
);

// ---- Cache arrays: 64 lines ----
reg         valid    [0:63];
reg         dirty    [0:63];
reg  [21:0] tag_arr  [0:63];
reg [127:0] data_arr [0:63];

// ---- Address fields (from live CPU addr) ----
wire  [1:0] woff = addr[3:2];
wire  [5:0] idx  = addr[9:4];
wire [21:0] ptag = addr[31:10];

// ---- Hit detection (combinational) ----
wire hit = valid[idx] && (tag_arr[idx] == ptag);

// ---- Read data (combinational) ----
wire [31:0] rdata_comb =
    (woff == 2'b00) ? data_arr[idx][31:0]   :
    (woff == 2'b01) ? data_arr[idx][63:32]  :
    (woff == 2'b10) ? data_arr[idx][95:64]  :
                      data_arr[idx][127:96];
assign rdata = rdata_comb;

// ---- Stall: miss in IDLE, or any non-IDLE state ----
localparam IDLE      = 2'd0;
localparam WRITEBACK = 2'd1;
localparam FETCH     = 2'd2;
reg [1:0] state;

// ---- Miss-just-resolved flag (suppresses redundant replay for 1 cycle) ----
reg        miss_just_resolved;

assign dcache_stall = (state != IDLE) || (req && !hit && !miss_just_resolved);

// ---- Saved request (latched at start of miss) ----
reg [31:0] saved_addr;
reg [31:0] saved_wdata;
reg  [3:0] saved_be;
reg        saved_we;

// ---- Registered pending new_line for FETCH completion ----
reg [127:0] new_line;

// ============================================================================
// Helper: apply a word write (with byte-enable) into a 128-bit cache line.
// Returns the updated line.
// ============================================================================
function [127:0] apply_write;
    input [127:0] line;
    input  [1:0]  wo;      // word offset
    input [31:0]  wd;      // write data
    input  [3:0]  wbe;     // byte enables
    reg [31:0] w;
    begin
        case (wo)
            2'b00: w = line[31:0];
            2'b01: w = line[63:32];
            2'b10: w = line[95:64];
            2'b11: w = line[127:96];
        endcase
        if (wbe[0]) w[ 7: 0] = wd[ 7: 0];
        if (wbe[1]) w[15: 8] = wd[15: 8];
        if (wbe[2]) w[23:16] = wd[23:16];
        if (wbe[3]) w[31:24] = wd[31:24];
        apply_write = line;
        case (wo)
            2'b00: apply_write[31:0]   = w;
            2'b01: apply_write[63:32]  = w;
            2'b10: apply_write[95:64]  = w;
            2'b11: apply_write[127:96] = w;
        endcase
    end
endfunction

// ============================================================================
// Main FSM
// ============================================================================
integer j;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        for (j = 0; j < 64; j = j + 1) begin
            valid[j] <= 1'b0;
            dirty[j] <= 1'b0;
        end
        state       <= IDLE;
        fill_req    <= 1'b0;
        fill_addr   <= 32'b0;
        wb_req      <= 1'b0;
        wb_addr     <= 32'b0;
        wb_wdata    <= 128'b0;
        saved_addr         <= 32'b0;
        saved_wdata        <= 32'b0;
        saved_be           <= 4'b0;
        saved_we           <= 1'b0;
        new_line           <= 128'b0;
        miss_just_resolved <= 1'b0;
    end
    else begin
        case (state)

            // ------------------------------------------------------------------
            IDLE: begin
                // Clear the miss-just-resolved flag after one IDLE cycle
                if (miss_just_resolved)
                    miss_just_resolved <= 1'b0;

                if (req && hit && !miss_just_resolved) begin
                    if (we) begin
                        // Write hit: update word in place, mark line dirty
                        data_arr[idx] <= apply_write(data_arr[idx], woff, wdata, be);
                        dirty[idx]    <= 1'b1;
                    end
                    // Read hit: rdata is combinational; nothing to register.
                end
                else if (req && !hit && !miss_just_resolved) begin
                    // Miss — save the request
                    saved_addr  <= addr;
                    saved_wdata <= wdata;
                    saved_be    <= be;
                    saved_we    <= we;

                    if (valid[idx] && dirty[idx]) begin
                        // Dirty eviction: write old line back first
                        wb_req   <= 1'b1;
                        wb_addr  <= {tag_arr[idx], idx, 4'b0};
                        wb_wdata <= data_arr[idx];
                        state    <= WRITEBACK;
                    end else begin
                        // Clean/invalid eviction: fetch directly
                        fill_req  <= 1'b1;
                        fill_addr <= {addr[31:4], 4'b0};
                        state     <= FETCH;
                    end
                end
            end

            // ------------------------------------------------------------------
            WRITEBACK: begin
                if (wb_ready) begin
                    wb_req   <= 1'b0;
                    // Dirty line written — now fetch the new line
                    fill_req  <= 1'b1;
                    fill_addr <= {saved_addr[31:4], 4'b0};
                    state     <= FETCH;
                end
            end

            // ------------------------------------------------------------------
            FETCH: begin
                if (fill_ready) begin
                    // Apply pending write if this was a write miss
                    new_line = fill_rdata;
                    if (saved_we)
                        new_line = apply_write(new_line, saved_addr[3:2],
                                               saved_wdata, saved_be);

                    // Install the (possibly modified) line
                    valid[saved_addr[9:4]]    <= 1'b1;
                    dirty[saved_addr[9:4]]    <= saved_we;  // dirty only on write
                    tag_arr[saved_addr[9:4]]  <= saved_addr[31:10];
                    data_arr[saved_addr[9:4]] <= new_line;

                    fill_req           <= 1'b0;
                    miss_just_resolved <= 1'b1;
                    state              <= IDLE;
                    // dcache_stall drops next cycle when hit=1 for saved_addr
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule
