// tb_soc.v
`timescale 1ns / 1ps
// ============================================================================
// Testbench — RV32IMA SoC with AXI4-Lite (Phase 5)
// ============================================================================
// Tests: CSR performance counters, UART TX, and dual-core operation.
// AXI slave is stubbed (always responds with dummy data).
// ============================================================================

`include "soc_axi_top.v"

module tb_soc;

////////////////////////////////////////////////////////////
// CLOCK & RESET
////////////////////////////////////////////////////////////
reg clk;
reg reset;

initial begin
    clk = 0;
    forever #5 clk = ~clk;  // 100 MHz
end

initial begin
    reset = 1;
    #20;
    reset = 0;
end

////////////////////////////////////////////////////////////
// AXI STUB — always accept writes, return 0 on reads
////////////////////////////////////////////////////////////
wire [31:0] m_axi_awaddr;
wire        m_axi_awvalid;
reg         m_axi_awready;
wire [31:0] m_axi_wdata;
wire [ 3:0] m_axi_wstrb;
wire        m_axi_wvalid;
reg         m_axi_wready;
reg  [ 1:0] m_axi_bresp;
reg         m_axi_bvalid;
wire        m_axi_bready;
wire [31:0] m_axi_araddr;
wire        m_axi_arvalid;
reg         m_axi_arready;
wire [31:0] m_axi_rdata_out;
reg  [31:0] m_axi_rdata;
reg  [ 1:0] m_axi_rresp;
reg         m_axi_rvalid;
wire        m_axi_rready;

// Simple AXI slave: accept everything immediately
always @(posedge clk or posedge reset) begin
    if (reset) begin
        m_axi_awready <= 1'b0;
        m_axi_wready  <= 1'b0;
        m_axi_bvalid  <= 1'b0;
        m_axi_bresp   <= 2'b00;
        m_axi_arready <= 1'b0;
        m_axi_rvalid  <= 1'b0;
        m_axi_rdata   <= 32'h0;
        m_axi_rresp   <= 2'b00;
    end
    else begin
        // Write: accept addr+data in one cycle, respond next
        m_axi_awready <= m_axi_awvalid && !m_axi_awready;
        m_axi_wready  <= m_axi_wvalid  && !m_axi_wready;
        if (m_axi_awready && m_axi_wready) begin
            m_axi_bvalid <= 1'b1;
        end
        else if (m_axi_bready && m_axi_bvalid) begin
            m_axi_bvalid <= 1'b0;
        end

        // Read: accept addr, respond next cycle
        m_axi_arready <= m_axi_arvalid && !m_axi_arready;
        if (m_axi_arready) begin
            m_axi_rvalid <= 1'b1;
            m_axi_rdata  <= 32'hDEAD_BEEF;  // stub data
        end
        else if (m_axi_rready && m_axi_rvalid) begin
            m_axi_rvalid <= 1'b0;
        end
    end
end

////////////////////////////////////////////////////////////
// DUT
////////////////////////////////////////////////////////////
wire       uart_tx_out;
wire       c0_exception, c1_exception;
wire [31:0] c0_pc_out, c0_inst_word_out;
wire [31:0] c1_pc_out, c1_inst_word_out;

soc_axi_top #(
    .RESET_C0  (32'h0000_0000),
    .RESET_C1  (32'h0000_0200),
    .CLK_FREQ  (100_000_000),
    .BAUD_RATE (115200)
) DUT (
    .clk              (clk),
    .reset            (reset),

    .bl_imem_we        (1'b0),
    .bl_imem_addr      (10'd0),
    .bl_imem_wdata     (32'd0),

    .bl_dmem_we        (1'b0),
    .bl_dmem_addr      (10'd0),
    .bl_dmem_wdata     (32'd0),

    // AXI4-Lite
    .m_axi_awaddr     (m_axi_awaddr),
    .m_axi_awvalid    (m_axi_awvalid),
    .m_axi_awready    (m_axi_awready),
    .m_axi_awprot     (),
    .m_axi_wdata      (m_axi_wdata),
    .m_axi_wstrb      (m_axi_wstrb),
    .m_axi_wvalid     (m_axi_wvalid),
    .m_axi_wready     (m_axi_wready),
    .m_axi_bresp      (m_axi_bresp),
    .m_axi_bvalid     (m_axi_bvalid),
    .m_axi_bready     (m_axi_bready),
    .m_axi_araddr     (m_axi_araddr),
    .m_axi_arvalid    (m_axi_arvalid),
    .m_axi_arready    (m_axi_arready),
    .m_axi_arprot     (),
    .m_axi_rdata      (m_axi_rdata),
    .m_axi_rresp      (m_axi_rresp),
    .m_axi_rvalid     (m_axi_rvalid),
    .m_axi_rready     (m_axi_rready),

    // UART
    .uart_tx          (uart_tx_out),

    // Debug
    .c0_exception     (c0_exception),
    .c0_pc_out        (c0_pc_out),
    .c0_inst_word_out (c0_inst_word_out),
    .c1_exception     (c1_exception),
    .c1_pc_out        (c1_pc_out),
    .c1_inst_word_out (c1_inst_word_out)
);

////////////////////////////////////////////////////////////
// MONITORING
////////////////////////////////////////////////////////////
reg [31:0] ctr;
reg c0_done, c1_done;
reg [3:0] c0_halt_cnt, c1_halt_cnt;

initial begin
    ctr = 0;
    c0_done = 0;
    c1_done = 0;
    c0_halt_cnt = 0;
    c1_halt_cnt = 0;
end

// Access internal store monitor
wire c0_dmem_wr = DUT.u_dual_core.c0_dmem_write_ready;
wire [31:0] c0_dmem_data = DUT.u_dual_core.c0_dmem_write_data;
wire c1_dmem_wr = DUT.u_dual_core.c1_dmem_write_ready;
wire [31:0] c1_dmem_data = DUT.u_dual_core.c1_dmem_write_data;

always @(posedge clk) begin
    ctr <= ctr + 1;

    if (c0_dmem_wr)
        $display("C0 time:%0t  store=%0d (0x%08h)  inst=%h", $time, c0_dmem_data, c0_dmem_data, c0_inst_word_out);
    if (c1_dmem_wr)
        $display("C1 time:%0t  store=%0d (0x%08h)  inst=%h", $time, c1_dmem_data, c1_dmem_data, c1_inst_word_out);

    // UART byte sent detection (write interface level)
    if (DUT.u_uart.wr_en)
        $display("[UART-WR] time:%0t  TX byte = 0x%02h ('%c')", $time, DUT.u_uart.wr_data, DUT.u_uart.wr_data);

    // End-of-program detection
    // The halt loops in boot.S are at 0x14 for Core 0 and 0x210 for Core 1.
    // We require the PC to remain at the halt loop for 5 cycles to ensure
    // it's not just a transient fetch during a jump/branch flush.
    if (!c0_done && (c0_pc_out == 32'h00000014) && (c0_inst_word_out == 32'h0000006f)) begin
        c0_halt_cnt <= c0_halt_cnt + 1;
        if (c0_halt_cnt > 5) begin
            $display("--- Core 0 finished at time %0t, cycles = %0d ---", $time, ctr);
            c0_done <= 1'b1;
        end
    end else begin
        c0_halt_cnt <= 0;
    end

    if (!c1_done && (c1_pc_out == 32'h00000210) && (c1_inst_word_out == 32'h0000006f)) begin
        c1_halt_cnt <= c1_halt_cnt + 1;
        if (c1_halt_cnt > 5) begin
            $display("--- Core 1 finished at time %0t, cycles = %0d ---", $time, ctr);
            c1_done <= 1'b1;
        end
    end else begin
        c1_halt_cnt <= 0;
    end
    if (c0_done && c1_done) begin
        // Print accumulated UART string before finishing
        uart_rx_print_string;
        $display("============================================");
        $display("Both cores finished. Total cycles = %0d", ctr);
        $display("============================================");
        $finish;
    end
end

////////////////////////////////////////////////////////////
// UART BITSTREAM DECODER — decodes serial TX output
////////////////////////////////////////////////////////////
// 8N1 protocol: start bit (low), 8 data bits LSB first, stop bit (high)
// At 100 MHz / 115200 baud ≈ 868 clocks per bit
// Sample at bit center (half-bit offset from start edge)
////////////////////////////////////////////////////////////
localparam CLKS_PER_BIT = 868;            // 100_000_000 / 115_200
localparam HALF_BIT     = CLKS_PER_BIT / 2;
localparam UART_BUF_SZ  = 256;           // max characters to capture

reg [7:0]  uart_rx_buf [0:UART_BUF_SZ-1]; // received character buffer
reg [7:0]  uart_rx_count;                  // number of chars received
reg [1:0]  uart_rx_state;                  // 0=idle, 1=start, 2=data, 3=stop
reg [15:0] uart_rx_clk_cnt;               // clock counter within bit
reg [2:0]  uart_rx_bit_idx;               // current data bit (0..7)
reg [7:0]  uart_rx_shift;                 // shift register for incoming byte
reg        uart_tx_prev;                   // previous TX line state

localparam URX_IDLE  = 2'd0,
           URX_START = 2'd1,
           URX_DATA  = 2'd2,
           URX_STOP  = 2'd3;

integer uart_i;
initial begin
    uart_rx_count  = 8'd0;
    uart_rx_state  = URX_IDLE;
    uart_rx_clk_cnt = 16'd0;
    uart_rx_bit_idx = 3'd0;
    uart_rx_shift  = 8'd0;
    uart_tx_prev   = 1'b1;
    for (uart_i = 0; uart_i < UART_BUF_SZ; uart_i = uart_i + 1)
        uart_rx_buf[uart_i] = 8'd0;
end

always @(posedge clk) begin
    if (!reset) begin
        uart_tx_prev <= uart_tx_out;

        case (uart_rx_state)
            URX_IDLE: begin
                // Detect falling edge (start bit) on TX line
                if (uart_tx_prev == 1'b1 && uart_tx_out == 1'b0) begin
                    uart_rx_state   <= URX_START;
                    uart_rx_clk_cnt <= 16'd0;
                end
            end

            URX_START: begin
                // Wait until bit center of start bit to confirm it's still low
                if (uart_rx_clk_cnt == HALF_BIT - 1) begin
                    if (uart_tx_out == 1'b0) begin
                        // Valid start bit — begin sampling data bits
                        uart_rx_state   <= URX_DATA;
                        uart_rx_clk_cnt <= 16'd0;
                        uart_rx_bit_idx <= 3'd0;
                        uart_rx_shift   <= 8'd0;
                    end else begin
                        // False start — back to idle
                        uart_rx_state <= URX_IDLE;
                    end
                end else begin
                    uart_rx_clk_cnt <= uart_rx_clk_cnt + 16'd1;
                end
            end

            URX_DATA: begin
                // Sample each data bit at its center (1 full bit period apart)
                if (uart_rx_clk_cnt == CLKS_PER_BIT - 1) begin
                    uart_rx_clk_cnt <= 16'd0;
                    // LSB first: shift in from MSB side
                    uart_rx_shift <= {uart_tx_out, uart_rx_shift[7:1]};
                    if (uart_rx_bit_idx == 3'd7) begin
                        uart_rx_state <= URX_STOP;
                    end else begin
                        uart_rx_bit_idx <= uart_rx_bit_idx + 3'd1;
                    end
                end else begin
                    uart_rx_clk_cnt <= uart_rx_clk_cnt + 16'd1;
                end
            end

            URX_STOP: begin
                // Wait for stop bit center
                if (uart_rx_clk_cnt == CLKS_PER_BIT - 1) begin
                    // Byte complete — store and display
                    if (uart_rx_count < UART_BUF_SZ) begin
                        uart_rx_buf[uart_rx_count] <= uart_rx_shift;
                        uart_rx_count <= uart_rx_count + 8'd1;
                    end
                    if (uart_rx_shift >= 8'h20 && uart_rx_shift < 8'h7F)
                        $display("[UART-RX] time:%0t  byte=0x%02h '%c'", $time, uart_rx_shift, uart_rx_shift);
                    else
                        $display("[UART-RX] time:%0t  byte=0x%02h", $time, uart_rx_shift);
                    uart_rx_state <= URX_IDLE;
                end else begin
                    uart_rx_clk_cnt <= uart_rx_clk_cnt + 16'd1;
                end
            end
        endcase
    end
end

// Task to print the complete received UART string at end of simulation
task uart_rx_print_string;
    integer idx;
    begin
        $write("[UART-RX] Complete string (%0d bytes): \"", uart_rx_count);
        for (idx = 0; idx < uart_rx_count; idx = idx + 1) begin
            if (uart_rx_buf[idx] == 8'h0D)
                $write("\\r");
            else if (uart_rx_buf[idx] == 8'h0A)
                $write("\\n");
            else if (uart_rx_buf[idx] >= 8'h20 && uart_rx_buf[idx] < 8'h7F)
                $write("%c", uart_rx_buf[idx]);
            else
                $write("\\x%02h", uart_rx_buf[idx]);
        end
        $display("\"");
    end
endtask

////////////////////////////////////////////////////////////
// SIMULATION CONTROL
////////////////////////////////////////////////////////////
initial begin
    $dumpfile("soc_waveforms.vcd");
    $dumpvars(0, tb_soc);
    #20000000;
    $display("TIMEOUT: simulation exceeded 20000000 time units");
    uart_rx_print_string;
    $finish;
end

endmodule

