/*
 * ocm4_soc - OpenCM4F system for the Tang Nano 20K with the 480x272 LCD and a rotary encoder
 * SPDX-License-Identifier: MIT
 *
 *   OpenCM4F (Cortex-M4F compatible, AXI4-Lite)
 *     M_AXI_I --------------------------> code ROM port A (instruction fetch)
 *     M_AXI_D --+-- 0x0000_0000 code ROM port B: 32 KB, vectors, code, constants (read only)
 *               +-- 0x2000_0000 data RAM: 24 KB, data, bss, stack (byte writes)
 *               +-- 0x4000_0000 display list  2 banks x 256 commands x 16 bytes (write only)
 *               +-- 0x4001_0000 gdata         2 banks x 4 KB (write only)
 *               +-- 0x4002_0000 I/O           frame, buttons, encoder, bank, colour, IRQ, palette
 *               +-- 0x4003_0000 PERF          clock counters by class (what the CPU does or waits for)
 *   gpu (display-list renderer, from Sat Signal Lab) -> LCD;  encoder (quadrature, push button)
 *   IRQ 0: frame start (when enabled in I/O IRQ)
 *
 * All slaves answer one clock after the address handshake, so responses come back in order.
 * Two clocks from the same PLL: clk (CPU, memories, I/O: 27 MHz) and clk_pix (renderer, LCD: 54 MHz,
 * twice clk, rising edges aligned). The display list and gdata are written on clk and read on clk_pix
 * (dual-clock block RAMs); the few other signals that cross pass two-flop synchronisers.
 */

`default_nettype none

module ocm4_soc #(
    parameter ROM_WORDS = 8192,           // 32 KB  (ROW below: address bits)
    parameter RAM_WORDS = 6144,           // 24 KB  (RAW below)
    parameter CLK_HZ    = 27000000      // clk (the CPU clock); clk_pix is 2 x clk
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clk_pix,
    input  wire        rst_pix_n,
    input  wire [1:0]  buttons,           // synchronised, 1 = pressed: [0] S1, [1] S2
    input  wire        enc_clk,           // rotary encoder pins (raw, active low)
    input  wire        enc_dt,
    input  wire        enc_sw,
    output wire        lcd_clk,
    output wire        lcd_de,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire [15:0] lcd_rgb,
    output wire        lockup,
    output wire        halted
);

  // =====================================================================================
  // CPU
  // =====================================================================================
  wire [31:0] i_araddr, i_rdata;
  wire [2:0]  i_arprot;
  wire        i_arvalid, i_arready, i_rvalid, i_rready;
  wire [1:0]  i_rresp;
  wire [31:0] d_awaddr, d_wdata, d_araddr, d_rdata;
  wire [2:0]  d_awprot, d_arprot;
  wire        d_awvalid, d_awready, d_wvalid, d_wready, d_bvalid, d_bready, d_arvalid, d_arready, d_rvalid, d_rready;
  wire [3:0]  d_wstrb;
  wire [1:0]  d_bresp, d_rresp;
  wire [0:0]  irq;
  wire [6:0]  perf_ev;

  opencm4f #(.NUM_IRQ(1), .PRIO_BITS(3)) u_cpu (
      .clk(clk), .rst_n(rst_n),
      .m_axi_i_araddr(i_araddr), .m_axi_i_arprot(i_arprot), .m_axi_i_arvalid(i_arvalid), .m_axi_i_arready(i_arready),
      .m_axi_i_rdata(i_rdata), .m_axi_i_rresp(i_rresp), .m_axi_i_rvalid(i_rvalid), .m_axi_i_rready(i_rready),
      .m_axi_d_awaddr(d_awaddr), .m_axi_d_awprot(d_awprot), .m_axi_d_awvalid(d_awvalid), .m_axi_d_awready(d_awready),
      .m_axi_d_wdata(d_wdata), .m_axi_d_wstrb(d_wstrb), .m_axi_d_wvalid(d_wvalid), .m_axi_d_wready(d_wready),
      .m_axi_d_bresp(d_bresp), .m_axi_d_bvalid(d_bvalid), .m_axi_d_bready(d_bready),
      .m_axi_d_araddr(d_araddr), .m_axi_d_arprot(d_arprot), .m_axi_d_arvalid(d_arvalid), .m_axi_d_arready(d_arready),
      .m_axi_d_rdata(d_rdata), .m_axi_d_rresp(d_rresp), .m_axi_d_rvalid(d_rvalid), .m_axi_d_rready(d_rready),
      .irq(irq), .nmi(1'b0), .rxev(1'b0), .txev(),
      .dbg_halt_on_bkpt(1'b0), .halted(halted), .lockup(lockup), .sleeping(), .sysresetreq(),
      .trc_valid(), .trc_pc(), .trc_insn(), .trc_skip(), .trc_rf_we(), .trc_rf_wa(), .trc_rf_wd(),
      .trc_fp_we(), .trc_fp_wa(), .trc_fp_wd(), .trc_xpsr(), .trc_fpscr(), .trc_control(), .perf_ev(perf_ev));

  // =====================================================================================
  // code ROM (two read ports: A = instruction fetch, B = data side) and data RAM (byte lanes)
  // =====================================================================================
  localparam ROW = 13;                     // address bits: 8192 words (ROM), 6144 words (RAM)
  localparam RAW = 13;
  reg [31:0] rom [0:ROM_WORDS-1];
  (* no_rw_check *) reg [7:0]  ram0 [0:RAM_WORDS-1];   // a clock reads or writes, never both
  (* no_rw_check *) reg [7:0]  ram1 [0:RAM_WORDS-1];
  (* no_rw_check *) reg [7:0]  ram2 [0:RAM_WORDS-1];
  (* no_rw_check *) reg [7:0]  ram3 [0:RAM_WORDS-1];
  initial begin
`include "init_rom.vh"                    // the firmware (tools/gen_init.py from fw/firmware.bin)
  end

  // ---- instruction port: AXI4-Lite read slave, one clock latency, back to back ----
  reg         ia_v;
  reg         ia_err;
  reg  [31:0] qa;
  assign i_arready = !ia_v || i_rready;
  wire   ia_fire   = i_arvalid && i_arready;
  wire [ROW-1:0] aa = i_araddr[ROW+1:2];
  always @(posedge clk) begin
    if (ia_fire) qa <= rom[aa];
  end
  always @(posedge clk) begin
    if (!rst_n) begin
      ia_v <= 1'b0; ia_err <= 1'b0;
    end else begin
      if (ia_fire) begin ia_v <= 1'b1; ia_err <= (i_araddr[31:2] >= ROM_WORDS); end
      else if (i_rready) ia_v <= 1'b0;
    end
  end
  assign i_rvalid = ia_v;
  assign i_rdata  = qa;
  assign i_rresp  = ia_err ? 2'b10 : 2'b00;

  // =====================================================================================
  // data bus: decode, ROM port B, RAM, peripherals
  // =====================================================================================
  reg         dr_v, db_v;
  reg  [1:0]  dr_resp, db_resp;
  reg  [2:0]  dr_sel;              // 0 ROM, 1 RAM, 2 I/O, 3 PERF, 4 zero
  wire        w_both  = d_awvalid && d_wvalid;
  assign d_awready = w_both && (!db_v || d_bready);
  assign d_wready  = d_awready;
  wire        w_fire  = d_awready;
  assign d_arready = !w_both && (!dr_v || d_rready);
  wire        r_fire  = d_arvalid && d_arready;

  // regions: 0 ROM, 2 RAM, 4 DL, 5 GD, 6 I/O, 7 PERF, 1 error
  function [2:0] region(input [31:0] a);
    if (a[31:28] == 4'h0 && a[27:2] < ROM_WORDS) region = 3'd0;
    else if (a[31:28] == 4'h2 && a[27:2] < RAM_WORDS) region = 3'd2;
    else if (a[31:20] == 12'h400 && a[19:18] == 2'b00) region = {1'b1, a[17:16]};
    else region = 3'd1;
  endfunction
  wire [2:0] rreg = region(d_araddr);
  wire [2:0] wreg = region(d_awaddr);

  // ROM port B (reads only)
  reg  [31:0] qrom;
  wire [ROW-1:0] ab = d_araddr[ROW+1:2];
  always @(posedge clk) if (r_fire) qrom <= rom[ab];

  // RAM (single port)
  wire [RAW-1:0] ra = w_fire ? d_awaddr[RAW+1:2] : d_araddr[RAW+1:2];
  wire           rw = w_fire && wreg == 3'd2;
  reg  [31:0]    qram;
  always @(posedge clk) begin
    if (rw && d_wstrb[0]) ram0[ra] <= d_wdata[7:0];
    if (rw && d_wstrb[1]) ram1[ra] <= d_wdata[15:8];
    if (rw && d_wstrb[2]) ram2[ra] <= d_wdata[23:16];
    if (rw && d_wstrb[3]) ram3[ra] <= d_wdata[31:24];
    if (r_fire) qram <= {ram3[ra], ram2[ra], ram1[ra], ram0[ra]};
  end

  // ---- display list: 4 word lanes of 512 x 32 ({bank, command}) ----
  wire [8:0]   dl_addr;
  // the renderer reads one bank while the CPU writes the other: no read-during-write logic
  (* no_rw_check *) reg  [31:0]  dl0 [0:511];
  (* no_rw_check *) reg  [31:0]  dl1 [0:511];
  (* no_rw_check *) reg  [31:0]  dl2 [0:511];
  (* no_rw_check *) reg  [31:0]  dl3 [0:511];
  reg  [127:0] dl_q;
  wire [8:0]   dl_wa = d_awaddr[12:4];
  wire         dl_we = w_fire && wreg == 3'd4;
  always @(posedge clk_pix) dl_q <= {dl3[dl_addr], dl2[dl_addr], dl1[dl_addr], dl0[dl_addr]};
  always @(posedge clk) begin
    if (dl_we && d_awaddr[3:2] == 2'd0) dl0[dl_wa] <= d_wdata;
    if (dl_we && d_awaddr[3:2] == 2'd1) dl1[dl_wa] <= d_wdata;
    if (dl_we && d_awaddr[3:2] == 2'd2) dl2[dl_wa] <= d_wdata;
    if (dl_we && d_awaddr[3:2] == 2'd3) dl3[dl_wa] <= d_wdata;
  end

  // ---- gdata: 2048 x 32 ({bank, word}) ----
  wire [10:0] gd_addr;
  (* no_rw_check *) reg  [31:0] gd [0:2047];
  reg  [31:0] gd_q;
  wire        gd_we = w_fire && wreg == 3'd5;
  always @(posedge clk_pix) gd_q <= gd[gd_addr];
  always @(posedge clk) begin
    if (gd_we) gd[d_awaddr[12:2]] <= d_wdata;
  end

  // ---- I/O registers ----
  wire [31:0] frame_cnt;
  wire [15:0] stat_max, stat_over;
  wire [15:0] enc_count;
  wire        enc_pressed;
  wire [1:0]  enc_ab;
  reg         bank_sel;
  reg  [15:0] bg;
  reg         irq_en, frame_flag;
  // renderer -> CPU: the frame toggle and the line statistics, synchronised
  reg  [2:0]  f0_s;                  // frame_cnt[0] through two flops, and its last value
  reg  [31:0] frames;                // frames counted in the CPU clock domain
  reg  [31:0] stat_s1, stat_s2;
  wire        frame_tick = f0_s[2] != f0_s[1];
  wire        io_we  = w_fire && wreg == 3'd6;
  reg  [31:0] io_q;
  always @(posedge clk) begin
    f0_s <= {f0_s[1:0], frame_cnt[0]};
    stat_s1 <= {stat_over, stat_max};
    stat_s2 <= stat_s1;
    if (frame_tick) begin                                    // the renderer started a frame
      frame_flag <= 1'b1;
      frames <= frames + 32'd1;
    end
    if (r_fire) begin
      case (d_araddr[5:2])
        4'd0: io_q <= frames;
        4'd1: io_q <= {30'd0, buttons};
        4'd4: io_q <= stat_s2;
        4'd6: io_q <= {13'd0, enc_ab, enc_pressed, enc_count};
        4'd7: io_q <= {23'd0, frame_flag, 7'd0, irq_en};
        4'd8: io_q <= CLK_HZ;
        4'd9: io_q <= {ROM_WORDS[13:0], 2'b00, RAM_WORDS[13:0], 2'b00};
        default: io_q <= 32'd0;
      endcase
    end
    if (io_we && !d_awaddr[7]) begin
      case (d_awaddr[5:2])
        4'd2: bank_sel <= d_wdata[0];
        4'd3: bg <= d_wdata[15:0];
        4'd7: begin irq_en <= d_wdata[0]; if (d_wdata[8]) frame_flag <= 1'b0; end
        default: ;
      endcase
    end
    if (!rst_n) begin
      bank_sel <= 1'b0; bg <= 16'd0; irq_en <= 1'b0; frame_flag <= 1'b0; frames <= 32'd0;
    end
  end
  assign irq = irq_en & frame_flag;

  // ---- performance counters: every clock belongs to exactly one class (what the core does) ----
  //   0x00 CTRL (rw: [0] run)
  //   0x40 + 4 k: clocks of class k (32 bits, wrap; software subtracts two readings)
  //     0 other (multi-cycle ALU steps, reset, halt)  1 retire  2 bubble (execute stage empty: fetch,
  //     branches)  3 load / store wait  4 mul / div  5 FPU  6 exception entry / return  7 sleep
  //   The counters live in LUT RAM (one increment per clock, at the class of that clock). Stop them
  //   (CTRL = 0) before reading: while they run, the RAM read port belongs to the increment.
  reg         pf_run;
  reg  [2:0]  pf_cls;
  always @* begin
    casez (perf_ev)
      7'b??????1: pf_cls = 3'd1;
      7'b?????10: pf_cls = 3'd2;
      7'b????100: pf_cls = 3'd3;
      7'b???1000: pf_cls = 3'd4;
      7'b??10000: pf_cls = 3'd5;
      7'b?100000: pf_cls = 3'd6;
      7'b1000000: pf_cls = 3'd7;
      default:    pf_cls = 3'd0;
    endcase
  end
  reg  [31:0] pf_m [0:7];
  integer pi;
  initial for (pi = 0; pi < 8; pi = pi + 1) pf_m[pi] = 32'd0;
  reg  [2:0]  pf_ra;                 // counter the last bus read asked for (read in the response clock)
  reg         pf_rc;                 // ... or CTRL
  wire [31:0] pf_rd = pf_m[pf_run ? pf_cls : pf_ra];
  always @(posedge clk) begin
    if (pf_run) pf_m[pf_cls] <= pf_rd + 32'd1;
  end
  wire        pf_we = w_fire && wreg == 3'd7;
  always @(posedge clk) begin
    if (pf_we && !d_awaddr[6]) pf_run <= d_wdata[0];
    if (r_fire) begin pf_ra <= d_araddr[4:2]; pf_rc <= !d_araddr[6]; end
    if (!rst_n) pf_run <= 1'b0;
  end
  wire [31:0] pf_q = pf_rc ? {31'd0, pf_run} : pf_rd;

  // ---- responses ----
  always @(posedge clk) begin
    if (!rst_n) begin
      dr_v <= 1'b0; db_v <= 1'b0; dr_resp <= 2'b00; db_resp <= 2'b00; dr_sel <= 3'd0;
    end else begin
      if (r_fire) begin
        dr_v <= 1'b1;
        dr_resp <= (rreg == 3'd1) ? 2'b11 : 2'b00;
        dr_sel <= (rreg == 3'd0) ? 3'd0 : (rreg == 3'd2) ? 3'd1 : (rreg == 3'd6) ? 3'd2 : (rreg == 3'd7) ? 3'd3 : 3'd4;
      end else if (d_rready) dr_v <= 1'b0;
      if (w_fire) begin
        db_v <= 1'b1;
        db_resp <= (wreg == 3'd1 || wreg == 3'd0) ? 2'b10 : 2'b00;      // writes to the ROM: SLVERR
      end else if (d_bready) db_v <= 1'b0;
    end
  end
  assign d_rvalid = dr_v;
  assign d_rresp  = dr_resp;
  assign d_rdata  = (dr_sel == 3'd0) ? qrom : (dr_sel == 3'd1) ? qram : (dr_sel == 3'd2) ? io_q :
                    (dr_sel == 3'd3) ? pf_q : 32'd0;
  assign d_bvalid = db_v;
  assign d_bresp  = db_resp;

  // =====================================================================================
  // renderer, encoder
  // =====================================================================================
  // CPU -> renderer: bank and background colour, synchronised (the renderer takes the bank at a frame start)
  reg  [16:0] pix_s1, pix_s2;
  always @(posedge clk_pix) begin
    pix_s1 <= {bank_sel, bg};
    pix_s2 <= pix_s1;
  end
  gpu #(.IMAGE(0)) u_gpu (
      .clk(clk_pix), .rst_n(rst_pix_n),
      .dl_addr(dl_addr), .dl_data(dl_q), .gd_addr(gd_addr), .gd_data(gd_q),
      .im_addr(), .im_busy(), .im_data(32'd0), .pal_we(1'b0), .pal_wa(5'd0), .pal_wd(16'd0),
      .bank_sel(pix_s2[16]), .bg(pix_s2[15:0]), .frame_cnt(frame_cnt), .stat_max(stat_max), .stat_over(stat_over),
      .lcd_clk(lcd_clk), .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_rgb(lcd_rgb));

  encoder #(.FILT(CLK_HZ / 500000), .DEB(CLK_HZ / 200)) u_enc (
      .clk(clk), .rst_n(rst_n), .pin_clk(enc_clk), .pin_dt(enc_dt), .pin_sw(enc_sw),
      .count(enc_count), .pressed(enc_pressed), .ab(enc_ab));

endmodule

`default_nettype wire
