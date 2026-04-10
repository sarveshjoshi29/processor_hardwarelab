`timescale 1ns/1ps
// ============================================================================
// Main Memory — Backing Store for L1 Caches
// ============================================================================
// Two independent modules:
//   instr_mem  — 1024-word instruction BRAM; cache-line read port only
//   data_mem   — 1024-word data BRAM; separate fill (read) and writeback (write)
//                cache-line ports
//
// Latency model (per port):
//   IDLE: new request accepted → latch address, start countdown
//   BUSY: counts MISS_CYCLES-1 down to 0, then asserts ready for 1 cycle
//   DONE: 1-cycle cooldown so the cache can deassert req before next request
//
// Cache-line layout (128-bit, little-endian word order):
//   rdata[31:0]   = word at addr+0   (word_off 0)
//   rdata[63:32]  = word at addr+4   (word_off 1)
//   rdata[95:64]  = word at addr+8   (word_off 2)
//   rdata[127:96] = word at addr+12  (word_off 3)
// ============================================================================

// ============================================================================
// Instruction Memory
// ============================================================================
module instr_mem #(
    parameter MISS_CYCLES = 4
)(
    input         clk,
    input         reset,

    // I-cache fill port
    input         ic_req,
    input  [31:0] ic_addr,    // cache-line aligned byte address
    output [127:0] ic_rdata,  // 4-word cache line
    output reg    ic_ready    // pulses 1 cycle when data is valid
);

    (* ram_style = "block" *)
    reg [31:0] imem [0:1023];

    initial begin
        $readmemh("imem.hex", imem);
    end

    // ---- Latency state machine ----
    localparam M_IDLE = 2'd0, M_BUSY = 2'd1, M_DONE = 2'd2;
    reg  [1:0] ic_state;
    reg  [3:0] ic_cnt;
    reg [31:0] ic_addr_lat;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ic_state   <= M_IDLE;
            ic_cnt     <= 4'd0;
            ic_addr_lat<= 32'b0;
            ic_ready   <= 1'b0;
        end else begin
            ic_ready <= 1'b0;   // default: deasserted
            case (ic_state)
                M_IDLE: begin
                    if (ic_req) begin
                        ic_addr_lat <= ic_addr;
                        ic_cnt      <= MISS_CYCLES - 1;
                        ic_state    <= M_BUSY;
                    end
                end
                M_BUSY: begin
                    if (ic_cnt == 4'd0) begin
                        ic_ready <= 1'b1;   // assert ready for 1 cycle
                        ic_state <= M_DONE;
                    end else begin
                        ic_cnt <= ic_cnt - 4'd1;
                    end
                end
                M_DONE: begin
                    // Cooldown: let cache see ready and deassert req
                    ic_state <= M_IDLE;
                end
            endcase
        end
    end

    // ---- Combinational cache-line read (from latched address) ----
    wire [9:0] ic_wbase = ic_addr_lat[11:2];  // word address of first word
    assign ic_rdata = { imem[ic_wbase + 3],
                        imem[ic_wbase + 2],
                        imem[ic_wbase + 1],
                        imem[ic_wbase    ] };

endmodule


// ============================================================================
// Data Memory
// ============================================================================
module data_mem #(
    parameter MISS_CYCLES = 4
)(
    input         clk,
    input         reset,

    // D-cache fill port (read: cache miss)
    input         dc_fill_req,
    input  [31:0] dc_fill_addr,   // cache-line aligned
    output [127:0] dc_fill_rdata,
    output reg    dc_fill_ready,

    // D-cache writeback port (write: dirty eviction)
    input         dc_wb_req,
    input  [31:0] dc_wb_addr,     // cache-line aligned
    input [127:0] dc_wb_wdata,
    output reg    dc_wb_ready,

    // Atomic word-level port (lr.w / sc.w — bypasses D-cache)
    input         atomic_req,
    input         atomic_we,       // 0=read(lr.w), 1=write(sc.w)
    input  [31:0] atomic_addr,     // byte address (word-aligned)
    input  [31:0] atomic_wdata,
    output [31:0] atomic_rdata,
    output reg    atomic_ready
);

    (* ram_style = "block" *)
    reg [31:0] dmem [0:1023];

    initial begin
        $readmemh("dmem.hex", dmem);
    end

    // ---- Fill (read) port state machine ----
    localparam M_IDLE = 2'd0, M_BUSY = 2'd1, M_DONE = 2'd2;

    reg  [1:0] fill_state;
    reg  [3:0] fill_cnt;
    reg [31:0] fill_addr_lat;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            fill_state    <= M_IDLE;
            fill_cnt      <= 4'd0;
            fill_addr_lat <= 32'b0;
            dc_fill_ready <= 1'b0;
        end else begin
            dc_fill_ready <= 1'b0;
            case (fill_state)
                M_IDLE: begin
                    if (dc_fill_req) begin
                        fill_addr_lat <= dc_fill_addr;
                        fill_cnt      <= MISS_CYCLES - 1;
                        fill_state    <= M_BUSY;
                    end
                end
                M_BUSY: begin
                    if (fill_cnt == 4'd0) begin
                        dc_fill_ready <= 1'b1;
                        fill_state    <= M_DONE;
                    end else begin
                        fill_cnt <= fill_cnt - 4'd1;
                    end
                end
                M_DONE: begin
                    fill_state <= M_IDLE;
                end
            endcase
        end
    end

    // Combinational cache-line read from latched address
    wire [9:0] fill_wbase = fill_addr_lat[11:2];
    assign dc_fill_rdata = { dmem[fill_wbase + 3],
                             dmem[fill_wbase + 2],
                             dmem[fill_wbase + 1],
                             dmem[fill_wbase    ] };

    // ---- Writeback (write) port state machine ----
    reg  [1:0] wb_state;
    reg  [3:0] wb_cnt;
    reg [31:0] wb_addr_lat;
    reg [127:0] wb_data_lat;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            wb_state    <= M_IDLE;
            wb_cnt      <= 4'd0;
            wb_addr_lat <= 32'b0;
            wb_data_lat <= 128'b0;
            dc_wb_ready <= 1'b0;
        end else begin
            dc_wb_ready <= 1'b0;
            case (wb_state)
                M_IDLE: begin
                    if (dc_wb_req) begin
                        wb_addr_lat <= dc_wb_addr;
                        wb_data_lat <= dc_wb_wdata;
                        wb_cnt      <= MISS_CYCLES - 1;
                        wb_state    <= M_BUSY;
                    end
                end
                M_BUSY: begin
                    if (wb_cnt == 4'd0) begin
                        // Commit the 4 words to the array
                        dmem[wb_addr_lat[11:2] + 0] <= wb_data_lat[31:0];
                        dmem[wb_addr_lat[11:2] + 1] <= wb_data_lat[63:32];
                        dmem[wb_addr_lat[11:2] + 2] <= wb_data_lat[95:64];
                        dmem[wb_addr_lat[11:2] + 3] <= wb_data_lat[127:96];
                        dc_wb_ready <= 1'b1;
                        wb_state    <= M_DONE;
                    end else begin
                        wb_cnt <= wb_cnt - 4'd1;
                    end
                end
                M_DONE: begin
                    wb_state <= M_IDLE;
                end
            endcase
        end
    end

    // ---- Atomic word-level port (1-cycle latency) ----
    localparam A_IDLE = 1'b0, A_DONE = 1'b1;
    reg        a_state;
    reg [31:0] a_addr_lat;
    reg [31:0] a_wdata_lat;
    reg        a_we_lat;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            a_state     <= A_IDLE;
            a_addr_lat  <= 32'b0;
            a_wdata_lat <= 32'b0;
            a_we_lat    <= 1'b0;
            atomic_ready <= 1'b0;
        end else begin
            atomic_ready <= 1'b0;
            case (a_state)
                A_IDLE: begin
                    if (atomic_req) begin
                        a_addr_lat  <= atomic_addr;
                        a_wdata_lat <= atomic_wdata;
                        a_we_lat    <= atomic_we;
                        a_state     <= A_DONE;
                    end
                end
                A_DONE: begin
                    if (a_we_lat)
                        dmem[a_addr_lat[11:2]] <= a_wdata_lat;
                    atomic_ready <= 1'b1;
                    a_state      <= A_IDLE;
                end
            endcase
        end
    end

    // Combinational read from latched address (available on atomic_ready cycle)
    assign atomic_rdata = dmem[a_addr_lat[11:2]];

endmodule
