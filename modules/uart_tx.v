`timescale 1ns/1ps

// Simple 8N1 UART transmitter with ready/valid byte interface.
// - LSB-first, 1 start bit (0), 1 stop bit (1)
// - `valid` is sampled when `ready` is high; one byte per handshake
module uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       reset,

    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,

    output reg        tx
);

    // Integer divider; for 100MHz/115200 this is 868 (error ~0.006%).
    localparam integer BAUD_DIV = (CLK_HZ / BAUD);

    localparam [1:0]
        S_IDLE  = 2'd0,
        S_START = 2'd1,
        S_DATA  = 2'd2,
        S_STOP  = 2'd3;

    reg [1:0] state;
    reg [12:0] baud_cnt;      // big enough for BAUD_DIV up to ~8191
    reg [2:0] bit_idx;
    reg [7:0] shreg;

    assign ready = (state == S_IDLE);

    wire baud_tick = (baud_cnt == (BAUD_DIV - 1));

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state    <= S_IDLE;
            baud_cnt <= 13'd0;
            bit_idx  <= 3'd0;
            shreg    <= 8'h00;
            tx       <= 1'b1;
        end else begin
            case (state)
                S_IDLE: begin
                    tx       <= 1'b1;
                    baud_cnt <= 13'd0;
                    bit_idx  <= 3'd0;
                    if (valid) begin
                        shreg <= data;
                        state <= S_START;
                    end
                end

                S_START: begin
                    tx <= 1'b0;
                    if (baud_tick) begin
                        baud_cnt <= 13'd0;
                        state    <= S_DATA;
                        bit_idx  <= 3'd0;
                    end else begin
                        baud_cnt <= baud_cnt + 13'd1;
                    end
                end

                S_DATA: begin
                    tx <= shreg[0];
                    if (baud_tick) begin
                        baud_cnt <= 13'd0;
                        shreg    <= {1'b0, shreg[7:1]};
                        if (bit_idx == 3'd7)
                            state <= S_STOP;
                        else
                            bit_idx <= bit_idx + 3'd1;
                    end else begin
                        baud_cnt <= baud_cnt + 13'd1;
                    end
                end

                S_STOP: begin
                    tx <= 1'b1;
                    if (baud_tick) begin
                        baud_cnt <= 13'd0;
                        state    <= S_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt + 13'd1;
                    end
                end

                default: begin
                    state <= S_IDLE;
                    tx    <= 1'b1;
                end
            endcase
        end
    end

endmodule
