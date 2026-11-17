/*
 * OpenCM4F - an open Cortex-M4F compatible processor (ARMv7E-M, Thumb-2, DSP extension, FPv4-SP FPU)
 * with AXI4-Lite bus interfaces
 * SPDX-License-Identifier: MIT
 *
 *   M_AXI_I  instruction fetches (read only, word accesses, up to 2 reads in flight)
 *   M_AXI_D  loads, stores, stacking, vector reads (byte strobes, posted writes, up to 2 reads)
 *   The System Control Space (0xE000_0000 - 0xE00F_FFFF: NVIC, SCB, SysTick, DWT, FPU control) is
 *   inside the core and never appears on the bus.
 *
 * Both masters need in-order responses (AXI4-Lite has no IDs). The reset vector table is read at
 * address 0 (SP, then PC); VTOR moves it later.
 *
 * Parameters: NUM_IRQ (1..16) external interrupts, PRIO_BITS (2..4) priority bits.
 */

`default_nettype none

module opencm4f #(
    parameter NUM_IRQ   = 16,
    parameter PRIO_BITS = 3
) (
    input  wire               clk,
    input  wire               rst_n,

    // instruction bus
    output wire [31:0]        m_axi_i_araddr,
    output wire [2:0]         m_axi_i_arprot,
    output wire               m_axi_i_arvalid,
    input  wire               m_axi_i_arready,
    input  wire [31:0]        m_axi_i_rdata,
    input  wire [1:0]         m_axi_i_rresp,
    input  wire               m_axi_i_rvalid,
    output wire               m_axi_i_rready,

    // data bus
    output wire [31:0]        m_axi_d_awaddr,
    output wire [2:0]         m_axi_d_awprot,
    output wire               m_axi_d_awvalid,
    input  wire               m_axi_d_awready,
    output wire [31:0]        m_axi_d_wdata,
    output wire [3:0]         m_axi_d_wstrb,
    output wire               m_axi_d_wvalid,
    input  wire               m_axi_d_wready,
    input  wire [1:0]         m_axi_d_bresp,
    input  wire               m_axi_d_bvalid,
    output wire               m_axi_d_bready,
    output wire [31:0]        m_axi_d_araddr,
    output wire [2:0]         m_axi_d_arprot,
    output wire               m_axi_d_arvalid,
    input  wire               m_axi_d_arready,
    input  wire [31:0]        m_axi_d_rdata,
    input  wire [1:0]         m_axi_d_rresp,
    input  wire               m_axi_d_rvalid,
    output wire               m_axi_d_rready,

    // interrupts, events, status
    input  wire [NUM_IRQ-1:0] irq,
    input  wire               nmi,
    input  wire               rxev,
    output wire               txev,
    input  wire               dbg_halt_on_bkpt,
    output wire               halted,
    output wire               lockup,
    output wire               sleeping,
    output wire               sysresetreq,

    // trace and performance events
    output wire               trc_valid,
    output wire [31:0]        trc_pc,
    output wire [31:0]        trc_insn,
    output wire               trc_skip,
    output wire               trc_rf_we,
    output wire [3:0]         trc_rf_wa,
    output wire [31:0]        trc_rf_wd,
    output wire               trc_fp_we,
    output wire [4:0]         trc_fp_wa,
    output wire [31:0]        trc_fp_wd,
    output wire [31:0]        trc_xpsr,
    output wire [31:0]        trc_fpscr,
    output wire [2:0]         trc_control,
    output wire [6:0]         perf_ev
);

  ocm4_core #(.NUM_IRQ(NUM_IRQ), .PRIO_BITS(PRIO_BITS)) u_core (
      .clk(clk), .rst_n(rst_n),
      .i_araddr(m_axi_i_araddr), .i_arprot(m_axi_i_arprot), .i_arvalid(m_axi_i_arvalid), .i_arready(m_axi_i_arready),
      .i_rdata(m_axi_i_rdata), .i_rresp(m_axi_i_rresp), .i_rvalid(m_axi_i_rvalid), .i_rready(m_axi_i_rready),
      .d_awaddr(m_axi_d_awaddr), .d_awprot(m_axi_d_awprot), .d_awvalid(m_axi_d_awvalid), .d_awready(m_axi_d_awready),
      .d_wdata(m_axi_d_wdata), .d_wstrb(m_axi_d_wstrb), .d_wvalid(m_axi_d_wvalid), .d_wready(m_axi_d_wready),
      .d_bresp(m_axi_d_bresp), .d_bvalid(m_axi_d_bvalid), .d_bready(m_axi_d_bready),
      .d_araddr(m_axi_d_araddr), .d_arprot(m_axi_d_arprot), .d_arvalid(m_axi_d_arvalid), .d_arready(m_axi_d_arready),
      .d_rdata(m_axi_d_rdata), .d_rresp(m_axi_d_rresp), .d_rvalid(m_axi_d_rvalid), .d_rready(m_axi_d_rready),
      .irq(irq), .nmi(nmi), .rxev(rxev), .txev(txev),
      .dbg_halt_on_bkpt(dbg_halt_on_bkpt), .halted(halted), .lockup(lockup), .sleeping(sleeping),
      .sysresetreq(sysresetreq),
      .trc_valid(trc_valid), .trc_pc(trc_pc), .trc_insn(trc_insn), .trc_skip(trc_skip),
      .trc_rf_we(trc_rf_we), .trc_rf_wa(trc_rf_wa), .trc_rf_wd(trc_rf_wd),
      .trc_fp_we(trc_fp_we), .trc_fp_wa(trc_fp_wa), .trc_fp_wd(trc_fp_wd),
      .trc_xpsr(trc_xpsr), .trc_fpscr(trc_fpscr), .trc_control(trc_control), .perf_ev(perf_ev));

endmodule

`default_nettype wire
