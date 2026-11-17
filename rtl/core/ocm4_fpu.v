/*
 * ocm4_fpu - single-precision floating-point unit of OpenCM4F (FPv4-SP data processing)
 * SPDX-License-Identifier: MIT
 *
 * Bit-exact with the ARMv7-M pseudo-code (FPAdd, FPSub, FPMul, FPMulAdd, FPDiv, FPSqrt, FPCompare,
 * FPToFixed, FixedToFP, FPSingleToHalf, FPHalfToSingle, FPRound): NaN propagation and default NaN
 * (DN), flush-to-zero (FZ), all four rounding modes, alternative half precision (AHP), tininess
 * before rounding, and the cumulative flags IDC IXC UFC OFC DZC IOC.
 *
 * One operation at a time (start -> done), multi-cycle datapath shared by all operations:
 *
 *   UNPK   unpack the operands, normalise subnormals, special cases (NaN, infinity, zero)
 *   MUL    24 x 24 product (an addition multiplies its first operand by 1.0)
 *   ALN    align the addend to the product (52-bit right shift with sticky); FP -> int shift
 *   ADD    add / subtract magnitudes
 *   NRM    leading-zero count and normalise
 *   RND1   denormalise tiny results (or flush them to zero with FZ)
 *   RND2   round, overflow, pack
 *   DIV    radix-2 division, 2 bits per clock (14 clocks); SQRT digit recurrence (13 clocks)
 *   F2I    round and saturate to an integer / fixed-point value
 *
 * VMLA VMLS VNMLA VNMLS (chained) run the datapath twice: product, rounded; then the addition.
 * Latency: add / mul / fma 7 clocks, chained 13, divide 21, square root 20, conversions 4..7.
 *
 * Operands: a = S[n], b = S[m], c = S[d]. flags is in FPSCR[7:0] bit positions.
 */

`default_nettype none
`include "ocm4_defs.vh"

module ocm4_fpu (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire [4:0]  op,
    input  wire [8:0]  prm,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] c,
    input  wire [4:0]  ctl,          // {AHP, DN, FZ, RMode[1:0]} = FPSCR[26:22]
    output reg         busy,
    output reg         done,
    output reg  [31:0] res,
    output reg  [7:0]  flags,
    output reg  [3:0]  nzcv,
    output reg         is_cmp
);

  localparam S_IDLE = 4'd0, S_UNPK = 4'd1, S_MUL = 4'd2, S_ALN = 4'd3, S_ADD = 4'd4, S_NRM = 4'd5,
             S_RND1 = 4'd6, S_RND2 = 4'd7, S_DIV = 4'd8, S_SQRT = 4'd9, S_F2I = 4'd10, S_FIN = 4'd11;

  localparam [31:0] QNAN = 32'h7FC0_0000;
  localparam F_IOC = 0, F_DZC = 1, F_OFC = 2, F_UFC = 3, F_IXC = 4, F_IDC = 7;

  // ---------------- latched request ----------------
  reg  [3:0]  st;
  // the request is not latched: the core holds op, prm, a, b, c and FPSCR until done
  wire [4:0]  fop = op;
  wire [8:0]  fprm = prm;
  wire [31:0] ra = a, rb = b, rc = c;
  wire        ahp = ctl[4], dn = ctl[3], fz = ctl[2];
  reg         rn;                    // round to nearest instead of FPSCR.RMode (see FOP_I2F)
  wire [1:0]  rmode = rn ? 2'b00 : ctl[1:0];
  reg         pass2;
  reg  [31:0] prod1;                 // rounded product of a chained multiply-accumulate
  reg  [7:0]  fl;

  wire chained = (fop == `FOP_MLA) || (fop == `FOP_MLS) || (fop == `FOP_NMLA) || (fop == `FOP_NMLS);
  wire fused   = (fop == `FOP_FMA) || (fop == `FOP_FMS) || (fop == `FOP_FNMA) || (fop == `FOP_FNMS);

  // ---------------- helpers ----------------
  function [4:0] clz24(input [23:0] x);
    integer k;
    reg f;
    begin
      clz24 = 5'd24; f = 1'b0;
      for (k = 23; k >= 0; k = k - 1)
        if (!f && x[k]) begin clz24 = 5'd23 - k[4:0]; f = 1'b1; end
    end
  endfunction
  function [5:0] clz52(input [51:0] x);
    integer k;
    reg f;
    begin
      clz52 = 6'd52; f = 1'b0;
      for (k = 51; k >= 0; k = k - 1)
        if (!f && x[k]) begin clz52 = 6'd51 - k[5:0]; f = 1'b1; end
    end
  endfunction
  // right shift with sticky (bit 0 collects everything shifted out); the bits falling off at each
  // level of the barrel shifter are ORed
  function [51:0] shr_st(input [51:0] x, input [11:0] n);
    reg [51:0] v;
    reg        st;
    integer    l;
    begin
      if (n >= 12'd52) shr_st = {51'd0, |x};
      else begin
        v = x; st = 1'b0;
        for (l = 0; l < 6; l = l + 1)
          if (n[l]) begin
            st = st | |(v & ((52'd1 << (1 << l)) - 52'd1));
            v = v >> (1 << l);
          end
        shr_st = v | {51'd0, st};
      end
    end
  endfunction

  // ---------------- operand selection (UNPK) ----------------
  // the operation the datapath performs now
  localparam M_ADD = 3'd0, M_MUL = 3'd1, M_FMA = 3'd2, M_DIV = 3'd3, M_SQRT = 3'd4, M_CVT = 3'd5, M_CMP = 3'd6;
  reg  [2:0]  mode;
  reg  [31:0] ox, oy, oz;           // operand patterns after FPNeg of the operation
  reg         ysub;                 // FPSub: second operand negated for the arithmetic only
  always @* begin
    ox = ra; oy = rb; oz = rc; ysub = 1'b0; mode = M_ADD;
    case (fop)
      `FOP_ADD:  mode = M_ADD;
      `FOP_SUB:  begin mode = M_ADD; ysub = 1'b1; end
      `FOP_MUL, `FOP_NMUL: mode = M_MUL;
      `FOP_FMA:  begin mode = M_FMA; end
      `FOP_FMS:  begin mode = M_FMA; ox = ra ^ 32'h8000_0000; end
      `FOP_FNMA: begin mode = M_FMA; ox = ra ^ 32'h8000_0000; oz = rc ^ 32'h8000_0000; end
      `FOP_FNMS: begin mode = M_FMA; oz = rc ^ 32'h8000_0000; end
      `FOP_DIV:  mode = M_DIV;
      `FOP_SQRT: mode = M_SQRT;
      `FOP_CMP:  begin mode = M_CMP; ox = rc; oy = fprm[1] ? 32'd0 : rb; end
      `FOP_F2I, `FOP_I2F, `FOP_F2H, `FOP_H2F: mode = M_CVT;
      default: begin   // chained: first the product, then the addition
        if (!pass2) mode = M_MUL;
        else begin
          mode = M_ADD;
          ox = (fop == `FOP_NMLA || fop == `FOP_NMLS) ? rc ^ 32'h8000_0000 : rc;
          oy = (fop == `FOP_MLS || fop == `FOP_NMLA) ? prod1 ^ 32'h8000_0000 : prod1;
        end
      end
    endcase
  end

  // unpack (single precision)
  wire [7:0]  xe8 = ox[30:23], ye8 = oy[30:23], ze8 = oz[30:23];
  wire [22:0] xf = ox[22:0], yf = oy[22:0], zf = oz[22:0];
  wire        xs = ox[31], zs = oz[31];
  wire        ys = oy[31] ^ ysub;
  wire        x_den = (xe8 == 8'd0) && (xf != 23'd0);
  wire        y_den = (ye8 == 8'd0) && (yf != 23'd0);
  wire        z_den = (ze8 == 8'd0) && (zf != 23'd0);
  wire        x_zero = (xe8 == 8'd0) && ((xf == 23'd0) || fz);
  wire        y_zero = (ye8 == 8'd0) && ((yf == 23'd0) || fz);
  wire        z_zero = (ze8 == 8'd0) && ((zf == 23'd0) || fz);
  wire        x_inf = (xe8 == 8'hFF) && (xf == 23'd0);
  wire        y_inf = (ye8 == 8'hFF) && (yf == 23'd0);
  wire        z_inf = (ze8 == 8'hFF) && (zf == 23'd0);
  wire        x_nan = (xe8 == 8'hFF) && (xf != 23'd0);
  wire        y_nan = (ye8 == 8'hFF) && (yf != 23'd0);
  wire        z_nan = (ze8 == 8'hFF) && (zf != 23'd0);
  wire        x_snan = x_nan && !xf[22];
  wire        y_snan = y_nan && !yf[22];
  wire        z_snan = z_nan && !zf[22];
  wire        x_qnan = x_nan && xf[22];
  wire        y_qnan = y_nan && yf[22];
  wire        z_qnan = z_nan && zf[22];
  // mantissas, normalised; exponents unbiased (12-bit signed)
  wire [23:0] xm0 = {xe8 != 8'd0, xf};
  wire [23:0] ym0 = {ye8 != 8'd0, yf};
  wire [4:0]  xlz = clz24(xm0);
  wire [4:0]  ylz = clz24(ym0);
  wire [23:0] xm = xm0 << xlz;
  wire [23:0] ym = ym0 << ylz;
  wire [11:0] xe = {4'd0, (xe8 == 8'd0) ? 8'd1 : xe8} - 12'd127 - {7'd0, xlz};
  wire [11:0] ye = {4'd0, (ye8 == 8'd0) ? 8'd1 : ye8} - 12'd127 - {7'd0, ylz};
  wire [23:0] zm = {ze8 != 8'd0, zf};
  wire [11:0] ze = {4'd0, (ze8 == 8'd0) ? 8'd1 : ze8} - 12'd127;

  // NaN processing
  function [31:0] quiet(input [31:0] v);
    quiet = v | 32'h0040_0000;
  endfunction
  // FPProcessNaNs (x, y) / FPProcessNaNs3 (z, x, y)
  reg        nan2, nan3;
  reg [31:0] nan2_v, nan3_v;
  always @* begin
    nan2 = x_nan || y_nan;
    if (x_snan)      nan2_v = quiet(ox);
    else if (y_snan) nan2_v = quiet(oy);
    else if (x_qnan) nan2_v = ox;
    else             nan2_v = oy;                    // FPSub returns operand 2's NaN, not negated
    nan3 = z_nan || x_nan || y_nan;
    if (z_snan)      nan3_v = quiet(oz);
    else if (x_snan) nan3_v = quiet(ox);
    else if (y_snan) nan3_v = quiet(oy);
    else if (z_qnan) nan3_v = oz;
    else if (x_qnan) nan3_v = ox;
    else             nan3_v = oy;
  end
  wire any_snan2 = x_snan || y_snan;
  wire any_snan3 = x_snan || y_snan || z_snan;

  // ---------------- special cases (computed in UNPK) ----------------
  reg        sp;            // the result is decided here
  reg [31:0] sp_v;
  reg [7:0]  sp_f;
  reg [3:0]  sp_nzcv;
  wire       rm_neg = (rmode == 2'b10);
  wire       prod_s = xs ^ ys;

  // integer / half inputs
  wire        cvt_uns = fprm[6];
  wire        cvt_16  = fprm[7];
  wire [5:0]  fbits   = fprm[5:0];
  wire [31:0] ival    = cvt_16 ? (cvt_uns ? {16'd0, oy[15:0]} : {{16{oy[15]}}, oy[15:0]}) : oy;
  wire        ineg    = !cvt_uns && ival[31];
  wire [31:0] imag    = ineg ? -ival : ival;
  wire [15:0] hv      = fprm[0] ? rb[31:16] : rb[15:0];
  wire        h_s     = hv[15];
  wire [4:0]  h_e     = hv[14:10];
  wire [9:0]  h_f     = hv[9:0];
  wire [4:0]  h_lz    = clz24({h_f, 14'd0});
  wire [9:0]  h_fn    = (h_f << (h_lz + 5'd1));      // fraction after the leading one
  wire [7:0]  h_sube  = 8'd127 - 8'd15 - {3'd0, h_lz};   // exponent of a subnormal half
  // compare key (total order of non-NaN values; zeros of both signs are equal)
  wire [31:0] cx = x_zero ? 32'd0 : {xs, xe8, xf};
  wire [31:0] cy = y_zero ? 32'd0 : {ys, ye8, yf};
  wire        c_eq = (cx == cy) || (x_zero && y_zero);
  wire        c_lt = (cx[31] != cy[31]) ? (cx[31] && !(x_zero && y_zero)) :
                     (cx[31] ? (cx[30:0] > cy[30:0]) : (cx[30:0] < cy[30:0]));

  always @* begin
    sp = 1'b0; sp_v = 32'd0; sp_f = 8'd0; sp_nzcv = 4'd0;
    case (mode)
      M_ADD: begin
        if (fz && (x_den || y_den)) sp_f[F_IDC] = 1'b1;
        if (nan2) begin
          sp = 1'b1; sp_v = dn ? QNAN : nan2_v; sp_f[F_IOC] = any_snan2;
        end else if (x_inf && y_inf && xs != ys) begin
          sp = 1'b1; sp_v = QNAN; sp_f[F_IOC] = 1'b1;
        end else if (x_inf || y_inf) begin
          sp = 1'b1; sp_v = {x_inf ? xs : ys, 8'hFF, 23'd0};
        end else if (x_zero && y_zero) begin
          sp = 1'b1; sp_v = {(xs == ys) ? xs : rm_neg, 31'd0};
        end else if (x_zero) begin
          sp = 1'b1; sp_v = {ys, oy[30:0]};
        end else if (y_zero) begin
          sp = 1'b1; sp_v = ox;
        end
      end
      M_MUL: begin
        if (fz && (x_den || y_den)) sp_f[F_IDC] = 1'b1;
        if (nan2) begin
          sp = 1'b1; sp_v = dn ? QNAN : nan2_v; sp_f[F_IOC] = any_snan2;
        end else if ((x_inf && y_zero) || (x_zero && y_inf)) begin
          sp = 1'b1; sp_v = QNAN; sp_f[F_IOC] = 1'b1;
        end else if (x_inf || y_inf) begin
          sp = 1'b1; sp_v = {prod_s, 8'hFF, 23'd0};
        end else if (x_zero || y_zero) begin
          sp = 1'b1; sp_v = {prod_s, 31'd0};
        end
      end
      M_FMA: begin
        if (fz && (x_den || y_den || z_den)) sp_f[F_IDC] = 1'b1;
        if (nan3) begin
          sp = 1'b1; sp_v = dn ? QNAN : nan3_v; sp_f[F_IOC] = any_snan3;
          if (z_qnan && ((x_inf && y_zero) || (x_zero && y_inf))) begin sp_v = QNAN; sp_f[F_IOC] = 1'b1; end
        end else if ((x_inf && y_zero) || (x_zero && y_inf) || (z_inf && (x_inf || y_inf) && zs != prod_s)) begin
          sp = 1'b1; sp_v = QNAN; sp_f[F_IOC] = 1'b1;
        end else if ((z_inf && !zs) || ((x_inf || y_inf) && !prod_s)) begin
          sp = 1'b1; sp_v = 32'h7F80_0000;
        end else if ((z_inf && zs) || ((x_inf || y_inf) && prod_s)) begin
          sp = 1'b1; sp_v = 32'hFF80_0000;
        end else if (z_zero && (x_zero || y_zero)) begin
          sp = 1'b1; sp_v = {(zs == prod_s) ? zs : rm_neg, 31'd0};
        end else if (x_zero || y_zero) begin
          sp = 1'b1; sp_v = oz;                       // product is zero: the addend, exact
        end
      end
      M_DIV: begin
        if (fz && (x_den || y_den)) sp_f[F_IDC] = 1'b1;
        if (nan2) begin
          sp = 1'b1; sp_v = dn ? QNAN : nan2_v; sp_f[F_IOC] = any_snan2;
        end else if ((x_inf && y_inf) || (x_zero && y_zero)) begin
          sp = 1'b1; sp_v = QNAN; sp_f[F_IOC] = 1'b1;
        end else if (x_inf || y_zero) begin
          sp = 1'b1; sp_v = {prod_s, 8'hFF, 23'd0}; sp_f[F_DZC] = !x_inf;
        end else if (x_zero || y_inf) begin
          sp = 1'b1; sp_v = {prod_s, 31'd0};
        end
      end
      M_SQRT: begin
        if (fz && y_den) sp_f[F_IDC] = 1'b1;
        if (y_nan) begin
          sp = 1'b1; sp_v = dn ? QNAN : quiet(oy); sp_f[F_IOC] = y_snan;
        end else if (y_zero) begin
          sp = 1'b1; sp_v = {ys, 31'd0};
        end else if (y_inf && !ys) begin
          sp = 1'b1; sp_v = 32'h7F80_0000;
        end else if (ys) begin
          sp = 1'b1; sp_v = QNAN; sp_f[F_IOC] = 1'b1;
        end
      end
      M_CMP: begin
        sp = 1'b1;
        if (fz && (x_den || y_den)) sp_f[F_IDC] = 1'b1;
        if (x_nan || y_nan) begin
          sp_nzcv = 4'b0011; sp_f[F_IOC] = x_snan || y_snan || fprm[0];
        end else if (c_eq) sp_nzcv = 4'b0110;
        else if (c_lt)     sp_nzcv = 4'b1000;
        else               sp_nzcv = 4'b0010;
      end
      default: begin   // conversions
        case (fop)
          `FOP_F2I: begin
            if (fz && y_den) sp_f[F_IDC] = 1'b1;
            if (y_nan) begin
              sp = 1'b1; sp_v = 32'd0; sp_f[F_IOC] = 1'b1;
            end else if (y_zero) begin
              sp = 1'b1; sp_v = 32'd0;
            end else if (y_inf || ($signed(ye) + $signed({6'd0, fbits}) > 12'sd33)) begin
              sp = 1'b1; sp_f[F_IOC] = 1'b1;
              if (cvt_uns)     sp_v = ys ? 32'd0 : (cvt_16 ? 32'h0000_FFFF : 32'hFFFF_FFFF);
              else if (cvt_16) sp_v = ys ? 32'hFFFF_8000 : 32'h0000_7FFF;
              else             sp_v = ys ? 32'h8000_0000 : 32'h7FFF_FFFF;
            end
          end
          `FOP_I2F: begin
            if (imag == 32'd0) begin sp = 1'b1; sp_v = 32'd0; end
          end
          `FOP_F2H: begin
            if (fz && y_den) sp_f[F_IDC] = 1'b1;
            if (y_nan) begin
              sp = 1'b1;
              if (ahp)     sp_v = {16'd0, ys, 15'd0};
              else if (dn) sp_v = 32'h0000_7E00;
              else         sp_v = {16'd0, ys, 5'h1F, 1'b1, yf[21:13]};
              sp_f[F_IOC] = y_snan || ahp;
            end else if (y_inf) begin
              sp = 1'b1;
              sp_v = ahp ? {16'd0, ys, 15'h7FFF} : {16'd0, ys, 5'h1F, 10'd0};
              sp_f[F_IOC] = ahp;
            end else if (y_zero) begin
              sp = 1'b1; sp_v = {16'd0, ys, 15'd0};
            end
            if (sp) sp_v = fprm[0] ? {sp_v[15:0], rc[15:0]} : {rc[31:16], sp_v[15:0]};
          end
          default: begin   // H2F: exact
            sp = 1'b1;
            if (h_e == 5'h1F && !ahp) begin
              if (h_f == 10'd0) sp_v = {h_s, 8'hFF, 23'd0};
              else begin
                sp_v = dn ? QNAN : {h_s, 8'hFF, 1'b1, h_f[8:0], 13'd0};
                sp_f[F_IOC] = !h_f[9];
              end
            end else if (h_e == 5'd0) begin
              if (h_f == 10'd0) sp_v = {h_s, 31'd0};
              else sp_v = {h_s, h_sube, h_fn, 13'd0};
            end else begin
              sp_v = {h_s, {3'd0, h_e} + 8'd112, h_f, 13'd0};
            end
          end
        endcase
      end
    endcase
  end

  // ---------------- datapath registers ----------------
  reg [23:0] pa, pb;            // multiplier operands
  reg [11:0] ep, ec, eM, ne, re;
  reg        sp_s, sc_s, rs;    // product sign, addend sign, result sign
  reg [23:0] cm;                // addend mantissa
  reg        cz;                // no addend
  reg [47:0] P;
  reg [51:0] big, small_, nv;
  reg        eff_sub, sbig, ssmall;
  reg [25:0] rm;                // round input: [25:2] significand, [1] round, [0] sticky
  reg        half;
  reg        tiny;
  reg [11:0] be;
  reg [25:0] rm2;
  // divide / square root
  reg [27:0] dq;
  reg [25:0] drem;
  reg [4:0]  it;
  reg [51:0] sqR;
  reg [29:0] sqrem;
  reg [25:0] sqq;
  // FP -> int
  reg [51:0] fiw;
  reg        fis;

  // ---------------- rounding (RND2) ----------------
  wire [23:0] r_sig  = half ? {13'd0, rm2[25:15]} : rm2[25:2];
  wire        r_rb   = half ? rm2[14] : rm2[1];
  wire        r_sb   = half ? (|rm2[13:0]) : rm2[0];
  wire        r_inx  = r_rb | r_sb;
  wire        r_up   = (rmode == 2'b00) ? (r_rb & (r_sb | r_sig[0])) :
                       (rmode == 2'b01) ? (!rs & r_inx) :
                       (rmode == 2'b10) ? (rs & r_inx) : 1'b0;
  wire [24:0] r_sum  = {1'b0, r_sig} + {24'd0, r_up};
  wire        r_cy   = half ? r_sum[11] : r_sum[24];
  wire        r_hid  = half ? r_sum[10] : r_sum[23];
  wire [11:0] r_be   = r_cy ? be + 12'd1 : ((be == 12'd0 && r_hid) ? 12'd1 : be);
  wire [22:0] r_fr   = half ? {13'd0, r_cy ? r_sum[10:1] : r_sum[9:0]} : (r_cy ? r_sum[23:1] : r_sum[22:0]);
  wire        r_ovf  = half ? (ahp ? ($signed(r_be) >= 12'sd32) : ($signed(r_be) >= 12'sd31)) : ($signed(r_be) >= 12'sd255);
  wire        r_toinf = (rmode == 2'b00) || (rmode == 2'b01 && !rs) || (rmode == 2'b10 && rs);
  reg  [31:0] r_val;
  reg  [7:0]  r_fl;
  always @* begin
    r_fl = 8'd0;
    if (half) begin
      if (r_ovf && ahp) begin
        r_val = {16'd0, rs, 15'h7FFF}; r_fl[F_IOC] = 1'b1;
      end else if (r_ovf) begin
        r_val = r_toinf ? {16'd0, rs, 5'h1F, 10'd0} : {16'd0, rs, 5'h1E, 10'h3FF};
        r_fl[F_OFC] = 1'b1; r_fl[F_IXC] = 1'b1;
      end else begin
        r_val = {16'd0, rs, r_be[4:0], r_fr[9:0]};
        r_fl[F_IXC] = r_inx; r_fl[F_UFC] = tiny & r_inx;
      end
    end else begin
      if (r_ovf) begin
        r_val = r_toinf ? {rs, 8'hFF, 23'd0} : {rs, 8'hFE, 23'h7FFFFF};
        r_fl[F_OFC] = 1'b1; r_fl[F_IXC] = 1'b1;
      end else begin
        r_val = {rs, r_be[7:0], r_fr};
        r_fl[F_IXC] = r_inx; r_fl[F_UFC] = tiny & r_inx;
      end
    end
  end

  // ---------------- divide / square root steps ----------------
  // quotient step: compare remainder with divisor, then shift
  wire        dg1 = (drem >= {2'd0, pb});
  wire [25:0] dr1 = (dg1 ? drem - {2'd0, pb} : drem) << 1;
  wire        dg2 = (dr1 >= {2'd0, pb});
  wire [25:0] dr2 = (dg2 ? dr1 - {2'd0, pb} : dr1) << 1;
  // square root step
  wire [29:0] s_r1 = {sqrem[27:0], sqR[51:50]};
  wire [29:0] s_t1 = {2'd0, sqq, 2'b01};
  wire        s_g1 = s_r1 >= s_t1;
  wire [29:0] s_a1 = s_g1 ? s_r1 - s_t1 : s_r1;
  wire [25:0] s_q1 = {sqq[24:0], s_g1};
  wire [29:0] s_r2 = {s_a1[27:0], sqR[49:48]};
  wire [29:0] s_t2 = {2'd0, s_q1, 2'b01};
  wire        s_g2 = s_r2 >= s_t2;
  wire [29:0] s_a2 = s_g2 ? s_r2 - s_t2 : s_r2;
  wire [25:0] s_q2 = {s_q1[24:0], s_g2};

  // ---------------- normalise ----------------
  wire [5:0]  n_lz = clz52(nv);
  wire [51:0] n_sh = nv << n_lz;

  // ---------------- FP -> int ----------------
  wire [33:0] fi_int = fiw[51:18];
  wire        fi_rb  = fiw[17];
  wire        fi_sb  = |fiw[16:0];
  wire        fi_inx = fi_rb | fi_sb;
  wire [1:0]  fi_rm  = fprm[8] ? 2'b11 : rmode;
  wire        fi_up  = (fi_rm == 2'b00) ? (fi_rb & (fi_sb | fi_int[0])) :
                       (fi_rm == 2'b01) ? (!fis & fi_inx) :
                       (fi_rm == 2'b10) ? (fis & fi_inx) : 1'b0;
  wire [34:0] fi_mag = {1'b0, fi_int} + {34'd0, fi_up};
  reg  [31:0] fi_val;
  reg  [7:0]  fi_fl;
  always @* begin
    fi_fl = 8'd0;
    fi_val = 32'd0;
    if (cvt_uns) begin
      if (fis && fi_mag != 35'd0) begin fi_val = 32'd0; fi_fl[F_IOC] = 1'b1; end
      else if (cvt_16 ? (fi_mag > 35'h0FFFF) : (fi_mag > 35'hFFFFFFFF)) begin
        fi_val = cvt_16 ? 32'h0000_FFFF : 32'hFFFF_FFFF; fi_fl[F_IOC] = 1'b1;
      end else fi_val = fi_mag[31:0];
    end else begin
      if (!fis && (cvt_16 ? (fi_mag > 35'h07FFF) : (fi_mag > 35'h7FFFFFFF))) begin
        fi_val = cvt_16 ? 32'h0000_7FFF : 32'h7FFF_FFFF; fi_fl[F_IOC] = 1'b1;
      end else if (fis && (cvt_16 ? (fi_mag > 35'h08000) : (fi_mag > 35'h80000000))) begin
        fi_val = cvt_16 ? 32'hFFFF_8000 : 32'h8000_0000; fi_fl[F_IOC] = 1'b1;
      end else fi_val = fis ? -fi_mag[31:0] : fi_mag[31:0];
    end
    if (!fi_fl[F_IOC] && fi_inx) fi_fl[F_IXC] = 1'b1;
  end

  // ---------------- the shared right shifter (ALN, RND1, F2I in UNPK) ----------------
  wire [11:0] emin = half ? -12'sd14 : -12'sd126;
  wire        aln_p = cz || $signed(ep) >= $signed(ec);   // the product is the bigger operand
  reg  [51:0] sh_x;
  reg  [11:0] sh_n;
  always @* begin
    case (st)
      S_ALN:   begin sh_x = aln_p ? {2'b00, cm, 26'd0} : {1'b0, P, 3'd0}; sh_n = aln_p ? ep - ec : ec - ep; end
      S_RND1:  begin sh_x = {rm, 26'd0}; sh_n = emin - re; end
      default: begin sh_x = {ym, 28'd0}; sh_n = 12'd33 - (ye + {6'd0, fbits}); end
    endcase
  end
  wire [51:0] sh_y = shr_st(sh_x, sh_n);
  wire [51:0] dn_t = sh_y;                                  // denormalise: shift with sticky
  wire [11:0] bias = half ? 12'd15 : 12'd127;
  wire [11:0] d_pc = ep - ec;

  always @(posedge clk) begin
    done <= 1'b0;
    if (!rst_n) begin
      st <= S_IDLE; busy <= 1'b0; pass2 <= 1'b0;
      res <= 32'd0; flags <= 8'd0; nzcv <= 4'd0; is_cmp <= 1'b0;
    end else begin
      case (st)
        S_IDLE: begin
          if (start) begin
            rn <= 1'b0;
            pass2 <= 1'b0; fl <= 8'd0; half <= 1'b0;
            busy <= 1'b1;
            st <= S_UNPK;
          end
        end

        S_UNPK: begin
          fl <= fl | sp_f;
          half <= 1'b0;
          is_cmp <= (mode == M_CMP);
          nzcv <= sp_nzcv;
          if (sp) begin
            res <= sp_v;
            st <= S_FIN;
          end else begin
            case (mode)
              M_ADD, M_MUL, M_FMA: begin
                pa <= xm;
                pb <= (mode == M_ADD) ? 24'h800000 : ym;
                ep <= (mode == M_ADD) ? xe : xe + ye;
                sp_s <= (mode == M_ADD) ? xs : prod_s;
                cz <= (mode == M_MUL) || (mode == M_FMA && z_zero);
                cm <= (mode == M_ADD) ? ym : zm;
                ec <= (mode == M_ADD) ? ye : ze;
                sc_s <= (mode == M_ADD) ? ys : zs;
                st <= S_MUL;
              end
              M_DIV: begin
                drem <= {2'd0, xm};
                pb <= ym;                          // the divisor (the multiplier is idle)
                ne <= xe - ye - 12'd2;
                rs <= prod_s;
                it <= 5'd14;
                st <= S_DIV;
              end
              M_SQRT: begin
                // odd exponent: radicand 2m, exponent - 1
                sqR <= ye[0] ? {ym, 28'd0} : {1'b0, ym, 27'd0};      // R = m' * 2^50
                ne <= ($signed(ye[0] ? ye - 12'd1 : ye) >>> 1) - 12'd2;
                sqrem <= 30'd0;
                sqq <= 26'd0;
                rs <= 1'b0;
                it <= 5'd13;
                st <= S_SQRT;
              end
              default: begin
                case (fop)
                  `FOP_F2I: begin
                    // shift {m, 28'b0} right by 33 - (e + fbits): integer bits [51:18]
                    fiw <= sh_y;
                    fis <= ys;
                    st <= S_F2I;
                  end
                  `FOP_I2F: begin
                    nv <= {imag, 20'd0};
                    ne <= 12'd29 - {6'd0, fbits};
                    rs <= ineg;
                    if (fprm[8]) rn <= 1'b1;
                    st <= S_NRM;
                  end
                  default: begin   // F2H
                    rs <= ys;
                    re <= ye;
                    rm <= {ym, 2'b00};
                    half <= 1'b1;
                    st <= S_RND1;
                  end
                endcase
              end
            endcase
          end
        end

        S_MUL: begin
          P <= pa * pb;
          st <= S_ALN;
        end

        S_ALN: begin
          // A = product at [50:3] (binary point at 49), B = addend at [49:26]
          if (aln_p) begin
            big <= {1'b0, P, 3'd0};
            small_ <= cz ? 52'd0 : sh_y;
            eM <= ep; sbig <= sp_s; ssmall <= sc_s;
          end else begin
            big <= {2'b00, cm, 26'd0};
            small_ <= sh_y;
            eM <= ec; sbig <= sc_s; ssmall <= sp_s;
          end
          eff_sub <= !cz && (sp_s != sc_s);
          st <= S_ADD;
        end

        S_ADD: begin
          if (eff_sub) begin
            if (small_ > big) begin nv <= small_ - big; rs <= ssmall; end
            else begin nv <= big - small_; rs <= sbig; end
          end else begin
            nv <= big + small_;
            rs <= sbig;
          end
          ne <= eM;
          st <= S_NRM;
        end

        S_NRM: begin
          if (nv == 52'd0) begin
            // exact zero from a subtraction: +0, or -0 when rounding toward minus infinity
            res <= {rm_neg, 31'd0};
            st <= S_FIN;
          end else begin
            re <= ne + 12'd2 - {6'd0, n_lz};
            rm <= {n_sh[51:28], n_sh[27], |n_sh[26:0]};
            st <= S_RND1;
          end
        end

        S_RND1: begin
          tiny <= $signed(re) < $signed(emin);
          if ($signed(re) < $signed(emin)) begin
            if (fz && !half) begin
              res <= {rs, 31'd0};
              fl <= fl | (8'd1 << F_UFC);
              st <= S_FIN;
            end else begin
              rm2 <= dn_t[51:26] | {25'd0, |dn_t[25:0]};
              be <= 12'd0;
              st <= S_RND2;
            end
          end else begin
            rm2 <= rm;
            be <= re + bias;
            st <= S_RND2;
          end
        end

        S_RND2: begin
          fl <= fl | r_fl;
          res <= (fop == `FOP_F2H) ? (fprm[0] ? {r_val[15:0], rc[15:0]} : {rc[31:16], r_val[15:0]}) : r_val;
          st <= S_FIN;
        end

        S_DIV: begin
          drem <= dr2;
          dq <= {dq[25:0], dg1, dg2};
          it <= it - 5'd1;
          if (it == 5'd1) st <= S_NRM;
        end

        S_SQRT: begin
          sqrem <= s_a2;
          sqq <= s_q2;
          sqR <= {sqR[47:0], 4'd0};
          it <= it - 5'd1;
          if (it == 5'd1) st <= S_NRM;
        end

        S_F2I: begin
          res <= fi_val;
          fl <= fl | fi_fl;
          st <= S_FIN;
        end

        S_FIN: begin
          if (chained && !pass2) begin
            // product done: now the addition
            prod1 <= res;
            pass2 <= 1'b1;
            st <= S_UNPK;
          end else begin
            if (fop == `FOP_NMUL) res <= res ^ 32'h8000_0000;
            flags <= fl;
            done <= 1'b1;
            busy <= 1'b0;
            st <= S_IDLE;
          end
        end
        default: st <= S_IDLE;
      endcase

      // divide and square root hand their result to the normaliser
      if (st == S_DIV && it == 5'd1) begin
        nv <= {dq[25:0], dg1, dg2, 24'd0} | {51'd0, (dr2 != 26'd0)};
      end
      if (st == S_SQRT && it == 5'd1) begin
        nv <= {s_q2, 26'd0} | {51'd0, (s_a2 != 30'd0)};
      end
    end
  end

endmodule

`default_nettype wire
