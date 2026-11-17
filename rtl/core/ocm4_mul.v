/*
 * ocm4_mul - multiplier: all ARMv7E-M multiplies in two clocks (products registered, then the
 * accumulate / round / saturate). One 33 x 33 signed multiplier (Gowin MULT36X36) and one 17 x 17
 * (MULT18X18) for the second product of the dual 16-bit instructions.
 * SPDX-License-Identifier: MIT
 *
 *   clock 1 (start): operands a = Rn, b = Rm -> products registered
 *   clock 2:         c = Ra / RdLo, d = RdHi -> lo, hi, q_set (valid in this clock, combinational)
 */

`default_nettype none
`include "ocm4_defs.vh"

module ocm4_mul (
    input  wire        clk,
    input  wire        start,
    input  wire [2:0]  kind,
    input  wire [9:0]  fl,          // MF_* flags
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [31:0] c,
    input  wire [31:0] d,
    output reg  [31:0] lo,
    output reg  [31:0] hi,
    output reg         q_set
);
  wire sgn = fl[`MF_SIGNED];

  // ---------------- clock 1: operands and products ----------------
  wire [31:0] bx = fl[`MF_X] ? {b[15:0], b[31:16]} : b;
  wire [15:0] xn = fl[`MF_N] ? a[31:16] : a[15:0];
  wire [15:0] ym = fl[`MF_M] ? b[31:16] : b[15:0];
  reg  signed [32:0] ma, mb;
  always @* begin
    case (kind)
      `MK_SMLXY: begin ma = {{17{xn[15]}}, xn}; mb = {{17{ym[15]}}, ym}; end
      `MK_SMLW:  begin ma = {a[31], a};          mb = {{17{ym[15]}}, ym}; end
      `MK_SMLD:  begin ma = {{17{a[15]}}, a[15:0]}; mb = {{17{bx[15]}}, bx[15:0]}; end
      default:   begin ma = {sgn & a[31], a};    mb = {sgn & b[31], b}; end
    endcase
  end
  wire signed [16:0] sa = {a[31], a[31:16]};
  wire signed [16:0] sb = {bx[31], bx[31:16]};

  reg signed [65:0] p;
  reg signed [33:0] p2;
  reg [2:0]  k;
  reg [9:0]  f;
  always @(posedge clk) begin
    if (start) begin
      p  <= ma * mb;
      p2 <= sa * sb;
      k  <= kind;
      f  <= fl;
    end
  end

  // ---------------- clock 2: accumulate (one 64-bit adder) ----------------
  // sum = Y + (neg ? ~X : X) + neg, X from the product(s), Y from the accumulator registers
  wire [63:0] p64  = p[63:0];
  wire [34:0] dual = {{3{p[31]}}, p[31:0]} + (f[`MF_SUB] ? ~{p2[33], p2} : {p2[33], p2}) + {34'd0, f[`MF_SUB]};
  wire [32:0] cd   = {1'b0, c} + {1'b0, d};             // UMAAL: RdLo + RdHi
  wire        accl = f[`MF_ACC] && f[`MF_LONG];          // 64-bit accumulator {RdHi, RdLo}
  reg  [63:0] X, Y;
  reg         neg;
  always @* begin
    neg = 1'b0;
    case (k)
      `MK_SMLXY: X = {{32{p[31]}}, p[31:0]};
      `MK_SMLW:  X = {{32{p[47]}}, p[47:16]};
      `MK_SMLD:  X = {{29{dual[34]}}, dual};
      default:   begin X = p64; neg = f[`MF_SUB]; end      // MUL, MULL, SMMUL (MLS, SMMLS subtract)
    endcase
    if (k == `MK_SMMUL)        Y = {f[`MF_ACC] ? c : 32'd0, f[`MF_ROUND] ? 32'h8000_0000 : 32'd0};
    else if (f[`MF_UMAAL])     Y = {31'd0, cd};
    else if (accl)             Y = {d, c};
    else if (f[`MF_ACC])       Y = (k == `MK_MUL || k == `MK_MULL) ? {32'd0, c} : {{32{c[31]}}, c};
    else                       Y = 64'd0;
  end
  wire [63:0] sum = Y + (neg ? ~X : X) + {63'd0, neg};
  wire        ov32 = (sum[35:31] != 5'b00000) && (sum[35:31] != 5'b11111);
  always @* begin
    lo = (k == `MK_SMMUL) ? sum[63:32] : sum[31:0];
    hi = sum[63:32];
    q_set = !f[`MF_LONG] && (k == `MK_SMLXY || k == `MK_SMLW || k == `MK_SMLD) && ov32;
  end

endmodule

`default_nettype wire
