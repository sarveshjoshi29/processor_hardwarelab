`timescale 1ns/1ps
// ============================================================================
// Testbench — UART Bootloader parser + memory write ports
// ============================================================================
// Feeds ASCII hex with '//' comments into uart_bootloader and verifies
// that instr_mem/data_mem arrays are programmed sequentially.
// ============================================================================

`include "memory.v"
`include "uart_bootloader.v"

module tb_uart_bootloader;

    reg clk;
    reg reset;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk; // 100 MHz
    end

    initial begin
        reset = 1'b1;
        #30;
        reset = 1'b0;
    end

    reg enable;
    reg rx_valid;
    reg [7:0] rx_byte;

    wire        imem_we;
    wire [9:0]  imem_addr;
    wire [31:0] imem_wdata;

    wire        dmem_we;
    wire [9:0]  dmem_addr;
    wire [31:0] dmem_wdata;

    wire done;

    uart_bootloader #(
        .IMEM_WORDS(4),
        .DMEM_WORDS(4)
    ) u_bl (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .rx_valid(rx_valid),
        .rx_byte(rx_byte),
        .imem_we(imem_we),
        .imem_addr(imem_addr),
        .imem_wdata(imem_wdata),
        .dmem_we(dmem_we),
        .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata),
        .done(done)
    );

    // Memories under test
    instr_mem u_imem (
        .clk(clk),
        .reset(reset),
        .bl_we(imem_we),
        .bl_addr(imem_addr),
        .bl_wdata(imem_wdata),
        .ic_req(1'b0),
        .ic_addr(32'd0),
        .ic_rdata(),
        .ic_ready()
    );

    data_mem u_dmem (
        .clk(clk),
        .reset(reset),
        .bl_we(dmem_we),
        .bl_addr(dmem_addr),
        .bl_wdata(dmem_wdata),
        .dc_fill_req(1'b0),
        .dc_fill_addr(32'd0),
        .dc_fill_rdata(),
        .dc_fill_ready(),
        .dc_wb_req(1'b0),
        .dc_wb_addr(32'd0),
        .dc_wb_wdata(128'd0),
        .dc_wb_ready(),
        .atomic_req(1'b0),
        .atomic_we(1'b0),
        .atomic_addr(32'd0),
        .atomic_wdata(32'd0),
        .atomic_rdata(),
        .atomic_ready()
    );

    task send_byte;
        input [7:0] b;
        begin
            @(posedge clk);
            rx_byte  <= b;
            rx_valid <= 1'b1;
            @(posedge clk);
            rx_valid <= 1'b0;
        end
    endtask

    function [7:0] hex_char;
        input [3:0] n;
        begin
            if (n < 4'd10)
                hex_char = "0" + n;
            else
                hex_char = "a" + (n - 4'd10);
        end
    endfunction

    task send_hex32;
        input [31:0] w;
        integer k;
        reg [3:0] nib;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                nib = (w >> (k*4)) & 32'hF;
                send_byte(hex_char(nib));
            end
        end
    endtask

    task send_newline;
        begin
            send_byte(8'h0A);
        end
    endtask

    task send_space;
        begin
            send_byte(8'h20);
        end
    endtask

    task send_comment_addr;
        input [31:0] addr;
        begin
            // Send: " // 32'hXXXXXXXX\n" (contains extra hex digits to ensure loader ignores comments)
            send_space;
            send_byte("/");
            send_byte("/");
            send_space;
            send_byte("3");
            send_byte("2");
            send_byte("'");
            send_byte("h");
            send_hex32(addr);
            send_newline;
        end
    endtask

    initial begin
        enable   = 1'b0;
        rx_valid = 1'b0;
        rx_byte  = 8'h00;

        @(negedge reset);
        #20;

        // Start bootloader
        enable = 1'b1;

        // 4 imem words with comments (comment contains extra hex digits we must ignore)
        send_hex32(32'h11111111); send_comment_addr(32'h00000000);
        send_hex32(32'h22222222); send_comment_addr(32'h00000004);
        send_hex32(32'h33333333); send_comment_addr(32'h00000008);
        send_hex32(32'h44444444); send_comment_addr(32'h0000000c);

        // 4 dmem words
        send_hex32(32'hAAAA0001); send_newline;
        send_hex32(32'hBBBB0002); send_newline;
        send_hex32(32'hCCCC0003); send_newline;
        send_hex32(32'hDDDD0004); send_newline;

        // Wait for done
        repeat (20) @(posedge clk);

        if (!done) begin
            $display("FAIL: done not asserted");
            $finish;
        end

        // Verify programmed words
        if (u_imem.imem[0] !== 32'h11111111) begin $display("FAIL: imem[0] %h", u_imem.imem[0]); $finish; end
        if (u_imem.imem[1] !== 32'h22222222) begin $display("FAIL: imem[1] %h", u_imem.imem[1]); $finish; end
        if (u_imem.imem[2] !== 32'h33333333) begin $display("FAIL: imem[2] %h", u_imem.imem[2]); $finish; end
        if (u_imem.imem[3] !== 32'h44444444) begin $display("FAIL: imem[3] %h", u_imem.imem[3]); $finish; end

        if (u_dmem.dmem[0] !== 32'hAAAA0001) begin $display("FAIL: dmem[0] %h", u_dmem.dmem[0]); $finish; end
        if (u_dmem.dmem[1] !== 32'hBBBB0002) begin $display("FAIL: dmem[1] %h", u_dmem.dmem[1]); $finish; end
        if (u_dmem.dmem[2] !== 32'hCCCC0003) begin $display("FAIL: dmem[2] %h", u_dmem.dmem[2]); $finish; end
        if (u_dmem.dmem[3] !== 32'hDDDD0004) begin $display("FAIL: dmem[3] %h", u_dmem.dmem[3]); $finish; end

        $display("PASS: uart_bootloader programmed imem/dmem correctly");
        $finish;
    end

endmodule
