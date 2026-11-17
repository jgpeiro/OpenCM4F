/*
 * encoder - rotary encoder with push button (KY-040 style module with pull-ups: CLK, DT and SW are
 * high at rest and pulled low by the contacts)
 * SPDX-License-Identifier: MIT
 *
 *   pins -> two-flop synchronisers -> glitch filter (a level is taken when it has been stable for
 *   FILT clocks) -> quadrature state machine -> 16-bit signed count of quarter steps
 *   SW -> synchroniser -> debounce (stable for DEB clocks) -> pressed level
 *
 * Turning clockwise, CLK falls before DT: the state {CLK, DT} goes 11 -> 01 -> 00 -> 10 -> 11 and the
 * count goes up by 4 per detent. Contact bounce on one line only moves the count back and forth by one
 * (Gray code), so it cancels out; the firmware turns quarter steps into detents (fw/ui.c), which also
 * lets it use encoders with 2 steps per detent. A step that skips a state (both lines changed at once,
 * which a real encoder cannot do) is ignored.
 *
 * Read in the I/O register ENC (fw/hw.h): [15:0] count, [16] pressed, [17] CLK, [18] DT (filtered).
 */

`default_nettype none

module encoder #(
    parameter FILT = 108,                 // 2 us at 54 MHz
    parameter DEB  = 270000               // 5 ms at 54 MHz
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        pin_clk,           // raw pins, active low
    input  wire        pin_dt,
    input  wire        pin_sw,
    output reg  [15:0] count,
    output reg         pressed,
    output wire [1:0]  ab                 // {DT, CLK} after the filter
);

  reg [1:0] s_clk, s_dt, s_sw;
  always @(posedge clk) begin
    s_clk <= {s_clk[0], pin_clk};
    s_dt  <= {s_dt[0], pin_dt};
    s_sw  <= {s_sw[0], pin_sw};
  end

  // glitch filter for the two quadrature lines
  reg [1:0] raw_q, st;                    // raw_q: last raw {CLK, DT}; st: filtered {CLK, DT}
  reg [7:0] fcnt;
  wire [1:0] raw = {s_clk[1], s_dt[1]};
  assign ab = {st[0], st[1]};

  // quadrature decoder: +1 for the clockwise successor of the state, -1 for the counter-clockwise one
  function [1:0] cw_next(input [1:0] s);  // 11 -> 01 -> 00 -> 10 -> 11
    case (s)
      2'b11: cw_next = 2'b01;
      2'b01: cw_next = 2'b00;
      2'b00: cw_next = 2'b10;
      default: cw_next = 2'b11;
    endcase
  endfunction
  function [1:0] ccw_next(input [1:0] s);
    case (s)
      2'b11: ccw_next = 2'b10;
      2'b10: ccw_next = 2'b00;
      2'b00: ccw_next = 2'b01;
      default: ccw_next = 2'b11;
    endcase
  endfunction

  // switch debounce
  reg        sw_q;
  reg [18:0] dcnt;

  always @(posedge clk) begin
    raw_q <= raw;
    if (raw != raw_q) fcnt <= 8'd0;
    else if (fcnt != FILT[7:0]) fcnt <= fcnt + 8'd1;
    else if (raw != st) begin             // stable for FILT clocks and different: a new state
      st <= raw;
      if (raw == cw_next(st)) count <= count + 16'd1;
      else if (raw == ccw_next(st)) count <= count - 16'd1;
    end

    sw_q <= ~s_sw[1];                     // 1 = pressed
    if (sw_q != pressed) begin
      if (dcnt == DEB[18:0]) begin pressed <= sw_q; dcnt <= 19'd0; end
      else dcnt <= dcnt + 19'd1;
    end else dcnt <= 19'd0;

    if (!rst_n) begin
      st <= 2'b11; raw_q <= 2'b11; fcnt <= 8'd0; count <= 16'd0;
      pressed <= 1'b0; dcnt <= 19'd0;
    end
  end

endmodule
