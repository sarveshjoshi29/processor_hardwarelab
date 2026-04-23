`timescale 1ns/1ps
// ============================================================================
// Testbench for L1 Instruction Cache (16-line geometry)
// ============================================================================
module tb_icache;

    reg         clk;
    reg         reset;
    reg  [31:0] fetch_pc;
    reg         pipeline_stall;
    wire [31:0] instr;
    wire        icache_stall;
    wire        mem_req;
    wire [31:0] mem_addr;
    reg  [127:0] mem_rdata;
    reg          mem_ready;

    icache #(.MEM_CYCLES(4)) uut (
        .clk(clk), .reset(reset), .fetch_pc(fetch_pc),
        .pipeline_stall(pipeline_stall), .instr(instr),
        .icache_stall(icache_stall), .mem_req(mem_req),
        .mem_addr(mem_addr), .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0, fail_count = 0, test_num = 0;

    task check(input [31:0] expected, input [255:0] msg);
    begin
        test_num = test_num + 1;
        if (instr === expected) begin
            $display("[PASS] Test %0d: %0s (instr=%h)", test_num, msg, instr);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: %0s (expected=%h, got=%h)", test_num, msg, expected, instr);
            fail_count = fail_count + 1;
        end
    end
    endtask

    // Memory fill emulator: responds after 4 cycles
    // Uses mem_just_done to prevent re-trigger when mem_req stays high
    // for 1 cycle after fill_ready fires.
    reg [3:0] mem_delay_cnt;
    reg       mem_pending;
    reg       mem_just_done;
    reg [127:0] mem_fill_data;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mem_delay_cnt <= 0; mem_pending <= 0; mem_just_done <= 0;
            mem_ready <= 0; mem_rdata <= 128'b0;
        end else begin
            mem_ready <= 1'b0;
            mem_just_done <= 1'b0;
            if (mem_req && !mem_pending && !mem_just_done) begin
                mem_pending   <= 1'b1;
                mem_delay_cnt <= 4'd3;
                mem_fill_data <= {mem_addr + 32'd12, mem_addr + 32'd8,
                                  mem_addr + 32'd4,  mem_addr};
            end
            else if (mem_pending) begin
                if (mem_delay_cnt == 0) begin
                    mem_ready <= 1'b1; mem_rdata <= mem_fill_data;
                    mem_pending <= 1'b0;
                    mem_just_done <= 1'b1;
                end else
                    mem_delay_cnt <= mem_delay_cnt - 1;
            end
        end
    end

    // Helper task: poll until stall drops, then wait for registered capture
    task wait_for_hit;
        integer i;
    begin
        for (i = 0; i < 200; i = i + 1) begin
            @(posedge clk);
            if (!icache_stall) begin
                // hit is true this cycle, instr_r captures on this posedge
                @(posedge clk); // instr_r now holds the captured value
                i = 200; // break
            end
        end
    end
    endtask

    initial begin
        $dumpfile("tb_icache.vcd");
        $dumpvars(0, tb_icache);

        reset = 1; fetch_pc = 32'h0; pipeline_stall = 0;
        #30; reset = 0; #10;

        // === Test 1: Cold miss at PC=0x00 ===
        $display("\n--- Test 1: Cold miss at PC=0x00 ---");
        fetch_pc = 32'h0000_0000;
        wait_for_hit;
        check(32'h0000_0000, "Cold miss fill word 0");

        // === Test 2: Hits within same line ===
        $display("\n--- Test 2: Same-line hits ---");
        fetch_pc = 32'h0000_0004;
        @(posedge clk); @(posedge clk); // 1 cycle for hit, 1 for registered capture
        check(32'h0000_0004, "Hit word 1");

        fetch_pc = 32'h0000_0008;
        @(posedge clk); @(posedge clk);
        check(32'h0000_0008, "Hit word 2");

        fetch_pc = 32'h0000_000C;
        @(posedge clk); @(posedge clk);
        check(32'h0000_000C, "Hit word 3");

        // === Test 3: Different index (cold miss) ===
        $display("\n--- Test 3: Cold miss at idx=1 ---");
        fetch_pc = 32'h0000_0010; // idx=1
        @(posedge clk); // let miss be detected
        wait_for_hit;
        check(32'h0000_0010, "Cold miss at idx=1 word 0");

        // === Test 4: Conflict miss (same index, different tag) ===
        $display("\n--- Test 4: Conflict miss ---");
        fetch_pc = 32'h0000_0100; // idx=0, tag=1
        @(posedge clk); // miss detected
        @(posedge clk); // FSM transitions to FETCH
        wait_for_hit;
        check(32'h0000_0100, "Conflict miss eviction");

        // Verify eviction: old line at idx=0 tag=0 should miss now
        $display("\n--- Test 4b: Verify old line evicted ---");
        fetch_pc = 32'h0000_0000;
        @(posedge clk); @(posedge clk);
        test_num = test_num + 1;
        if (icache_stall) begin
            $display("[PASS] Test %0d: Correctly missed after conflict eviction", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] Test %0d: Should have missed after conflict eviction", test_num);
            fail_count = fail_count + 1;
        end
        wait_for_hit;

        // === Test 5: Pipeline stall ===
        $display("\n--- Test 5: Pipeline stall ---");
        // PC=0x00 should be a hit now (just refilled)
        fetch_pc = 32'h0000_0000;
        @(posedge clk); @(posedge clk); @(posedge clk);
        // instr_r should now hold 0x00000000
        pipeline_stall = 1;
        fetch_pc = 32'h0000_0004; // different word, same line — still a hit
        @(posedge clk); @(posedge clk); @(posedge clk);
        // instr should NOT have changed (stall suppresses capture)
        check(32'h0000_0000, "Stall suppresses capture");
        pipeline_stall = 0;

        #20;
        $display("\n========================================");
        $display("ICACHE TB: %0d passed, %0d failed", pass_count, fail_count);
        $display("========================================");
        if (fail_count > 0) $display("*** SOME TESTS FAILED ***");
        else $display("*** ALL TESTS PASSED ***");
        $finish;
    end

    initial begin #100000; $display("[TIMEOUT]"); $finish; end
endmodule
