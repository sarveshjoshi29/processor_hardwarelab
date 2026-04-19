// uart_bootloader.v
`timescale 1ns/1ps
// ============================================================================
// UART Bootloader — loads imem + dmem from ASCII .hex streams
// ============================================================================
// Expected input format: the same style as existing imem.hex/dmem.hex files:
// - One 32-bit word per line as 8 hex chars (e.g. 0180006f)
// - Optional whitespace
// - Optional end-of-line comments using // ...
//
// Behavior:
// - When enable rises, clears internal counters and starts accepting bytes.
// - Consumes hex digits only; ignores whitespace.
// - Ignores anything after '//' until newline.
// - Writes sequential words:
//     first IMEM_WORDS words -> imem[0..]
//     then DMEM_WORDS words  -> dmem[0..]
// - Asserts done once both regions are filled.
// ============================================================================
module uart_bootloader #(
    parameter integer IMEM_WORDS = 1024,
    parameter integer DMEM_WORDS = 1024
)(
    input         clk,
    input         reset,

    input         enable,

    input         rx_valid,
    input  [7:0]  rx_byte,

    output reg        imem_we,
    output reg [9:0]  imem_addr,
    output reg [31:0] imem_wdata,

    output reg        dmem_we,
    output reg [9:0]  dmem_addr,
    output reg [31:0] dmem_wdata,

    output reg        done
);

    reg enable_d;

    reg        target_dmem; // 0 = imem, 1 = dmem
    integer    imem_count;
    integer    dmem_count;

    reg [2:0]  nibble_count;
    reg [31:0] word_shift;

    reg        in_comment;
    reg        slash_pending;

    function is_hex;
        input [7:0] c;
        begin
            is_hex = ((c >= "0" && c <= "9") ||
                      (c >= "a" && c <= "f") ||
                      (c >= "A" && c <= "F"));
        end
    endfunction

    function [3:0] hex_val;
        input [7:0] c;
        begin
            if (c >= "0" && c <= "9") hex_val = c - "0";
            else if (c >= "a" && c <= "f") hex_val = c - "a" + 4'd10;
            else if (c >= "A" && c <= "F") hex_val = c - "A" + 4'd10;
            else hex_val = 4'h0;
        end
    endfunction

    wire is_ws = (rx_byte == 8'h0A) || (rx_byte == 8'h0D) || (rx_byte == 8'h20) || (rx_byte == 8'h09);
    wire [3:0] rx_nibble = hex_val(rx_byte);
    wire [31:0] word_shift_next = {word_shift[27:0], rx_nibble};

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            enable_d      <= 1'b0;

            imem_we       <= 1'b0;
            imem_addr     <= 10'd0;
            imem_wdata    <= 32'd0;

            dmem_we       <= 1'b0;
            dmem_addr     <= 10'd0;
            dmem_wdata    <= 32'd0;

            done          <= 1'b0;

            target_dmem   <= 1'b0;
            imem_count    <= 0;
            dmem_count    <= 0;
            nibble_count  <= 3'd0;
            word_shift    <= 32'd0;

            in_comment    <= 1'b0;
            slash_pending <= 1'b0;
        end else begin
            enable_d <= enable;

            imem_we <= 1'b0;
            dmem_we <= 1'b0;

            // Restart loader on enable rising edge
            if (enable && !enable_d) begin
                done          <= 1'b0;
                target_dmem   <= 1'b0;
                imem_count    <= 0;
                dmem_count    <= 0;
                nibble_count  <= 3'd0;
                word_shift    <= 32'd0;
                in_comment    <= 1'b0;
                slash_pending <= 1'b0;
            end

            if (!enable) begin
                // idle when disabled
            end else if (!done && rx_valid) begin
                // comment handling
                if (in_comment) begin
                    if (rx_byte == 8'h0A || rx_byte == 8'h0D) begin
                        in_comment    <= 1'b0;
                        slash_pending <= 1'b0;
                    end
                end else begin
                    // Resolve pending '/' (used to detect '//' comments)
                    if (slash_pending) begin
                        if (rx_byte == "/") begin
                            in_comment    <= 1'b1;
                            slash_pending <= 1'b0;
                        end else begin
                            // Not a comment start; drop the previous '/' and process this byte.
                            slash_pending <= 1'b0;
                            if (rx_byte == "/") begin
                                slash_pending <= 1'b1;
                            end else if (is_ws) begin
                                // ignore
                            end else if (is_hex(rx_byte)) begin
                                word_shift <= word_shift_next;
                                if (nibble_count == 3'd7) begin
                                    nibble_count <= 3'd0;
                                    word_shift   <= 32'd0;

                                    if (!target_dmem) begin
                                        if (imem_count < IMEM_WORDS) begin
                                            imem_we    <= 1'b1;
                                            imem_addr  <= imem_count[9:0];
                                            imem_wdata <= word_shift_next;
                                            imem_count <= imem_count + 1;

                                            if (imem_count == IMEM_WORDS-1)
                                                target_dmem <= 1'b1;
                                        end
                                    end else begin
                                        if (dmem_count < DMEM_WORDS) begin
                                            dmem_we    <= 1'b1;
                                            dmem_addr  <= dmem_count[9:0];
                                            dmem_wdata <= word_shift_next;
                                            dmem_count <= dmem_count + 1;

                                            if (dmem_count == DMEM_WORDS-1)
                                                done <= 1'b1;
                                        end
                                    end
                                end else begin
                                    nibble_count <= nibble_count + 3'd1;
                                end
                            end
                        end
                    end else begin
                        if (rx_byte == "/") begin
                            slash_pending <= 1'b1;
                        end else if (is_ws) begin
                            // ignore
                        end else if (is_hex(rx_byte)) begin
                            word_shift <= word_shift_next;
                            if (nibble_count == 3'd7) begin
                                nibble_count <= 3'd0;
                                word_shift   <= 32'd0;

                                if (!target_dmem) begin
                                    if (imem_count < IMEM_WORDS) begin
                                        imem_we    <= 1'b1;
                                        imem_addr  <= imem_count[9:0];
                                        imem_wdata <= word_shift_next;
                                        imem_count <= imem_count + 1;

                                        if (imem_count == IMEM_WORDS-1)
                                            target_dmem <= 1'b1;
                                    end
                                end else begin
                                    if (dmem_count < DMEM_WORDS) begin
                                        dmem_we    <= 1'b1;
                                        dmem_addr  <= dmem_count[9:0];
                                        dmem_wdata <= word_shift_next;
                                        dmem_count <= dmem_count + 1;

                                        if (dmem_count == DMEM_WORDS-1)
                                            done <= 1'b1;
                                    end
                                end
                            end else begin
                                nibble_count <= nibble_count + 3'd1;
                            end
                        end else begin
                            // ignore other chars
                        end
                    end
                end
            end
        end
    end

endmodule
