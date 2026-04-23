// uart_rx.v
`timescale 1ns/1ps
// ============================================================================
// UART Receiver — 8N1, Configurable Baud Rate
// ============================================================================
// - 8 data bits, no parity, 1 stop bit
// - Samples each bit in the middle of the bit period.
// - Presents a 1-cycle pulse on data_valid when a byte is received.
// ============================================================================
module uart_rx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD     = 115200
)(
    input         clk,
    input         reset,

    input         rx_in,

    output reg [7:0] data_out,
    output reg       data_valid
);

    localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD;

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] baud_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift_reg;

    // 2-FF metastability synchronizer on async rx_in. Without this, the
    // FSM samples a glitching/metastable input directly and can shift in
    // corrupted bits (observed: single-bit flips like 't'→'|').
    (* ASYNC_REG = "TRUE" *)
    reg rx_sync_0, rx_sync_1;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            rx_sync_0 <= 1'b1;
            rx_sync_1 <= 1'b1;
        end else begin
            rx_sync_0 <= rx_in;
            rx_sync_1 <= rx_sync_0;
        end
    end
    wire rx_s = rx_sync_1;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state      <= S_IDLE;
            baud_cnt   <= 32'd0;
            bit_idx    <= 3'd0;
            shift_reg  <= 8'd0;
            data_out   <= 8'd0;
            data_valid <= 1'b0;
        end else begin
            data_valid <= 1'b0;
            case (state)
                S_IDLE: begin
                    baud_cnt <= 32'd0;
                    bit_idx  <= 3'd0;
                    if (!rx_s) begin
                        // Potential start bit detected
                        state    <= S_START;
                        baud_cnt <= 32'd0;
                    end
                end

                S_START: begin
                    // Wait half a bit, then confirm start bit still low
                    if (baud_cnt >= (CLKS_PER_BIT/2)) begin
                        if (!rx_s) begin
                            state    <= S_DATA;
                            baud_cnt <= 32'd0;
                            bit_idx  <= 3'd0;
                        end else begin
                            state <= S_IDLE; // false start
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 32'd1;
                    end
                end

                S_DATA: begin
                    if (baud_cnt == CLKS_PER_BIT - 1) begin
                        baud_cnt <= 32'd0;
                        shift_reg[bit_idx] <= rx_s; // LSB first
                        if (bit_idx == 3'd7) begin
                            state   <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 32'd1;
                    end
                end

                S_STOP: begin
                    if (baud_cnt == CLKS_PER_BIT - 1) begin
                        baud_cnt   <= 32'd0;
                        data_out   <= shift_reg;
                        data_valid <= 1'b1;
                        state      <= S_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt + 32'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
