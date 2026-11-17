/*
 * ocm4_bitops - single-cycle bit-manipulation and DSP (SIMD, saturation) instructions:
 *   MOVW MOVT BFI BFC UBFX SBFX CLZ RBIT REV REV16 REVSH, SXT/UXT(A)B/H/B16, SSAT USAT SSAT16 USAT16,
 *   PKHBT PKHTB SEL, parallel add/subtract (S Q SH U UQ UH x ADD16 ASX SAX SUB16 ADD8 SUB8),
 *   QADD QSUB QDADD QDSUB, USAD8 USADA8
 * SPDX-License-Identifier: MIT
 *
 * The rotations of BFI, UBFX, SBFX and of the extends, and the shifts of SSAT, USAT and PKH, are done
 * by the core's barrel shifter: sh is the rotated / shifted operand of port B.
 */

`default_nettype none
`include "ocm4_defs.vh"

module ocm4_bitops (
    input  wire [4:0]  sub,
    input  wire [9:0]  imm,
    input  wire [31:0] a,        // Rn
    input  wire [31:0] b,        // Rm (imm16 for MOVW, MOVT)
    input  wire [31:0] sh,       // port B through the shifter
    input  wire [31:0] c,        // Rd (MOVT, BFI) or Ra (USADA8)
    input  wire [3:0]  ge,
    output reg  [31:0] res,
    output reg  [3:0]  ge_out,
    output reg         ge_we,
    output reg         q_set
);

  // ---------------- bit fields (sh = Rn rotated: right by lsb for UBFX / SBFX, left for BFI) ----------
  wire [4:0]  lsb   = imm[4:0];
  wire [4:0]  hi    = imm[9:5];                    // msb (BFI) or width - 1 (UBFX, SBFX)
  wire [31:0] mhi   = 32'hFFFFFFFF >> (5'd31 - hi); // bits 0 .. hi
  wire [31:0] bfm   = mhi & (32'hFFFFFFFF << lsb);  // bits lsb .. msb
  wire [31:0] ubfx  = sh & mhi;
  wire [31:0] sbfx  = ubfx | (sh[hi] ? ~mhi : 32'd0);

  // ---------------- CLZ, RBIT ----------------
  reg [5:0]  clz;
  reg [31:0] rbit;
  integer k;
  always @* begin
    clz = 6'd32;
    for (k = 0; k < 32; k = k + 1)
      if (b[k]) clz = 6'd31 - k[5:0];
    for (k = 0; k < 32; k = k + 1) rbit[k] = b[31 - k];
  end

  // ---------------- extends (sh = Rm rotated by 0, 8, 16, 24) ----------------
  wire        xs   = imm[2];
  wire [1:0]  xsz  = imm[4:3];                     // 0 byte, 1 halfword, 2 two bytes
  wire [15:0] e_lo = (xsz == 2'd1) ? sh[15:0] : {{8{xs & sh[7]}}, sh[7:0]};
  wire [15:0] e_hi = (xsz == 2'd2) ? {{8{xs & sh[23]}}, sh[23:16]} :
                     (xsz == 2'd1) ? {16{xs & sh[15]}} : {16{xs & sh[7]}};
  wire [16:0] x_lo = {1'b0, a[15:0]} + {1'b0, e_lo};
  wire [15:0] x_hi = a[31:16] + e_hi + {15'd0, (xsz != 2'd2) & x_lo[16]};

  // ---------------- saturation: shared thermometer masks ----------------
  // 32-bit (operand sh): SSAT to imm + 1 bits, USAT to imm bits
  wire [31:0] m32  = 32'hFFFFFFFF << imm[4:0];
  wire [31:0] t32  = sh & m32;
  wire        s_ok = (t32 == 32'd0) || (t32 == m32);
  wire [31:0] ssat = s_ok ? sh : (sh[31] ? m32 : ~m32);
  wire        u_ov = sh[31] || (t32 != 32'd0);
  wire [31:0] usat = !u_ov ? sh : (sh[31] ? 32'd0 : ~m32);
  // 16-bit lanes (operand b): SSAT16 to imm + 1 bits, USAT16 to imm bits
  wire [15:0] m16  = 16'hFFFF << imm[3:0];
  wire [15:0] t0   = b[15:0] & m16;
  wire [15:0] t1   = b[31:16] & m16;
  wire        s0ok = (t0 == 16'd0) || (t0 == m16);
  wire        s1ok = (t1 == 16'd0) || (t1 == m16);
  wire [15:0] ss0  = s0ok ? b[15:0] : (b[15] ? m16 : ~m16);
  wire [15:0] ss1  = s1ok ? b[31:16] : (b[31] ? m16 : ~m16);
  wire        u0ov = b[15] || (t0 != 16'd0);
  wire        u1ov = b[31] || (t1 != 16'd0);
  wire [15:0] us0  = !u0ov ? b[15:0] : (b[15] ? 16'd0 : ~m16);
  wire [15:0] us1  = !u1ov ? b[31:16] : (b[31] ? 16'd0 : ~m16);

  // ---------------- QADD family: Rd = sat(Rm +/- [sat(2 Rn)]) ----------------
  wire        d_ov = a[31] ^ a[30];
  wire [31:0] a2   = d_ov ? (a[31] ? 32'h80000000 : 32'h7FFFFFFF) : {a[30:0], 1'b0};
  wire [31:0] qa   = imm[1] ? a2 : a;
  wire [32:0] qs   = imm[0] ? {b[31], b} - {qa[31], qa} : {b[31], b} + {qa[31], qa};
  wire        q_ov = qs[32] ^ qs[31];
  wire [31:0] qres = q_ov ? (qs[32] ? 32'h80000000 : 32'h7FFFFFFF) : qs[31:0];

  // ---------------- parallel add / subtract ----------------
  // halfword lanes: Rn half op Rm half (Rm halves swapped for ASX / SAX); byte lanes 0 and 2 use the
  // halfword adders, byte lanes 1 and 3 have their own
  wire [2:0] pop = imm[2:0];
  wire [1:0] pk  = imm[4:3];                       // 0 plain (GE), 1 saturating, 2 halving
  wire       un  = imm[5];
  wire       w8  = (pop == `PAR_ADD8) || (pop == `PAR_SUB8);
  wire       swp = (pop == `PAR_ASX) || (pop == `PAR_SAX);
  wire       sb0 = (pop == `PAR_SUB16) || (pop == `PAR_SUB8) || (pop == `PAR_ASX);
  wire       sb1 = (pop == `PAR_SUB16) || (pop == `PAR_SUB8) || (pop == `PAR_SAX);
  wire [15:0] ya = swp ? b[31:16] : b[15:0];
  wire [15:0] yb = swp ? b[15:0] : b[31:16];
  function [17:0] ext18(input [15:0] v, input byte_, input u);
    ext18 = byte_ ? {{10{!u & v[7]}}, v[7:0]} : {{2{!u & v[15]}}, v};
  endfunction
  wire [17:0] xa0 = ext18(a[15:0], w8, un), ya0 = ext18(ya, w8, un);
  wire [17:0] xa2 = ext18(a[31:16], w8, un), yb2 = ext18(yb, w8, un);
  wire [17:0] r0 = sb0 ? xa0 - ya0 : xa0 + ya0;
  wire [17:0] r2 = sb1 ? xa2 - yb2 : xa2 + yb2;
  wire [9:0]  xa1 = {{2{!un & a[15]}}, a[15:8]}, yb1 = {{2{!un & b[15]}}, b[15:8]};
  wire [9:0]  xa3 = {{2{!un & a[31]}}, a[31:24]}, yb3 = {{2{!un & b[31]}}, b[31:24]};
  wire [9:0]  r1 = sb0 ? xa1 - yb1 : xa1 + yb1;
  wire [9:0]  r3 = sb1 ? xa3 - yb3 : xa3 + yb3;
  // a lane: {ge, result}
  function [16:0] post16(input [17:0] r, input s, input u, input [1:0] kk);
    reg g, ovp, ovn;
    reg [15:0] o;
    begin
      g = (u && !s) ? r[16] : !r[17];               // unsigned add: carry; otherwise result >= 0
      if (u) begin ovp = !r[17] && r[16]; ovn = r[17]; end
      else   begin ovp = !r[17] && r[15]; ovn = r[17] && !r[15]; end
      case (kk)
        2'd1: o = ovp ? (u ? 16'hFFFF : 16'h7FFF) : ovn ? (u ? 16'h0000 : 16'h8000) : r[15:0];
        2'd2: o = r[16:1];
        default: o = r[15:0];
      endcase
      post16 = {g, o};
    end
  endfunction
  function [8:0] post8(input [9:0] r, input s, input u, input [1:0] kk);
    reg g, ovp, ovn;
    reg [7:0] o;
    begin
      g = (u && !s) ? r[8] : !r[9];
      if (u) begin ovp = !r[9] && r[8]; ovn = r[9]; end
      else   begin ovp = !r[9] && r[7]; ovn = r[9] && !r[7]; end
      case (kk)
        2'd1: o = ovp ? (u ? 8'hFF : 8'h7F) : ovn ? (u ? 8'h00 : 8'h80) : r[7:0];
        2'd2: o = r[8:1];
        default: o = r[7:0];
      endcase
      post8 = {g, o};
    end
  endfunction
  wire [16:0] p0  = post16(r0, sb0, un, pk);
  wire [16:0] p2  = post16(r2, sb1, un, pk);
  wire [8:0]  p0b = post8(r0[9:0], sb0, un, pk);
  wire [8:0]  p1b = post8(r1, sb0, un, pk);
  wire [8:0]  p2b = post8(r2[9:0], sb1, un, pk);
  wire [8:0]  p3b = post8(r3, sb1, un, pk);
  wire [31:0] par_res = w8 ? {p3b[7:0], p2b[7:0], p1b[7:0], p0b[7:0]} : {p2[15:0], p0[15:0]};
  wire [3:0]  par_ge  = w8 ? {p3b[8], p2b[8], p1b[8], p0b[8]} : {p2[16], p2[16], p0[16], p0[16]};

  // ---------------- USAD8 ----------------
  function [7:0] absd(input [7:0] x, input [7:0] y);
    absd = (x >= y) ? x - y : y - x;
  endfunction
  wire [8:0]  ad01 = {1'b0, absd(a[7:0], b[7:0])} + {1'b0, absd(a[15:8], b[15:8])};
  wire [8:0]  ad23 = {1'b0, absd(a[23:16], b[23:16])} + {1'b0, absd(a[31:24], b[31:24])};
  wire [31:0] usad = (imm[0] ? c : 32'd0) + {22'd0, ad01} + {22'd0, ad23};

  always @* begin
    res = 32'd0;
    ge_out = ge;
    ge_we = 1'b0;
    q_set = 1'b0;
    case (sub)
      `BIT_MOVW:   res = {16'd0, b[15:0]};
      `BIT_MOVT:   res = {b[15:0], c[15:0]};
      `BIT_BFI:    res = (hi >= lsb) ? ((c & ~bfm) | (sh & bfm)) : c;   // BFC: sh = 0
      `BIT_UBFX:   res = ubfx;
      `BIT_SBFX:   res = sbfx;
      `BIT_CLZ:    res = {26'd0, clz};
      `BIT_RBIT:   res = rbit;
      `BIT_REV:    res = {b[7:0], b[15:8], b[23:16], b[31:24]};
      `BIT_REV16:  res = {b[23:16], b[31:24], b[7:0], b[15:8]};
      `BIT_REVSH:  res = {{16{b[7]}}, b[7:0], b[15:8]};
      `BIT_EXT:    res = {x_hi, x_lo[15:0]};
      `BIT_SSAT:   begin res = ssat; q_set = !s_ok; end
      `BIT_USAT:   begin res = usat; q_set = u_ov; end
      `BIT_SSAT16: begin res = {ss1, ss0}; q_set = !s0ok | !s1ok; end
      `BIT_USAT16: begin res = {us1, us0}; q_set = u0ov | u1ov; end
      `BIT_PKH:    res = imm[0] ? {a[31:16], sh[15:0]} : {sh[31:16], a[15:0]};
      `BIT_SEL:    res = {ge[3] ? a[31:24] : b[31:24], ge[2] ? a[23:16] : b[23:16],
                          ge[1] ? a[15:8] : b[15:8], ge[0] ? a[7:0] : b[7:0]};
      `BIT_PAR: begin
        res = par_res;
        if (pk == 2'd0) begin ge_out = par_ge; ge_we = 1'b1; end
      end
      `BIT_QADD:   begin res = qres; q_set = q_ov | (imm[1] & d_ov); end
      `BIT_USAD:   res = usad;
      default:     res = 32'd0;
    endcase
  end

endmodule

`default_nettype wire
