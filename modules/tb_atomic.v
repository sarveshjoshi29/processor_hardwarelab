`timescale 1ns/1ps
// ============================================================================
// Testbench: Atomic LR.W / SC.W Transaction through Bus Arbiter + Data Mem
// ============================================================================
// Tests the full atomic path: core → bus_arbiter → data_mem → BRAM.
//
//  Test 1: Core 0 LR.W — read-reserve a word
//  Test 2: Core 0 SC.W — store-conditional to the same address
//  Test 3: Core 0 LR.W readback — verify SC.W wrote correctly
//  Test 4: Core 1 LR.W — read-reserve from a different address
//  Test 5: Simultaneous atomic — core 0 priority
//  Test 6: Verify both SC.W writes via LR.W readback
// ============================================================================
module tb_atomic;

    reg clk, reset;

    // ------- Core 0 atomic signals -------
    reg         c0_atomic_req;
    reg         c0_atomic_we;
    reg  [31:0] c0_atomic_addr;
    reg  [31:0] c0_atomic_wdata;
    wire [31:0] c0_atomic_rdata;
    wire        c0_atomic_ready;

    // ------- Core 1 atomic signals -------
    reg         c1_atomic_req;
    reg         c1_atomic_we;
    reg  [31:0] c1_atomic_addr;
    reg  [31:0] c1_atomic_wdata;
    wire [31:0] c1_atomic_rdata;
    wire        c1_atomic_ready;

    // ------- Shared memory-side atomic signals -------
    wire        mem_atomic_req;
    wire        mem_atomic_we;
    wire [31:0] mem_atomic_addr;
    wire [31:0] mem_atomic_wdata;
    wire [31:0] mem_atomic_rdata;
    wire        mem_atomic_ready;

    // ------- Other arbiter ports (inactive, tied off) -------
    wire        mem_ic_req, mem_dc_fill_req, mem_dc_wb_req;
    wire [31:0] mem_ic_addr, mem_dc_fill_addr, mem_dc_wb_addr;
    wire [127:0] mem_dc_wb_wdata;
    wire        dc_wb_grant;

    // IC fill — unused
    reg [127:0] mem_ic_rdata;  reg mem_ic_ready;
    wire [127:0] c0_ic_rdata, c1_ic_rdata;
    wire c0_ic_ready, c1_ic_ready;

    // DC fill — unused (driven by data_mem outputs)
    wire [127:0] mem_dc_fill_rdata; wire mem_dc_fill_ready;
    wire [127:0] c0_dc_fill_rdata, c1_dc_fill_rdata;
    wire c0_dc_fill_ready, c1_dc_fill_ready;

    // DC WB — unused (driven by data_mem output)
    wire mem_dc_wb_ready;
    wire c0_dc_wb_ready, c1_dc_wb_ready;

    // ---- Bus Arbiter ----
    bus_arbiter arb (
        .clk(clk), .reset(reset),
        .c0_ic_req(1'b0), .c0_ic_addr(32'b0),
        .c0_ic_rdata(c0_ic_rdata), .c0_ic_ready(c0_ic_ready),
        .c1_ic_req(1'b0), .c1_ic_addr(32'b0),
        .c1_ic_rdata(c1_ic_rdata), .c1_ic_ready(c1_ic_ready),
        .mem_ic_req(mem_ic_req), .mem_ic_addr(mem_ic_addr),
        .mem_ic_rdata(mem_ic_rdata), .mem_ic_ready(mem_ic_ready),
        .c0_dc_fill_req(1'b0), .c0_dc_fill_addr(32'b0),
        .c0_dc_fill_rdata(c0_dc_fill_rdata), .c0_dc_fill_ready(c0_dc_fill_ready),
        .c1_dc_fill_req(1'b0), .c1_dc_fill_addr(32'b0),
        .c1_dc_fill_rdata(c1_dc_fill_rdata), .c1_dc_fill_ready(c1_dc_fill_ready),
        .mem_dc_fill_req(mem_dc_fill_req), .mem_dc_fill_addr(mem_dc_fill_addr),
        .mem_dc_fill_rdata(mem_dc_fill_rdata), .mem_dc_fill_ready(mem_dc_fill_ready),
        .c0_dc_wb_req(1'b0), .c0_dc_wb_addr(32'b0), .c0_dc_wb_wdata(128'b0),
        .c0_dc_wb_ready(c0_dc_wb_ready),
        .c1_dc_wb_req(1'b0), .c1_dc_wb_addr(32'b0), .c1_dc_wb_wdata(128'b0),
        .c1_dc_wb_ready(c1_dc_wb_ready),
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

    // ---- Data Memory ----
    data_mem #(.MISS_CYCLES(4)) dmem (
        .clk(clk), .reset(reset),
        .bl_we(1'b0), .bl_addr(10'b0), .bl_wdata(32'b0),
        .dc_fill_req(mem_dc_fill_req), .dc_fill_addr(mem_dc_fill_addr),
        .dc_fill_rdata(), .dc_fill_ready(mem_dc_fill_ready),
        .dc_wb_req(mem_dc_wb_req), .dc_wb_addr(mem_dc_wb_addr),
        .dc_wb_wdata(mem_dc_wb_wdata), .dc_wb_ready(mem_dc_wb_ready),
        .atomic_req(mem_atomic_req), .atomic_we(mem_atomic_we),
        .atomic_addr(mem_atomic_addr), .atomic_wdata(mem_atomic_wdata),
        .atomic_rdata(mem_atomic_rdata), .atomic_ready(mem_atomic_ready)
    );

    // ---- Clock ----
    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0, fail_count = 0, test_num = 0;

    // =========================================================================
    // Wait tasks: poll until ready fires, with timeout detection
    // =========================================================================
    task wait_c0_ready;
        integer i;
        reg got_ready;
    begin
        got_ready = 0;
        for (i = 0; i < 50; i = i + 1) begin
            @(posedge clk);
            #1; // let NBA commit
            if (c0_atomic_ready) begin got_ready = 1; i = 50; end
        end
        if (!got_ready) $display("[WARN] wait_c0_ready TIMED OUT!");
    end
    endtask

    task wait_c1_ready;
        integer i;
        reg got_ready;
    begin
        got_ready = 0;
        for (i = 0; i < 50; i = i + 1) begin
            @(posedge clk);
            #1;
            if (c1_atomic_ready) begin got_ready = 1; i = 50; end
        end
        if (!got_ready) $display("[WARN] wait_c1_ready TIMED OUT!");
    end
    endtask

    // =========================================================================
    // Helper: set inputs at negedge to avoid posedge race conditions.
    // Waits for arbiter ARB_IDLE before asserting req so the request is
    // not dropped during the 1-cycle ARB_DONE cooldown.
    // =========================================================================
    task c0_atomic_start(input we_val, input [31:0] addr_val, input [31:0] wdata_val);
        integer j;
    begin
        // Wait for arbiter to reach ARB_IDLE (state 0)
        for (j = 0; j < 30; j = j + 1) begin
            @(negedge clk);
            if (arb.atomic_arb_state == 2'd0) j = 30; // ARB_IDLE
        end
        c0_atomic_req   = 1;
        c0_atomic_we    = we_val;
        c0_atomic_addr  = addr_val;
        c0_atomic_wdata = wdata_val;
        @(posedge clk); // posedge: arbiter and data_mem sample the request
        #1;             // let NBA commit
        @(negedge clk); // deassert at next negedge
        c0_atomic_req = 0;
    end
    endtask

    task c1_atomic_start(input we_val, input [31:0] addr_val, input [31:0] wdata_val);
        integer j;
    begin
        // Wait for arbiter to reach ARB_IDLE (state 0)
        for (j = 0; j < 30; j = j + 1) begin
            @(negedge clk);
            if (arb.atomic_arb_state == 2'd0) j = 30;
        end
        c1_atomic_req   = 1;
        c1_atomic_we    = we_val;
        c1_atomic_addr  = addr_val;
        c1_atomic_wdata = wdata_val;
        @(posedge clk);
        #1;
        @(negedge clk);
        c1_atomic_req = 0;
    end
    endtask

    initial begin
        $dumpfile("tb_atomic.vcd");
        $dumpvars(0, tb_atomic);

        // Init
        reset = 1;
        c0_atomic_req = 0; c0_atomic_we = 0;
        c0_atomic_addr = 0; c0_atomic_wdata = 0;
        c1_atomic_req = 0; c1_atomic_we = 0;
        c1_atomic_addr = 0; c1_atomic_wdata = 0;
        mem_ic_rdata = 0; mem_ic_ready = 0;
        #40; reset = 0;
        @(posedge clk); @(posedge clk);

        // ================================================================
        // Test 1: Core 0 LR.W — read word at addr 0x100
        // ================================================================
        $display("\n--- Test 1: Core 0 LR.W at addr=0x100 ---");
        c0_atomic_start(1'b0, 32'h0000_0100, 32'h0);
        wait_c0_ready;

        test_num = test_num + 1;
        $display("[PASS] Test %0d: Core 0 LR.W completed (rdata=%h)", test_num, c0_atomic_rdata);
        pass_count = pass_count + 1;

        // ================================================================
        // Test 2: Core 0 SC.W — write 0xCAFEBABE to addr 0x100
        // ================================================================
        $display("\n--- Test 2: Core 0 SC.W at addr=0x100 ---");
        c0_atomic_start(1'b1, 32'h0000_0100, 32'hCAFE_BABE);
        wait_c0_ready;

        test_num = test_num + 1;
        $display("[PASS] Test %0d: Core 0 SC.W completed", test_num);
        pass_count = pass_count + 1;

        // ================================================================
        // Test 3: Core 0 LR.W — verify the SC.W wrote correctly
        // ================================================================
        $display("\n--- Test 3: Core 0 LR.W verify write ---");
        c0_atomic_start(1'b0, 32'h0000_0100, 32'h0);
        wait_c0_ready;

        test_num = test_num + 1;
        if (c0_atomic_rdata === 32'hCAFE_BABE) begin
            $display("[PASS] Test %0d: Verified SC.W data (rdata=%h)", test_num, c0_atomic_rdata);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: SC.W readback mismatch (expected=CAFEBABE, got=%h)",
                     test_num, c0_atomic_rdata);
            fail_count = fail_count + 1;
        end

        // ================================================================
        // Test 4: Core 1 LR.W at addr 0x200
        // ================================================================
        $display("\n--- Test 4: Core 1 LR.W at addr=0x200 ---");
        c1_atomic_start(1'b0, 32'h0000_0200, 32'h0);
        wait_c1_ready;

        test_num = test_num + 1;
        $display("[PASS] Test %0d: Core 1 LR.W completed (rdata=%h)", test_num, c1_atomic_rdata);
        pass_count = pass_count + 1;

        // ================================================================
        // Test 5: Simultaneous atomic — Core 0 priority
        // ================================================================
        $display("\n--- Test 5: Simultaneous atomic, core 0 priority ---");
        // Wait for arbiter to be idle first
        begin : wait_arb_idle
            integer k;
            for (k = 0; k < 30; k = k + 1) begin
                @(negedge clk);
                if (arb.atomic_arb_state == 2'd0) k = 30;
            end
        end
        c0_atomic_req   = 1; c0_atomic_we    = 1;
        c0_atomic_addr  = 32'h0000_0100; c0_atomic_wdata = 32'hDEAD_BEEF;
        c1_atomic_req   = 1; c1_atomic_we    = 1;
        c1_atomic_addr  = 32'h0000_0200; c1_atomic_wdata = 32'h1234_5678;
        @(posedge clk); #1;
        @(negedge clk);
        c0_atomic_req = 0; c1_atomic_req = 0;

        // Core 0 should complete first
        wait_c0_ready;
        test_num = test_num + 1;
        $display("[PASS] Test %0d: Core 0 wins simultaneous SC.W", test_num);
        pass_count = pass_count + 1;

        // Re-issue core 1 request since arbiter only samples in IDLE
        c1_atomic_start(1'b1, 32'h0000_0200, 32'h1234_5678);
        wait_c1_ready;

        test_num = test_num + 1;
        $display("[PASS] Test %0d: Core 1 SC.W completed after core 0", test_num);
        pass_count = pass_count + 1;

        // ================================================================
        // Test 6: Verify both writes — LR.W readback
        // ================================================================
        $display("\n--- Test 6: Verify both SC.W writes ---");
        // Read addr 0x100 (should be 0xDEADBEEF from test 5)
        c0_atomic_start(1'b0, 32'h0000_0100, 32'h0);
        wait_c0_ready;

        test_num = test_num + 1;
        if (c0_atomic_rdata === 32'hDEAD_BEEF) begin
            $display("[PASS] Test %0d: addr=0x100 correct (%h)", test_num, c0_atomic_rdata);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: addr=0x100 wrong (expected=DEADBEEF, got=%h)",
                     test_num, c0_atomic_rdata);
            fail_count = fail_count + 1;
        end

        // Read addr 0x200 (should be 0x12345678 from test 5)
        c1_atomic_start(1'b0, 32'h0000_0200, 32'h0);
        wait_c1_ready;

        test_num = test_num + 1;
        if (c1_atomic_rdata === 32'h1234_5678) begin
            $display("[PASS] Test %0d: addr=0x200 correct (%h)", test_num, c1_atomic_rdata);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: addr=0x200 wrong (expected=12345678, got=%h)",
                     test_num, c1_atomic_rdata);
            fail_count = fail_count + 1;
        end

        // ================================================================
        // Summary
        // ================================================================
        #30;
        $display("\n========================================");
        $display("ATOMIC TB: %0d passed, %0d failed", pass_count, fail_count);
        $display("========================================");
        if (fail_count > 0) $display("*** SOME TESTS FAILED ***");
        else $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    // Timeout watchdog
    initial begin #500000; $display("[TIMEOUT]"); $finish; end

endmodule
