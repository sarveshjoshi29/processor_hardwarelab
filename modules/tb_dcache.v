`timescale 1ns/1ps
// ============================================================================
// Testbench for L1 Data Cache (16-line geometry)
// ============================================================================
module tb_dcache;

    reg clk, reset, req, we;
    reg [3:0] be;
    reg [31:0] addr, wdata;
    wire [31:0] rdata;
    wire dcache_stall;
    wire fill_req;
    wire [31:0] fill_addr;
    reg [127:0] fill_rdata;
    reg fill_ready;
    wire wb_req;
    wire [31:0] wb_addr;
    wire [127:0] wb_wdata;
    reg wb_ready;

    dcache #(.MEM_CYCLES(4)) uut (
        .clk(clk), .reset(reset), .req(req), .we(we), .be(be),
        .addr(addr), .wdata(wdata), .rdata(rdata), .dcache_stall(dcache_stall),
        .fill_req(fill_req), .fill_addr(fill_addr), .fill_rdata(fill_rdata),
        .fill_ready(fill_ready), .wb_req(wb_req), .wb_addr(wb_addr),
        .wb_wdata(wb_wdata), .wb_ready(wb_ready)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0, fail_count = 0, test_num = 0;

    task check_rdata(input [31:0] expected, input [255:0] msg);
    begin
        test_num = test_num + 1;
        if (rdata === expected) begin
            $display("[PASS] Test %0d: %0s (rdata=%h)", test_num, msg, rdata);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: %0s (expected=%h, got=%h)", test_num, msg, expected, rdata);
            fail_count = fail_count + 1;
        end
    end
    endtask

    // Fill emulator: 4-cycle latency
    reg [3:0] fd; reg fp; reg [127:0] fdp;
    reg [31:0] fill_addr_latched;
    always @(posedge clk or posedge reset) begin
        if (reset) begin fd<=0; fp<=0; fill_ready<=0; fill_rdata<=0; end
        else begin
            fill_ready <= 0;
            if (fill_req && !fp) begin
                fp<=1; fd<=3;
                fill_addr_latched <= fill_addr;
                fdp <= {fill_addr+32'd12, fill_addr+32'd8,
                        fill_addr+32'd4,  fill_addr};
            end else if (fp) begin
                if (fd==0) begin fill_ready<=1; fill_rdata<=fdp; fp<=0; end
                else fd<=fd-1;
            end
        end
    end

    // WB emulator: 4-cycle latency
    reg [3:0] wd; reg wp;
    reg [31:0] wba; reg [127:0] wbd;
    always @(posedge clk or posedge reset) begin
        if (reset) begin wd<=0; wp<=0; wb_ready<=0; end
        else begin
            wb_ready <= 0;
            if (wb_req && !wp) begin
                wp<=1; wd<=3; wba<=wb_addr; wbd<=wb_wdata;
            end else if (wp) begin
                if (wd==0) begin wb_ready<=1; wp<=0; end
                else wd<=wd-1;
            end
        end
    end

    // Wait until dcache is not stalling, with polling
    task wait_idle;
        integer i;
    begin
        for (i = 0; i < 100; i = i + 1) begin
            @(posedge clk);
            if (!dcache_stall) begin
                i = 100; // break
            end
        end
    end
    endtask

    initial begin
        $dumpfile("tb_dcache.vcd");
        $dumpvars(0, tb_dcache);
        reset=1; req=0; we=0; be=0; addr=0; wdata=0;
        #30; reset=0;
        @(posedge clk); @(posedge clk);

        // ================================================================
        // Test 1: Read miss → fill → read hit
        // ================================================================
        $display("\n--- Test 1: Read miss at addr=0x00 ---");
        req=1; we=0; be=0; addr=32'h0000_0000;
        wait_idle;
        // miss_just_resolved=1 this cycle, stall=0
        // Next cycle: miss_just_resolved clears, req=1, hit=1, rdata valid
        @(posedge clk);
        check_rdata(32'h0000_0000, "Read miss fill word 0");

        // Read word 1 (immediate hit)
        addr = 32'h0000_0004;
        @(posedge clk);
        check_rdata(32'h0000_0004, "Read hit word 1");

        // ================================================================
        // Test 2: Write hit → read back
        // ================================================================
        $display("\n--- Test 2: Write hit ---");
        we=1; be=4'hF; addr=32'h0000_0000; wdata=32'hDEAD_BEEF;
        @(posedge clk); // write condition sampled, data_arr <= updated (non-blocking)
        @(posedge clk); // data_arr now has new value after NBA commit
        // Read back
        we=0; be=0; addr=32'h0000_0000;
        @(posedge clk); // rdata_comb reads updated data_arr
        check_rdata(32'hDEAD_BEEF, "Write hit readback");

        // ================================================================
        // Test 3: Dirty eviction
        // ================================================================
        $display("\n--- Test 3: Dirty eviction ---");
        we=0; addr=32'h0000_0100; // idx=0, tag=1 → conflict with dirty line
        wait_idle;
        @(posedge clk); // miss_just_resolved clears
        check_rdata(32'h0000_0100, "Post-eviction fill");

        // Verify writeback data
        test_num = test_num + 1;
        if (wbd[31:0] === 32'hDEAD_BEEF) begin
            $display("[PASS] Test %0d: WB dirty data correct (%h)", test_num, wbd[31:0]);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: WB dirty data wrong (expected=deadbeef, got=%h)", test_num, wbd[31:0]);
            fail_count = fail_count + 1;
        end

        req=0; #30;
        $display("\n========================================");
        $display("DCACHE TB: %0d passed, %0d failed", pass_count, fail_count);
        $display("========================================");
        if (fail_count > 0) $display("*** SOME TESTS FAILED ***");
        else $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin #500000; $display("[TIMEOUT]"); $finish; end
endmodule
