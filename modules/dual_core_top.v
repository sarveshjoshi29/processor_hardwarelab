`timescale 1ns/1ps
// dual_core_top.v
// ============================================================================
// Dual-Core RV32IMA Top-Level
// ============================================================================
// Instantiates:
//   - 2x rv32ima_core   (core 0 and core 1)
//   - 1x bus_arbiter     (multiplexes 4 port types between cores)
//   - 1x exclusive_monitor (LR/SC reservation tracking)
//   - 1x instr_mem       (shared instruction BRAM)
//   - 1x data_mem        (shared data BRAM with atomic port)
//
// Core 0 starts at RESET_C0, Core 1 at RESET_C1.
// Both cores share the same instruction and data memory.
// Core 0 has bus priority on simultaneous requests.
// ============================================================================

// All modules added as separate design sources in Vivado — no `include needed
// For Icarus Verilog simulation, include sub-modules explicitly:

`ifndef SYNTHESIS
`include "rv32ima_core.v"
`include "bus_arbiter.v"
`include "exclusive_monitor.v"
`include "memory.v"
`endif

module dual_core_top
#(
    parameter [31:0] RESET_C0 = 32'h0000_0000,
    parameter [31:0] RESET_C1 = 32'h0000_0200   // core 1 starts at offset 512
)
(
    input         clk,
    input         reset,
    input         stall,

    // ---- Bootloader write ports (word writes into BRAM) ----
    input         bl_imem_we,
    input  [ 9:0] bl_imem_addr,
    input  [31:0] bl_imem_wdata,

    input         bl_dmem_we,
    input  [ 9:0] bl_dmem_addr,
    input  [31:0] bl_dmem_wdata,

    // ---- Core 0 monitoring ----
    output        c0_exception,
    output [31:0] c0_pc_out,
    output [31:0] c0_inst_fetch_pc,
    output [31:0] c0_inst_word_out,
    output        c0_dmem_write_ready,
    output [31:0] c0_dmem_write_data,
    output [ 3:0] c0_dmem_write_byte,

    // ---- Core 1 monitoring ----
    output        c1_exception,
    output [31:0] c1_pc_out,
    output [31:0] c1_inst_fetch_pc,
    output [31:0] c1_inst_word_out,
    output        c1_dmem_write_ready,
    output [31:0] c1_dmem_write_data,
    output [ 3:0] c1_dmem_write_byte,

    // ---- MMIO port (Phase 5 — arbitrated between cores) ----
    output        mmio_req,
    output        mmio_we,
    output [31:0] mmio_addr,
    output [31:0] mmio_wdata,
    output [ 3:0] mmio_be,
    input  [31:0] mmio_rdata,
    input         mmio_ready
);

    // ======================================================================
    //  Core 0 ↔ Bus Arbiter wires
    // ======================================================================
    wire        c0_ic_req,   c0_ic_ready;
    wire [31:0] c0_ic_addr;
    wire [127:0] c0_ic_rdata;

    wire        c0_dc_fill_req,   c0_dc_fill_ready;
    wire [31:0] c0_dc_fill_addr;
    wire [127:0] c0_dc_fill_rdata;

    wire        c0_dc_wb_req,   c0_dc_wb_ready;
    wire [31:0] c0_dc_wb_addr;
    wire [127:0] c0_dc_wb_wdata;

    wire        c0_atomic_req, c0_atomic_we, c0_atomic_ready;
    wire [31:0] c0_atomic_addr, c0_atomic_wdata, c0_atomic_rdata;

    // ---- Core 0 MMIO wires (Phase 5) ----
    wire        c0_mmio_req, c0_mmio_we;
    wire [31:0] c0_mmio_addr, c0_mmio_wdata;
    wire [ 3:0] c0_mmio_be;
    wire [31:0] c0_mmio_rdata;
    wire        c0_mmio_ready;

    // ---- Core 0 exclusive monitor wires ----
    wire        c0_lr_valid, c0_sc_valid;
    wire [31:0] c0_atomic_addr_em;
    wire        c0_sc_fail;

    // ======================================================================
    //  Core 1 ↔ Bus Arbiter wires
    // ======================================================================
    wire        c1_ic_req,   c1_ic_ready;
    wire [31:0] c1_ic_addr;
    wire [127:0] c1_ic_rdata;

    wire        c1_dc_fill_req,   c1_dc_fill_ready;
    wire [31:0] c1_dc_fill_addr;
    wire [127:0] c1_dc_fill_rdata;

    wire        c1_dc_wb_req,   c1_dc_wb_ready;
    wire [31:0] c1_dc_wb_addr;
    wire [127:0] c1_dc_wb_wdata;

    wire        c1_atomic_req, c1_atomic_we, c1_atomic_ready;
    wire [31:0] c1_atomic_addr, c1_atomic_wdata, c1_atomic_rdata;

    // ---- Core 1 MMIO wires (Phase 5) ----
    wire        c1_mmio_req, c1_mmio_we;
    wire [31:0] c1_mmio_addr, c1_mmio_wdata;
    wire [ 3:0] c1_mmio_be;
    wire [31:0] c1_mmio_rdata;
    wire        c1_mmio_ready;

    // ---- Core 1 exclusive monitor wires ----
    wire        c1_lr_valid, c1_sc_valid;
    wire [31:0] c1_atomic_addr_em;
    wire        c1_sc_fail;

    // ======================================================================
    //  Bus Arbiter ↔ Shared Memory wires
    // ======================================================================
    wire        mem_ic_req,    mem_ic_ready;
    wire [31:0] mem_ic_addr;
    wire [127:0] mem_ic_rdata;

    wire        mem_dc_fill_req,    mem_dc_fill_ready;
    wire [31:0] mem_dc_fill_addr;
    wire [127:0] mem_dc_fill_rdata;

    wire        mem_dc_wb_req,    mem_dc_wb_ready;
    wire [31:0] mem_dc_wb_addr;
    wire [127:0] mem_dc_wb_wdata;

    wire        mem_atomic_req, mem_atomic_we, mem_atomic_ready;
    wire [31:0] mem_atomic_addr, mem_atomic_wdata, mem_atomic_rdata;

    // ======================================================================
    //  Snoop wires (D-cache writeback → exclusive monitor)
    // ======================================================================
    // The bus arbiter exposes dc_wb_grant to identify which core's writeback
    // is currently being served. This feeds the exclusive monitor snoop port.
    wire        arb_dc_wb_grant;
    wire        snoop_valid   = mem_dc_wb_req;
    wire [31:0] snoop_addr    = mem_dc_wb_addr;
    // Combinational priority decode on the raw per-core wb requests.
    // arb_dc_wb_grant is a registered signal that lags by a cycle; using it
    // here tags the first cycle of a new wb with the previous owner's core
    // id and can break LR/SC reservation snooping.
    wire        snoop_core_id = c1_dc_wb_req && !c0_dc_wb_req;

    // ======================================================================
    //  CORE 0
    // ======================================================================
    rv32ima_core #(
        .RESET   (RESET_C0),
        .CORE_ID (0)
    ) core0 (
        .clk             (clk),
        .reset           (reset),
        .stall           (stall),
        .exception       (c0_exception),
        .pc_out          (c0_pc_out),
        .inst_fetch_pc   (c0_inst_fetch_pc),
        .inst_word_out   (c0_inst_word_out),
        .dmem_write_ready(c0_dmem_write_ready),
        .dmem_write_data (c0_dmem_write_data),
        .dmem_write_byte (c0_dmem_write_byte),

        // I-cache ↔ arbiter
        .ic_fill_req     (c0_ic_req),
        .ic_fill_addr    (c0_ic_addr),
        .ic_fill_rdata   (c0_ic_rdata),
        .ic_fill_ready   (c0_ic_ready),

        // D-cache fill ↔ arbiter
        .dc_fill_req     (c0_dc_fill_req),
        .dc_fill_addr    (c0_dc_fill_addr),
        .dc_fill_rdata   (c0_dc_fill_rdata),
        .dc_fill_ready   (c0_dc_fill_ready),

        // D-cache writeback ↔ arbiter
        .dc_wb_req       (c0_dc_wb_req),
        .dc_wb_addr      (c0_dc_wb_addr),
        .dc_wb_wdata     (c0_dc_wb_wdata),
        .dc_wb_ready     (c0_dc_wb_ready),

        // Atomic ↔ arbiter
        .atomic_req_o    (c0_atomic_req),
        .atomic_we_o     (c0_atomic_we),
        .atomic_addr_o   (c0_atomic_addr),
        .atomic_wdata_o  (c0_atomic_wdata),
        .atomic_rdata_i  (c0_atomic_rdata),
        .atomic_ready_i  (c0_atomic_ready),

        // Exclusive monitor
        .lr_valid_o      (c0_lr_valid),
        .sc_valid_o      (c0_sc_valid),
        .atomic_addr_em_o(c0_atomic_addr_em),
        .sc_fail_i       (c0_sc_fail),

        // MMIO (Phase 5)
        .mmio_req_o      (c0_mmio_req),
        .mmio_we_o       (c0_mmio_we),
        .mmio_addr_o     (c0_mmio_addr),
        .mmio_wdata_o    (c0_mmio_wdata),
        .mmio_be_o       (c0_mmio_be),
        .mmio_rdata_i    (c0_mmio_rdata),
        .mmio_ready_i    (c0_mmio_ready)
    );

    // ======================================================================
    //  CORE 1
    // ======================================================================
    rv32ima_core #(
        .RESET   (RESET_C1),
        .CORE_ID (1)
    ) core1 (
        .clk             (clk),
        .reset           (reset),
        .stall           (stall),
        .exception       (c1_exception),
        .pc_out          (c1_pc_out),
        .inst_fetch_pc   (c1_inst_fetch_pc),
        .inst_word_out   (c1_inst_word_out),
        .dmem_write_ready(c1_dmem_write_ready),
        .dmem_write_data (c1_dmem_write_data),
        .dmem_write_byte (c1_dmem_write_byte),

        .ic_fill_req     (c1_ic_req),
        .ic_fill_addr    (c1_ic_addr),
        .ic_fill_rdata   (c1_ic_rdata),
        .ic_fill_ready   (c1_ic_ready),

        .dc_fill_req     (c1_dc_fill_req),
        .dc_fill_addr    (c1_dc_fill_addr),
        .dc_fill_rdata   (c1_dc_fill_rdata),
        .dc_fill_ready   (c1_dc_fill_ready),

        .dc_wb_req       (c1_dc_wb_req),
        .dc_wb_addr      (c1_dc_wb_addr),
        .dc_wb_wdata     (c1_dc_wb_wdata),
        .dc_wb_ready     (c1_dc_wb_ready),

        .atomic_req_o    (c1_atomic_req),
        .atomic_we_o     (c1_atomic_we),
        .atomic_addr_o   (c1_atomic_addr),
        .atomic_wdata_o  (c1_atomic_wdata),
        .atomic_rdata_i  (c1_atomic_rdata),
        .atomic_ready_i  (c1_atomic_ready),

        .lr_valid_o      (c1_lr_valid),
        .sc_valid_o      (c1_sc_valid),
        .atomic_addr_em_o(c1_atomic_addr_em),
        .sc_fail_i       (c1_sc_fail),

        // MMIO (Phase 5)
        .mmio_req_o      (c1_mmio_req),
        .mmio_we_o       (c1_mmio_we),
        .mmio_addr_o     (c1_mmio_addr),
        .mmio_wdata_o    (c1_mmio_wdata),
        .mmio_be_o       (c1_mmio_be),
        .mmio_rdata_i    (c1_mmio_rdata),
        .mmio_ready_i    (c1_mmio_ready)
    );

    // ======================================================================
    //  BUS ARBITER
    // ======================================================================
    bus_arbiter u_arbiter (
        .clk             (clk),
        .reset           (reset),

        // I-cache fill
        .c0_ic_req       (c0_ic_req),
        .c0_ic_addr      (c0_ic_addr),
        .c0_ic_rdata     (c0_ic_rdata),
        .c0_ic_ready     (c0_ic_ready),
        .c1_ic_req       (c1_ic_req),
        .c1_ic_addr      (c1_ic_addr),
        .c1_ic_rdata     (c1_ic_rdata),
        .c1_ic_ready     (c1_ic_ready),
        .mem_ic_req      (mem_ic_req),
        .mem_ic_addr     (mem_ic_addr),
        .mem_ic_rdata    (mem_ic_rdata),
        .mem_ic_ready    (mem_ic_ready),

        // D-cache fill
        .c0_dc_fill_req  (c0_dc_fill_req),
        .c0_dc_fill_addr (c0_dc_fill_addr),
        .c0_dc_fill_rdata(c0_dc_fill_rdata),
        .c0_dc_fill_ready(c0_dc_fill_ready),
        .c1_dc_fill_req  (c1_dc_fill_req),
        .c1_dc_fill_addr (c1_dc_fill_addr),
        .c1_dc_fill_rdata(c1_dc_fill_rdata),
        .c1_dc_fill_ready(c1_dc_fill_ready),
        .mem_dc_fill_req (mem_dc_fill_req),
        .mem_dc_fill_addr(mem_dc_fill_addr),
        .mem_dc_fill_rdata(mem_dc_fill_rdata),
        .mem_dc_fill_ready(mem_dc_fill_ready),

        // D-cache writeback
        .c0_dc_wb_req    (c0_dc_wb_req),
        .c0_dc_wb_addr   (c0_dc_wb_addr),
        .c0_dc_wb_wdata  (c0_dc_wb_wdata),
        .c0_dc_wb_ready  (c0_dc_wb_ready),
        .c1_dc_wb_req    (c1_dc_wb_req),
        .c1_dc_wb_addr   (c1_dc_wb_addr),
        .c1_dc_wb_wdata  (c1_dc_wb_wdata),
        .c1_dc_wb_ready  (c1_dc_wb_ready),
        .mem_dc_wb_req   (mem_dc_wb_req),
        .mem_dc_wb_addr  (mem_dc_wb_addr),
        .mem_dc_wb_wdata (mem_dc_wb_wdata),
        .mem_dc_wb_ready (mem_dc_wb_ready),

        // Atomic
        .c0_atomic_req   (c0_atomic_req),
        .c0_atomic_we    (c0_atomic_we),
        .c0_atomic_addr  (c0_atomic_addr),
        .c0_atomic_wdata (c0_atomic_wdata),
        .c0_atomic_rdata (c0_atomic_rdata),
        .c0_atomic_ready (c0_atomic_ready),
        .c1_atomic_req   (c1_atomic_req),
        .c1_atomic_we    (c1_atomic_we),
        .c1_atomic_addr  (c1_atomic_addr),
        .c1_atomic_wdata (c1_atomic_wdata),
        .c1_atomic_rdata (c1_atomic_rdata),
        .c1_atomic_ready (c1_atomic_ready),
        .mem_atomic_req  (mem_atomic_req),
        .mem_atomic_we   (mem_atomic_we),
        .mem_atomic_addr (mem_atomic_addr),
        .mem_atomic_wdata(mem_atomic_wdata),
        .mem_atomic_rdata(mem_atomic_rdata),
        .mem_atomic_ready(mem_atomic_ready),

        // Snoop helper
        .dc_wb_grant     (arb_dc_wb_grant)
    );

    // ======================================================================
    //  EXCLUSIVE MONITOR
    // ======================================================================
    exclusive_monitor u_exmon (
        .clk           (clk),
        .reset         (reset),

        .c0_lr_valid   (c0_lr_valid),
        .c0_sc_valid   (c0_sc_valid),
        .c0_addr       (c0_atomic_addr_em),
        .c0_sc_fail    (c0_sc_fail),

        .c1_lr_valid   (c1_lr_valid),
        .c1_sc_valid   (c1_sc_valid),
        .c1_addr       (c1_atomic_addr_em),
        .c1_sc_fail    (c1_sc_fail),

        .snoop_valid   (snoop_valid),
        .snoop_addr    (snoop_addr),
        .snoop_core_id (snoop_core_id)
    );

    // ======================================================================
    //  SHARED INSTRUCTION MEMORY
    // ======================================================================
    instr_mem u_instr_mem (
        .clk        (clk),
        .reset      (reset),
        .bl_we      (bl_imem_we),
        .bl_addr    (bl_imem_addr),
        .bl_wdata   (bl_imem_wdata),
        .ic_req     (mem_ic_req),
        .ic_addr    (mem_ic_addr),
        .ic_rdata   (mem_ic_rdata),
        .ic_ready   (mem_ic_ready)
    );

    // ======================================================================
    //  SHARED DATA MEMORY
    // ======================================================================
    data_mem u_data_mem (
        .clk            (clk),
        .reset          (reset),
        .bl_we          (bl_dmem_we),
        .bl_addr        (bl_dmem_addr),
        .bl_wdata       (bl_dmem_wdata),
        .dc_fill_req    (mem_dc_fill_req),
        .dc_fill_addr   (mem_dc_fill_addr),
        .dc_fill_rdata  (mem_dc_fill_rdata),
        .dc_fill_ready  (mem_dc_fill_ready),
        .dc_wb_req      (mem_dc_wb_req),
        .dc_wb_addr     (mem_dc_wb_addr),
        .dc_wb_wdata    (mem_dc_wb_wdata),
        .dc_wb_ready    (mem_dc_wb_ready),
        .atomic_req     (mem_atomic_req),
        .atomic_we      (mem_atomic_we),
        .atomic_addr    (mem_atomic_addr),
        .atomic_wdata   (mem_atomic_wdata),
        .atomic_rdata   (mem_atomic_rdata),
        .atomic_ready   (mem_atomic_ready)
    );

    // ======================================================================
    //  MMIO ARBITER (Phase 5 — simple Core 0 priority)
    // ======================================================================
    // Single-cycle arbitration: Core 0 has priority. The other core's
    // ready is deasserted until the granted core's request completes.
    wire mmio_grant = !c0_mmio_req && c1_mmio_req;  // 0=core0, 1=core1

    assign mmio_req   = c0_mmio_req || c1_mmio_req;
    assign mmio_we    = mmio_grant ? c1_mmio_we    : c0_mmio_we;
    assign mmio_addr  = mmio_grant ? c1_mmio_addr  : c0_mmio_addr;
    assign mmio_wdata = mmio_grant ? c1_mmio_wdata : c0_mmio_wdata;
    assign mmio_be    = mmio_grant ? c1_mmio_be    : c0_mmio_be;

    assign c0_mmio_rdata = mmio_rdata;
    assign c1_mmio_rdata = mmio_rdata;
    assign c0_mmio_ready = mmio_ready && !mmio_grant;
    assign c1_mmio_ready = mmio_ready &&  mmio_grant;

endmodule
