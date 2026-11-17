/*
 * ocm4_div - SDIV / UDIV: radix-2 restoring division, two quotient bits per clock, starting at the
 * first significant bit of the dividend (small dividends finish early: 2 + ceil(bits / 2) clocks).
 * Division by zero gives 0 (the core traps first when CCR.DIV_0_TRP is set).
 * SPDX-License-Identifier: MIT
 */

`default_nettype none

module ocm4_div (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        sgn,
    input  wire [31:0] n,
    input  wire [31:0] d,
    output reg         done,          // one clock pulse with the quotient
    output wire [31:0] q
);
  function [5:0] clz32(input [31:0] x);
    integer k;
    reg found;
    begin
      clz32 = 6'd32;
      found = 1'b0;
      for (k = 31; k >= 0; k = k - 1)
        if (!found && x[k]) begin
          clz32 = 6'd31 - k[5:0];
          found = 1'b1;
        end
    end
  endfunction

  wire        nneg = sgn & n[31];
  wire        dneg = sgn & d[31];
  wire [31:0] na = nneg ? -n : n;
  wire [31:0] da = dneg ? -d : d;
  wire [5:0]  lz = clz32(na);
  wire [5:0]  lze = {lz[5:1], 1'b0};

  reg  [31:0] dv, qr, rem;
  reg  [4:0]  cnt;             // pairs of bits left
  reg         busy, neg;

  wire [32:0] r1 = {rem, qr[31]};
  wire        g1 = r1 >= {1'b0, dv};
  wire [32:0] r1s = g1 ? r1 - {1'b0, dv} : r1;
  wire [32:0] r2 = {r1s[31:0], qr[30]};
  wire        g2 = r2 >= {1'b0, dv};
  wire [32:0] r2s = g2 ? r2 - {1'b0, dv} : r2;

  assign q = neg ? -qr : qr;

  always @(posedge clk) begin
    done <= 1'b0;
    if (!rst_n) begin
      busy <= 1'b0;
    end else if (start) begin
      dv  <= da;
      rem <= 32'd0;
      neg <= nneg ^ dneg;
      if (d == 32'd0 || lz == 6'd32) begin
        qr   <= 32'd0;
        done <= 1'b1;
        busy <= 1'b0;
      end else begin
        qr   <= na << lze;
        cnt  <= 5'd16 - lze[5:1];
        busy <= 1'b1;
      end
    end else if (busy) begin
      rem <= r2s[31:0];
      qr  <= {qr[29:0], g1, g2};
      cnt <= cnt - 5'd1;
      if (cnt == 5'd1) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
