/*
 * ocm4_shifter, ocm4_alu - barrel shifter (Shift_C of the ARMv7-M ARM) and the integer ALU
 * SPDX-License-Identifier: MIT
 */

`default_nettype none
`include "ocm4_defs.vh"

// Shift_C(value, type, amount, carry_in): one right rotator and a mask do all four shift types.
//   type 0 LSL, 1 LSR, 2 ASR, 3 ROR;  rrx: rotate right with extend (ignores type and amount)
//   amount 0..255 (register shifts use Rs[7:0]; immediate shifts are decoded to 0..32)
module ocm4_shifter (
    input  wire [31:0] v,
    input  wire [1:0]  typ,
    input  wire [7:0]  amt,
    input  wire        rrx,
    input  wire        cin,
    output reg  [31:0] res,
    output reg         cout
);
  wire [4:0]  r    = amt[4:0];
  wire        zero = (amt == 8'd0);
  wire        big  = |amt[7:5];                 // >= 32
  wire        lsl  = (typ == 2'd0);
  wire [4:0]  ra   = lsl ? (5'd0 - r) : r;      // rotate right by 32 - r for a left shift
  wire [63:0] vv   = {v, v} >> ra;
  wire [31:0] rot  = vv[31:0];
  wire [31:0] mr   = 32'hFFFFFFFF >> r;         // bits kept by a right shift
  wire [31:0] ml   = 32'hFFFFFFFF << r;         // bits kept by a left shift

  always @* begin
    res  = v;
    cout = cin;
    if (rrx) begin
      res  = {cin, v[31:1]};
      cout = v[0];
    end else if (!zero) begin
      case (typ)
        2'd0: begin                               // LSL
          if (big) begin
            res  = 32'd0;
            cout = (amt == 8'd32) ? v[0] : 1'b0;
          end else begin
            res  = rot & ml;
            cout = rot[0];
          end
        end
        2'd1: begin                               // LSR
          if (big) begin
            res  = 32'd0;
            cout = (amt == 8'd32) ? v[31] : 1'b0;
          end else begin
            res  = rot & mr;
            cout = rot[31];
          end
        end
        2'd2: begin                               // ASR
          if (big) begin
            res  = {32{v[31]}};
            cout = v[31];
          end else begin
            res  = (rot & mr) | (v[31] ? ~mr : 32'd0);
            cout = rot[31];
          end
        end
        default: begin                            // ROR
          res  = rot;
          cout = rot[31];
        end
      endcase
    end
  end
endmodule

module ocm4_alu (
    input  wire [3:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        cin,       // APSR.C
    input  wire        sh_c,      // carry from the shifter / immediate expansion
    output reg  [31:0] res,
    output wire        n,
    output wire        z,
    output reg         c,
    output reg         v
);
  reg  [31:0] aa, bb;
  reg         ci;
  reg         arith;
  wire [32:0] sum = {1'b0, aa} + {1'b0, bb} + {32'd0, ci};

  always @* begin
    aa = a; bb = b; ci = 1'b0; arith = 1'b0;
    case (op)
      `ALU_SUB: begin bb = ~b; ci = 1'b1; arith = 1'b1; end
      `ALU_RSB: begin aa = ~a; ci = 1'b1; arith = 1'b1; end
      `ALU_ADD: begin arith = 1'b1; end
      `ALU_ADC: begin ci = cin; arith = 1'b1; end
      `ALU_SBC: begin bb = ~b; ci = cin; arith = 1'b1; end
      default: ;
    endcase
    case (op)
      `ALU_AND: res = a & b;
      `ALU_EOR: res = a ^ b;
      `ALU_ORN: res = a | ~b;
      `ALU_ORR: res = a | b;
      `ALU_MOV: res = b;
      `ALU_BIC: res = a & ~b;
      `ALU_MVN: res = ~b;
      default:  res = sum[31:0];
    endcase
    c = arith ? sum[32] : sh_c;
    v = (aa[31] == bb[31]) && (sum[31] != aa[31]);
  end
  assign n = res[31];
  assign z = (res == 32'd0);
endmodule

`default_nettype wire
