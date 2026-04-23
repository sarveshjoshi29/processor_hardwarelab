`timescale 1ns/1ps
module tb;
    reg clk=0, reset=1;
    reg req=0, we=0;
    reg [31:0] addr=0, wdata=0;
    wire [31:0] rdata;
    wire ready;

    data_mem #(.MISS_CYCLES(4)) dm (
        .clk(clk), .reset(reset),
        .bl_we(1'b0), .bl_addr(10'b0), .bl_wdata(32'b0),
        .dc_fill_req(1'b0), .dc_fill_addr(32'b0),
        .dc_fill_rdata(), .dc_fill_ready(),
        .dc_wb_req(1'b0), .dc_wb_addr(32'b0), .dc_wb_wdata(128'b0),
        .dc_wb_ready(),
        .atomic_req(req), .atomic_we(we),
        .atomic_addr(addr), .atomic_wdata(wdata),
        .atomic_rdata(rdata), .atomic_ready(ready)
    );

    always #5 clk = ~clk;

    initial begin
        #20 reset=0;
        @(posedge clk);

        // Write 0xCAFEBABE to addr 0x100
        $display("=== SC.W ===");
        req=1; we=1; addr=32'h100; wdata=32'hCAFEBABE;
        #1; // let comb settle
        $display("t=%0t PRE-POSEDGE: rd_addr=%h a_state=%d req=%b", $time, dm.rd_addr, dm.a_state, req);
        @(posedge clk);
        #1;
        $display("t=%0t POST-POSEDGE-1: a_state=%d wr_en=%b wr_addr=%h wr_din=%h BRAM64=%h", 
                 $time, dm.a_state, dm.wr_en, dm.wr_addr, dm.wr_din, dm.dmem[64]);
        req=0; we=0;
        @(posedge clk);
        #1;
        $display("t=%0t POST-POSEDGE-2: a_state=%d rdy=%b BRAM64=%h", $time, dm.a_state, ready, dm.dmem[64]);
        @(posedge clk);
        #1;
        $display("t=%0t POST-POSEDGE-3: BRAM64=%h", $time, dm.dmem[64]);

        repeat(3) @(posedge clk);

        // Read addr 0x100
        $display("\n=== LR.W ===");
        $display("t=%0t BRAM64=%h", $time, dm.dmem[64]);
        req=1; we=0; addr=32'h100;
        #1;
        $display("t=%0t PRE-POSEDGE: rd_addr=%h a_state=%d", $time, dm.rd_addr, dm.a_state);
        @(posedge clk);
        #1;
        $display("t=%0t POST-1: a_state=%d rd_dout=%h rd_addr=%h", $time, dm.a_state, dm.rd_dout, dm.rd_addr);
        req=0;
        @(posedge clk);
        #1;
        $display("t=%0t POST-2: a_state=%d rd_dout=%h rdy=%b rdata=%h", $time, dm.a_state, dm.rd_dout, ready, rdata);
        @(posedge clk);
        #1;
        $display("t=%0t POST-3: rdata=%h", $time, rdata);

        #30; $finish;
    end
endmodule
