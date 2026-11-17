/*
 * tb_core - testbench top for OpenCM4F: the core and the AXI4-Lite test memory (axil_mem)
 * Clock, reset, stall rate and seed come from cocotb.
 * SPDX-License-Identifier: MIT
 */
`timescale 1ns/1ps
`default_nettype none

module tb_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  stall,
    input  wire [31:0] seed,
    input  wire        halt_on_bkpt,
    input  wire        ext_irq_en
);
  wire [31:0] i_araddr, i_rdata, d_awaddr, d_wdata, d_araddr, d_rdata;
  wire [2:0]  i_arprot, d_awprot, d_arprot;
  wire        i_arvalid, i_arready, i_rvalid, i_rready;
  wire [1:0]  i_rresp, d_bresp, d_rresp;
  wire        d_awvalid, d_awready, d_wvalid, d_wready, d_bvalid, d_bready, d_arvalid, d_arready, d_rvalid, d_rready;
  wire [3:0]  d_wstrb;
  wire [31:0] tohost, irq_lines;
  wire        tohost_we, putc_we, nmi_line;
  wire [7:0]  putc_char;

  wire        halted, lockup, sleeping, sysresetreq, txev;
  wire        trc_valid, trc_skip, trc_rf_we, trc_fp_we;
  wire [31:0] trc_pc, trc_insn, trc_rf_wd, trc_fp_wd, trc_xpsr, trc_fpscr;
  wire [3:0]  trc_rf_wa;
  wire [4:0]  trc_fp_wa;
  wire [2:0]  trc_control;
  wire [6:0]  perf_ev;

  opencm4f #(.NUM_IRQ(16), .PRIO_BITS(3)) u_cpu (
      .clk(clk), .rst_n(rst_n),
      .m_axi_i_araddr(i_araddr), .m_axi_i_arprot(i_arprot), .m_axi_i_arvalid(i_arvalid), .m_axi_i_arready(i_arready),
      .m_axi_i_rdata(i_rdata), .m_axi_i_rresp(i_rresp), .m_axi_i_rvalid(i_rvalid), .m_axi_i_rready(i_rready),
      .m_axi_d_awaddr(d_awaddr), .m_axi_d_awprot(d_awprot), .m_axi_d_awvalid(d_awvalid), .m_axi_d_awready(d_awready),
      .m_axi_d_wdata(d_wdata), .m_axi_d_wstrb(d_wstrb), .m_axi_d_wvalid(d_wvalid), .m_axi_d_wready(d_wready),
      .m_axi_d_bresp(d_bresp), .m_axi_d_bvalid(d_bvalid), .m_axi_d_bready(d_bready),
      .m_axi_d_araddr(d_araddr), .m_axi_d_arprot(d_arprot), .m_axi_d_arvalid(d_arvalid), .m_axi_d_arready(d_arready),
      .m_axi_d_rdata(d_rdata), .m_axi_d_rresp(d_rresp), .m_axi_d_rvalid(d_rvalid), .m_axi_d_rready(d_rready),
      .irq(ext_irq_en ? irq_lines[15:0] : 16'd0), .nmi(nmi_line), .rxev(1'b0), .txev(txev),
      .dbg_halt_on_bkpt(halt_on_bkpt), .halted(halted), .lockup(lockup), .sleeping(sleeping),
      .sysresetreq(sysresetreq),
      .trc_valid(trc_valid), .trc_pc(trc_pc), .trc_insn(trc_insn), .trc_skip(trc_skip),
      .trc_rf_we(trc_rf_we), .trc_rf_wa(trc_rf_wa), .trc_rf_wd(trc_rf_wd),
      .trc_fp_we(trc_fp_we), .trc_fp_wa(trc_fp_wa), .trc_fp_wd(trc_fp_wd),
      .trc_xpsr(trc_xpsr), .trc_fpscr(trc_fpscr), .trc_control(trc_control), .perf_ev(perf_ev));

  axil_mem #(.WORDS(65536)) u_mem (
      .clk(clk), .rst_n(rst_n), .stall(stall), .seed(seed),
      .i_araddr(i_araddr), .i_arvalid(i_arvalid), .i_arready(i_arready), .i_rdata(i_rdata), .i_rresp(i_rresp),
      .i_rvalid(i_rvalid), .i_rready(i_rready),
      .d_awaddr(d_awaddr), .d_awvalid(d_awvalid), .d_awready(d_awready), .d_wdata(d_wdata), .d_wstrb(d_wstrb),
      .d_wvalid(d_wvalid), .d_wready(d_wready), .d_bresp(d_bresp), .d_bvalid(d_bvalid), .d_bready(d_bready),
      .d_araddr(d_araddr), .d_arvalid(d_arvalid), .d_arready(d_arready), .d_rdata(d_rdata), .d_rresp(d_rresp),
      .d_rvalid(d_rvalid), .d_rready(d_rready),
      .tohost(tohost), .tohost_we(tohost_we), .putc_char(putc_char), .putc_we(putc_we), .irq_lines(irq_lines),
      .nmi_line(nmi_line));
endmodule

`default_nettype wire
