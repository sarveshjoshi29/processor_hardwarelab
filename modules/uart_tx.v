// uart_tx.v
`timescale 1ns/1ps
// ============================================================================
// UART Transmitter — 8N1, Configurable Baud Rate (Phase 5)
// ============================================================================
// Simple shift-register UART TX. Sends one byte at a time.
// 8 data bits, no parity, 1 stop bit.
//
// Memory-mapped interface:
//   Write: load byte into TX shift register, begin transmission
//   Read:  returns {31'b0, tx_busy}
//
// Parameters:
//   CLK_FREQ — system clock frequency in Hz (default 100 MHz)
//   BAUD     — baud rate (default 115200)
// ============================================================================
module uart_tx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD     = 115200
)(
    input         clk,
    input         reset,

    // ---- Simple write interface ----
    input         wr_en,             // 1 = load byte and start TX
    input  [ 7:0] wr_data,           // byte to transmit

    // ---- Status ----
    output        tx_busy,           // 1 = transmission in progress

    // ---- Serial output ----
    output reg    tx_out             // UART TX line (active-low start bit)
);

// ---- Baud rate divider ----
localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD;

// ---- State encoding ----
localparam [1:0] S_IDLE  = 2'd0,
                 S_START = 2'd1,
                 S_DATA  = 2'd2,
                 S_STOP  = 2'd3;

reg [1:0]  state;
reg [15:0] baud_cnt;       // baud rate counter
reg [ 2:0] bit_idx;        // which data bit (0–7)
reg [ 7:0] shift_reg;      // data being transmitted

assign tx_busy = (state != S_IDLE);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        state     <= S_IDLE;
        baud_cnt  <= 16'd0;
        bit_idx   <= 3'd0;
        shift_reg <= 8'd0;
        tx_out    <= 1'b1;           // idle high
    end
    else begin
        case (state)
            S_IDLE: begin
                tx_out   <= 1'b1;
                baud_cnt <= 16'd0;
                bit_idx  <= 3'd0;
                if (wr_en) begin
                    shift_reg <= wr_data;
                    state     <= S_START;
                end
            end

            S_START: begin
                tx_out <= 1'b0;      // start bit = low
                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt <= 16'd0;
                    state    <= S_DATA;
                end
                else begin
                    baud_cnt <= baud_cnt + 16'd1;
                end
            end

            S_DATA: begin
                tx_out <= shift_reg[0];   // LSB first
                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt  <= 16'd0;
                    shift_reg <= {1'b0, shift_reg[7:1]};
                    if (bit_idx == 3'd7) begin
                        state <= S_STOP;
                    end
                    else begin
                        bit_idx <= bit_idx + 3'd1;
                    end
                end
                else begin
                    baud_cnt <= baud_cnt + 16'd1;
                end
            end

            S_STOP: begin
                tx_out <= 1'b1;      // stop bit = high
                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt <= 16'd0;
                    state    <= S_IDLE;
                end
                else begin
                    baud_cnt <= baud_cnt + 16'd1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
