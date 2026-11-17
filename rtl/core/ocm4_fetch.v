/*
 * ocm4_fetch - instruction fetch: AXI4-Lite read master (word fetches) and an instruction queue of
 * eight halfwords (circular buffer) that feeds the decoder.
 * SPDX-License-Identifier: MIT
 *
 *  - up to two read transactions in flight; the slave must answer in order (AXI4-Lite has no IDs)
 *  - a redirect (taken branch, exception) flushes the queue; responses of reads issued before it are
 *    dropped. The address of the redirect goes out in the same clock unless an earlier AR is still
 *    waiting for ARREADY (AXI: a presented address must stay until it is accepted)
 *  - a target on an odd halfword drops the first halfword of its word
 *  - RRESP != OKAY marks the halfwords as faulty; executing them gives a BusFault (IBUSERR)
 */

`default_nettype none

module ocm4_fetch (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite instruction bus (read only)
    output wire [31:0] araddr,
    output wire [2:0]  arprot,
    output wire        arvalid,
    input  wire        arready,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rvalid,
    output wire        rready,

    input  wire        priv,          // privileged (ARPROT[0])
    input  wire        enable,        // 0 while the core is in reset or locked up: no new fetches

    input  wire        redir,         // flush and fetch from redir_pc
    input  wire [31:0] redir_pc,

    // to the decoder: the first two halfwords of the queue
    output wire [15:0] hw0,
    output wire [15:0] hw1,
    output wire        v0,
    output wire        v1,
    output wire        e0,            // bus error on this halfword
    output wire        e1,
    output reg  [31:0] pc0,           // address of hw0
    input  wire [1:0]  consume        // halfwords taken by the decoder this clock (0, 1, 2)
);

  reg  [15:0] q [0:7];
  reg  [7:0]  qerr;
  reg  [3:0]  rp, wp;           // halfword pointers (one wrap bit)
  reg  [31:0] fa;               // next word address to fetch
  reg  [1:0]  infl;             // reads accepted, response not yet seen
  reg  [1:0]  disc;             // responses still to drop
  reg         skip;             // drop the first halfword of the next kept response
  reg         ar_pend;          // an AR is presented and waiting for ARREADY
  reg  [31:0] ar_pend_addr;

  assign rready = 1'b1;
  assign arprot = {1'b1, 1'b0, priv};          // instruction, secure, privilege

  wire       r_fire = rvalid;
  wire       r_keep = r_fire && (disc == 2'd0);
  wire [3:0] qcnt   = wp - rp;

  // halfwords that kept responses will still bring (two each at most)
  wire [2:0] kept_infl = {1'b0, infl} + {2'b0, ar_pend} - {1'b0, disc};
  wire [4:0] room_need = {1'b0, qcnt} + {1'b0, kept_infl, 1'b0} + 5'd2;
  wire       want = enable && !ar_pend && (room_need <= 5'd8) && ({1'b0, infl} + {2'b0, ar_pend} < 3'd2);
  wire       want_redir = enable && !ar_pend && ((infl - (r_fire ? 2'd1 : 2'd0)) < 2'd2);
  wire       issue = redir ? want_redir : want;

  assign arvalid = ar_pend | issue;
  assign araddr  = ar_pend ? ar_pend_addr : (redir ? {redir_pc[31:2], 2'b00} : fa);
  wire   ar_fire = arvalid && arready;

  wire [2:0] r0 = rp[2:0];
  wire [2:0] r1 = rp[2:0] + 3'd1;
  assign hw0 = q[r0];
  assign hw1 = q[r1];
  assign v0  = qcnt >= 4'd1;
  assign v1  = qcnt >= 4'd2;
  assign e0  = qerr[r0];
  assign e1  = qerr[r1];

  wire [2:0] w0 = wp[2:0];
  wire [2:0] w1 = wp[2:0] + 3'd1;

  always @(posedge clk) begin
    if (r_keep && !redir) begin
      if (skip) begin
        q[w0] <= rdata[31:16]; qerr[w0] <= rresp[1];
      end else begin
        q[w0] <= rdata[15:0];  qerr[w0] <= rresp[1];
        q[w1] <= rdata[31:16]; qerr[w1] <= rresp[1];
      end
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      rp      <= 4'd0;
      wp      <= 4'd0;
      fa      <= 32'd0;
      pc0     <= 32'd0;
      infl    <= 2'd0;
      disc    <= 2'd0;
      skip    <= 1'b0;
      ar_pend <= 1'b0;
      ar_pend_addr <= 32'd0;
    end else begin
      infl <= infl + (ar_fire ? 2'd1 : 2'd0) - (r_fire ? 2'd1 : 2'd0);
      if (arvalid && !arready && !ar_pend) begin
        ar_pend      <= 1'b1;
        ar_pend_addr <= araddr;
      end else if (ar_fire) begin
        ar_pend <= 1'b0;
      end
      if (redir) begin
        rp   <= 4'd0;
        wp   <= 4'd0;
        pc0  <= {redir_pc[31:1], 1'b0};
        skip <= redir_pc[1];
        // everything in flight now (and a held AR) belongs to the old path
        disc <= infl - (r_fire ? 2'd1 : 2'd0) + (ar_pend ? 2'd1 : 2'd0);
        fa   <= {redir_pc[31:2], 2'b00} + (issue ? 32'd4 : 32'd0);
      end else begin
        rp   <= rp + {2'd0, consume};
        pc0  <= pc0 + {29'd0, consume, 1'b0};
        if (r_keep) wp <= wp + (skip ? 4'd1 : 4'd2);
        if (r_fire && disc != 2'd0) disc <= disc - 2'd1;
        if (r_keep) skip <= 1'b0;
        if (issue) fa <= fa + 32'd4;
      end
    end
  end

endmodule

`default_nettype wire
