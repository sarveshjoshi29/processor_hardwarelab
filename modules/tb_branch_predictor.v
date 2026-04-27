`timescale 1ns/1ps
// ============================================================================
// Self-checking unit testbench for branch_predictor
// - Trains 2-bit counter across thresholds
// - Verifies target updates only on taken
// - Verifies direct-mapped aliasing overwrites entry
// ============================================================================
module tb_branch_predictor;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg         reset;

    reg  [31:0] fetch_pc;
    wire        predict_taken;
    wire [31:0] predict_target;

    reg         update_en;
    reg  [31:0] update_pc;
    reg         actual_taken;
    reg  [31:0] actual_target;

    branch_predictor dut (
        .clk(clk),
        .reset(reset),
        .fetch_pc(fetch_pc),
        .predict_taken(predict_taken),
        .predict_target(predict_target),
        .update_en(update_en),
        .update_pc(update_pc),
        .actual_taken(actual_taken),
        .actual_target(actual_target)
    );

    localparam [31:0] PC_A  = 32'h0000_0100; // idx=PC[5:2]=0
    localparam [31:0] TGT_A = 32'h0000_0200;

    localparam [31:0] PC_B  = 32'h0000_4100; // same idx=0, different tag
    localparam [31:0] TGT_B = 32'h0000_1234;

    integer errors;

    task automatic expect_pred;
        input [31:0] pc;
        input        exp_taken;
        input [31:0] exp_target; // checked only if exp_taken==1
        input [256*8:1] what;
        begin
            fetch_pc = pc;
            #1;

            if (predict_taken !== exp_taken) begin
                $display("[FAIL] %0s: predict_taken exp=%b got=%b pc=%h", what, exp_taken, predict_taken, pc);
                errors = errors + 1;
            end

            if (exp_taken) begin
                if (predict_target !== exp_target) begin
                    $display("[FAIL] %0s: predict_target exp=%h got=%h pc=%h", what, exp_target, predict_target, pc);
                    errors = errors + 1;
                end
            end

            if (errors == 0)
                $display("[ OK ] %0s", what);
        end
    endtask

    task automatic do_update;
        input [31:0] pc;
        input        taken;
        input [31:0] tgt;
        begin
            update_en     = 1'b1;
            update_pc     = pc;
            actual_taken  = taken;
            actual_target = tgt;
            @(posedge clk);
            #1;
            update_en     = 1'b0;
            update_pc     = 32'b0;
            actual_taken  = 1'b0;
            actual_target = 32'b0;
        end
    endtask

    task automatic apply_reset;
        begin
            reset = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            reset = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        $dumpfile("tb_branch_predictor.vcd");
        $dumpvars(0, tb_branch_predictor);

        errors        = 0;
        reset         = 1'b0;
        fetch_pc      = 32'b0;
        update_en     = 1'b0;
        update_pc     = 32'b0;
        actual_taken  = 1'b0;
        actual_target = 32'b0;

        apply_reset();

        // After reset: no valid entry => never predicts taken
        expect_pred(PC_A, 1'b0, 32'b0, "reset: no prediction");

        // Train: 00 -> 01 (still not taken)
        do_update(PC_A, 1'b1, TGT_A);
        expect_pred(PC_A, 1'b0, 32'b0, "after 1st taken update: still NT");

        // 01 -> 10 (predict taken)
        do_update(PC_A, 1'b1, TGT_A);
        expect_pred(PC_A, 1'b1, TGT_A, "after 2nd taken update: predicts T");

        // 10 -> 11 (strong taken)
        do_update(PC_A, 1'b1, TGT_A);
        expect_pred(PC_A, 1'b1, TGT_A, "after 3rd taken update: strong T");

        // Not-taken update must NOT update target, but decrements counter: 11 -> 10
        do_update(PC_A, 1'b0, 32'hDEAD_BEEF);
        expect_pred(PC_A, 1'b1, TGT_A, "NT update: still predicts T; target unchanged");

        // Another not-taken: 10 -> 01 (now not taken)
        do_update(PC_A, 1'b0, 32'hFEED_C0DE);
        expect_pred(PC_A, 1'b0, 32'b0, "2nd NT update: predicts NT");

        // ---- Aliasing test (direct-mapped overwrite) ----
        apply_reset();

        // Train PC_A to taken (00->01->10)
        do_update(PC_A, 1'b1, TGT_A);
        do_update(PC_A, 1'b1, TGT_A);
        expect_pred(PC_A, 1'b1, TGT_A, "alias: PC_A predicts taken");

        // One taken update on PC_B overwrites same index entry
        do_update(PC_B, 1'b1, TGT_B);

        // PC_A should now miss (tag mismatch) => not taken
        expect_pred(PC_A, 1'b0, 32'b0, "alias: PC_A no longer hits after PC_B overwrite");

        // PC_B should hit and predict taken with its target
        expect_pred(PC_B, 1'b1, TGT_B, "alias: PC_B hits and predicts taken");

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL (%0d errors)", errors);
        end
        $finish;
    end

    initial begin
        #20000;
        $display("FAIL (TIMEOUT)");
        $finish;
    end

endmodule
