`timescale 1ns / 1ps
// ============================================================================
// top_fpga.v — Nexys A7 FPGA Top-Level for RV32IMA Dual-Core SoC
// ============================================================================
// Board:    Digilent Nexys A7-100T (Artix-7 XC7A100T-1CSG324C)
// Clock:    100 MHz onboard oscillator → CLK100MHZ
// Reset:    BTNC (active-high pushbutton, active-high internally)
// UART TX:  JA[1] (Pmod Header JA, pin 1) — directly drives serial TX
//
// Switches:
//   SW[0]      = run/halt (active-high = run)
//   SW[1]      = 7-seg core select (0 = Core 0 PC, 1 = Core 1 PC)
//   SW[2]      = bootloader mode (1 = stall CPU and accept UART load)
//   SW[13]     = LED[7:0] core select (0 = Core 0 PC, 1 = Core 1 PC)
//   SW[15:14]  = clock speed select
//
// LEDs:
//   [7:0]  = selected core PC[9:2] (SW[13] selects core)
//   [8]    = Core 0 exception
//   [9]    = Core 1 exception
//   [10]   = UART TX activity (lights during transmission)
//   [11]   = run status
//   [12]   = Core 0 heartbeat (toggles on PC change)
//   [13]   = Core 1 heartbeat (toggles on PC change)
//   [14]   = SW[1] echo (core select indicator)
//   [15]   = SW[15] echo
//
// Clock modes (selected by SW[15:14]):
//   2'b00 — 1 Hz  (step-through debug)
//   2'b01 — 10 Hz (slow trace)
//   2'b10 — 1 kHz (fast trace)
//   2'b11 — 50 MHz (full speed, UART works at 115200 baud)
//
// AXI4-Lite master is left unconnected (directly tied ready/valid for
// Vivado synthesis; a real SoC would attach an AXI interconnect here).
// ============================================================================

// All modules added as separate design sources in Vivado — no `include needed

module top_fpga (
    input  wire        CLK100MHZ,     // 100 MHz board oscillator
    input  wire        BTNC,          // center button — reset (active-high)

    input  wire [15:0] SW,            // 16 slide switches
    output wire [15:0] LED,           // 16 LEDs

    output wire        JA1,           // UART TX (to PC)
    input  wire        JA2,           // UART RX (from PC)

    // 7-segment display (active-low segments, active-low digit enables)
    output wire [ 6:0] SEG,           // segments a–g
    output wire        DP,            // decimal point
    output wire [ 7:0] AN             // digit anodes (active-low)
);

    // ======================================================================
    //  RESET SYNCHRONIZER (2-FF metastability guard)
    // ======================================================================
    // Initial value ensures reset is asserted at power-up until button state
    // is sampled. On Xilinx FPGAs, reg init values are loaded at config time.
    (* ASYNC_REG = "TRUE" *)
    reg [2:0] rst_sync = 3'b111;   // power-up in reset
    wire      sys_reset = rst_sync[2];

    always @(posedge CLK100MHZ) begin
        rst_sync <= {rst_sync[1:0], BTNC};
    end

    // ======================================================================
    //  CLOCK DIVIDER — selectable via SW[15:14]
    // ======================================================================
    reg [25:0] clk_cnt;
    reg        div_clk;

    // Divider thresholds for each mode (toggle half-period counts)
    // 100 MHz / (2 * threshold) = output frequency
    wire [25:0] clk_threshold =
        (SW[15:14] == 2'b00) ? 26'd49_999_999 :   // 1 Hz
        (SW[15:14] == 2'b01) ? 26'd4_999_999  :   // 10 Hz
        (SW[15:14] == 2'b10) ? 26'd49_999     :   // 1 kHz
                               26'd0;              // 50 MHz (100/2)

    always @(posedge CLK100MHZ) begin
        if (sys_reset) begin
            clk_cnt <= 26'd0;
            div_clk <= 1'b0;
        end else begin
            if (clk_cnt >= clk_threshold) begin
                clk_cnt <= 26'd0;
                div_clk <= ~div_clk;
            end else begin
                clk_cnt <= clk_cnt + 26'd1;
            end
        end
    end

    // ======================================================================
    //  SYSTEM CLOCK
    // ======================================================================
    // All modes now use div_clk. In full-speed mode (threshold=0),
    // div_clk toggles every CLK100MHZ cycle → 50 MHz.
    // This eliminates the BUFGMUX CDC crossing and halves the timing
    // requirement, easily meeting Artix-7 timing constraints.
    wire sys_clk;

`ifdef SYNTHESIS
    // Use BUFG to drive the divided clock onto a global clock network
    BUFG u_bufg_sys (
        .I (div_clk),
        .O (sys_clk)
    );
`else
    assign sys_clk = div_clk;
`endif

    // ======================================================================
    //  SW INPUT SYNCHRONIZERS (SW[0]=run, SW[2]=boot_mode)
    // ======================================================================
    // Raw slide switches are async wrt sys_clk. Feeding them directly into
    // the SoC reset combinational net caused glitches / metastability on
    // the FPGA (sim doesn't model this). Two-FF sync on sys_clk fixes it.
    (* ASYNC_REG = "TRUE" *) reg sw0_m, sw0_s;
    (* ASYNC_REG = "TRUE" *) reg sw2_m, sw2_s;
    always @(posedge sys_clk) begin
        sw0_m <= SW[0];
        sw0_s <= sw0_m;
        sw2_m <= SW[2];
        sw2_s <= sw2_m;
    end
    wire run       = sw0_s;
    wire boot_mode = sw2_s;

    // ======================================================================
    //  RESET SYNCHRONIZERS on sys_clk (async-assert, sync-deassert)
    // ======================================================================
    // sys_reset is registered on CLK100MHZ. When sys_clk is the slower
    // div_clk, or the mux is mid-switch, a direct combinational reset can
    // deassert asynchronously with respect to sys_clk — allowing half the
    // pipeline FFs to see reset=0 one cycle before the other half. That
    // manifests as corrupted startup state that never appears in sim.
    //
    // sys_rst_s   : only BTNC/power-up reset, used by uart_rx + bootloader
    //               (they must remain live while boot_mode=1).
    // soc_reset   : full SoC reset — also asserted in boot_mode and !run.
    wire raw_sys_rst = sys_reset;
    (* ASYNC_REG = "TRUE" *) reg [1:0] sys_rst_sync_ff;
    always @(posedge sys_clk or posedge raw_sys_rst) begin
        if (raw_sys_rst) sys_rst_sync_ff <= 2'b11;
        else             sys_rst_sync_ff <= {sys_rst_sync_ff[0], 1'b0};
    end
    wire sys_rst_s = sys_rst_sync_ff[1];

    wire raw_reset = sys_reset || !run || boot_mode;
    (* ASYNC_REG = "TRUE" *) reg [1:0] soc_rst_sync;
    always @(posedge sys_clk or posedge raw_reset) begin
        if (raw_reset) soc_rst_sync <= 2'b11;
        else           soc_rst_sync <= {soc_rst_sync[0], 1'b0};
    end
    wire soc_reset = soc_rst_sync[1];

    // ======================================================================
    //  SoC INSTANTIATION
    // ======================================================================
    // UART baud rate: only accurate in full-speed mode (50 MHz).
    // In debug modes the baud is proportionally slower — use a logic
    // analyzer or oscilloscope, not a serial terminal.

    wire        uart_tx_pin;
    wire        c0_exception, c1_exception;
    wire [31:0] c0_pc, c1_pc;
    wire [31:0] c0_inst, c1_inst;

    // Bootloader write buses into SoC memories
    wire        bl_imem_we;
    wire [ 9:0] bl_imem_addr;
    wire [31:0] bl_imem_wdata;
    wire        bl_dmem_we;
    wire [ 9:0] bl_dmem_addr;
    wire [31:0] bl_dmem_wdata;
    wire        bl_done;

    // AXI4-Lite stub — directly provide ready/valid responses
    wire        stub_awready = 1'b1;
    wire        stub_wready  = 1'b1;
    wire [ 1:0] stub_bresp   = 2'b00;   // OKAY
    wire        stub_bvalid  = 1'b1;
    wire        stub_arready = 1'b1;
    wire [31:0] stub_rdata   = 32'h0;
    wire [ 1:0] stub_rresp   = 2'b00;
    wire        stub_rvalid  = 1'b1;

    soc_axi_top #(
        .RESET_C0  (32'h0000_0000),
        .RESET_C1  (32'h0000_0200),
        .CLK_FREQ  (50_000_000),
        .BAUD_RATE (115200)
    ) u_soc (
        .clk              (sys_clk),
        .reset            (soc_reset),

        // Bootloader write ports
        .bl_imem_we        (bl_imem_we),
        .bl_imem_addr      (bl_imem_addr),
        .bl_imem_wdata     (bl_imem_wdata),
        .bl_dmem_we        (bl_dmem_we),
        .bl_dmem_addr      (bl_dmem_addr),
        .bl_dmem_wdata     (bl_dmem_wdata),

        // AXI4-Lite master → stub slave
        .m_axi_awaddr     (),
        .m_axi_awvalid    (),
        .m_axi_awready    (stub_awready),
        .m_axi_awprot     (),

        .m_axi_wdata      (),
        .m_axi_wstrb      (),
        .m_axi_wvalid     (),
        .m_axi_wready     (stub_wready),

        .m_axi_bresp      (stub_bresp),
        .m_axi_bvalid     (stub_bvalid),
        .m_axi_bready     (),

        .m_axi_araddr     (),
        .m_axi_arvalid    (),
        .m_axi_arready    (stub_arready),
        .m_axi_arprot     (),

        .m_axi_rdata      (stub_rdata),
        .m_axi_rresp      (stub_rresp),
        .m_axi_rvalid     (stub_rvalid),
        .m_axi_rready     (),

        // UART TX
        .uart_tx          (uart_tx_pin),

        // Debug / monitoring
        .c0_exception     (c0_exception),
        .c0_pc_out        (c0_pc),
        .c0_inst_word_out (c0_inst),
        .c1_exception     (c1_exception),
        .c1_pc_out        (c1_pc),
        .c1_inst_word_out (c1_inst)
    );

    // ======================================================================
    //  UART RX + BOOTLOADER (loads imem.hex then dmem.hex)
    // ======================================================================
    wire [7:0] uart_rx_byte;
    wire       uart_rx_valid;

    uart_rx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115200)
    ) u_uart_rx (
        .clk        (sys_clk),
        .reset      (sys_rst_s),
        .rx_in      (JA2),
        .data_out   (uart_rx_byte),
        .data_valid (uart_rx_valid)
    );

    uart_bootloader #(
        .IMEM_WORDS (1024),
        .DMEM_WORDS (1024)
    ) u_boot (
        .clk        (sys_clk),
        .reset      (sys_rst_s),
        .enable     (boot_mode),
        .rx_valid   (uart_rx_valid),
        .rx_byte    (uart_rx_byte),
        .imem_we    (bl_imem_we),
        .imem_addr  (bl_imem_addr),
        .imem_wdata (bl_imem_wdata),
        .dmem_we    (bl_dmem_we),
        .dmem_addr  (bl_dmem_addr),
        .dmem_wdata (bl_dmem_wdata),
        .done       (bl_done)
    );

    // ======================================================================
    //  CORE ACTIVITY HEARTBEAT (registered — no combinational loops)
    // ======================================================================
    // Each heartbeat bit toggles when the respective core's PC changes.
    // Produces visible flicker on the LED proving the core is active.
    reg [31:0] c0_pc_prev, c1_pc_prev;
    reg        c0_heartbeat, c1_heartbeat;

    always @(posedge sys_clk) begin
        if (sys_rst_s) begin
            c0_pc_prev  <= 32'd0;
            c1_pc_prev  <= 32'd0;
            c0_heartbeat <= 1'b0;
            c1_heartbeat <= 1'b0;
        end else begin
            c0_pc_prev <= c0_pc;
            c1_pc_prev <= c1_pc;
            if (c0_pc != c0_pc_prev)
                c0_heartbeat <= ~c0_heartbeat;
            if (c1_pc != c1_pc_prev)
                c1_heartbeat <= ~c1_heartbeat;
        end
    end

    // ======================================================================
    //  IO MAPPING
    // ======================================================================
    assign JA1 = uart_tx_pin;

    // Core select: SW[13] for LED[7:0], SW[1] for 7-segment
    wire core_sel_led = SW[13];
    wire core_sel_seg = SW[1];

    // LED[7:0] = selected core's PC word address (PC[9:2])
    assign LED[7:0]   = core_sel_led ? c1_pc[9:2] : c0_pc[9:2];
    assign LED[8]     = c0_exception;
    assign LED[9]     = c1_exception;
    assign LED[10]    = ~uart_tx_pin;      // inverted: LED on during TX
    assign LED[11]    = run;
    assign LED[12]    = c0_heartbeat;       // Core 0 activity
    assign LED[13]    = c1_heartbeat;       // Core 1 activity
    assign LED[14]    = SW[1];              // core select echo
    assign LED[15]    = SW[15];             // clock mode echo

    // ======================================================================
    //  7-SEGMENT DISPLAY — shows Core 0 PC in hex (4 digits)
    // ======================================================================
    // Simple multiplexed driver at ~1 kHz refresh from 100 MHz
    reg [19:0] seg_cnt;
    reg [ 1:0] seg_sel;

    always @(posedge CLK100MHZ) begin
        if (sys_reset) begin
            seg_cnt <= 20'd0;
            seg_sel <= 2'd0;
        end else begin
            if (seg_cnt == 20'd99_999) begin
                seg_cnt <= 20'd0;
                seg_sel <= seg_sel + 2'd1;
            end else begin
                seg_cnt <= seg_cnt + 20'd1;
            end
        end
    end

    // Select which core's PC to display on 7-seg
    wire [31:0] seg_pc = core_sel_seg ? c1_pc : c0_pc;

    // Select which nibble to display
    reg [3:0] hex_digit;
    always @(*) begin
        case (seg_sel)
            2'd0: hex_digit = seg_pc[ 3: 0];
            2'd1: hex_digit = seg_pc[ 7: 4];
            2'd2: hex_digit = seg_pc[11: 8];
            2'd3: hex_digit = seg_pc[15:12];
        endcase
    end

    // Digit enable (active-low)
    reg [7:0] an_r;
    always @(*) begin
        an_r = 8'hFF;  // all off
        an_r[seg_sel] = 1'b0;
    end
    assign AN = an_r;
    assign DP = 1'b1;  // decimal point off

    // Hex to 7-segment decoder (active-low: 0 = segment on)
    reg [6:0] seg_r;
    always @(*) begin
        case (hex_digit)
            4'h0: seg_r = 7'b1000000;
            4'h1: seg_r = 7'b1111001;
            4'h2: seg_r = 7'b0100100;
            4'h3: seg_r = 7'b0110000;
            4'h4: seg_r = 7'b0011001;
            4'h5: seg_r = 7'b0010010;
            4'h6: seg_r = 7'b0000010;
            4'h7: seg_r = 7'b1111000;
            4'h8: seg_r = 7'b0000000;
            4'h9: seg_r = 7'b0010000;
            4'hA: seg_r = 7'b0001000;
            4'hB: seg_r = 7'b0000011;
            4'hC: seg_r = 7'b1000110;
            4'hD: seg_r = 7'b0100001;
            4'hE: seg_r = 7'b0000110;
            4'hF: seg_r = 7'b0001110;
        endcase
    end
    assign SEG = seg_r;

endmodule
