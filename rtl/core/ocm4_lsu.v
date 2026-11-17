/*
 * ocm4_lsu - load / store unit: data-side AXI4-Lite master and the path to the System Control Space
 * SPDX-License-Identifier: MIT
 *
 *  - one request per clock from the execute stage (req held until ack): byte, halfword or word, any
 *    alignment; an access that crosses a word boundary becomes two bus transactions (unaligned LDR,
 *    LDRH, STR, STRH as the Cortex-M4 allows them)
 *  - reads: up to two in flight, answered in order (rvalid, rdata aligned and extended, rerr)
 *  - writes are posted: ack when AW and W are accepted; B responses are counted, an error response
 *    gives werr (imprecise BusFault). A read waits until no write is outstanding (read after write
 *    ordering on any interconnect)
 *  - 0xE000_0000 .. 0xE00F_FFFF (PPB) goes to the SCS registers, not to the bus
 */

`default_nettype none

module ocm4_lsu (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req,
    input  wire        wr,
    input  wire [31:0] addr,
    input  wire [1:0]  size,         // 0 byte, 1 halfword, 2 word
    input  wire        sign,
    input  wire [31:0] wdata,
    input  wire        priv,
    output wire        ack,
    output wire        rvalid,
    output wire [31:0] rdata,
    output wire        rerr,
    output reg         werr,
    output wire        idle,         // nothing outstanding (DSB, DMB, exception entry)

    // AXI4-Lite data bus
    output wire [31:0] m_awaddr,
    output wire [2:0]  m_awprot,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [31:0] m_araddr,
    output wire [2:0]  m_arprot,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready,

    // System Control Space
    output wire        scs_acc,
    output wire        scs_wr,
    output wire [19:0] scs_addr,
    output wire [31:0] scs_wdata,
    output wire [3:0]  scs_wstrb,
    output wire        scs_priv,
    input  wire [31:0] scs_rdata,
    input  wire        scs_err
);

  // ---------------- request decode ----------------
  wire        ppb    = (addr[31:20] == 12'hE00);
  wire [1:0]  off    = addr[1:0];
  wire [7:0]  bmask  = (size == 2'd0) ? 8'h01 : (size == 2'd1) ? 8'h03 : 8'h0F;
  wire [7:0]  st8    = bmask << off;
  wire [63:0] wd64   = {32'd0, wdata} << {off, 3'b000};
  wire        split  = (st8[7:4] != 4'd0) && !ppb;
  wire [31:0] a_lo   = {addr[31:2], 2'b00};
  wire [31:0] a_hi   = a_lo + 32'd4;

  // ---------------- state ----------------
  reg         part2;            // second half of a split access is next
  reg  [1:0]  rcnt;             // AXI reads in flight
  reg  [1:0]  wcnt;             // writes waiting for B
  reg         aw_done, w_done;  // this beat: AW / W already accepted
  reg         scs_pend;         // an SCS read answers next clock
  // per in-flight read: size, sign, offset, split part (1 = first half of a split, 2 = second)
  reg  [5:0]  rq0, rq1;         // {sign, size[1:0], off[1:0], ...} FIFO of 2
  reg  [1:0]  rqp0, rqp1;
  reg  [31:0] lo_word;          // first word of a split read

  wire        cur_hi   = part2;
  wire [31:0] cur_addr = cur_hi ? a_hi : a_lo;
  wire [3:0]  cur_strb = cur_hi ? st8[7:4] : st8[3:0];
  wire [31:0] cur_wd   = cur_hi ? wd64[63:32] : wd64[31:0];

  // ---------------- reads ----------------
  wire rd_req   = req && !wr;
  wire rd_axi_ok = rd_req && !ppb && (wcnt == 2'd0) && !werr_hold && (rcnt < 2'd2) && !scs_pend;
  assign m_arvalid = rd_axi_ok;
  assign m_araddr  = cur_addr;
  assign m_arprot  = {1'b0, 1'b0, priv};
  wire ar_fire = m_arvalid && m_arready;
  wire rd_scs  = rd_req && ppb && (rcnt == 2'd0) && (wcnt == 2'd0) && !scs_pend;

  // ---------------- writes ----------------
  wire wr_req  = req && wr;
  wire wr_axi  = wr_req && !ppb && (wcnt < 2'd2);
  assign m_awvalid = wr_axi && !aw_done;
  assign m_wvalid  = wr_axi && !w_done;
  assign m_awaddr  = cur_addr;
  assign m_awprot  = {1'b0, 1'b0, priv};
  assign m_wdata   = cur_wd;
  assign m_wstrb   = cur_strb;
  assign m_bready  = 1'b1;
  wire aw_ok = aw_done || (m_awvalid && m_awready);
  wire w_ok  = w_done || (m_wvalid && m_wready);
  wire wbeat = wr_axi && aw_ok && w_ok;               // this write beat is complete
  wire wr_scs = wr_req && ppb && (rcnt == 2'd0) && !scs_pend;
  reg  werr_hold;

  // ---------------- acknowledge ----------------
  wire beat = ar_fire || wbeat;                       // one AXI beat of the request done
  assign ack = (beat && (!split || part2)) || rd_scs || wr_scs;

  // ---------------- SCS ----------------
  assign scs_acc   = rd_scs || wr_scs;
  assign scs_wr    = wr_scs;
  assign scs_addr  = {addr[19:2], 2'b00};
  assign scs_wdata = wd64[31:0];
  assign scs_wstrb = st8[3:0];
  assign scs_priv  = priv;
  reg [5:0] scs_info;

  // ---------------- read responses ----------------
  wire        r_fire = m_rvalid;
  assign m_rready = 1'b1;
  wire [5:0]  hinfo = rq0;                            // oldest in flight
  wire [1:0]  hpart = rqp0;
  wire [5:0]  info  = scs_pend ? scs_info : hinfo;
  wire [31:0] word  = scs_pend ? scs_rdata : m_rdata;
  wire [63:0] both  = (hpart == 2'd2) ? {m_rdata, lo_word} : {32'd0, word};
  wire [63:0] sh    = both >> {info[1:0], 3'b000};
  wire [1:0]  isz   = info[3:2];
  wire        isg   = info[4];
  assign rdata  = (isz == 2'd0) ? {{24{isg & sh[7]}}, sh[7:0]} :
                  (isz == 2'd1) ? {{16{isg & sh[15]}}, sh[15:0]} : sh[31:0];
  assign rvalid = scs_pend || (r_fire && hpart != 2'd1);
  reg         err_lo;                                 // error on the first half of a split read
  assign rerr   = scs_pend ? scs_err : (m_rresp[1] || (hpart == 2'd2 && err_lo));

  assign idle = (rcnt == 2'd0) && (wcnt == 2'd0) && !scs_pend && !(m_bvalid && wcnt != 2'd0);

  always @(posedge clk) begin
    werr <= 1'b0;
    if (!rst_n) begin
      part2 <= 1'b0; rcnt <= 2'd0; wcnt <= 2'd0; aw_done <= 1'b0; w_done <= 1'b0;
      scs_pend <= 1'b0; rq0 <= 6'd0; rq1 <= 6'd0; rqp0 <= 2'd0; rqp1 <= 2'd0; err_lo <= 1'b0;
      werr_hold <= 1'b0; scs_info <= 6'd0; lo_word <= 32'd0;
    end else begin
      // split sequencing
      if (beat && split && !part2) part2 <= 1'b1;
      else if (beat && part2) part2 <= 1'b0;
      // write beat bookkeeping
      if (wr_axi) begin
        if (wbeat) begin aw_done <= 1'b0; w_done <= 1'b0; end
        else begin
          if (m_awvalid && m_awready) aw_done <= 1'b1;
          if (m_wvalid && m_wready) w_done <= 1'b1;
        end
      end
      wcnt <= wcnt + (wbeat ? 2'd1 : 2'd0) - ((m_bvalid && wcnt != 2'd0) ? 2'd1 : 2'd0);
      if (m_bvalid && wcnt != 2'd0 && m_bresp[1]) werr <= 1'b1;
      werr_hold <= 1'b0;
      // SCS
      scs_pend <= rd_scs;
      if (rd_scs) scs_info <= {1'b0, sign, size, off};
      if (wr_scs && scs_err) werr <= 1'b1;
      // read FIFO
      rcnt <= rcnt + (ar_fire ? 2'd1 : 2'd0) - (r_fire ? 2'd1 : 2'd0);
      if (r_fire) begin
        if (hpart == 2'd1) begin lo_word <= m_rdata; err_lo <= m_rresp[1]; end
        rq0 <= rq1; rqp0 <= rqp1;
      end
      if (ar_fire) begin
        if ((rcnt == 2'd0) || (rcnt == 2'd1 && r_fire)) begin
          rq0 <= {1'b0, sign, size, off}; rqp0 <= split ? (part2 ? 2'd2 : 2'd1) : 2'd0;
        end else begin
          rq1 <= {1'b0, sign, size, off}; rqp1 <= split ? (part2 ? 2'd2 : 2'd1) : 2'd0;
        end
      end
    end
  end

endmodule

`default_nettype wire
