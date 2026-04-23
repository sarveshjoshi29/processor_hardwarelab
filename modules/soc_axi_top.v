// soc_axi_top.v
`timescale 1ns/1ps
// ============================================================================
// RV32IMA SoC — AXI4-Lite Top-Level Wrapper (Phase 5)
// ============================================================================
// Architecture:
//   dual_core_top (2x rv32ima_core, bus arbiter, caches, shared memory)
//       ↓ MMIO port
//   Address Decode
//       ├─ 0x2000_0000: UART TX (internal peripheral)
//       └─ All other MMIO: → AXI4-Lite master interface
//
// Exposed to outside world:
//   - AXI4-Lite master interface (32-bit address, 32-bit data)
//   - Clock, Reset
//   - UART TX serial output
//   - Monitoring/debug outputs
// ============================================================================

// All modules added as separate design sources in Vivado — no `include needed
// For Icarus Verilog simulation, include sub-modules explicitly:
`ifndef SYNTHESIS
`include "dual_core_top.v"
`include "uart_tx.v"
`endif

module soc_axi_top #(
    parameter [31:0] RESET_C0  = 32'h0000_0000,
    parameter [31:0] RESET_C1  = 32'h0000_0200,
    parameter        CLK_FREQ  = 100_000_000,
    parameter        BAUD_RATE = 115200
)(
    input         clk,
    input         reset,

    // ====================================================================
    // Bootloader write ports (from FPGA-top UART loader)
    // ====================================================================
    input         bl_imem_we,
    input  [ 9:0] bl_imem_addr,
    input  [31:0] bl_imem_wdata,

    input         bl_dmem_we,
    input  [ 9:0] bl_dmem_addr,
    input  [31:0] bl_dmem_wdata,

    // ====================================================================
    // AXI4-Lite Master Interface (for external memory/peripherals)
    // ====================================================================
    // Write Address Channel
    output [31:0] m_axi_awaddr,
    output        m_axi_awvalid,
    input         m_axi_awready,
    output [ 2:0] m_axi_awprot,

    // Write Data Channel
    output [31:0] m_axi_wdata,
    output [ 3:0] m_axi_wstrb,
    output        m_axi_wvalid,
    input         m_axi_wready,

    // Write Response Channel
    input  [ 1:0] m_axi_bresp,
    input         m_axi_bvalid,
    output        m_axi_bready,

    // Read Address Channel
    output [31:0] m_axi_araddr,
    output        m_axi_arvalid,
    input         m_axi_arready,
    output [ 2:0] m_axi_arprot,

    // Read Data Channel
    input  [31:0] m_axi_rdata,
    input  [ 1:0] m_axi_rresp,
    input         m_axi_rvalid,
    output        m_axi_rready,

    // ====================================================================
    // UART TX Serial Output
    // ====================================================================
    output        uart_tx,

    // ====================================================================
    // Debug / Monitoring
    // ====================================================================
    output        c0_exception,
    output [31:0] c0_pc_out,
    output [31:0] c0_inst_word_out,
    output        c1_exception,
    output [31:0] c1_pc_out,
    output [31:0] c1_inst_word_out
);

    // ======================================================================
    //  DUAL-CORE TOP (includes bus arbiter, caches, shared memory)
    // ======================================================================
    wire        mmio_req, mmio_we;
    wire [31:0] mmio_addr, mmio_wdata;
    wire [ 3:0] mmio_be;
    wire [31:0] mmio_rdata;
    wire        mmio_ready;

    wire [31:0] c0_inst_fetch_pc, c1_inst_fetch_pc;
    wire        c0_dmem_write_ready, c1_dmem_write_ready;
    wire [31:0] c0_dmem_write_data,  c1_dmem_write_data;
    wire [ 3:0] c0_dmem_write_byte,  c1_dmem_write_byte;

    dual_core_top #(
        .RESET_C0 (RESET_C0),
        .RESET_C1 (RESET_C1)
    ) u_dual_core (
        .clk              (clk),
        .reset            (reset),
        .stall            (1'b0),

        .bl_imem_we        (bl_imem_we),
        .bl_imem_addr      (bl_imem_addr),
        .bl_imem_wdata     (bl_imem_wdata),

        .bl_dmem_we        (bl_dmem_we),
        .bl_dmem_addr      (bl_dmem_addr),
        .bl_dmem_wdata     (bl_dmem_wdata),

        .c0_exception     (c0_exception),
        .c0_pc_out        (c0_pc_out),
        .c0_inst_fetch_pc (c0_inst_fetch_pc),
        .c0_inst_word_out (c0_inst_word_out),
        .c0_dmem_write_ready(c0_dmem_write_ready),
        .c0_dmem_write_data (c0_dmem_write_data),
        .c0_dmem_write_byte (c0_dmem_write_byte),

        .c1_exception     (c1_exception),
        .c1_pc_out        (c1_pc_out),
        .c1_inst_fetch_pc (c1_inst_fetch_pc),
        .c1_inst_word_out (c1_inst_word_out),
        .c1_dmem_write_ready(c1_dmem_write_ready),
        .c1_dmem_write_data (c1_dmem_write_data),
        .c1_dmem_write_byte (c1_dmem_write_byte),

        // MMIO port (Phase 5)
        .mmio_req         (mmio_req),
        .mmio_we          (mmio_we),
        .mmio_addr        (mmio_addr),
        .mmio_wdata       (mmio_wdata),
        .mmio_be          (mmio_be),
        .mmio_rdata       (mmio_rdata),
        .mmio_ready       (mmio_ready)
    );

    // ======================================================================
    //  ADDRESS DECODE: UART (0x2000_0000) vs AXI (everything else)
    // ======================================================================
    wire uart_sel = (mmio_addr[31:4] == 28'h2000_000);  // 0x2000_0000–0x2000_000F
    wire axi_sel  = mmio_req && !uart_sel;
    wire uart_access = mmio_req && uart_sel;

    // ======================================================================
    //  UART TX PERIPHERAL (mapped at 0x2000_0000)
    // ======================================================================
    wire        uart_busy;
    wire        uart_wr_en = uart_access && mmio_we;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD_RATE)
    ) u_uart (
        .clk      (clk),
        .reset    (reset),
        .wr_en    (uart_wr_en),
        .wr_data  (mmio_wdata[7:0]),
        .tx_busy  (uart_busy),
        .tx_out   (uart_tx)
    );

    // UART read returns busy status; UART write is always accepted (1-cycle)
    // unless UART is busy (stalls pipeline until not busy).
    wire uart_rdata_valid = uart_access && !mmio_we;
    wire [31:0] uart_rdata = {31'b0, uart_busy};
    wire uart_ready = uart_access && (mmio_we ? !uart_busy : 1'b1);

    // ======================================================================
    //  AXI4-LITE MASTER BRIDGE
    // ======================================================================
    // Converts word-level MMIO requests to AXI4-Lite transactions.
    // State machine: IDLE → (AW+W)/AR → wait response → IDLE
    // ======================================================================

    localparam [2:0] AXI_IDLE    = 3'd0,
                     AXI_WR_ADDR = 3'd1,
                     AXI_WR_DATA = 3'd2,
                     AXI_WR_RESP = 3'd3,
                     AXI_RD_ADDR = 3'd4,
                     AXI_RD_DATA = 3'd5;

    reg [2:0]  axi_state;
    reg [31:0] axi_addr_r, axi_wdata_r, axi_rdata_r;
    reg [ 3:0] axi_wstrb_r;
    reg        axi_done;

    // AXI output registers
    reg        awvalid_r, wvalid_r, bready_r;
    reg        arvalid_r, rready_r;

    assign m_axi_awaddr  = axi_addr_r;
    assign m_axi_awvalid = awvalid_r;
    assign m_axi_awprot  = 3'b000;

    assign m_axi_wdata   = axi_wdata_r;
    assign m_axi_wstrb   = axi_wstrb_r;
    assign m_axi_wvalid  = wvalid_r;

    assign m_axi_bready  = bready_r;

    assign m_axi_araddr  = axi_addr_r;
    assign m_axi_arvalid = arvalid_r;
    assign m_axi_arprot  = 3'b000;

    assign m_axi_rready  = rready_r;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            axi_state  <= AXI_IDLE;
            axi_addr_r <= 32'b0;
            axi_wdata_r<= 32'b0;
            axi_rdata_r<= 32'b0;
            axi_wstrb_r<= 4'b0;
            axi_done   <= 1'b0;
            awvalid_r  <= 1'b0;
            wvalid_r   <= 1'b0;
            bready_r   <= 1'b0;
            arvalid_r  <= 1'b0;
            rready_r   <= 1'b0;
        end
        else begin
            axi_done <= 1'b0;  // pulse

            case (axi_state)
                AXI_IDLE: begin
                    if (axi_sel) begin
                        axi_addr_r  <= mmio_addr;
                        axi_wdata_r <= mmio_wdata;
                        axi_wstrb_r <= mmio_be;
                        if (mmio_we) begin
                            awvalid_r <= 1'b1;
                            wvalid_r  <= 1'b1;
                            axi_state <= AXI_WR_ADDR;
                        end
                        else begin
                            arvalid_r <= 1'b1;
                            axi_state <= AXI_RD_ADDR;
                        end
                    end
                end

                // ---- Write: address + data phase ----
                AXI_WR_ADDR: begin
                    if (m_axi_awready) awvalid_r <= 1'b0;
                    if (m_axi_wready)  wvalid_r  <= 1'b0;
                    if ((m_axi_awready || !awvalid_r) &&
                        (m_axi_wready  || !wvalid_r)) begin
                        bready_r  <= 1'b1;
                        axi_state <= AXI_WR_RESP;
                    end
                end

                // ---- Write: response phase ----
                AXI_WR_RESP: begin
                    if (m_axi_bvalid) begin
                        bready_r  <= 1'b0;
                        axi_done  <= 1'b1;
                        axi_state <= AXI_IDLE;
                    end
                end

                // ---- Read: address phase ----
                AXI_RD_ADDR: begin
                    if (m_axi_arready) begin
                        arvalid_r <= 1'b0;
                        rready_r  <= 1'b1;
                        axi_state <= AXI_RD_DATA;
                    end
                end

                // ---- Read: data phase ----
                AXI_RD_DATA: begin
                    if (m_axi_rvalid) begin
                        rready_r    <= 1'b0;
                        axi_rdata_r <= m_axi_rdata;
                        axi_done    <= 1'b1;
                        axi_state   <= AXI_IDLE;
                    end
                end

                default: axi_state <= AXI_IDLE;
            endcase
        end
    end

    // ======================================================================
    //  MMIO RESPONSE MUX — combine UART and AXI responses
    // ======================================================================
    assign mmio_rdata = uart_sel ? uart_rdata : axi_rdata_r;
    assign mmio_ready = uart_sel ? uart_ready : axi_done;

endmodule
