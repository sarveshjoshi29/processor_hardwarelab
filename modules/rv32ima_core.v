// rv32ima_core.v
`timescale 1ns/1ps
// ============================================================================
// RV32IMA Single-Core Pipeline — Phase 4.5
// ============================================================================
// Refactored from pipe (pipeline.v) for dual-core integration:
//   - Memory modules (instr_mem, data_mem) removed — ports exposed externally
//   - I-cache fill, D-cache fill/writeback, and atomic ports go to bus arbiter
//   - RV32A lr.w/sc.w bypass D-cache entirely through atomic port
//   - Exclusive monitor interface for LR/SC reservation tracking
//   - CORE_ID parameter for per-core identification
//
// This module instantiates:
//   icache, dcache, IF_ID, execute, ex_mem_reg, mem_stage, mem_wb_reg, wb,
//   hazard_forward_unit, divider, branch_predictor
// ============================================================================
// For Icarus Verilog simulation, include sub-modules explicitly:
`ifndef SYNTHESIS
`ifndef RV32IMA_CORE_INCLUDED
`define RV32IMA_CORE_INCLUDED
`include "IF_ID.v"
`include "execute.v"
`include "ex_mem_reg.v"
`include "mem_stage.v"
`include "mem_wb_reg.v"
`include "wb.v"
`include "hazard_forward_unit.v"
`include "divider.v"
`include "branch_predictor.v"
`include "icache.v"
`include "dcache.v"
`include "csr_perf.v"
`endif
`endif

module rv32ima_core
#(
    parameter [31:0] RESET   = 32'h0000_0000,
    parameter        CORE_ID = 0
)
(
    input                clk,
    input                reset,
    input                stall,
    output               exception,
    output [31:0]        pc_out,
    output [31:0]        inst_fetch_pc,

    // Testbench monitoring outputs
    output [31:0]        inst_word_out,
    output               dmem_write_ready,
    output [31:0]        dmem_write_data,
    output [ 3:0]        dmem_write_byte,

    // ====================================================================
    // I-cache ↔ Bus Arbiter (fill port)
    // ====================================================================
    output               ic_fill_req,
    output [31:0]        ic_fill_addr,
    input  [127:0]       ic_fill_rdata,
    input                ic_fill_ready,

    // ====================================================================
    // D-cache ↔ Bus Arbiter (fill port — cache miss read)
    // ====================================================================
    output               dc_fill_req,
    output [31:0]        dc_fill_addr,
    input  [127:0]       dc_fill_rdata,
    input                dc_fill_ready,

    // ====================================================================
    // D-cache ↔ Bus Arbiter (writeback port — dirty eviction)
    // ====================================================================
    output               dc_wb_req,
    output [31:0]        dc_wb_addr,
    output [127:0]       dc_wb_wdata,
    input                dc_wb_ready,

    // ====================================================================
    // Atomic port ↔ Bus Arbiter (lr.w / sc.w — bypasses D-cache)
    // ====================================================================
    output               atomic_req_o,
    output               atomic_we_o,
    output [31:0]        atomic_addr_o,
    output [31:0]        atomic_wdata_o,
    input  [31:0]        atomic_rdata_i,
    input                atomic_ready_i,

    // ====================================================================
    // Exclusive monitor interface
    // ====================================================================
    output               lr_valid_o,       // 1 = lr.w in MEM stage this cycle
    output               sc_valid_o,       // 1 = sc.w in MEM stage this cycle
    output [31:0]        atomic_addr_em_o, // address for exclusive monitor
    input                sc_fail_i,        // 1 = sc.w failed (from exclusive monitor)

    // ====================================================================
    // MMIO port (Phase 5 — for peripheral access, bypasses D-cache)
    // ====================================================================
    output               mmio_req_o,
    output               mmio_we_o,
    output [31:0]        mmio_addr_o,
    output [31:0]        mmio_wdata_o,
    output [ 3:0]        mmio_be_o,
    input  [31:0]        mmio_rdata_i,
    input                mmio_ready_i
);

    // ======================================================================
    //  WIRE / REG DECLARATIONS
    // ======================================================================

    reg          stall_read;
    reg  [31:0]  fetch_pc;
    // Register file: forced to distributed RAM to avoid synthesizing
    // 32x32 = 1024 FFs per core plus two large 32:1 muxes.  x0 is
    // handled by the read-side mux below, so no reset is needed on the
    // array itself.
    (* ram_style = "distributed" *)
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

    // ---- RV32A: ID/EX atomic outputs ----
    wire         id_ex_atomic_lr, id_ex_atomic_sc;

    // ---- CSR: ID/EX outputs (Phase 5) ----
    wire         id_ex_csr_en;

    // ---- EX stage outputs ----
    wire [31:0]  ex_next_pc;
    wire         ex_branch_taken;
    wire [31:0]  ex_alu_result, ex_store_data, ex_pc;
    wire         ex_mem_write, ex_mem_to_reg, ex_reg_write_en;
    wire [ 4:0]  ex_rd;
    wire [ 2:0]  ex_funct3;
    wire         ex_atomic_lr, ex_atomic_sc;

    // ---- EX stage CSR outputs (Phase 5) ----
    wire         ex_csr_en;
    wire [31:0]  ex_csr_wdata;

    // ---- EX/MEM register outputs ----
    wire [31:0]  em_alu_result, em_store_data, em_pc;
    wire         em_mem_write, em_mem_to_reg, em_reg_write_en;
    wire [ 4:0]  em_rd;
    wire [ 2:0]  em_funct3;
    wire         em_branch_taken;
    wire         em_atomic_lr, em_atomic_sc;

    // ---- EX/MEM CSR outputs (Phase 5) ----
    wire         em_csr_en;
    wire [31:0]  em_csr_wdata;

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
    //  CACHE WIRES (internal: cache ↔ core; external ports go to arbiter)
    // ======================================================================

    // Cache stall signals
    wire         icache_stall;
    wire         dcache_stall;

    // ---- RV32A: Atomic bypass logic ----
    // lr.w/sc.w bypass D-cache entirely.
    // Always send memory request for both LR and SC (even failing SC).
    // This breaks the combinatorial loop: sc_fail → atomic_need_mem →
    // atomic_stall → pipeline_stall → sc_valid → exmon → sc_fail.
    // A failing SC sends a harmless read (atomic_we=0); the result is ignored.
    wire atomic_need_mem = em_atomic_lr || em_atomic_sc;
    wire atomic_stall    = atomic_need_mem && !atomic_ready_i;

    // ---- MMIO detection (Phase 5) ----
    // Only the 0x2xxx_xxxx region is MMIO (UART + AXI peripherals).
    // dmem lives at 0x4xxx_xxxx and must go through the D-cache, not the AXI
    // stub — otherwise every .data/.bss/stack access silently reads 0.
    wire mmio_access = (em_alu_result[31:28] == 4'h2);
    wire mmio_data_access = (em_mem_write || em_mem_to_reg)
                          && !em_atomic_lr && !em_atomic_sc
                          && mmio_access;
    wire mmio_stall  = mmio_data_access && !mmio_ready_i;

    wire mem_stall       = icache_stall || dcache_stall || atomic_stall || mmio_stall;

    // ---- Unified pipeline freeze ----
    wire pipeline_stall  = stall_read || mem_stall;

    // ---- Suppress hazard-unit signals during cache/atomic stall ----
    wire eff_hz_stall_if    = hz_stall_if   && !mem_stall;
    wire eff_pipeline_flush = pipeline_flush && !mem_stall;

    // I-cache instruction output
    wire [31:0]  icache_instr;

    // D-cache read data
    wire [31:0]  dcache_rdata;

    // ======================================================================
    //  EXCLUSIVE MONITOR INTERFACE
    // ======================================================================
    assign lr_valid_o      = em_atomic_lr && !pipeline_stall;
    assign sc_valid_o      = em_atomic_sc && !pipeline_stall;
    assign atomic_addr_em_o = em_alu_result;

    // ======================================================================
    //  ATOMIC PORT OUTPUTS (to bus arbiter)
    // ======================================================================
    assign atomic_req_o   = atomic_need_mem;
    assign atomic_we_o    = em_atomic_sc && !sc_fail_i;
    assign atomic_addr_o  = em_alu_result;
    assign atomic_wdata_o = em_store_data;

    // ======================================================================
    //  MMIO PORT OUTPUTS (Phase 5)
    // ======================================================================
    assign mmio_req_o   = mmio_data_access;
    assign mmio_we_o    = em_mem_write && mmio_access;
    assign mmio_addr_o  = em_alu_result;
    assign mmio_wdata_o = mem_dmem_write_data;
    assign mmio_be_o    = mem_dmem_write_byte;

    // ======================================================================
    //  CSR UNIT (Phase 5 — Performance Counters)
    // ======================================================================
    // CSR read happens combinationally from EX stage address.
    // CSR write happens sequentially from MEM stage (after flush check).
    wire [31:0] csr_rdata;

    // Event signals for performance counters
    reg prev_icache_stall, prev_dcache_stall;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            prev_icache_stall <= 1'b0;
            prev_dcache_stall <= 1'b0;
        end else begin
            prev_icache_stall <= icache_stall;
            prev_dcache_stall <= dcache_stall;
        end
    end
    wire evt_icache_miss = icache_stall && !prev_icache_stall;
    wire evt_dcache_miss = dcache_stall && !prev_dcache_stall;

    // Instruction retirement: register write or store in WB, not stalled
    wire evt_instret = (mw_reg_write_en || (em_mem_write && !mmio_access && !pipeline_stall))
                     && !pipeline_stall;

    // CSR write in MEM stage (survived flush)
    // csr_op derived from funct3[1:0] stored in em_funct3
    // CSR address from immediate field (lower 12 bits of I-type immediate)
    wire [11:0] csr_addr_ex  = id_ex_immediate[11:0]; // EX stage (for read)

    // CSR address must flow to MEM stage for write — use a dedicated register
    reg [11:0] em_csr_addr;
    reg [ 4:0] em_csr_rs1_addr;
    always @(posedge clk or posedge reset) begin
        if (reset || (eff_div_busy && !mem_stall)) begin
            em_csr_addr     <= 12'b0;
            em_csr_rs1_addr <= 5'b0;
        end
        else if (!pipeline_stall) begin
            em_csr_addr     <= id_ex_immediate[11:0];
            em_csr_rs1_addr <= id_ex_rs1;
        end
    end

    wire        csr_wen = em_csr_en && !pipeline_stall
                        && (em_funct3[1:0] == 2'b01 || em_csr_rs1_addr != 5'd0);

    csr_perf u_csr (
        .clk             (clk),
        .reset           (reset),
        .evt_cycle       (1'b1),
        .evt_instret     (evt_instret),
        .evt_icache_miss (evt_icache_miss),
        .evt_dcache_miss (evt_dcache_miss),
        .evt_br_mispredict(bp_mispredict),
        .evt_stall       (pipeline_stall),
        .csr_addr        (csr_wen ? em_csr_addr : csr_addr_ex),
        .csr_rdata       (csr_rdata),
        .csr_wen         (csr_wen),
        .csr_op          (em_funct3[1:0]),
        .csr_wdata       (em_csr_wdata)
    );

    // Override EX ALU result with CSR read data when CSR instruction in EX
    wire [31:0] ex_alu_result_csr = ex_csr_en ? csr_rdata : ex_alu_result;

    // ======================================================================
    //  MEM/WB INPUT MUXING FOR ATOMICS
    // ======================================================================
    // lr.w: treat like a load — use atomic_rdata as memory read data
    // sc.w: override alu_result with {31'b0, sc_fail} for both WB and forwarding
    wire [31:0] em_fwd_data       = em_atomic_sc ? {31'b0, sc_fail_i}
                                                  : em_alu_result;
    wire [31:0] mw_alu_result_in  = em_fwd_data;
    wire [31:0] mw_mem_data_in    = em_atomic_lr ? atomic_rdata_i
                                    : mmio_access  ? mmio_rdata_i
                                                   : mem_read_data;
    wire        mw_mem_to_reg_in  = em_mem_to_reg || em_atomic_lr;

    // ======================================================================
    //  CACHE INSTANTIATION (memory ports go external)
    // ======================================================================

    icache u_icache (
        .clk            (clk),
        .reset          (reset),
        .fetch_pc       (fetch_pc),
        .pipeline_stall (pipeline_stall),
        .instr          (icache_instr),
        .icache_stall   (icache_stall),
        .mem_req        (ic_fill_req),
        .mem_addr       (ic_fill_addr),
        .mem_rdata      (ic_fill_rdata),
        .mem_ready      (ic_fill_ready)
    );

    // D-cache req gated: suppress for atomic (lr/sc) and MMIO accesses
    dcache u_dcache (
        .clk            (clk),
        .reset          (reset),
        .req            ((em_mem_write || em_mem_to_reg)
                          && !em_atomic_lr && !em_atomic_sc && !mmio_access),
        .we             (em_mem_write),
        .be             (mem_dmem_write_byte),
        .addr           (mem_dmem_addr),
        .wdata          (mem_dmem_write_data),
        .rdata          (dcache_rdata),
        .dcache_stall   (dcache_stall),
        .fill_req       (dc_fill_req),
        .fill_addr      (dc_fill_addr),
        .fill_rdata     (dc_fill_rdata),
        .fill_ready     (dc_fill_ready),
        .wb_req         (dc_wb_req),
        .wb_addr        (dc_wb_addr),
        .wb_wdata       (dc_wb_wdata),
        .wb_ready       (dc_wb_ready)
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
                if_id_instr_reg <= icache_instr;
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
    assign inst_word_out   = if_id_instruction;

    assign dmem_write_ready = mem_dmem_write_en && !pipeline_stall;
    assign dmem_write_data  = mem_dmem_write_data;
    assign dmem_write_byte  = mem_dmem_write_byte;

    // ======================================================================
    //  FLUSH DELAY REGISTER
    // ======================================================================
    always @(posedge clk or posedge reset) begin
        if (reset)
            flush_delay <= 1'b0;
        else if (!pipeline_stall)
            flush_delay <= bp_mispredict;
    end

    // ======================================================================
    //  IF/ID PC REGISTER
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

    // Power-on init: zero the register file for both simulation and
    // Xilinx bitstream loading. Avoids the async reset loop, which would
    // prevent distributed-RAM inference and force 1024 FFs per core.
    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1)
            regs[i] = 32'b0;
    end
    always @(posedge clk) begin
        if (mw_reg_write_en && (mw_rd != 5'd0) && !pipeline_stall) begin
            regs[mw_rd] <= wb_data;
        end
    end

    // ======================================================================
    //  STALL REGISTER
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
        .stall_read_i        (pipeline_stall),
        .inst_fetch_pc       (if_id_pc),
        .instruction_i       (instruction),

        .stall_if_id         (eff_hz_stall_if),
        .stall_div           (eff_div_busy || mem_stall),
        .flush_if_id         (eff_pipeline_flush),

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
        .predicted_target_w  (id_ex_predicted_target),

        .atomic_lr_w         (id_ex_atomic_lr),
        .atomic_sc_w         (id_ex_atomic_sc),

        .csr_en_w            (id_ex_csr_en)
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
        .ex_mem_fwd_data (em_fwd_data),
        .mem_wb_fwd_data (wb_data),
        .atomic_lr       (id_ex_atomic_lr),
        .atomic_sc       (id_ex_atomic_sc),
        .csr_en          (id_ex_csr_en),
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
        .ex_atomic_lr    (ex_atomic_lr),
        .ex_atomic_sc    (ex_atomic_sc),
        .mispredict      (bp_mispredict),
        .ex_csr_en       (ex_csr_en),
        .ex_csr_wdata    (ex_csr_wdata)
    );

    // ======================================================================
    //  EX/MEM PIPELINE REGISTER
    // ======================================================================
    ex_mem_reg u_ex_mem (
        .clk             (clk),
        .reset_n         (!reset),
        .stall           (pipeline_stall),
        .flush           (eff_div_busy && !mem_stall),

        .alu_result_i    (ex_alu_result_csr),
        .reg_write_data_i(ex_store_data),
        .pc_i            (ex_pc),
        .mem_write_i     (ex_mem_write),
        .mem_to_reg_i    (ex_mem_to_reg),
        .reg_write_en_i  (ex_reg_write_en),
        .rd_i            (ex_rd),
        .funct3_i        (ex_funct3),
        .branch_taken_i  (ex_branch_taken),
        .atomic_lr_i     (ex_atomic_lr),
        .atomic_sc_i     (ex_atomic_sc),
        .csr_en_i        (ex_csr_en),
        .csr_wdata_i     (ex_csr_wdata),

        .alu_result_o    (em_alu_result),
        .reg_write_data_o(em_store_data),
        .pc_o            (em_pc),
        .mem_write_o     (em_mem_write),
        .mem_to_reg_o    (em_mem_to_reg),
        .reg_write_en_o  (em_reg_write_en),
        .rd_o            (em_rd),
        .funct3_o        (em_funct3),
        .branch_taken_o  (em_branch_taken),
        .atomic_lr_o     (em_atomic_lr),
        .atomic_sc_o     (em_atomic_sc),
        .csr_en_o        (em_csr_en),
        .csr_wdata_o     (em_csr_wdata)
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
        .dmem_read_data_i   (dcache_rdata),
        .dmem_addr_o        (mem_dmem_addr),
        .dmem_write_data_o  (mem_dmem_write_data),
        .dmem_write_byte_o  (mem_dmem_write_byte),
        .dmem_write_en_o    (mem_dmem_write_en),
        .dmem_read_en_o     (mem_dmem_read_en),
        .mem_read_data_o    (mem_read_data),
        .byte_offset_o      (mem_byte_offset)
    );

    // ======================================================================
    //  MEM/WB PIPELINE REGISTER (with atomic muxing)
    // ======================================================================
    mem_wb_reg u_mem_wb (
        .clk             (clk),
        .reset_n         (!reset),
        .stall           (pipeline_stall),

        .alu_result_i    (mw_alu_result_in),    // sc.w: {31'b0, sc_fail}
        .mem_read_data_i (mw_mem_data_in),       // lr.w: atomic_rdata
        .pc_i            (em_pc),
        .mem_to_reg_i    (mw_mem_to_reg_in),     // lr.w: forced to 1
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
