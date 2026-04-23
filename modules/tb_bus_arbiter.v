`timescale 1ns/1ps
// ============================================================================
// Testbench for Bus Arbiter — Registered Writeback Path
// ============================================================================
module tb_bus_arbiter;

    reg clk, reset;

    // IC fill ports
    reg c0_ic_req, c1_ic_req;
    reg [31:0] c0_ic_addr, c1_ic_addr;
    wire [127:0] c0_ic_rdata, c1_ic_rdata;
    wire c0_ic_ready, c1_ic_ready;
    wire mem_ic_req;
    wire [31:0] mem_ic_addr;
    reg [127:0] mem_ic_rdata;
    reg mem_ic_ready;

    // DC fill ports
    reg c0_dc_fill_req, c1_dc_fill_req;
    reg [31:0] c0_dc_fill_addr, c1_dc_fill_addr;
    wire [127:0] c0_dc_fill_rdata, c1_dc_fill_rdata;
    wire c0_dc_fill_ready, c1_dc_fill_ready;
    wire mem_dc_fill_req;
    wire [31:0] mem_dc_fill_addr;
    reg [127:0] mem_dc_fill_rdata;
    reg mem_dc_fill_ready;

    // DC WB ports
    reg c0_dc_wb_req, c1_dc_wb_req;
    reg [31:0] c0_dc_wb_addr, c1_dc_wb_addr;
    reg [127:0] c0_dc_wb_wdata, c1_dc_wb_wdata;
    wire c0_dc_wb_ready, c1_dc_wb_ready;
    wire mem_dc_wb_req;
    wire [31:0] mem_dc_wb_addr;
    wire [127:0] mem_dc_wb_wdata;
    reg mem_dc_wb_ready;

    // Atomic ports
    reg c0_atomic_req, c1_atomic_req;
    reg c0_atomic_we, c1_atomic_we;
    reg [31:0] c0_atomic_addr, c1_atomic_addr;
    reg [31:0] c0_atomic_wdata, c1_atomic_wdata;
    wire [31:0] c0_atomic_rdata, c1_atomic_rdata;
    wire c0_atomic_ready, c1_atomic_ready;
    wire mem_atomic_req, mem_atomic_we;
    wire [31:0] mem_atomic_addr, mem_atomic_wdata;
    reg [31:0] mem_atomic_rdata;
    reg mem_atomic_ready;

    wire dc_wb_grant;

    bus_arbiter uut (
        .clk(clk), .reset(reset),
        .c0_ic_req(c0_ic_req), .c0_ic_addr(c0_ic_addr),
        .c0_ic_rdata(c0_ic_rdata), .c0_ic_ready(c0_ic_ready),
        .c1_ic_req(c1_ic_req), .c1_ic_addr(c1_ic_addr),
        .c1_ic_rdata(c1_ic_rdata), .c1_ic_ready(c1_ic_ready),
        .mem_ic_req(mem_ic_req), .mem_ic_addr(mem_ic_addr),
        .mem_ic_rdata(mem_ic_rdata), .mem_ic_ready(mem_ic_ready),
        .c0_dc_fill_req(c0_dc_fill_req), .c0_dc_fill_addr(c0_dc_fill_addr),
        .c0_dc_fill_rdata(c0_dc_fill_rdata), .c0_dc_fill_ready(c0_dc_fill_ready),
        .c1_dc_fill_req(c1_dc_fill_req), .c1_dc_fill_addr(c1_dc_fill_addr),
        .c1_dc_fill_rdata(c1_dc_fill_rdata), .c1_dc_fill_ready(c1_dc_fill_ready),
        .mem_dc_fill_req(mem_dc_fill_req), .mem_dc_fill_addr(mem_dc_fill_addr),
        .mem_dc_fill_rdata(mem_dc_fill_rdata), .mem_dc_fill_ready(mem_dc_fill_ready),
        .c0_dc_wb_req(c0_dc_wb_req), .c0_dc_wb_addr(c0_dc_wb_addr),
        .c0_dc_wb_wdata(c0_dc_wb_wdata), .c0_dc_wb_ready(c0_dc_wb_ready),
        .c1_dc_wb_req(c1_dc_wb_req), .c1_dc_wb_addr(c1_dc_wb_addr),
        .c1_dc_wb_wdata(c1_dc_wb_wdata), .c1_dc_wb_ready(c1_dc_wb_ready),
        .mem_dc_wb_req(mem_dc_wb_req), .mem_dc_wb_addr(mem_dc_wb_addr),
        .mem_dc_wb_wdata(mem_dc_wb_wdata), .mem_dc_wb_ready(mem_dc_wb_ready),
        .c0_atomic_req(c0_atomic_req), .c0_atomic_we(c0_atomic_we),
        .c0_atomic_addr(c0_atomic_addr), .c0_atomic_wdata(c0_atomic_wdata),
        .c0_atomic_rdata(c0_atomic_rdata), .c0_atomic_ready(c0_atomic_ready),
        .c1_atomic_req(c1_atomic_req), .c1_atomic_we(c1_atomic_we),
        .c1_atomic_addr(c1_atomic_addr), .c1_atomic_wdata(c1_atomic_wdata),
        .c1_atomic_rdata(c1_atomic_rdata), .c1_atomic_ready(c1_atomic_ready),
        .mem_atomic_req(mem_atomic_req), .mem_atomic_we(mem_atomic_we),
        .mem_atomic_addr(mem_atomic_addr), .mem_atomic_wdata(mem_atomic_wdata),
        .mem_atomic_rdata(mem_atomic_rdata), .mem_atomic_ready(mem_atomic_ready),
        .dc_wb_grant(dc_wb_grant)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0, fail_count = 0;

    initial begin
        $dumpfile("tb_bus_arbiter.vcd");
        $dumpvars(0, tb_bus_arbiter);

        // Init all signals
        reset = 1;
        c0_ic_req=0; c1_ic_req=0; c0_ic_addr=0; c1_ic_addr=0;
        c0_dc_fill_req=0; c1_dc_fill_req=0; c0_dc_fill_addr=0; c1_dc_fill_addr=0;
        c0_dc_wb_req=0; c1_dc_wb_req=0;
        c0_dc_wb_addr=0; c1_dc_wb_addr=0;
        c0_dc_wb_wdata=0; c1_dc_wb_wdata=0;
        c0_atomic_req=0; c1_atomic_req=0;
        c0_atomic_we=0; c1_atomic_we=0;
        c0_atomic_addr=0; c1_atomic_addr=0;
        c0_atomic_wdata=0; c1_atomic_wdata=0;
        mem_ic_rdata=0; mem_ic_ready=0;
        mem_dc_fill_rdata=0; mem_dc_fill_ready=0;
        mem_dc_wb_ready=0;
        mem_atomic_rdata=0; mem_atomic_ready=0;
        #30; reset=0; #10;

        // =============================================================
        // Test 1: Core 0 writeback — registered data path
        // =============================================================
        $display("\n--- Test 1: Core 0 WB registered path ---");
        c0_dc_wb_req   = 1;
        c0_dc_wb_addr  = 32'hAAAA_0000;
        c0_dc_wb_wdata = {32'hDDDD_DDDD, 32'hCCCC_CCCC,
                          32'hBBBB_BBBB, 32'hAAAA_AAAA};
        @(posedge clk); // IDLE -> BUSY
        @(posedge clk); // BUSY, req should be asserted
        // Verify registered data
        if (mem_dc_wb_req === 1'b1 &&
            mem_dc_wb_addr === 32'hAAAA_0000 &&
            mem_dc_wb_wdata[31:0] === 32'hAAAA_AAAA) begin
            $display("[PASS] Core 0 WB data registered correctly");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] WB data mismatch (req=%b addr=%h w0=%h)",
                     mem_dc_wb_req, mem_dc_wb_addr, mem_dc_wb_wdata[31:0]);
            fail_count = fail_count + 1;
        end

        // Complete the transaction
        mem_dc_wb_ready = 1;
        @(posedge clk); // BUSY -> DONE
        mem_dc_wb_ready = 0;
        c0_dc_wb_req = 0;

        if (c0_dc_wb_ready === 1'b1) begin
            $display("[PASS] Core 0 WB ready routed correctly");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Core 0 WB ready not asserted");
            fail_count = fail_count + 1;
        end
        @(posedge clk); // DONE -> IDLE

        // =============================================================
        // Test 2: Core 1 writeback
        // =============================================================
        $display("\n--- Test 2: Core 1 WB ---");
        @(posedge clk);
        c1_dc_wb_req   = 1;
        c1_dc_wb_addr  = 32'h5555_0000;
        c1_dc_wb_wdata = {32'h4444, 32'h3333, 32'h2222, 32'h1111};
        @(posedge clk); @(posedge clk);
        if (mem_dc_wb_addr === 32'h5555_0000 && dc_wb_grant === 1'b1) begin
            $display("[PASS] Core 1 WB granted correctly");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Core 1 WB grant wrong (addr=%h grant=%b)",
                     mem_dc_wb_addr, dc_wb_grant);
            fail_count = fail_count + 1;
        end
        mem_dc_wb_ready = 1;
        @(posedge clk);
        mem_dc_wb_ready = 0;
        c1_dc_wb_req = 0;
        @(posedge clk);

        // =============================================================
        // Test 3: Simultaneous requests — core 0 priority
        // =============================================================
        $display("\n--- Test 3: Simultaneous WB, core 0 priority ---");
        @(posedge clk);
        c0_dc_wb_req = 1; c0_dc_wb_addr = 32'hC0_0000;
        c1_dc_wb_req = 1; c1_dc_wb_addr = 32'hC1_0000;
        @(posedge clk); @(posedge clk);
        if (dc_wb_grant === 1'b0 && mem_dc_wb_addr === 32'hC0_0000) begin
            $display("[PASS] Core 0 wins priority");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Priority wrong (grant=%b addr=%h)",
                     dc_wb_grant, mem_dc_wb_addr);
            fail_count = fail_count + 1;
        end
        mem_dc_wb_ready = 1; @(posedge clk);
        mem_dc_wb_ready = 0; c0_dc_wb_req = 0;
        @(posedge clk); // DONE->IDLE
        // Now core 1 should get served
        @(posedge clk); @(posedge clk);
        if (dc_wb_grant === 1'b1 && mem_dc_wb_addr === 32'hC1_0000) begin
            $display("[PASS] Core 1 served after core 0 done");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Core 1 not served (grant=%b addr=%h)",
                     dc_wb_grant, mem_dc_wb_addr);
            fail_count = fail_count + 1;
        end
        mem_dc_wb_ready = 1; @(posedge clk);
        mem_dc_wb_ready = 0; c1_dc_wb_req = 0;
        @(posedge clk);

        #20;
        $display("\n=== BUS ARBITER: %0d passed, %0d failed ===",
                 pass_count, fail_count);
        $finish;
    end

    initial begin #100000; $display("[TIMEOUT]"); $finish; end
endmodule
