`timescale 1ns/1ps
// ============================================================================
// Main Memory — Backing Store for L1 Caches (BRAM-friendly)
// ============================================================================
// Two independent modules:
//   instr_mem  — 1024-word instruction BRAM; serialized cache-line reads
//   data_mem   — 1024-word data BRAM; serialized fill reads & writeback writes
//
// Architecture: All array accesses go through a single read port and a single
// write port with registered outputs, so Vivado infers Block RAM.  Multi-word
// cache-line transfers are serialized over MISS_CYCLES (default 4) cycles.
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

    // Bootloader write port (word writes)
    input         bl_we,
    input  [ 9:0] bl_addr,
    input  [31:0] bl_wdata,

    // I-cache fill port
    input         ic_req,
    input  [31:0] ic_addr,       // cache-line aligned byte address
    output reg [127:0] ic_rdata, // 4-word cache line (registered)
    output reg    ic_ready       // pulses 1 cycle when data is valid
);

    // ---- Block RAM (single read port, registered output) ----
    (* ram_style = "block" *)
    reg [31:0] imem [0:1023];

    initial begin
        $readmemh("imem.hex", imem);
    end

    // Bootloader write port (no reset clearing; BRAM contents persist)
    always @(posedge clk) begin
        if (bl_we)
            imem[bl_addr] <= bl_wdata;
    end

    reg  [9:0]  rd_addr;
    reg  [31:0] rd_dout;

    always @(posedge clk) begin
        rd_dout <= imem[rd_addr];
    end

    // ---- FSM ----
    // Reads 4 words over MISS_CYCLES cycles using pipelined BRAM access.
    // The combinational address mux presents the first address on the same
    // cycle that ic_req fires (IDLE→BUSY transition), so rd_dout has word 0
    // ready on the first BUSY cycle.
    localparam S_IDLE = 2'd0, S_BUSY = 2'd1, S_DONE = 2'd2;
    reg  [1:0] state;
    reg  [3:0] cnt;
    reg  [1:0] word;        // word being captured this cycle (0..3)
    reg [31:0] addr_lat;
    wire [9:0] base = addr_lat[11:2];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state    <= S_IDLE;
            cnt      <= 4'd0;
            word     <= 2'd0;
            addr_lat <= 32'd0;
            ic_ready <= 1'b0;
            ic_rdata <= 128'd0;
        end else begin
            ic_ready <= 1'b0;   // default: deasserted
            case (state)
                S_IDLE: begin
                    if (ic_req) begin
                        addr_lat <= ic_addr;
                        cnt      <= MISS_CYCLES - 1;
                        word     <= 2'd0;
                        state    <= S_BUSY;
                    end
                end
                S_BUSY: begin
                    // Capture current word from BRAM read port
                    case (word)
                        2'd0: ic_rdata[ 31: 0] <= rd_dout;
                        2'd1: ic_rdata[ 63:32] <= rd_dout;
                        2'd2: ic_rdata[ 95:64] <= rd_dout;
                        2'd3: ic_rdata[127:96] <= rd_dout;
                    endcase

                    if (cnt == 4'd0) begin
                        ic_ready <= 1'b1;
                        state    <= S_DONE;
                    end else begin
                        cnt  <= cnt - 4'd1;
                        word <= word + 2'd1;
                    end
                end
                S_DONE: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

    // ---- Read address mux (combinational — feeds BRAM address port) ----
    // On the IDLE→BUSY transition cycle, presents base+0 so the BRAM
    // output is valid on the first BUSY cycle.  During BUSY, prefetches
    // the next word (word+1).
    always @(*) begin
        if (state == S_IDLE && ic_req)
            rd_addr = ic_addr[11:2];                   // word 0
        else if (state == S_BUSY)
            rd_addr = base + {8'd0, word + 2'd1};      // next word
        else
            rd_addr = 10'd0;
    end

endmodule


// ============================================================================
// Data Memory
// ============================================================================
module data_mem #(
    parameter MISS_CYCLES = 4
)(
    input         clk,
    input         reset,

    // Bootloader write port (word writes)
    input         bl_we,
    input  [ 9:0] bl_addr,
    input  [31:0] bl_wdata,

    // D-cache fill port (read: cache miss)
    input         dc_fill_req,
    input  [31:0] dc_fill_addr,       // cache-line aligned
    output reg [127:0] dc_fill_rdata, // registered
    output reg    dc_fill_ready,

    // D-cache writeback port (write: dirty eviction)
    input         dc_wb_req,
    input  [31:0] dc_wb_addr,         // cache-line aligned
    input [127:0] dc_wb_wdata,
    output reg    dc_wb_ready,

    // Atomic word-level port (lr.w / sc.w — bypasses D-cache)
    input         atomic_req,
    input         atomic_we,           // 0=read(lr.w), 1=write(sc.w)
    input  [31:0] atomic_addr,         // byte address (word-aligned)
    input  [31:0] atomic_wdata,
    output reg [31:0] atomic_rdata,    // registered
    output reg    atomic_ready
);

    // ---- Block RAM (Simple Dual Port: 1 read + 1 write) ----
    (* ram_style = "block" *)
    reg [31:0] dmem [0:1023];

    initial begin
        $readmemh("dmem.hex", dmem);
    end

    // Read port (registered output)
    reg  [9:0]  rd_addr;
    reg  [31:0] rd_dout;
    always @(posedge clk) begin
        rd_dout <= dmem[rd_addr];
    end

    // Write port
    reg         wr_en;
    reg  [9:0]  wr_addr;
    reg  [31:0] wr_din;
    always @(posedge clk) begin
        if (wr_en)
            dmem[wr_addr] <= wr_din;
    end

    // ========================================================================
    //  Fill (read) FSM — serialized 4-word BRAM reads
    // ========================================================================
    localparam F_IDLE = 2'd0, F_BUSY = 2'd1, F_DONE = 2'd2;
    reg  [1:0] f_state;
    reg  [3:0] f_cnt;
    reg  [1:0] f_word;
    reg [31:0] f_addr;
    wire [9:0] f_base = f_addr[11:2];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            f_state       <= F_IDLE;
            f_cnt         <= 4'd0;
            f_word        <= 2'd0;
            f_addr        <= 32'd0;
            dc_fill_ready <= 1'b0;
            dc_fill_rdata <= 128'd0;
        end else begin
            dc_fill_ready <= 1'b0;
            case (f_state)
                F_IDLE: begin
                    if (dc_fill_req) begin
                        f_addr  <= dc_fill_addr;
                        f_cnt   <= MISS_CYCLES - 1;
                        f_word  <= 2'd0;
                        f_state <= F_BUSY;
                    end
                end
                F_BUSY: begin
                    // Capture word from BRAM read port (1-cycle pipelined)
                    case (f_word)
                        2'd0: dc_fill_rdata[ 31: 0] <= rd_dout;
                        2'd1: dc_fill_rdata[ 63:32] <= rd_dout;
                        2'd2: dc_fill_rdata[ 95:64] <= rd_dout;
                        2'd3: dc_fill_rdata[127:96] <= rd_dout;
                    endcase

                    if (f_cnt == 4'd0) begin
                        dc_fill_ready <= 1'b1;
                        f_state       <= F_DONE;
                    end else begin
                        f_cnt  <= f_cnt - 4'd1;
                        f_word <= f_word + 2'd1;
                    end
                end
                F_DONE: begin
                    f_state <= F_IDLE;
                end
            endcase
        end
    end

    // ========================================================================
    //  Writeback (write) FSM — serialized 4-word BRAM writes
    // ========================================================================
    localparam W_IDLE = 2'd0, W_BUSY = 2'd1, W_DONE = 2'd2;
    reg  [1:0] w_state;
    reg  [3:0] w_cnt;
    reg  [1:0] w_word;
    reg [31:0] w_addr;
    reg [127:0] w_data;
    wire [9:0] w_base = w_addr[11:2];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            w_state     <= W_IDLE;
            w_cnt       <= 4'd0;
            w_word      <= 2'd0;
            w_addr      <= 32'd0;
            w_data      <= 128'd0;
            dc_wb_ready <= 1'b0;
        end else begin
            dc_wb_ready <= 1'b0;
            case (w_state)
                W_IDLE: begin
                    if (dc_wb_req) begin
                        w_addr  <= dc_wb_addr;
                        w_data  <= dc_wb_wdata;
                        w_cnt   <= MISS_CYCLES - 1;
                        w_word  <= 2'd0;
                        w_state <= W_BUSY;
                    end
                end
                W_BUSY: begin
                    // Write port mux handles the actual BRAM write
                    if (w_cnt == 4'd0) begin
                        dc_wb_ready <= 1'b1;
                        w_state     <= W_DONE;
                    end else begin
                        w_cnt  <= w_cnt - 4'd1;
                        w_word <= w_word + 2'd1;
                    end
                end
                W_DONE: begin
                    w_state <= W_IDLE;
                end
            endcase
        end
    end

    // ========================================================================
    //  Atomic FSM (lr.w / sc.w — single word)
    // ========================================================================
    // NOTE: bus_arbiter has independent FSMs per port, so atomic_req can fire
    // concurrently with dc_fill_req or dc_wb_req. The rd/wr port muxes below
    // give fill/wb priority, so atomic must wait for them to release the port.
    //
    // States:
    //   A_IDLE — waiting for request
    //   A_WAIT — request latched, waiting for read/write port to be free
    //   A_DONE — port granted this cycle; capture rd_dout / assert wr_en
    localparam A_IDLE = 2'd0, A_WAIT = 2'd1, A_DONE = 2'd2;
    reg  [1:0] a_state;
    reg [31:0] a_addr;
    reg [31:0] a_wdata;
    reg        a_we;

    // Port-availability flags (combinational, checked this cycle)
    wire atomic_rd_ok = (f_state == F_IDLE) && !dc_fill_req;
    wire atomic_wr_ok = (w_state == W_IDLE) && !dc_wb_req && !bl_we;
    // SC.W needs write port; LR.W only needs read port
    wire a_go_new     = atomic_we ? (atomic_rd_ok && atomic_wr_ok) : atomic_rd_ok;
    wire a_go_wait    = a_we      ? (atomic_rd_ok && atomic_wr_ok) : atomic_rd_ok;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            a_state      <= A_IDLE;
            a_addr       <= 32'd0;
            a_wdata      <= 32'd0;
            a_we         <= 1'b0;
            atomic_ready <= 1'b0;
            atomic_rdata <= 32'd0;
        end else begin
            atomic_ready <= 1'b0;
            case (a_state)
                A_IDLE: begin
                    if (atomic_req) begin
                        a_addr  <= atomic_addr;
                        a_wdata <= atomic_wdata;
                        a_we    <= atomic_we;
                        a_state <= a_go_new ? A_DONE : A_WAIT;
                    end
                end
                A_WAIT: begin
                    if (a_go_wait)
                        a_state <= A_DONE;
                end
                A_DONE: begin
                    // For LR.W: rd_dout reflects the cycle where a_addr was
                    //          presented on rd_addr (prev cycle: A_IDLE fast
                    //          path, or A_WAIT slow path).
                    // For SC.W: write port mux fires this cycle (atomic priority).
                    atomic_rdata <= rd_dout;
                    atomic_ready <= 1'b1;
                    a_state      <= A_IDLE;
                end
            endcase
        end
    end

    // ========================================================================
    //  BRAM read address mux (combinational)
    // ========================================================================
    // Priority: active fill > atomic (LR.W or SC.W pre-read).
    // Fast path: atomic_req arrives with fill idle → present atomic addr
    //            immediately; rd_dout valid next cycle in A_DONE.
    // Slow path: atomic_req arrives during fill → latch into A_WAIT and
    //            present atomic addr once fill releases the port.
    always @(*) begin
        if (f_state == F_IDLE && dc_fill_req)
            rd_addr = dc_fill_addr[11:2];              // fill: word 0
        else if (f_state == F_BUSY)
            rd_addr = f_base + {8'd0, f_word + 2'd1};  // fill: next word
        else if (a_state == A_IDLE && atomic_req && atomic_rd_ok)
            rd_addr = atomic_addr[11:2];               // atomic fast path
        else if (a_state == A_WAIT && atomic_rd_ok)
            rd_addr = a_addr[11:2];                    // atomic slow path
        else
            rd_addr = 10'd0;
    end

    // ========================================================================
    //  BRAM write port mux (combinational)
    // ========================================================================
    always @(*) begin
        wr_en   = 1'b0;
        wr_addr = 10'd0;
        wr_din  = 32'd0;

        if (bl_we) begin
            // Highest priority: bootloader programming
            wr_en   = 1'b1;
            wr_addr = bl_addr;
            wr_din  = bl_wdata;
        end else if (w_state == W_BUSY) begin
            wr_en   = 1'b1;
            wr_addr = w_base + {8'd0, w_word};
            case (w_word)
                2'd0: wr_din = w_data[ 31: 0];
                2'd1: wr_din = w_data[ 63:32];
                2'd2: wr_din = w_data[ 95:64];
                2'd3: wr_din = w_data[127:96];
            endcase
        end else if (a_state == A_DONE && a_we) begin
            wr_en   = 1'b1;
            wr_addr = a_addr[11:2];
            wr_din  = a_wdata;
        end
    end

endmodule
