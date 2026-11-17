/*
 * gpu - display-list scanline renderer and LCD timing (480 x 272, 9 MHz pixel clock from 54 MHz)
 * SPDX-License-Identifier: MIT
 *
 * While the LCD shows line v from one line buffer, the renderer draws line v+1 into the other:
 * it walks the command list of the current bank (fw/gpu.h) in order and blends every command
 * that covers the line, one pixel per clock. A displayed pixel is replaced by the background
 * colour as it is read, so every line starts empty. A line has 3120 clocks.
 *
 * Pixel paths (all end in the same blend stage, read-modify-write of the line buffer):
 *   SHAPE / ARC  x -> |dx| -> dx^2 -> (r+1)^2 - d^2 -> * 1/r -> alpha -> * opacity
 *   TEXT / ICON  glyph ROM (4 bits) -> alpha -> * opacity
 *   SPAN         gdata word {bottom, top} -> coverage of the pixel row -> * opacity
 *   IMAGE        image RAM word -> 4-bit index -> palette colour, opacity
 * Bit-exact with host/raster.c.
 */

`default_nettype none

module gpu #(
    parameter IMAGE = 1                 // 0: no IMAGE command (no image RAM attached)
) (
    input  wire         clk,
    input  wire         rst_n,

    output wire [8:0]   dl_addr,        // {bank, command}
    input  wire [127:0] dl_data,        // registered read, one clock
    output wire [10:0]  gd_addr,        // {bank, word}
    input  wire [31:0]  gd_data,        // registered read, one clock
    output wire [11:0]  im_addr,        // image RAM word
    output wire         im_busy,        // the renderer reads the image RAM this clock
    input  wire [31:0]  im_data,        // registered read, one clock
    input  wire         pal_we,         // palette write (CPU)
    input  wire [4:0]   pal_wa,
    input  wire [15:0]  pal_wd,

    input  wire         bank_sel,       // bank to use from the next frame on
    input  wire [15:0]  bg,
    output reg  [31:0]  frame_cnt,
    output reg  [15:0]  stat_max,       // most clocks a line needed
    output reg  [15:0]  stat_over,      // lines that did not finish in time

    output reg          lcd_clk,
    output reg          lcd_de,
    output reg          lcd_hs,
    output reg          lcd_vs,
    output reg  [15:0]  lcd_rgb
);

  // ================================================================
  // LCD timing: 520 x 300 pixel clocks, a pixel = 6 clocks
  // ================================================================
  reg [2:0] pe;
  reg [9:0] h, v;
  wire line_go = (pe == 3'd5) && (h == 10'd519);
  wire [9:0] vn = (v == 10'd299) ? 10'd0 : v + 10'd1;
  always @(posedge clk) begin
    if (!rst_n) begin
      pe <= 3'd0; h <= 10'd0; v <= 10'd0; lcd_clk <= 1'b0;
    end else begin
      pe <= (pe == 3'd5) ? 3'd0 : pe + 3'd1;
      if (pe == 3'd5) begin
        h <= (h == 10'd519) ? 10'd0 : h + 10'd1;
        if (h == 10'd519) v <= vn;
      end
      if (pe == 3'd5) lcd_clk <= 1'b1;
      if (pe == 3'd2) lcd_clk <= 1'b0;
    end
  end

  // ================================================================
  // line buffers
  // ================================================================
  wire        db = v[0];                       // displayed buffer
  (* no_rw_check *) reg  [15:0] lb0 [0:511];    // the blend stage forwards its own writes
  (* no_rw_check *) reg  [15:0] lb1 [0:511];
  reg  [15:0] lb0_q, lb1_q;
  wire [8:0]  disp_ra = h[8:0];
  wire        disp_we = (pe == 3'd3) && (h < 10'd480) && (v < 10'd272);
  // renderer side (signals below)
  wire [8:0]  rd_ra;
  reg         wr_we;
  reg  [8:0]  wr_wa;
  reg  [15:0] wr_wd;
  wire [8:0]  ra0 = db ? rd_ra : disp_ra;
  wire [8:0]  ra1 = db ? disp_ra : rd_ra;
  wire        we0 = db ? wr_we : disp_we;
  wire        we1 = db ? disp_we : wr_we;
  wire [8:0]  wa0 = db ? wr_wa : disp_ra;
  wire [8:0]  wa1 = db ? disp_ra : wr_wa;
  wire [15:0] wd0 = db ? wr_wd : bg;
  wire [15:0] wd1 = db ? bg : wr_wd;
  always @(posedge clk) begin
    lb0_q <= lb0[ra0];
    lb1_q <= lb1[ra1];
    if (we0) lb0[wa0] <= wd0;
    if (we1) lb1[wa1] <= wd1;
  end
  wire [15:0] disp_q = db ? lb1_q : lb0_q;
  wire [15:0] rend_q = db ? lb0_q : lb1_q;

  // pixel output: one pixel late, all signals delayed alike
  reg [15:0] pix_q;
  wire       de_now = (h < 10'd480) && (v < 10'd272);
  always @(posedge clk) begin
    if (pe == 3'd3) pix_q <= disp_q;           // address h has been stable since pe 0
    if (pe == 3'd5) begin                      // shown during the next pixel period
      lcd_rgb <= de_now ? pix_q : 16'd0;
      lcd_de  <= de_now;
      lcd_hs  <= !((h >= 10'd493) && (h <= 10'd496));
      lcd_vs  <= !((v >= 10'd281) && (v <= 10'd284));
    end
    if (!rst_n) begin
      lcd_de <= 1'b0; lcd_hs <= 1'b1; lcd_vs <= 1'b1;
    end
  end

  // ================================================================
  // ROMs
  // ================================================================
  reg [3:0]  font_s [0:17279];
  reg [3:0]  font_l [0:4031];          // 14 glyphs x 18 rows x 16 columns
  reg [3:0]  icons  [0:4031];
  reg [4:0]  widths [0:127];
  reg [15:0] rec    [0:255];
  initial begin
`include "init_font_s.vh"
`include "init_font_l.vh"
`include "init_icons.vh"
`include "init_widths.vh"
`include "init_rec.vh"
  end

  // ================================================================
  // renderer state
  // ================================================================
  // There is no drain between commands: the per-command values the pixel stages need (colour,
  // opacity, radii, curve tables) live in two slots, used in turn by consecutive commands, and
  // every pixel carries the number of its slot. A command waits in R_DEC only if its slot is still
  // used by pixels in flight (two commands back). The shape path is the longest, so a later command
  // never overtakes an earlier one, and the blend stage forwards the two writes in flight
  // (read-modify-write of the same pixel).
  localparam [3:0] R_IDLE = 4'd0, R_REFETCH = 4'd1, R_DEC = 4'd2, R_SET0 = 4'd3, R_SET1 = 4'd4, R_RUN = 4'd5,
                   R_TFETCH = 4'd6, R_TGET = 4'd7, R_TPIX = 4'd8, R_FLUSH = 4'd9;
  localparam integer FLUSH = 12;

  reg  [3:0]  st;
  reg         bank_l;
  reg  [8:0]  ry;                              // line being rendered
  reg  [7:0]  ci;                              // command index
  reg  [15:0] lclk;                            // clocks spent on this line
  reg  [3:0]  dcnt;

  assign dl_addr = {bank_l, (st == R_DEC) ? ci + 8'd1 : ci};

  // decoded command
  wire [3:0]  q_op = dl_data[31:28];
  wire [8:0]  q_y0 = dl_data[27:19], q_y1 = dl_data[18:10], q_x0 = dl_data[9:1];
  wire [8:0]  q_x1 = dl_data[63:55];
  wire [63:0] q_p  = dl_data[127:64];
  wire        q_active = (ry >= q_y0) && (ry <= q_y1);

  reg  [3:0]  op;
  reg  [8:0]  x0, x1, y0, y1;
  reg  [63:0] p;

  // per-command slots (see above)
  reg         cs;                              // slot of the command being set up / drawn
  reg  [15:0] col_s0, col_s1;
  reg  [8:0]  x0_s0, x0_s1;
  reg  [4:0]  opa_s0, opa_s1;
  reg  [16:0] dy2_s0, dy2_s1, ro2_s0, ro2_s1, ri2_s0, ri2_s1;
  reg  [15:0] rco_s0, rco_s1, rci_s0, rci_s1;  // curve tables: outer, inner edge
  wire [4:0]  opa_c = cs ? opa_s1 : opa_s0;

  // shape / arc parameters
  wire        is_arc = (op == 4'd2);
  wire [10:0] cx = p[10:0];
  wire [9:0]  cy = p[20:11];
  wire [9:0]  ex = is_arc ? 10'd0 : p[30:21];
  wire [9:0]  ey = is_arc ? 10'd0 : p[40:31];
  wire [7:0]  r  = is_arc ? {1'b0, p[27:21]} : p[48:41];
  wire [7:0]  t  = is_arc ? {1'b0, p[34:28]} : p[56:49];
  wire        big = p[35];
  wire signed [7:0] sxv = $signed(p[42:36]), syv = $signed(p[49:43]), exv = $signed(p[56:50]), eyv = $signed(p[63:57]);
  wire [7:0]  ri = r - t;

  // text / icon / span parameters
  wire [11:0] t_addr = p[11:0];
  wire [6:0]  t_len = p[18:12];
  wire        t_font = p[19];
  wire [3:0]  ic_idx = p[3:0];
  wire [9:0]  s_addr = p[9:0];
  wire        s_fill = p[10];
  // image parameters
  wire [11:0] i_base = p[11:0];
  wire [5:0]  i_stride = p[17:12];
  wire [7:0]  i_rows = p[25:18];
  wire [7:0]  i_r0 = p[33:26];
  wire        i_sx = p[34], i_sy = p[35], i_pal = p[36], i_transp = p[37];

  // per-line constants of the current command
  reg  [7:0]  dy;
  reg  [7:0]  rec_a0, rec_a1;
  reg  [15:0] rec_q0, rec_q1;
  always @(posedge clk) begin
    rec_q0 <= rec[rec_a0];
    rec_q1 <= rec[rec_a1];
  end
  reg signed [21:0] c1, c2;
  reg  [4:0]  row;

  wire [9:0]  py  = {ry, 1'b1};
  wire signed [11:0] dys = $signed({2'b00, py}) - $signed({2'b00, cy});
  wire [11:0] ady = dys[11] ? -dys : dys;
  wire signed [12:0] dye = $signed({1'b0, ady}) - $signed({3'b000, ey});
  wire signed [11:0] dxs0 = $signed({2'b00, x0, 1'b1}) - $signed({1'b0, cx});

  // run counters
  reg  [8:0]  xr;                              // pixel x
  reg  [6:0]  tk;                              // text: character index
  reg  [8:0]  txc;                             // text: x of the current character
  reg  [4:0]  tcol, tw;                        // column in glyph, glyph width
  reg  [6:0]  tg;                              // glyph index
  wire [11:0] tbyte = t_addr + {5'd0, tk};
  wire [9:0]  sj = s_addr + {1'b0, xr - x0};

  assign gd_addr = {bank_l, (op == 4'd5) ? sj : tbyte[11:2]};

  // image: row base address (per line), column of the current pixel
  wire [8:0]  dyr = ry - y0;
  reg  [8:0]  irow;
  reg  [11:0] im_rb;
  wire [8:0]  irow_w = (irow >= {1'b0, i_rows}) ? irow - {1'b0, i_rows} : irow;
  wire [8:0]  icol_x = xr - x0;
  wire [8:0]  icol_s = i_sx ? {1'b0, icol_x[8:1]} : icol_x;
  assign im_addr = im_rb + {6'd0, icol_s[8:3]};
  assign im_busy = (st == R_RUN) && (op == 4'd6);

  // ---------------- issue registers (stage 0) ----------------
  reg         s0_v;                            // shape pixel
  reg  [8:0]  s0_x;
  reg signed [21:0] s0_c1, s0_c2;
  reg         s0_t, s0_tag;
  reg         g0_v;                            // glyph / icon pixel
  reg         g0_f;                            // first pixel of a command (x = x0)
  reg  [1:0]  g0_sel;                          // 0 small font, 1 large font, 2 icon
  reg         g0_tag;
  reg         n0_v;                            // span pixel
  reg         n0_f;
  reg         n0_tag;
  reg         n0_fill;
  reg  [8:0]  n0_bot;
  reg         i0_v;                            // image pixel
  reg         i0_f;
  reg  [2:0]  i0_nib;
  reg         i0_tag;
  reg         i0_pal, i0_transp;
  // s0 reads the shape parameters of the command registers directly: they change at the earliest
  // two clocks after the last pixel was issued (R_REFETCH, R_DEC)
  wire [10:0] s0_cx = cx;
  wire [9:0]  s0_ex = ex;
  wire        s0_arc = is_arc, s0_big = big;

  // glyph ROM address (registered read -> data in the next clock)
  wire [10:0] gs_row = {tg[6:0], 4'd0} - {4'd0, tg[6:0]} + {6'd0, row};          // g * 15 + row
  wire [14:0] gs_x12 = {1'b0, gs_row, 3'd0} + {2'b0, gs_row, 2'd0};               // (g * 15 + row) * 12
  wire [9:0]  gl_row = {1'b0, tg[3:0], 4'd0} + {4'd0, tg[3:0], 1'b0} + {5'd0, row};   // g * 18 + row
  wire [8:0]  ic_row = {ic_idx, 4'd0} + {1'b0, ic_idx, 3'd0} + {4'd0, row};          // i * 24 + row
  wire [14:0] fs_a = gs_x12 + {11'd0, 4'd11 - tcol[3:0]};   // rows are stored mirrored (tools/gen_assets.py)
  wire [13:0] fl_a = {gl_row, ~tcol[3:0]};
  wire [13:0] ic_a = {ic_row, 4'd0} + {1'b0, ic_row, 3'd0} + {9'd0, tcol};
  reg  [3:0]  fs_q, fl_q, ic_q;
  always @(posedge clk) begin
    fs_q <= font_s[fs_a];
    fl_q <= font_l[fl_a];
    ic_q <= icons[ic_a];
  end

  // ---------------- shape pipeline S1..S6 ----------------
  reg         s1_v, s2_v, s3_v, s4_v, s5_v, s6_v;
  reg         s0_f, s1_f, s2_f, s3_f, s4_f, s5_f, s6_f;   // first pixel of a command
  reg         s1_in, s2_in, s3_in, s4_in;
  reg  [7:0]  s1_dx;
  reg  [16:0] s2_dx2;
  reg signed [18:0] s3_do, s3_di;
  reg  [31:0] s4_mo, s4_mi;
  reg  [4:0]  s5_a, s6_a;
  reg         s1_t, s2_t, s3_t;
  reg         s1_tag, s2_tag, s3_tag, s4_tag, s5_tag, s6_tag;
  wire [16:0] s2_dy2 = s2_tag ? dy2_s1 : dy2_s0;
  wire [16:0] s2_ro2 = s2_tag ? ro2_s1 : ro2_s0;
  wire [16:0] s2_ri2 = s2_tag ? ri2_s1 : ri2_s0;
  wire [15:0] s3_rco = s3_tag ? rco_s1 : rco_s0;
  wire [15:0] s3_rci = s3_tag ? rci_s1 : rci_s0;
  wire [4:0]  s5_opa = s5_tag ? opa_s1 : opa_s0;
  wire [11:0] s0_px = {2'b00, s0_x, 1'b1};
  wire signed [12:0] s0_dxs = $signed({1'b0, s0_px}) - $signed({2'b00, s0_cx});
  wire [11:0] s0_adx = s0_dxs[12] ? -s0_dxs[11:0] : s0_dxs[11:0];
  wire signed [12:0] s0_dxe = $signed({1'b0, s0_adx}) - $signed({3'b000, s0_ex});
  wire [4:0]  s4_ao = (s4_mo[31:12] > 20'd16) ? 5'd16 : s4_mo[16:12];
  wire [4:0]  s4_ai = (s4_mi[31:12] > 20'd16) ? 5'd16 : s4_mi[16:12];
  wire [9:0]  s5_m = s5_a * s5_opa;
  always @(posedge clk) begin
    s1_v <= s0_v; s1_f <= s0_f;
    s1_dx <= s0_dxe[12] ? 8'd0 : (s0_dxe > 13'sd255) ? 8'd255 : s0_dxe[7:0];
    s1_in <= !s0_arc || (s0_big ? (s0_c1 >= 0 || s0_c2 >= 0) : (s0_c1 >= 0 && s0_c2 >= 0));
    s1_t <= s0_t; s1_tag <= s0_tag;
    s2_v <= s1_v; s2_f <= s1_f; s2_in <= s1_in;
    s2_dx2 <= s1_dx * s1_dx;
    s2_t <= s1_t; s2_tag <= s1_tag;
    s3_v <= s2_v; s3_f <= s2_f; s3_in <= s2_in;
    s3_do <= $signed({2'b00, s2_ro2}) - $signed({2'b00, s2_dx2 + s2_dy2});
    s3_di <= $signed({2'b00, s2_ri2}) - $signed({2'b00, s2_dx2 + s2_dy2});
    s3_t <= s2_t; s3_tag <= s2_tag;
    s4_v <= s3_v; s4_f <= s3_f; s4_in <= s3_in;
    s4_mo <= (s3_do > 0) ? s3_do[16:0] * s3_rco : 32'd0;
    s4_mi <= (s3_di > 0 && s3_t) ? s3_di[16:0] * s3_rci : 32'd0;
    s4_tag <= s3_tag;
    s5_v <= s4_v; s5_f <= s4_f;
    s5_a <= !s4_in ? 5'd0 : (s4_ao > s4_ai) ? s4_ao - s4_ai : 5'd0;
    s5_tag <= s4_tag;
    s6_v <= s5_v; s6_f <= s5_f;
    s6_a <= s5_m[8:4];
    s6_tag <= s5_tag;
    if (!rst_n) begin s1_v <= 0; s2_v <= 0; s3_v <= 0; s4_v <= 0; s5_v <= 0; s6_v <= 0; end
  end

  // ---------------- glyph / icon pipeline G1..G2 ----------------
  reg         g1_v, g2_v;
  reg         g1_f, g2_f;
  reg  [4:0]  g1_a, g2_a;
  reg         g1_tag, g2_tag;
  wire [3:0]  g0_a4 = (g0_sel == 2'd2) ? ic_q : (g0_sel == 2'd1) ? fl_q : fs_q;
  wire [4:0]  g0_a16 = {1'b0, g0_a4} + {4'd0, g0_a4[3]};
  wire [9:0]  g0_m = g0_a16 * (g0_tag ? opa_s1 : opa_s0);
  always @(posedge clk) begin
    g1_v <= g0_v; g1_f <= g0_f; g1_a <= g0_m[8:4]; g1_tag <= g0_tag;   // ROM data of g0 is valid now
    g2_v <= g1_v; g2_f <= g1_f; g2_a <= g1_a; g2_tag <= g1_tag;
    if (!rst_n) begin g1_v <= 0; g2_v <= 0; end
  end

  // ---------------- span pipeline N1..N2 ----------------
  reg         n1_v, n2_v;
  reg         n1_f, n2_f;
  reg  [4:0]  n1_a, n2_a;
  reg         n1_tag, n2_tag;
  wire [15:0] n_top = {3'd0, ry, 4'd0}, n_bot = n_top + 16'd16;
  wire [15:0] n_lo = gd_data[15:0], n_hi = n0_fill ? {3'd0, n0_bot, 4'd0} : gd_data[31:16];
  wire [15:0] n_b = (n_hi < n_bot) ? n_hi : n_bot;
  wire [15:0] n_t = (n_lo > n_top) ? n_lo : n_top;
  wire signed [16:0] n_c = $signed({1'b0, n_b}) - $signed({1'b0, n_t});
  wire [4:0]  n_a = n_c[16] ? 5'd0 : (n_c > 17'sd16) ? 5'd16 : n_c[4:0];
  wire [9:0]  n_m = n_a * (n0_tag ? opa_s1 : opa_s0);
  always @(posedge clk) begin
    n1_v <= n0_v; n1_f <= n0_f; n1_a <= n_m[8:4]; n1_tag <= n0_tag;   // gdata of n0 is valid now
    n2_v <= n1_v; n2_f <= n1_f; n2_a <= n1_a; n2_tag <= n1_tag;
    if (!rst_n) begin n1_v <= 0; n2_v <= 0; end
  end

  // ---------------- image pipeline I1..I2 ----------------
  reg  [15:0] pal [0:31];
  always @(posedge clk) if (pal_we) pal[pal_wa] <= pal_wd;
  reg         i1_v, i2_v;
  reg         i1_f, i2_f;
  reg  [4:0]  i1_a, i2_a;
  reg  [15:0] i1_col, i2_col;
  reg         i1_tag, i2_tag;
  wire [3:0]  i_nib = im_data[{i0_nib, 2'b00} +: 4];
  always @(posedge clk) begin
    i1_v <= i0_v; i1_f <= i0_f;                                        // image RAM data of i0 is valid now
    i1_a <= (i0_transp && i_nib == 4'd0) ? 5'd0 : (i0_tag ? opa_s1 : opa_s0);
    i1_tag <= i0_tag; i2_tag <= i1_tag;
    i1_col <= pal[{i0_pal, i_nib}];
    i2_v <= i1_v; i2_f <= i1_f; i2_a <= i1_a; i2_col <= i1_col;
    if (!rst_n) begin i1_v <= 0; i2_v <= 0; end
  end

  // ---------------- blend (read-modify-write with forwarding) ----------------
  wire        i2_ve = (IMAGE != 0) && i2_v;      // the image pipeline (none without image RAM)
  wire        o_v = s6_v | g2_v | n2_v | i2_ve;
  // x of the pixel: the pixels of a command leave the pipelines in order, one column after the other,
  // so x is x0 of the command for its first pixel and the last x + 1 for the others
  reg  [8:0]  b1_x;
  wire        o_tag = s6_v ? s6_tag : g2_v ? g2_tag : (n2_v || IMAGE == 0) ? n2_tag : i2_tag;
  wire        o_f = s6_v ? s6_f : g2_v ? g2_f : (n2_v || IMAGE == 0) ? n2_f : i2_f;
  wire [8:0]  o_x = o_f ? (o_tag ? x0_s1 : x0_s0) : b1_x + 9'd1;     // b1_x: x of the last pixel
  wire [4:0]  o_a = s6_v ? s6_a : g2_v ? g2_a : (n2_v || IMAGE == 0) ? n2_a : i2_a;
  wire [15:0] o_col = (IMAGE != 0 && !s6_v && !g2_v && !n2_v) ? i2_col : o_tag ? col_s1 : col_s0;
  // slots still used by pixels in flight
  wire [1:0]  busy_s = {s0_v & s0_tag | s1_v & s1_tag | s2_v & s2_tag | s3_v & s3_tag | s4_v & s4_tag |
                        s5_v & s5_tag | s6_v & s6_tag | g0_v & g0_tag | g1_v & g1_tag | g2_v & g2_tag |
                        n0_v & n0_tag | n1_v & n1_tag | n2_v & n2_tag |
                        (IMAGE != 0) & (i0_v & i0_tag | i1_v & i1_tag | i2_v & i2_tag),
                        s0_v & !s0_tag | s1_v & !s1_tag | s2_v & !s2_tag | s3_v & !s3_tag | s4_v & !s4_tag |
                        s5_v & !s5_tag | s6_v & !s6_tag | g0_v & !g0_tag | g1_v & !g1_tag | g2_v & !g2_tag |
                        n0_v & !n0_tag | n1_v & !n1_tag | n2_v & !n2_tag |
                        (IMAGE != 0) & (i0_v & !i0_tag | i1_v & !i1_tag | i2_v & !i2_tag)};
  assign rd_ra = o_x;
  reg         b1_v;
  reg  [4:0]  b1_a;
  reg  [15:0] b1_col;
  reg         w2_we;                           // the write that reached the RAM at the last edge
  reg  [8:0]  w2_wa;
  reg  [15:0] w2_wd;
  wire [15:0] dst = (wr_we && wr_wa == b1_x) ? wr_wd : (w2_we && w2_wa == b1_x) ? w2_wd : rend_q;
  wire [4:0]  b1_na = 5'd16 - b1_a;
  wire [9:0]  bl_r = dst[15:11] * b1_na + b1_col[15:11] * b1_a + 10'd8;
  wire [10:0] bl_g = dst[10:5] * b1_na + b1_col[10:5] * b1_a + 11'd8;
  wire [9:0]  bl_b = dst[4:0] * b1_na + b1_col[4:0] * b1_a + 10'd8;
  always @(posedge clk) begin
    b1_v <= o_v && (o_a != 5'd0);
    if (o_v) b1_x <= o_x;
    b1_a <= o_a;
    b1_col <= o_col;
    wr_we <= b1_v;
    wr_wa <= b1_x;
    wr_wd <= {bl_r[8:4], bl_g[9:4], bl_b[8:4]};
    w2_we <= wr_we;
    w2_wa <= wr_wa;
    w2_wd <= wr_wd;
    if (!rst_n) begin b1_v <= 1'b0; wr_we <= 1'b0; w2_we <= 1'b0; end
  end

  // ================================================================
  // sequencer
  // ================================================================
  wire render_line = (vn < 10'd271) || (vn == 10'd299);
  wire [8:0] rn = (vn == 10'd299) ? 9'd0 : vn[8:0] + 9'd1;
  wire [7:0] gsel = (tbyte[1:0] == 2'd0) ? gd_data[7:0] : (tbyte[1:0] == 2'd1) ? gd_data[15:8] :
                    (tbyte[1:0] == 2'd2) ? gd_data[23:16] : gd_data[31:24];
  wire [6:0] gidx = t_font ? ((gsel > 8'd13) ? 7'd0 : {3'b000, gsel[3:0]}) : ((gsel > 8'd95) ? 7'd0 : gsel[6:0]);
  wire [6:0] widx = t_font ? 7'd96 + {2'b00, gidx[4:0]} : gidx;
  wire [4:0] gw = widths[widx];
  wire [4:0] t_h = t_font ? 5'd18 : 5'd15;

  always @(posedge clk) begin
    s0_v <= 1'b0;
    g0_v <= 1'b0;
    n0_v <= 1'b0;
    i0_v <= 1'b0;
    if (st != R_IDLE) lclk <= lclk + 16'd1;
    if (!rst_n) begin
      st <= R_IDLE;
      frame_cnt <= 32'd0;
      stat_max <= 16'd0;
      stat_over <= 16'd0;
      bank_l <= 1'b0;
      cs <= 1'b0;
    end else if (line_go) begin
      if (st != R_IDLE) stat_over <= stat_over + 16'd1;
      if (vn == 10'd299) begin
        frame_cnt <= frame_cnt + 32'd1;
        bank_l <= bank_sel;
      end
      if (render_line) begin
        ry <= rn;
        ci <= 8'd0;
        lclk <= 16'd0;
        st <= R_REFETCH;
      end else begin
        st <= R_IDLE;
      end
    end else begin
      case (st)
        R_REFETCH: st <= R_DEC;
        R_DEC: begin
          if (q_op == 4'd0) begin
            st <= R_FLUSH;                             // let the last pixels reach the line buffer
            dcnt <= 4'd0;
          end else begin
            if (q_active && busy_s[!cs]) begin
              st <= R_REFETCH;                         // its slot is still in use: read it again
            end else begin
              ci <= ci + 8'd1;
              if (q_active) begin
                op <= q_op; x0 <= q_x0; x1 <= q_x1; y0 <= q_y0; y1 <= q_y1; p <= q_p;
                cs <= !cs;
                if (cs) begin opa_s0 <= dl_data[54:50]; col_s0 <= dl_data[47:32]; x0_s0 <= q_x0; end
                else    begin opa_s1 <= dl_data[54:50]; col_s1 <= dl_data[47:32]; x0_s1 <= q_x0; end
                st <= R_SET0;
              end
            end
          end
        end
        R_SET0: begin
          dy <= dye[12] ? 8'd0 : (dye > 13'sd255) ? 8'd255 : dye[7:0];
          rec_a0 <= r;
          rec_a1 <= ri;
          row <= ry - y0;
          irow <= (i_sy ? {1'b0, dyr[8:1]} : dyr) + {1'b0, i_r0};
          xr <= x0;
          tk <= 7'd0;
          txc <= x0;
          c1 <= sxv * dys - syv * dxs0;
          c2 <= dxs0 * eyv - dys * exv;
          st <= R_SET1;
        end
        R_SET1: begin
          if (cs) begin
            dy2_s1 <= dy * dy;
            ro2_s1 <= ({1'b0, r} + 9'd1) * ({1'b0, r} + 9'd1);
            ri2_s1 <= ({1'b0, ri} + 9'd1) * ({1'b0, ri} + 9'd1);
          end else begin
            dy2_s0 <= dy * dy;
            ro2_s0 <= ({1'b0, r} + 9'd1) * ({1'b0, r} + 9'd1);
            ri2_s0 <= ({1'b0, ri} + 9'd1) * ({1'b0, ri} + 9'd1);
          end
          if (IMAGE) im_rb <= i_base + irow_w * i_stride;
          st <= (op == 4'd3) ? R_TFETCH : (op == 4'd4) ? R_TPIX : R_RUN;
          tcol <= 5'd0;
          tw <= 5'd24;
          if (op == 4'd3 && dyr >= {4'd0, t_h}) st <= R_REFETCH;
          if (op == 4'd4 && dyr >= 9'd24) st <= R_REFETCH;
        end
        R_RUN: begin                                   // shape, arc, span: one pixel per clock
          if (op == 4'd5) begin
            n0_v <= 1'b1; n0_f <= (xr == x0); n0_tag <= cs; n0_fill <= s_fill; n0_bot <= y1 + 9'd1;
          end else if (op == 4'd6) begin
            i0_v <= IMAGE != 0; i0_f <= (xr == x0); i0_nib <= icol_s[2:0]; i0_tag <= cs; i0_pal <= i_pal; i0_transp <= i_transp;
          end else begin
            if (xr == x0) begin
              if (cs) begin rco_s1 <= rec_q0; rci_s1 <= rec_q1; end
              else    begin rco_s0 <= rec_q0; rci_s0 <= rec_q1; end
            end
            s0_v <= 1'b1; s0_x <= xr; s0_f <= (xr == x0); s0_c1 <= c1; s0_c2 <= c2; s0_t <= (t != 8'd0); s0_tag <= cs;
            c1 <= c1 - {{13{syv[7]}}, syv, 1'b0};
            c2 <= c2 + {{13{eyv[7]}}, eyv, 1'b0};
          end
          xr <= xr + 9'd1;
          if (xr == x1) st <= R_REFETCH;
        end
        R_TFETCH: begin                                // the gdata word of character tk is read now
          if (tk == t_len || txc > x1) st <= R_REFETCH;
          else st <= R_TGET;
        end
        R_TGET: begin
          tg <= gidx;
          tw <= gw;
          tcol <= 5'd0;
          st <= (gw == 5'd0) ? R_TFETCH : R_TPIX;
          if (gw == 5'd0) tk <= tk + 7'd1;
        end
        R_TPIX: begin                                  // glyph ROM address presented now
          g0_v <= 1'b1;
          g0_f <= (txc == x0) && (tcol == 5'd0);
          g0_sel <= (op == 4'd4) ? 2'd2 : {1'b0, t_font};
          g0_tag <= cs;
          if (tcol + 5'd1 == tw || txc + {4'd0, tcol} == x1) begin
            txc <= txc + {4'd0, tw};
            tk <= tk + 7'd1;
            st <= (op == 4'd4 || txc + {4'd0, tcol} == x1) ? R_REFETCH : R_TFETCH;
          end
          tcol <= tcol + 5'd1;
        end
        R_FLUSH: begin
          dcnt <= dcnt + 4'd1;
          if (dcnt == FLUSH - 1) begin
            st <= R_IDLE;
            if (lclk > stat_max) stat_max <= lclk;
          end
        end
        default: st <= R_IDLE;
      endcase
    end
  end

endmodule
