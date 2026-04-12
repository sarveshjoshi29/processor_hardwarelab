`timescale 1ns/1ps
// dual_core_top.v
// ============================================================================
// Dual-Core RV32IMA Top-Level
// ============================================================================
// Instantiates:
//   - 2x rv32ima_core   (core 0 and core 1)
//   - 1x bus_arbiter     (multiplexes 3 port types between cores)
//   - 1x instr_mem       (shared instruction BRAM)
//   - 1x data_mem        (shared data BRAM)
//
// Core 0 starts at RESET_C0, Core 1 at RESET_C1.
// Both cores share the same instruction and data memory.
// Core 0 has bus priority on simultaneous requests.
// ============================================================================

`include "rv32ima_core.v"
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
`include "bus_arbiter.v"

module dual_core_top
#(
    parameter [31:0] RESET_C0 = 32'h0000_0000,
    parameter [31:0] RESET_C1 = 32'h0000_0200   // core 1 starts at offset 512
)
(
    input         clk,
    input         reset,
    input         stall,

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
    output [ 3:0] c1_dmem_write_byte
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

    // ======================================================================
    //  Snoop helper (D-cache writeback)
    // ======================================================================
    wire        arb_dc_wb_grant;

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
        .dc_wb_ready     (c0_dc_wb_ready)

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
        .dc_wb_ready     (c1_dc_wb_ready)

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

        // Snoop helper
        .dc_wb_grant     (arb_dc_wb_grant)
    );

    // ======================================================================
    //  SHARED INSTRUCTION MEMORY
    // ======================================================================
    instr_mem u_instr_mem (
        .clk        (clk),
        .reset      (reset),
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
        .dc_fill_req    (mem_dc_fill_req),
        .dc_fill_addr   (mem_dc_fill_addr),
        .dc_fill_rdata  (mem_dc_fill_rdata),
        .dc_fill_ready  (mem_dc_fill_ready),
        .dc_wb_req      (mem_dc_wb_req),
        .dc_wb_addr     (mem_dc_wb_addr),
        .dc_wb_wdata    (mem_dc_wb_wdata),
        .dc_wb_ready    (mem_dc_wb_ready)
    );

endmodule
