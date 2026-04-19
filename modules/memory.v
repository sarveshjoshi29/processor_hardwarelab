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

    // Store as cache-lines to map naturally to BRAM.
    // 1024 x 32-bit words = 256 x 128-bit cache lines.
    (* ram_style = "block" *)
    reg [127:0] imem_line [0:255];

    // imem.hex is generated as 32-bit words; pack into 128-bit cache lines.
    integer ii;
    reg [31:0] imem_words [0:1023];
    initial begin
        $readmemh("imem.hex", imem_words);
        for (ii = 0; ii < 256; ii = ii + 1) begin
            imem_line[ii] = {imem_words[ii*4 + 3],
                             imem_words[ii*4 + 2],
                             imem_words[ii*4 + 1],
                             imem_words[ii*4 + 0]};
        end
    end

    // ---- Latency state machine ----
    localparam M_IDLE = 2'd0, M_BUSY = 2'd1, M_DONE = 2'd2;
    reg  [1:0] ic_state;
    reg  [3:0] ic_cnt;
    reg [31:0]  ic_addr_lat;
    reg [127:0] ic_rdata_lat;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ic_state   <= M_IDLE;
            ic_cnt     <= 4'd0;
            ic_addr_lat<= 32'b0;
            ic_ready   <= 1'b0;
            ic_rdata_lat <= 128'b0;
        end else begin
            ic_ready <= 1'b0;   // default: deasserted
            case (ic_state)
                M_IDLE: begin
                    if (ic_req) begin
                        ic_addr_lat <= ic_addr;
                        ic_cnt      <= MISS_CYCLES - 1;
                        ic_state    <= M_BUSY;
                        // Synchronous BRAM-style read (data available next cycle).
                        ic_rdata_lat <= imem_line[ic_addr[11:4]];
                    end
                end
                M_BUSY: begin
                    // Keep output stable throughout BUSY.
                    ic_rdata_lat <= ic_rdata_lat;
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

    // Cache-line read is synchronous and held in ic_rdata_lat.
    assign ic_rdata = ic_rdata_lat;

endmodule


// ============================================================================
// Data Memory
// ============================================================================

// ---------------------------------------------------------------------------
// True dual-port BRAM template (Xilinx-friendly)
// - 256 deep × 128-bit (16-byte write enable)
// - Registered read data (1-cycle)
// - Separate always block per port
// ---------------------------------------------------------------------------
module bram_tdp_128x256 #(
    parameter INIT_FILE = "dmem.hex"
)(
    input         clk,

    // Port A
    input         ena,
    input  [7:0]  addra,
    input  [127:0] dina,
    input  [15:0] wea,      // 1 bit per byte
    output reg [127:0] douta,

    // Port B
    input         enb,
    input  [7:0]  addrb,
    input  [127:0] dinb,
    input  [15:0] web,
    output reg [127:0] doutb
);
    (* ram_style = "block" *)
    reg [127:0] mem [0:255];

    // INIT_FILE is generated as 32-bit words; pack into 128-bit cache lines.
    integer i;
    reg [31:0] words [0:1023];
    initial begin
        $readmemh(INIT_FILE, words);
        for (i = 0; i < 256; i = i + 1) begin
            mem[i] = {words[i*4 + 3],
                      words[i*4 + 2],
                      words[i*4 + 1],
                      words[i*4 + 0]};
        end
    end

    integer b;

    always @(posedge clk) begin
        if (ena) begin
            douta <= mem[addra];
            for (b = 0; b < 16; b = b + 1) begin
                if (wea[b])
                    mem[addra][b*8 +: 8] <= dina[b*8 +: 8];
            end
        end
    end

    always @(posedge clk) begin
        if (enb) begin
            doutb <= mem[addrb];
            for (b = 0; b < 16; b = b + 1) begin
                if (web[b])
                    mem[addrb][b*8 +: 8] <= dinb[b*8 +: 8];
            end
        end
    end
endmodule

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

    // Backing BRAM (true dual-port)
    reg         bram_ena;
    reg  [7:0]  bram_addra;
    reg  [127:0] bram_dina;
    reg  [15:0] bram_wea;
    wire [127:0] bram_douta;

    reg         bram_enb;
    reg  [7:0]  bram_addrb;
    reg  [127:0] bram_dinb;
    reg  [15:0] bram_web;
    wire [127:0] bram_doutb;

    bram_tdp_128x256 #(
        .INIT_FILE("dmem.hex")
    ) u_dmem_bram (
        .clk   (clk),

        .ena   (bram_ena),
        .addra (bram_addra),
        .dina  (bram_dina),
        .wea   (bram_wea),
        .douta (bram_douta),

        .enb   (bram_enb),
        .addrb (bram_addrb),
        .dinb  (bram_dinb),
        .web   (bram_web),
        .doutb (bram_doutb)
    );

    // ---- Fill (read) port state machine ----
    localparam M_IDLE = 2'd0, M_BUSY = 2'd1, M_DONE = 2'd2;

    reg  [1:0] fill_state;
    reg  [3:0] fill_cnt;
    reg [31:0] fill_addr_lat;
    reg [127:0] fill_rdata_lat;

    // ---- Port A (shared) ----
    // Shared BRAM port A for fill + atomic. Only one operation issued at a time.
    reg        porta_is_atomic;
    reg        porta_wait;

    // ---- Atomic word-level port ----
    // Serialized with fill reads so the memory remains 2-port.
    localparam A_IDLE = 2'd0, A_READ = 2'd1, A_WRITE = 2'd2;
    reg  [1:0] a_state;
    reg [31:0] a_addr_lat;
    reg [31:0] a_wdata_lat;
    reg        a_we_lat;
    reg [127:0] a_line_lat;

    // Helper: byte-enable + aligned write data for one word within 128-bit line
    wire [1:0]   a_word_sel = a_addr_lat[3:2];
    wire [127:0] a_wdata_aligned = (a_we_lat) ? ({96'b0, a_wdata_lat} << (a_word_sel * 32)) : 128'b0;
    wire [15:0]  a_wstrb = (a_we_lat) ? (16'h000F << (a_word_sel * 4)) : 16'h0000;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            fill_state     <= M_IDLE;
            fill_cnt       <= 4'd0;
            fill_addr_lat  <= 32'b0;
            dc_fill_ready  <= 1'b0;
            fill_rdata_lat <= 128'b0;

            a_state        <= A_IDLE;
            a_addr_lat     <= 32'b0;
            a_wdata_lat    <= 32'b0;
            a_we_lat       <= 1'b0;
            a_line_lat     <= 128'b0;
            atomic_ready   <= 1'b0;

            bram_ena        <= 1'b0;
            bram_addra      <= 8'd0;
            bram_dina       <= 128'b0;
            bram_wea        <= 16'h0000;

            porta_is_atomic <= 1'b0;
            porta_wait      <= 1'b0;
        end else begin
            dc_fill_ready <= 1'b0;
            atomic_ready <= 1'b0;

            // Default: no BRAM ops.
            bram_ena <= 1'b0;
            bram_wea <= 16'h0000;

            // Capture port-A read data into the right destination.
            if (porta_wait) begin
                if (porta_is_atomic)
                    a_line_lat <= bram_douta;
                else
                    fill_rdata_lat <= bram_douta;
                porta_wait <= 1'b0;
            end

            // Priority: atomic over fill (only when fill is idle).
            if (a_state == A_IDLE) begin
                if (atomic_req && (fill_state == M_IDLE)) begin
                    a_addr_lat      <= atomic_addr;
                    a_wdata_lat     <= atomic_wdata;
                    a_we_lat        <= atomic_we;

                    // Issue atomic read on port A
                    bram_addra      <= atomic_addr[11:4];
                    bram_ena        <= 1'b1;
                    bram_wea        <= 16'h0000;
                    porta_is_atomic <= 1'b1;
                    porta_wait      <= 1'b1;
                    a_state         <= A_READ;
                end else if (dc_fill_req) begin
                    fill_addr_lat   <= dc_fill_addr;
                    fill_cnt        <= MISS_CYCLES - 1;
                    fill_state      <= M_BUSY;

                    // Issue fill read on port A
                    bram_addra      <= dc_fill_addr[11:4];
                    bram_ena        <= 1'b1;
                    bram_wea        <= 16'h0000;
                    porta_is_atomic <= 1'b0;
                    porta_wait      <= 1'b1;
                end
            end

            // Fill latency FSM.
            case (fill_state)
                M_IDLE: begin
                    // filled by logic above
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

            // Atomic state machine.
            // - A_READ: we have issued a read and will capture it via porta_wait.
            // - A_WRITE: optional byte-write to selected word.
            if (a_state == A_READ) begin
                // When porta_wait clears, a_line_lat has been updated with bram_douta.
                if (!porta_wait) begin
                    if (a_we_lat) begin
                        // Issue byte write on port A (selected 4 bytes)
                        bram_addra <= a_addr_lat[11:4];
                        bram_ena   <= 1'b1;
                        bram_dina  <= a_wdata_aligned;
                        bram_wea   <= a_wstrb;
                        a_state    <= A_WRITE;
                    end else begin
                        atomic_ready <= 1'b1;
                        a_state      <= A_IDLE;
                    end
                end
            end else if (a_state == A_WRITE) begin
                // Write is committed on this clock edge.
                atomic_ready <= 1'b1;
                a_state      <= A_IDLE;
            end
        end
    end

    assign dc_fill_rdata = fill_rdata_lat;

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

            bram_enb    <= 1'b0;
            bram_addrb  <= 8'd0;
            bram_dinb   <= 128'b0;
            bram_web    <= 16'h0000;
        end else begin
            dc_wb_ready <= 1'b0;
            // Default: no BRAM port B op.
            bram_enb <= 1'b0;
            bram_web <= 16'h0000;
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
                        // Commit cache-line to BRAM (full 16 bytes) on port B
                        bram_addrb <= wb_addr_lat[11:4];
                        bram_dinb  <= wb_data_lat;
                        bram_enb   <= 1'b1;
                        bram_web   <= 16'hFFFF;
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

    // Read returned on atomic_ready cycle.
    assign atomic_rdata = (a_word_sel == 2'd0) ? a_line_lat[31:0] :
                          (a_word_sel == 2'd1) ? a_line_lat[63:32] :
                          (a_word_sel == 2'd2) ? a_line_lat[95:64] :
                                                 a_line_lat[127:96];

endmodule
