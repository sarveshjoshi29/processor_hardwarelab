// ============================================================================
// 5-Stage RISC-V RV32IM Pipeline — Top Level (Phase 4: L1 Caches)
// ============================================================================
// Phase 4 additions:
//   - L1 I-Cache (icache.v): 1 KB direct-mapped, 4-word lines, read-only
//   - L1 D-Cache (dcache.v): 1 KB direct-mapped, 4-word lines, write-back/allocate
//   - Backing memory (memory.v) now has cache-line-only ports (4-cycle latency)
//   - mem_stall = icache_stall || dcache_stall — freezes all pipeline registers
//   - pipeline_stall = stall_read || mem_stall  (replaces raw stall_read usage)
//   - dmem_write_ready gated with !pipeline_stall so each store is reported once
// ============================================================================

`include "IF_ID.v"
`include "execute.v"
`include "ex_mem_reg.v"
`include "mem_stage.v"
`include "mem_wb_reg.v"
`include "wb.v"
`include "hazard_forward_unit.v"
`include "divider.v"
`include "memory.v"
`include "branch_predictor.v"
`include "icache.v"
`include "dcache.v"

`timescale 1ns/1ps
module pipe
#(
    parameter [31:0] RESET = 32'h0000_0000
)
(
    input                clk,
    input                reset,
    input                stall,
    output               exception,
    output [31:0]        pc_out,
    output [31:0]        inst_fetch_pc,

    // Testbench monitoring outputs
    output [31:0]        inst_word_out,   // instruction in IF/ID (end-of-program check)
    output               dmem_write_ready,// store committed this cycle
    output [31:0]        dmem_write_data, // store data
    output [ 3:0]        dmem_write_byte  // store byte enables
);

    // ======================================================================
    //  WIRE / REG DECLARATIONS
    // ======================================================================

    reg          stall_read;
    reg  [31:0]  fetch_pc;
    reg  [31:0]  regs [31:0];

    // ---- ID/EX register outputs ----
    wire [31:0]  id_ex_immediate;
    wire         id_ex_immediate_sel;
    wire         id_ex_alu, id_ex_lui, id_ex_auipc;
    wire         id_ex_jal, id_ex_jalr, id_ex_branch;
    wire         id_ex_mem_write, id_ex_mem_to_reg;
    wire         id_ex_arithsubtype, id_ex_muldiv;
    wire [31:0]  id_ex_pc;
    wire [ 4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    wire [ 2:0]  id_ex_alu_op;
    wire         id_ex_illegal;
    wire [31:0]  instruction;

    // ---- EX stage outputs ----
    wire [31:0]  ex_next_pc;
    wire         ex_branch_taken;
    wire [31:0]  ex_alu_result, ex_store_data, ex_pc;
    wire         ex_mem_write, ex_mem_to_reg, ex_reg_write_en;
    wire [ 4:0]  ex_rd;
    wire [ 2:0]  ex_funct3;

    // ---- EX/MEM register outputs ----
    wire [31:0]  em_alu_result, em_store_data, em_pc;
    wire         em_mem_write, em_mem_to_reg, em_reg_write_en;
    wire [ 4:0]  em_rd;
    wire [ 2:0]  em_funct3;
    wire         em_branch_taken;

    // ---- MEM stage outputs ----
    wire [31:0]  mem_dmem_addr, mem_dmem_write_data;
    wire [ 3:0]  mem_dmem_write_byte;
    wire         mem_dmem_write_en, mem_dmem_read_en;
    wire [31:0]  mem_read_data;
    wire [ 1:0]  mem_byte_offset;

    // ---- MEM/WB register outputs ----
    wire [31:0]  mw_alu_result, mw_mem_read_data, mw_pc;
    wire         mw_mem_to_reg, mw_reg_write_en;
    wire [ 4:0]  mw_rd;
    wire [ 2:0]  mw_funct3;
    wire [ 1:0]  mw_byte_offset;

    // ---- WB output ----
    wire [31:0]  wb_data;

    // ---- Hazard & forwarding ----
    wire [ 1:0]  forward_a, forward_b;
    wire         hz_stall_if, hz_stall_id;
    wire         hz_flush_id_ex, hz_flush_if_id;
    wire         div_busy, div_done_w;

    wire is_div_in_ex = id_ex_muldiv && id_ex_alu_op[2];
    wire eff_div_busy = div_busy || (is_div_in_ex && !div_done_w);

    // ---- Branch prediction ----
    wire         bp_predict_taken;
    wire [31:0]  bp_predict_target;
    wire         bp_mispredict;
    wire         id_ex_predicted_taken;
    wire [31:0]  id_ex_predicted_target;
    reg          flush_delay;
    wire         pipeline_flush = bp_mispredict || flush_delay;

    reg  [31:0]  if_id_pc;
    reg          if_id_predicted_taken;
    reg  [31:0]  if_id_predicted_target;

    // ======================================================================
    //  CACHE WIRES
    // ======================================================================

    // I-cache ↔ instr_mem
    wire         ic_fill_req;
    wire [31:0]  ic_fill_addr;
    wire [127:0] ic_fill_rdata;
    wire         ic_fill_ready;

    // D-cache ↔ data_mem (fill)
    wire         dc_fill_req;
    wire [31:0]  dc_fill_addr;
    wire [127:0] dc_fill_rdata;
    wire         dc_fill_ready;

    // D-cache ↔ data_mem (writeback)
    wire         dc_wb_req;
    wire [31:0]  dc_wb_addr;
    wire [127:0] dc_wb_wdata;
    wire         dc_wb_ready;

    // Cache stall signals
    wire         icache_stall;
    wire         dcache_stall;
    wire         mem_stall        = icache_stall || dcache_stall;

    // ---- Unified pipeline freeze (cache miss OR system stall) ----
    wire pipeline_stall = stall_read || mem_stall;

    // ---- Suppress hazard-unit signals during cache stall ----
    // (mem_stall already handles the freeze; hazard actions would corrupt state)
    wire eff_hz_stall_if    = hz_stall_if   && !mem_stall;
    wire eff_pipeline_flush = pipeline_flush && !mem_stall;

    // I-cache instruction output (registered, 1-cycle hit latency)
    wire [31:0]  icache_instr;

    // D-cache read data (combinational)
    wire [31:0]  dcache_rdata;

    // ======================================================================
    //  CACHE + BACKING MEMORY INSTANTIATION
    // ======================================================================

    icache u_icache (
        .clk        (clk),
        .reset      (reset),
        .fetch_pc   (fetch_pc),
        .pipeline_stall(pipeline_stall),
        .instr      (icache_instr),
        .icache_stall(icache_stall),
        .mem_req    (ic_fill_req),
        .mem_addr   (ic_fill_addr),
        .mem_rdata  (ic_fill_rdata),
        .mem_ready  (ic_fill_ready)
    );

    instr_mem u_instr_mem (
        .clk        (clk),
        .reset      (reset),
        .ic_req     (ic_fill_req),
        .ic_addr    (ic_fill_addr),
        .ic_rdata   (ic_fill_rdata),
        .ic_ready   (ic_fill_ready)
    );

    dcache u_dcache (
        .clk        (clk),
        .reset      (reset),
        .req        ((em_mem_write || em_mem_to_reg) && !icache_stall),
        .we         (em_mem_write),
        .be         (mem_dmem_write_byte),
        .addr       (mem_dmem_addr),
        .wdata      (mem_dmem_write_data),
        .rdata      (dcache_rdata),
        .dcache_stall(dcache_stall),
        .fill_req   (dc_fill_req),
        .fill_addr  (dc_fill_addr),
        .fill_rdata (dc_fill_rdata),
        .fill_ready (dc_fill_ready),
        .wb_req     (dc_wb_req),
        .wb_addr    (dc_wb_addr),
        .wb_wdata   (dc_wb_wdata),
        .wb_ready   (dc_wb_ready)
    );

    data_mem u_data_mem (
        .clk            (clk),
        .reset          (reset),
        .dc_fill_req    (dc_fill_req),
        .dc_fill_addr   (dc_fill_addr),
        .dc_fill_rdata  (dc_fill_rdata),
        .dc_fill_ready  (dc_fill_ready),
        .dc_wb_req      (dc_wb_req),
        .dc_wb_addr     (dc_wb_addr),
        .dc_wb_wdata    (dc_wb_wdata),
        .dc_wb_ready    (dc_wb_ready)
    );

    // ======================================================================
    //  IF/ID INSTRUCTION MUX (held instruction during load-use stall)
    // ======================================================================
    reg  [31:0]  if_id_instr_reg;
    reg          if_id_stall_held;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            if_id_instr_reg  <= 32'b0;
            if_id_stall_held <= 1'b0;
        end
        else if (eff_pipeline_flush) begin
            if_id_stall_held <= 1'b0;
        end
        else if (eff_hz_stall_if) begin
            if (!if_id_stall_held)
                if_id_instr_reg <= icache_instr;   // save I-cache output for replay
            if_id_stall_held <= 1'b1;
        end
        else if (!mem_stall) begin
            if_id_stall_held <= 1'b0;
        end
    end

    wire [31:0] if_id_instruction = if_id_stall_held ? if_id_instr_reg : icache_instr;

    wire [ 4:0] if_id_rs1 = if_id_instruction[19:15];
    wire [ 4:0] if_id_rs2 = if_id_instruction[24:20];

    // ======================================================================
    //  TOP-LEVEL ASSIGNMENTS
    // ======================================================================
    assign pc_out          = fetch_pc;
    assign inst_fetch_pc   = fetch_pc;
    assign inst_word_out   = if_id_instruction;   // testbench end-of-program check

    // Store visible to testbench only on the cycle the write commits (no stall)
    assign dmem_write_ready = mem_dmem_write_en && !pipeline_stall;
    assign dmem_write_data  = mem_dmem_write_data;
    assign dmem_write_byte  = mem_dmem_write_byte;

    // ======================================================================
    //  FLUSH DELAY REGISTER (2-cycle mispredict penalty)
    // ======================================================================
    always @(posedge clk or posedge reset) begin
        if (reset)
            flush_delay <= 1'b0;
        else if (!pipeline_stall)
            flush_delay <= bp_mispredict;
    end

    // ======================================================================
    //  IF/ID PC REGISTER (tracks actual PC of instruction in IF/ID)
    // ======================================================================
    always @(posedge clk or posedge reset) begin
        if (reset)
            if_id_pc <= RESET;
        else if (!pipeline_stall && !eff_hz_stall_if)
            if_id_pc <= fetch_pc;
    end

    // ======================================================================
    //  IF/ID PREDICTION REGISTERS
    // ======================================================================
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            if_id_predicted_taken  <= 1'b0;
            if_id_predicted_target <= 32'b0;
        end
        else if (eff_pipeline_flush) begin
            if_id_predicted_taken  <= 1'b0;
            if_id_predicted_target <= 32'b0;
        end
        else if (!pipeline_stall && !eff_hz_stall_if) begin
            if_id_predicted_taken  <= bp_predict_taken;
            if_id_predicted_target <= bp_predict_target;
        end
    end

    // ======================================================================
    //  REGISTER FILE — Read (combinational) + Write (clocked)
    // ======================================================================
    wire [31:0] reg_rdata1, reg_rdata2;
    assign reg_rdata1 = (id_ex_rs1 == 5'd0) ? 32'b0 : regs[id_ex_rs1];
    assign reg_rdata2 = (id_ex_rs2 == 5'd0) ? 32'b0 : regs[id_ex_rs2];

    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'b0;
        end
        else if (mw_reg_write_en && (mw_rd != 5'd0) && !pipeline_stall) begin
            regs[mw_rd] <= wb_data;
        end
    end

    // ======================================================================
    //  STALL REGISTER (startup stall)
    // ======================================================================
    always @(posedge clk or posedge reset) begin
        if (reset) stall_read <= 1'b1;
        else        stall_read <= stall;
    end

    // ======================================================================
    //  HAZARD DETECTION & FORWARDING UNIT
    // ======================================================================
    hazard_forward_unit hfu (
        .id_ex_rs1         (id_ex_rs1),
        .id_ex_rs2         (id_ex_rs2),
        .if_id_rs1         (if_id_rs1),
        .if_id_rs2         (if_id_rs2),
        .id_ex_rd          (id_ex_rd),
        .id_ex_mem_to_reg  (id_ex_mem_to_reg),
        .ex_mem_rd         (em_rd),
        .ex_mem_reg_write  (em_reg_write_en),
        .mem_wb_rd         (mw_rd),
        .mem_wb_reg_write  (mw_reg_write_en),
        .div_busy          (eff_div_busy),
        .branch_taken      (bp_mispredict),
        .forward_a         (forward_a),
        .forward_b         (forward_b),
        .stall_if          (hz_stall_if),
        .stall_id          (hz_stall_id),
        .flush_id_ex       (hz_flush_id_ex),
        .flush_if_id       (hz_flush_if_id)
    );

    // ======================================================================
    //  STAGE 1/2: IF/ID
    // ======================================================================
    IF_ID IF_ID_stage (
        .clk                 (clk),
        .reset               (!reset),
        .stall               (stall),
        .exception           (exception),
        .inst_mem_is_valid   (1'b1),
        .inst_mem_read_data  (if_id_instruction),
        .stall_read_i        (pipeline_stall),       // freeze on cache miss too
        .inst_fetch_pc       (if_id_pc),
        .instruction_i       (instruction),

        .stall_if_id         (eff_hz_stall_if),      // suppress during cache stall
        .stall_div           (eff_div_busy || mem_stall), // hold ID/EX during cache stall
        .flush_if_id         (eff_pipeline_flush),   // suppress flush during cache stall

        .inst_mem_offset     (fetch_pc[1:0]),
        .execute_immediate_w (id_ex_immediate),
        .immediate_sel_w     (id_ex_immediate_sel),
        .alu_w               (id_ex_alu),
        .lui_w               (id_ex_lui),
        .auipc_w             (id_ex_auipc),
        .jal_w               (id_ex_jal),
        .jalr_w              (id_ex_jalr),
        .branch_w            (id_ex_branch),
        .mem_write_w         (id_ex_mem_write),
        .mem_to_reg_w        (id_ex_mem_to_reg),
        .arithsubtype_w      (id_ex_arithsubtype),
        .muldiv_w            (id_ex_muldiv),
        .pc_w                (id_ex_pc),
        .src1_select_w       (id_ex_rs1),
        .src2_select_w       (id_ex_rs2),
        .dest_reg_sel_w      (id_ex_rd),
        .alu_operation_w     (id_ex_alu_op),
        .illegal_inst_w      (id_ex_illegal),
        .instruction_o       (instruction),

        .predicted_taken_i   (if_id_predicted_taken),
        .predicted_target_i  (if_id_predicted_target),
        .predicted_taken_w   (id_ex_predicted_taken),
        .predicted_target_w  (id_ex_predicted_target)
    );

    // ======================================================================
    //  STAGE 3: EXECUTE
    // ======================================================================
    execute execute_stage (
        .clk             (clk),
        .reset           (reset),
        .reg_rdata1      (reg_rdata1),
        .reg_rdata2      (reg_rdata2),
        .execute_imm     (id_ex_immediate),
        .pc              (id_ex_pc),
        .immediate_sel   (id_ex_immediate_sel),
        .mem_write       (id_ex_mem_write),
        .jal             (id_ex_jal),
        .jalr            (id_ex_jalr),
        .lui             (id_ex_lui),
        .auipc           (id_ex_auipc),
        .alu             (id_ex_alu),
        .branch          (id_ex_branch),
        .arithsubtype    (id_ex_arithsubtype),
        .muldiv          (id_ex_muldiv),
        .mem_to_reg      (id_ex_mem_to_reg),
        .dest_reg_sel    (id_ex_rd),
        .alu_op          (id_ex_alu_op),
        .rs1_addr        (id_ex_rs1),
        .rs2_addr        (id_ex_rs2),
        .forward_a       (forward_a),
        .forward_b       (forward_b),
        .ex_mem_fwd_data (em_alu_result),
        .mem_wb_fwd_data (wb_data),
        .predicted_taken  (id_ex_predicted_taken),
        .predicted_target (id_ex_predicted_target),
        .next_pc         (ex_next_pc),
        .branch_taken    (ex_branch_taken),
        .ex_alu_result   (ex_alu_result),
        .ex_store_data   (ex_store_data),
        .ex_pc           (ex_pc),
        .ex_mem_write    (ex_mem_write),
        .ex_mem_to_reg   (ex_mem_to_reg),
        .ex_reg_write_en (ex_reg_write_en),
        .ex_rd           (ex_rd),
        .ex_funct3       (ex_funct3),
        .div_busy        (div_busy),
        .div_done        (div_done_w),
        .mispredict      (bp_mispredict)
    );

    // ======================================================================
    //  EX/MEM PIPELINE REGISTER
    // ======================================================================
    ex_mem_reg u_ex_mem (
        .clk             (clk),
        .reset_n         (!reset),
        .stall           (pipeline_stall),            // freeze on cache miss
        .flush           (eff_div_busy && !mem_stall),// bubble for div, not cache

        .alu_result_i    (ex_alu_result),
        .reg_write_data_i(ex_store_data),
        .pc_i            (ex_pc),
        .mem_write_i     (ex_mem_write),
        .mem_to_reg_i    (ex_mem_to_reg),
        .reg_write_en_i  (ex_reg_write_en),
        .rd_i            (ex_rd),
        .funct3_i        (ex_funct3),
        .branch_taken_i  (ex_branch_taken),

        .alu_result_o    (em_alu_result),
        .reg_write_data_o(em_store_data),
        .pc_o            (em_pc),
        .mem_write_o     (em_mem_write),
        .mem_to_reg_o    (em_mem_to_reg),
        .reg_write_en_o  (em_reg_write_en),
        .rd_o            (em_rd),
        .funct3_o        (em_funct3),
        .branch_taken_o  (em_branch_taken)
    );

    // ======================================================================
    //  STAGE 4: MEMORY ACCESS
    // ======================================================================
    mem_stage mem_stage_inst (
        .alu_result_i       (em_alu_result),
        .reg_write_data_i   (em_store_data),
        .mem_write_i        (em_mem_write),
        .mem_to_reg_i       (em_mem_to_reg),
        .funct3_i           (em_funct3),
        .dmem_read_data_i   (dcache_rdata),      // from D-cache (not raw data_mem)
        .dmem_addr_o        (mem_dmem_addr),
        .dmem_write_data_o  (mem_dmem_write_data),
        .dmem_write_byte_o  (mem_dmem_write_byte),
        .dmem_write_en_o    (mem_dmem_write_en),
        .dmem_read_en_o     (mem_dmem_read_en),
        .mem_read_data_o    (mem_read_data),
        .byte_offset_o      (mem_byte_offset)
    );

    // ======================================================================
    //  MEM/WB PIPELINE REGISTER
    // ======================================================================
    mem_wb_reg u_mem_wb (
        .clk             (clk),
        .reset_n         (!reset),
        .stall           (pipeline_stall),   // freeze on cache miss

        .alu_result_i    (em_alu_result),
        .mem_read_data_i (mem_read_data),
        .pc_i            (em_pc),
        .mem_to_reg_i    (em_mem_to_reg),
        .reg_write_en_i  (em_reg_write_en),
        .rd_i            (em_rd),
        .funct3_i        (em_funct3),
        .byte_offset_i   (mem_byte_offset),

        .alu_result_o    (mw_alu_result),
        .mem_read_data_o (mw_mem_read_data),
        .pc_o            (mw_pc),
        .mem_to_reg_o    (mw_mem_to_reg),
        .reg_write_en_o  (mw_reg_write_en),
        .rd_o            (mw_rd),
        .funct3_o        (mw_funct3),
        .byte_offset_o   (mw_byte_offset)
    );

    // ======================================================================
    //  STAGE 5: WRITE-BACK
    // ======================================================================
    wb wb_stage (
        .alu_result_i    (mw_alu_result),
        .mem_read_data_i (mw_mem_read_data),
        .mem_to_reg_i    (mw_mem_to_reg),
        .funct3_i        (mw_funct3),
        .byte_offset_i   (mw_byte_offset),
        .wb_data_o       (wb_data)
    );

    // ======================================================================
    //  BRANCH PREDICTOR
    // ======================================================================
    wire btb_update_en = id_ex_branch || id_ex_jal || id_ex_jalr;

    branch_predictor bp (
        .clk            (clk),
        .reset          (reset),
        .fetch_pc       (fetch_pc),
        .predict_taken  (bp_predict_taken),
        .predict_target (bp_predict_target),
        .update_en      (btb_update_en),
        .update_pc      (id_ex_pc),
        .actual_taken   (ex_branch_taken),
        .actual_target  (ex_next_pc)
    );

    // ======================================================================
    //  PC UPDATE LOGIC
    // ======================================================================
    always @(posedge clk or posedge reset) begin
        if (reset)
            fetch_pc <= RESET;
        else if (!pipeline_stall) begin
            if (bp_mispredict)
                fetch_pc <= ex_next_pc;
            else if (!eff_hz_stall_if) begin
                if (bp_predict_taken)
                    fetch_pc <= bp_predict_target;
                else
                    fetch_pc <= fetch_pc + 32'd4;
            end
        end
    end

endmodule
