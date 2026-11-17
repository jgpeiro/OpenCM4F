/*
 * ocm4_regfile - register file with one synchronous write port and four asynchronous read ports
 * (one copy of the array per read port, so it maps to LUT RAM: RAM16SDP4 on Gowin).
 * SPDX-License-Identifier: MIT
 *
 * Used twice: core registers (16 x 32: physical index 0..12, 13 = MSP, 14 = LR, 15 = PSP; the PC
 * is not stored here) and FP registers (32 x 32, S0..S31).
 */

`default_nettype none

module ocm4_regfile #(
    parameter AW = 4
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [31:0]   wd,
    input  wire [AW-1:0] ra0,
    input  wire [AW-1:0] ra1,
    input  wire [AW-1:0] ra2,
    input  wire [AW-1:0] ra3,
    output wire [31:0]   rd0,
    output wire [31:0]   rd1,
    output wire [31:0]   rd2,
    output wire [31:0]   rd3
);
  localparam N = 1 << AW;
  reg [31:0] m0 [0:N-1];
  reg [31:0] m1 [0:N-1];
  reg [31:0] m2 [0:N-1];
  reg [31:0] m3 [0:N-1];

  integer i;
  initial begin
    for (i = 0; i < N; i = i + 1) begin
      m0[i] = 32'd0; m1[i] = 32'd0; m2[i] = 32'd0; m3[i] = 32'd0;
    end
  end

  always @(posedge clk) begin
    if (we) begin
      m0[wa] <= wd;
      m1[wa] <= wd;
      m2[wa] <= wd;
      m3[wa] <= wd;
    end
  end

  assign rd0 = m0[ra0];
  assign rd1 = m1[ra1];
  assign rd2 = m2[ra2];
  assign rd3 = m3[ra3];

endmodule

`default_nettype wire
