`timescale 1ns/1ps
// ============================================================================
// RV32M Iterative Restoring Divider (32-cycle)
// ============================================================================
// Computes quotient and remainder for both signed and unsigned 32-bit division.
// Special cases (RV32M spec):
//   - Division by zero : quotient = -1 (0xFFFFFFFF), remainder = dividend
//   - Signed overflow  : INT_MIN / -1 → quotient = INT_MIN, remainder = 0
//
// Timing:
//   - busy goes high the cycle after start
//   - done pulses high for 1 cycle when result is ready
//   - On the done cycle, busy is LOW — pipeline advances
//   - Special cases take 1 cycle (like the done cycle of normal operation)
// ============================================================================
module divider (
    input         clk,
    input         reset,

    input         start,
    input         signed_op,
    input  [31:0] dividend,
    input  [31:0] divisor,

    output reg        busy,
    output reg        done,
    output reg [31:0] quotient,
    output reg [31:0] remainder
);

localparam [31:0] INT_MIN = 32'h8000_0000;

// ---- Internal state ----
reg [5:0]  cycle_cnt;
reg [31:0] dvd_abs;       // |dividend|
reg [31:0] dvs_abs;       // |divisor|
reg [31:0] rem;           // partial remainder (32 bits)
reg [31:0] quot;          // quotient being built
reg        quot_sign;
reg        rem_sign;
reg        is_divzero;    // 1 = div-by-zero special case
reg        is_overflow;   // 1 = signed overflow (INT_MIN / -1) special case
reg [31:0] dvd_saved;     // original dividend (for div-by-zero remainder)

// ---- One step of restoring division ----
wire [32:0] shifted    = {rem[30:0], dvd_abs[31 - cycle_cnt]};
wire [32:0] subtracted = shifted - {1'b0, dvs_abs};
wire        no_borrow  = ~subtracted[32];

always @(posedge clk or posedge reset) begin
    if (reset) begin
        busy       <= 1'b0;
        done       <= 1'b0;
        quotient   <= 32'b0;
        remainder  <= 32'b0;
        cycle_cnt  <= 6'd0;
        dvd_abs    <= 32'b0;
        dvs_abs    <= 32'b0;
        rem        <= 32'b0;
        quot       <= 32'b0;
        quot_sign  <= 1'b0;
        rem_sign   <= 1'b0;
        is_divzero <= 1'b0;
        is_overflow<= 1'b0;
        dvd_saved  <= 32'b0;
    end
    else begin
        done <= 1'b0;  // clear done each cycle by default

        if (start && !busy) begin
            dvd_saved <= dividend;

            if (divisor == 32'b0) begin
                // Division by zero — handle in next cycle
                is_divzero  <= 1'b1;
                is_overflow <= 1'b0;
                busy        <= 1'b1;
            end
            else if (signed_op && (dividend == INT_MIN) && (divisor == 32'hFFFF_FFFF)) begin
                // Signed overflow — handle in next cycle
                is_divzero  <= 1'b0;
                is_overflow <= 1'b1;
                busy        <= 1'b1;
            end
            else begin
                // Normal operation
                is_divzero  <= 1'b0;
                is_overflow <= 1'b0;
                quot_sign   <= signed_op && (dividend[31] ^ divisor[31]);
                rem_sign    <= signed_op && dividend[31];
                dvd_abs     <= (signed_op && dividend[31]) ? (~dividend + 1) : dividend;
                dvs_abs     <= (signed_op && divisor[31])  ? (~divisor  + 1) : divisor;
                rem         <= 32'b0;
                quot        <= 32'b0;
                cycle_cnt   <= 6'd0;
                busy        <= 1'b1;
            end
        end
        else if (busy) begin
            if (is_divzero) begin
                // Division by zero: quotient = -1, remainder = original dividend
                quotient  <= 32'hFFFF_FFFF;
                remainder <= dvd_saved;
                done      <= 1'b1;
                busy      <= 1'b0;
            end
            else if (is_overflow) begin
                // Signed overflow: quotient = INT_MIN, remainder = 0
                quotient  <= INT_MIN;
                remainder <= 32'b0;
                done      <= 1'b1;
                busy      <= 1'b0;
            end
            else if (cycle_cnt < 6'd32) begin
                // One restoring division step
                if (no_borrow) begin
                    rem  <= subtracted[31:0];
                    quot <= {quot[30:0], 1'b1};
                end else begin
                    rem  <= shifted[31:0];
                    quot <= {quot[30:0], 1'b0};
                end
                cycle_cnt <= cycle_cnt + 1;
            end
            else begin
                // 32 bits computed — apply signs and output
                quotient  <= quot_sign ? (~quot + 1) : quot;
                remainder <= rem_sign  ? (~rem  + 1) : rem;
                done      <= 1'b1;
                busy      <= 1'b0;
            end
        end
    end
end

endmodule
