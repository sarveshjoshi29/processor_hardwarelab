`timescale 1ns / 1ps
// ============================================================================
// Testbench — Edge Cases for RV32M Multiply/Divide
// ============================================================================
// Exercises signed/unsigned mul/div and division-by-zero cases via execute.v.
// ============================================================================

`include "divider.v"
`include "execute.v"

module tb_edge_cases_muldiv;

// RV32M funct3 encodings
localparam [2:0] MUL    = 3'b000;
localparam [2:0] MULH   = 3'b001;
localparam [2:0] MULHSU = 3'b010;
localparam [2:0] MULHU  = 3'b011;
localparam [2:0] DIV    = 3'b100;
localparam [2:0] DIVU   = 3'b101;
localparam [2:0] REM    = 3'b110;
localparam [2:0] REMU   = 3'b111;

// Clock and reset
reg clk;
reg reset;

initial begin
    clk = 0;
    forever #5 clk = ~clk;
end

initial begin
    reset = 1;
    #20;
    reset = 0;
end

// Execute stage inputs
reg  [31:0] reg_rdata1;
reg  [31:0] reg_rdata2;
reg  [31:0] execute_imm;
reg  [31:0] pc;
reg         immediate_sel;
reg         mem_write;
reg         jal;
reg         jalr;
reg         lui;
reg         auipc;
reg         alu;
reg         branch;
reg         arithsubtype;
reg         muldiv;
reg         mem_to_reg;
reg  [4:0]  dest_reg_sel;
reg  [2:0]  alu_op;
reg  [4:0]  rs1_addr;
reg  [4:0]  rs2_addr;
reg  [1:0]  forward_a;
reg  [1:0]  forward_b;
reg  [31:0] ex_mem_fwd_data;
reg  [31:0] mem_wb_fwd_data;
reg         atomic_lr;
reg         atomic_sc;
reg         predicted_taken;
reg  [31:0] predicted_target;

// Execute stage outputs
wire [31:0] ex_alu_result;
wire [31:0] ex_store_data;
wire [31:0] ex_pc;
wire        ex_mem_write;
wire        ex_mem_to_reg;
wire        ex_reg_write_en;
wire [4:0]  ex_rd;
wire [2:0]  ex_funct3;
wire        div_busy;
wire        div_done;
wire        ex_atomic_lr;
wire        ex_atomic_sc;
wire        mispredict;
wire [31:0] next_pc;
wire        branch_taken;

execute dut (
    .clk             (clk),
    .reset           (reset),
    .reg_rdata1      (reg_rdata1),
    .reg_rdata2      (reg_rdata2),
    .execute_imm     (execute_imm),
    .pc              (pc),
    .immediate_sel   (immediate_sel),
    .mem_write       (mem_write),
    .jal             (jal),
    .jalr            (jalr),
    .lui             (lui),
    .auipc           (auipc),
    .alu             (alu),
    .branch          (branch),
    .arithsubtype    (arithsubtype),
    .muldiv          (muldiv),
    .mem_to_reg      (mem_to_reg),
    .dest_reg_sel    (dest_reg_sel),
    .alu_op          (alu_op),
    .rs1_addr        (rs1_addr),
    .rs2_addr        (rs2_addr),
    .forward_a       (forward_a),
    .forward_b       (forward_b),
    .ex_mem_fwd_data (ex_mem_fwd_data),
    .mem_wb_fwd_data (mem_wb_fwd_data),
    .atomic_lr       (atomic_lr),
    .atomic_sc       (atomic_sc),
    .predicted_taken (predicted_taken),
    .predicted_target(predicted_target),
    .next_pc         (next_pc),
    .branch_taken    (branch_taken),
    .ex_alu_result   (ex_alu_result),
    .ex_store_data   (ex_store_data),
    .ex_pc           (ex_pc),
    .ex_mem_write    (ex_mem_write),
    .ex_mem_to_reg   (ex_mem_to_reg),
    .ex_reg_write_en (ex_reg_write_en),
    .ex_rd           (ex_rd),
    .ex_funct3       (ex_funct3),
    .div_busy        (div_busy),
    .div_done        (div_done),
    .ex_atomic_lr    (ex_atomic_lr),
    .ex_atomic_sc    (ex_atomic_sc),
    .mispredict      (mispredict)
);

integer errors;
integer case_idx;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

task set_defaults;
begin
    reg_rdata1      = 32'b0;
    reg_rdata2      = 32'b0;
    execute_imm     = 32'b0;
    pc              = 32'b0;
    immediate_sel   = 1'b0;
    mem_write       = 1'b0;
    jal             = 1'b0;
    jalr            = 1'b0;
    lui             = 1'b0;
    auipc           = 1'b0;
    alu             = 1'b1;
    branch          = 1'b0;
    arithsubtype    = 1'b0;
    muldiv          = 1'b1;
    mem_to_reg      = 1'b0;
    dest_reg_sel    = 5'b0;
    alu_op          = 3'b000;
    rs1_addr        = 5'b0;
    rs2_addr        = 5'b0;
    forward_a       = 2'b00;
    forward_b       = 2'b00;
    ex_mem_fwd_data = 32'b0;
    mem_wb_fwd_data = 32'b0;
    atomic_lr       = 1'b0;
    atomic_sc       = 1'b0;
    predicted_taken = 1'b0;
    predicted_target= 32'b0;
end
endtask

task check_mul;
    input [2:0] op;
    input [31:0] a;
    input [31:0] b;
    reg signed [63:0] prod_ss;
    reg signed [63:0] prod_su;
    reg [63:0] prod_uu;
    reg [31:0] expected;
begin
    case_idx = case_idx + 1;
    reg_rdata1 = a;
    reg_rdata2 = b;
    alu_op     = op;
    #1;

    prod_ss = $signed(a) * $signed(b);
    prod_su = $signed(a) * $signed({1'b0, b});
    prod_uu = {32'b0, a} * {32'b0, b};

    case (op)
        MUL:    expected = prod_ss[31:0];
        MULH:   expected = prod_ss[63:32];
        MULHSU: expected = prod_su[63:32];
        MULHU:  expected = prod_uu[63:32];
        default: expected = 32'h0;
    endcase

    if (ex_alu_result !== expected) begin
        $display("CASE %0d MUL FAIL op=%0d a=%h b=%h got=%h exp=%h", case_idx, op, a, b, ex_alu_result, expected);
        errors = errors + 1;
    end else begin
        $display("CASE %0d MUL PASS op=%0d a=%h b=%h got=%h exp=%h", case_idx, op, a, b, ex_alu_result, expected);
    end
end
endtask

task check_div;
    input [2:0] op;
    input [31:0] a;
    input [31:0] b;
    reg signed [31:0] sa;
    reg signed [31:0] sb;
    reg [31:0] expected;
    integer i;
    reg done_seen;
begin
    case_idx = case_idx + 1;
    // Wait for divider to be idle before starting a new operation
    while (div_busy) begin
        @(posedge clk);
    end
    if (div_done) begin
        @(posedge clk);
    end

    sa = a;
    sb = b;
    reg_rdata1 = a;
    reg_rdata2 = b;
    alu_op     = op;
    alu        = 1'b1;

    // Start division with muldiv asserted
    muldiv = 1'b1;
    @(posedge clk);

    done_seen = 1'b0;
    for (i = 0; i < 40; i = i + 1) begin
        @(posedge clk);
        if (div_done && !done_seen) begin
            done_seen = 1'b1;
            #1;
            if (op == DIV) begin
                if (b == 32'b0)
                    expected = 32'hFFFF_FFFF;
                else if (a == 32'h8000_0000 && b == 32'hFFFF_FFFF)
                    expected = 32'h8000_0000;
                else
                    expected = sa / sb;
            end else if (op == DIVU) begin
                if (b == 32'b0)
                    expected = 32'hFFFF_FFFF;
                else
                    expected = a / b;
            end else if (op == REM) begin
                if (b == 32'b0)
                    expected = a;
                else if (a == 32'h8000_0000 && b == 32'hFFFF_FFFF)
                    expected = 32'h0;
                else
                    expected = sa % sb;
            end else begin
                if (b == 32'b0)
                    expected = a;
                else
                    expected = a % b;
            end

            if (ex_alu_result !== expected) begin
                $display("CASE %0d DIV FAIL op=%0d a=%h b=%h got=%h exp=%h", case_idx, op, a, b, ex_alu_result, expected);
                errors = errors + 1;
            end else begin
                $display("CASE %0d DIV PASS op=%0d a=%h b=%h got=%h exp=%h", case_idx, op, a, b, ex_alu_result, expected);
            end

            // Prevent automatic restart after completion
            muldiv = 1'b0;
        end
    end

    if (!done_seen) begin
        $display("CASE %0d DIV TIMEOUT op=%0d a=%h b=%h", case_idx, op, a, b);
        errors = errors + 1;
    end
end
endtask

// ---------------------------------------------------------------------------
// Test sequence
// ---------------------------------------------------------------------------

initial begin
    errors = 0;
    case_idx = 0;
    set_defaults();
    #30;

    // Multiplication edge cases
    check_mul(MUL,    32'h0000_0000, 32'h0000_0000);
    check_mul(MUL,    32'h0000_0001, 32'h0000_0001);
    check_mul(MUL,    32'hFFFF_FFFF, 32'h0000_0002); // -1 * 2
    check_mul(MUL,    32'h8000_0000, 32'h0000_0002); // INT_MIN * 2
    check_mul(MUL,    32'h7FFF_FFFF, 32'h7FFF_FFFF);

    check_mul(MULH,   32'h8000_0000, 32'h0000_0002);
    check_mul(MULH,   32'hFFFF_FFFF, 32'hFFFF_FFFF);
    check_mul(MULH,   32'h7FFF_FFFF, 32'h7FFF_FFFF);

    check_mul(MULHSU, 32'h8000_0000, 32'hFFFF_FFFF);
    check_mul(MULHSU, 32'hFFFF_FFFF, 32'h0000_0002);
    check_mul(MULHSU, 32'h7FFF_FFFF, 32'h8000_0000);

    check_mul(MULHU,  32'hFFFF_FFFF, 32'hFFFF_FFFF);
    check_mul(MULHU,  32'h0000_0001, 32'hFFFF_FFFF);
    check_mul(MULHU,  32'h8000_0000, 32'h8000_0000);

    // Division edge cases
    check_div(DIV,  32'h0000_000A, 32'h0000_0003);
    check_div(DIV,  32'hFFFF_FFF6, 32'h0000_0003); // -10 / 3
    check_div(DIV,  32'h0000_000A, 32'hFFFF_FFFD); // 10 / -3
    check_div(DIV,  32'hFFFF_FFF6, 32'hFFFF_FFFD); // -10 / -3
    check_div(DIV,  32'h8000_0000, 32'hFFFF_FFFF); // overflow
    check_div(DIV,  32'h0000_0001, 32'h0000_0000); // div by zero

    check_div(REM,  32'h0000_000A, 32'h0000_0003);
    check_div(REM,  32'hFFFF_FFF6, 32'h0000_0003); // -10 % 3
    check_div(REM,  32'h0000_000A, 32'hFFFF_FFFD); // 10 % -3
    check_div(REM,  32'hFFFF_FFF6, 32'hFFFF_FFFD); // -10 % -3
    check_div(REM,  32'h8000_0000, 32'hFFFF_FFFF); // overflow remainder
    check_div(REM,  32'h0000_0001, 32'h0000_0000); // rem by zero

    check_div(DIVU, 32'h0000_000A, 32'h0000_0003);
    check_div(DIVU, 32'hFFFF_FFFF, 32'h0000_0002);
    check_div(DIVU, 32'h8000_0000, 32'h0000_0001);
    check_div(DIVU, 32'h0000_0001, 32'h0000_0000); // divu by zero

    check_div(REMU, 32'h0000_000A, 32'h0000_0003);
    check_div(REMU, 32'hFFFF_FFFF, 32'h0000_0002);
    check_div(REMU, 32'h8000_0000, 32'h0000_0001);
    check_div(REMU, 32'h0000_0001, 32'h0000_0000); // remu by zero

    if (errors == 0)
        $display("MULDIV EDGE CASES: PASS");
    else
        $display("MULDIV EDGE CASES: FAIL (%0d errors)", errors);

    $finish;
end

endmodule
