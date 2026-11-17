/*
 * ocm4_decode - Thumb / Thumb-2 decoder of the ARMv7E-M instruction set with the FPv4-SP extension
 * SPDX-License-Identifier: MIT
 *
 * Purely combinational: the first two halfwords of the instruction queue -> one micro-op for the
 * execute stage. It also tracks nothing itself: the IT state comes in (itstate) and the state after
 * this instruction goes out (it_next); the core keeps the register.
 *
 * Register read ports (the core reads them and substitutes R15 = PC + 4, or Align(PC + 4, 4) when
 * a_align is set):
 *   port A (ra): Rn, the base of loads and stores, the value of MSR / CBZ / CBNZ
 *   port B (rb): Rm, BX target, the second register of STRD, VMOV core sources
 *   port C (rc): Rs (register shifts), Ra / RdLo (accumulate), Rt of stores, old Rd (MOVT, BFI)
 * FP read ports: fn -> fa, fm -> fb, fd -> fc
 */

`default_nettype none
`include "ocm4_defs.vh"

module ocm4_decode (
    input  wire [15:0] h1,
    input  wire [15:0] h2,
    input  wire        v0,
    input  wire        v1,
    input  wire        e0,
    input  wire        e1,
    input  wire [7:0]  itstate,

    output wire        dvalid,       // a complete instruction is available
    output wire        is32,
    output reg  [4:0]  op,
    output reg  [4:0]  sub,
    output reg  [3:0]  aluop,
    output reg  [3:0]  ra,
    output reg  [3:0]  rb,
    output reg  [3:0]  rc,
    output reg         a_align,
    output reg         a_zero,       // operand A = 0
    output reg         use_imm,
    output reg  [31:0] imm,
    output reg         imm_c,        // carry out of the immediate expansion ...
    output reg         imm_cv,       // ... when it has one
    output reg  [1:0]  sh_typ,
    output reg  [7:0]  sh_amt,
    output reg         sh_rrx,
    output reg         sh_reg,       // shift amount from port C
    output reg         setflags,
    output reg  [3:0]  rd,
    output reg         rd_we,
    output reg  [3:0]  rd2,
    output reg         rd2_we,
    output reg  [3:0]  cond,
    output reg  [9:0]  bp,           // bit-op parameters / multiplier flags
    output reg  [1:0]  msize,        // 0 byte, 1 half, 2 word, 3 dual
    output reg         msign,
    output reg         mpre,
    output reg         madd,
    output reg         mwb,
    output reg         munpriv,
    output reg         mexcl,
    output reg  [5:0]  cnt,          // registers / words of LDM, STM, VLDM, VSTM
    output reg  [4:0]  fn,
    output reg  [4:0]  fm,
    output reg  [4:0]  fd,
    output reg         fload,
    output reg  [7:0]  it_next
);

  // ---------------- length, validity ----------------
  assign is32   = (h1[15:11] == 5'b11101) || (h1[15:11] == 5'b11110) || (h1[15:11] == 5'b11111);
  assign dvalid = v0 && (!is32 || v1 || e0);     // a faulty first halfword is enough for an IFAULT

  wire       in_it   = (itstate[3:0] != 4'd0);
  wire [3:0] it_cond = itstate[7:4];
  wire [7:0] it_adv  = (itstate[2:0] == 3'd0) ? 8'd0 : {itstate[7:5], itstate[3:0], 1'b0};
  wire       sf16    = !in_it;                   // 16-bit data processing sets flags outside IT blocks

  // ---------------- immediates ----------------
  // ThumbExpandImm_C
  wire [11:0] i12 = {h1[10], h2[14:12], h2[7:0]};
  reg  [31:0] tei;
  reg         tei_cv;
  always @* begin
    tei_cv = 1'b0;
    if (i12[11:10] == 2'b00) begin
      case (i12[9:8])
        2'b00: tei = {24'd0, i12[7:0]};
        2'b01: tei = {8'd0, i12[7:0], 8'd0, i12[7:0]};
        2'b10: tei = {i12[7:0], 8'd0, i12[7:0], 8'd0};
        default: tei = {4{i12[7:0]}};
      endcase
    end else begin
      tei = ({24'd0, 1'b1, i12[6:0]} >> i12[11:7]) | ({24'd0, 1'b1, i12[6:0]} << (6'd32 - {1'b0, i12[11:7]}));
      tei_cv = 1'b1;
    end
  end

  // DecodeImmShift for the 32-bit shifted-register forms: type h2[5:4], imm5 = imm3:imm2
  wire [4:0] i5_32 = {h2[14:12], h2[7:6]};
  wire [1:0] ty_32 = h2[5:4];

  // branch offsets
  wire [31:0] off_b16c = {{23{h1[7]}}, h1[7:0], 1'b0};
  wire [31:0] off_b16  = {{20{h1[10]}}, h1[10:0], 1'b0};
  wire        bS  = h1[10];
  wire        bJ1 = h2[13];
  wire        bJ2 = h2[11];
  wire [31:0] off_b32c = {{11{bS}}, bS, bJ2, bJ1, h1[5:0], h2[10:0], 1'b0};
  wire [31:0] off_b32  = {{7{bS}}, bS, ~(bJ1 ^ bS), ~(bJ2 ^ bS), h1[9:0], h2[10:0], 1'b0};

  function [5:0] popc16(input [15:0] x);
    integer k;
    begin
      popc16 = 6'd0;
      for (k = 0; k < 16; k = k + 1) popc16 = popc16 + {5'd0, x[k]};
    end
  endfunction

  // VFPExpandImm (single): imm8 = h1[3:0]:h2[3:0]
  wire [7:0]  fi8 = {h1[3:0], h2[3:0]};
  wire [31:0] fimm = {fi8[7], ~fi8[6], {5{fi8[6]}}, fi8[5:0], 19'd0};

  // FP register fields
  wire [4:0] sD = {h2[15:12], h1[6]};            // Sd = Vd:D
  wire [4:0] sN = {h1[3:0], h2[7]};              // Sn = Vn:N
  wire [4:0] sM = {h2[3:0], h2[5]};              // Sm = Vm:M
  wire [4:0] dD = {h1[6], h2[15:12]};            // Dd = D:Vd (index of the D register)
  wire [4:0] dM = {h2[5], h2[3:0]};              // Dm = M:Vm
  wire [4:0] dN = {h2[7], h1[3:0]};              // Dn = N:Vn

  // ---------------- the decoder ----------------
  reg undef;
  always @* begin
    // defaults
    op = `OP_ALU; sub = 5'd0; aluop = `ALU_MOV;
    ra = 4'd0; rb = 4'd0; rc = 4'd0;
    a_align = 1'b0; a_zero = 1'b0;
    use_imm = 1'b0; imm = 32'd0; imm_c = 1'b0; imm_cv = 1'b0;
    sh_typ = 2'd0; sh_amt = 8'd0; sh_rrx = 1'b0; sh_reg = 1'b0;
    setflags = 1'b0;
    rd = 4'd0; rd_we = 1'b0; rd2 = 4'd0; rd2_we = 1'b0;
    cond = in_it ? it_cond : 4'hE;
    bp = 10'd0;
    msize = 2'd2; msign = 1'b0; mpre = 1'b1; madd = 1'b1; mwb = 1'b0; munpriv = 1'b0; mexcl = 1'b0;
    cnt = 6'd0;
    fn = 5'd0; fm = 5'd0; fd = 5'd0; fload = 1'b0;
    it_next = in_it ? it_adv : 8'd0;
    undef = 1'b0;

    if (!is32) begin
      // =====================================================================
      // 16-bit
      // =====================================================================
      casez (h1[15:10])
        6'b000???: begin
          // shift (immediate), add, subtract
          if (h1[12:11] != 2'b11) begin
            // LSL / LSR / ASR #imm5 (MOVS Rd, Rm when LSL #0)
            aluop = `ALU_MOV; rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]}; rd_we = 1'b1; setflags = sf16;
            sh_typ = h1[12:11];
            sh_amt = (h1[10:6] == 5'd0 && h1[12:11] != 2'b00) ? 8'd32 : {3'd0, h1[10:6]};
          end else begin
            ra = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]}; rd_we = 1'b1; setflags = sf16;
            aluop = h1[9] ? `ALU_SUB : `ALU_ADD;
            if (h1[10]) begin use_imm = 1'b1; imm = {29'd0, h1[8:6]}; end
            else rb = {1'b0, h1[8:6]};
          end
        end
        6'b001???: begin
          // MOV / CMP / ADD / SUB #imm8
          ra = {1'b0, h1[10:8]}; rd = {1'b0, h1[10:8]}; use_imm = 1'b1; imm = {24'd0, h1[7:0]};
          case (h1[12:11])
            2'b00: begin aluop = `ALU_MOV; rd_we = 1'b1; setflags = sf16; end
            2'b01: begin aluop = `ALU_SUB; setflags = 1'b1; end
            2'b10: begin aluop = `ALU_ADD; rd_we = 1'b1; setflags = sf16; end
            default: begin aluop = `ALU_SUB; rd_we = 1'b1; setflags = sf16; end
          endcase
        end
        6'b010000: begin
          // data processing (register): op h1[9:6], Rm h1[5:3], Rdn h1[2:0]
          ra = {1'b0, h1[2:0]}; rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]}; rd_we = 1'b1; setflags = sf16;
          case (h1[9:6])
            4'b0000: aluop = `ALU_AND;
            4'b0001: aluop = `ALU_EOR;
            4'b0010, 4'b0011, 4'b0100, 4'b0111: begin
              // LSL / LSR / ASR / ROR Rdn, Rm: shift Rdn (port B) by Rm (port C)
              aluop = `ALU_MOV; rb = {1'b0, h1[2:0]}; rc = {1'b0, h1[5:3]}; sh_reg = 1'b1;
              sh_typ = (h1[9:6] == 4'b0010) ? 2'd0 : (h1[9:6] == 4'b0011) ? 2'd1 :
                       (h1[9:6] == 4'b0100) ? 2'd2 : 2'd3;
            end
            4'b0101: aluop = `ALU_ADC;
            4'b0110: aluop = `ALU_SBC;
            4'b1000: begin aluop = `ALU_AND; rd_we = 1'b0; setflags = 1'b1; end   // TST
            4'b1001: begin aluop = `ALU_RSB; ra = {1'b0, h1[5:3]}; use_imm = 1'b1; imm = 32'd0; end  // RSB #0
            4'b1010: begin aluop = `ALU_SUB; rd_we = 1'b0; setflags = 1'b1; end   // CMP
            4'b1011: begin aluop = `ALU_ADD; rd_we = 1'b0; setflags = 1'b1; end   // CMN
            4'b1100: aluop = `ALU_ORR;
            4'b1101: begin                                                        // MULS Rdm, Rn, Rdm
              op = `OP_MUL; sub = {2'b00, `MK_MUL}; ra = {1'b0, h1[5:3]}; rb = {1'b0, h1[2:0]};
              setflags = 1'b0; bp[`MF_SETNZ] = sf16;
            end
            4'b1110: aluop = `ALU_BIC;
            default: aluop = `ALU_MVN;
          endcase
        end
        6'b010001: begin
          // special data instructions and branch and exchange
          case (h1[9:8])
            2'b00: begin    // ADD Rdn, Rm (high registers, no flags)
              aluop = `ALU_ADD; ra = {h1[7], h1[2:0]}; rb = h1[6:3]; rd = {h1[7], h1[2:0]}; rd_we = 1'b1;
            end
            2'b01: begin    // CMP Rn, Rm
              aluop = `ALU_SUB; ra = {h1[7], h1[2:0]}; rb = h1[6:3]; setflags = 1'b1;
            end
            2'b10: begin    // MOV Rd, Rm
              aluop = `ALU_MOV; rb = h1[6:3]; rd = {h1[7], h1[2:0]}; rd_we = 1'b1;
            end
            default: begin  // BX / BLX Rm
              op = `OP_BX; rb = h1[6:3];
              if (h1[7]) begin rd = 4'd14; rd_we = 1'b1; end
            end
          endcase
        end
        6'b01001?: begin
          // LDR Rt, [PC, #imm8 << 2]
          op = `OP_LD; ra = 4'd15; a_align = 1'b1; use_imm = 1'b1; imm = {22'd0, h1[7:0], 2'b00};
          rd = {1'b0, h1[10:8]}; rd_we = 1'b1;
        end
        6'b0101??: begin
          // load / store (register offset)
          ra = {1'b0, h1[5:3]}; rb = {1'b0, h1[8:6]}; rc = {1'b0, h1[2:0]}; rd = {1'b0, h1[2:0]};
          case (h1[11:9])
            3'b000: begin op = `OP_ST; msize = 2'd2; end
            3'b001: begin op = `OP_ST; msize = 2'd1; end
            3'b010: begin op = `OP_ST; msize = 2'd0; end
            3'b011: begin op = `OP_LD; msize = 2'd0; msign = 1'b1; rd_we = 1'b1; end
            3'b100: begin op = `OP_LD; msize = 2'd2; rd_we = 1'b1; end
            3'b101: begin op = `OP_LD; msize = 2'd1; rd_we = 1'b1; end
            3'b110: begin op = `OP_LD; msize = 2'd0; rd_we = 1'b1; end
            default: begin op = `OP_LD; msize = 2'd1; msign = 1'b1; rd_we = 1'b1; end
          endcase
        end
        6'b011???: begin
          // STR / LDR / STRB / LDRB (immediate)
          ra = {1'b0, h1[5:3]}; rc = {1'b0, h1[2:0]}; rd = {1'b0, h1[2:0]}; use_imm = 1'b1;
          op = h1[11] ? `OP_LD : `OP_ST; rd_we = h1[11];
          if (h1[12]) begin msize = 2'd0; imm = {27'd0, h1[10:6]}; end
          else        begin msize = 2'd2; imm = {25'd0, h1[10:6], 2'b00}; end
        end
        6'b1000??: begin
          // STRH / LDRH (immediate)
          ra = {1'b0, h1[5:3]}; rc = {1'b0, h1[2:0]}; rd = {1'b0, h1[2:0]}; use_imm = 1'b1;
          op = h1[11] ? `OP_LD : `OP_ST; rd_we = h1[11]; msize = 2'd1; imm = {26'd0, h1[10:6], 1'b0};
        end
        6'b1001??: begin
          // STR / LDR Rt, [SP, #imm8 << 2]
          ra = 4'd13; rc = {1'b0, h1[10:8]}; rd = {1'b0, h1[10:8]}; use_imm = 1'b1;
          op = h1[11] ? `OP_LD : `OP_ST; rd_we = h1[11]; imm = {22'd0, h1[7:0], 2'b00};
        end
        6'b10100?: begin
          // ADR Rd, label
          aluop = `ALU_ADD; ra = 4'd15; a_align = 1'b1; use_imm = 1'b1; imm = {22'd0, h1[7:0], 2'b00};
          rd = {1'b0, h1[10:8]}; rd_we = 1'b1;
        end
        6'b10101?: begin
          // ADD Rd, SP, #imm8 << 2
          aluop = `ALU_ADD; ra = 4'd13; use_imm = 1'b1; imm = {22'd0, h1[7:0], 2'b00};
          rd = {1'b0, h1[10:8]}; rd_we = 1'b1;
        end
        6'b1011??: begin
          // miscellaneous 16-bit
          casez (h1[11:5])
            7'b00000??: begin   // ADD SP, SP, #imm7 << 2
              aluop = `ALU_ADD; ra = 4'd13; use_imm = 1'b1; imm = {23'd0, h1[6:0], 2'b00}; rd = 4'd13; rd_we = 1'b1;
            end
            7'b00001??: begin   // SUB SP, SP, #imm7 << 2
              aluop = `ALU_SUB; ra = 4'd13; use_imm = 1'b1; imm = {23'd0, h1[6:0], 2'b00}; rd = 4'd13; rd_we = 1'b1;
            end
            7'b?0?1???: begin   // CBZ / CBNZ
              op = `OP_BR; sub = h1[11] ? 5'd2 : 5'd1; ra = {1'b0, h1[2:0]}; cond = 4'hE;
              imm = {25'd0, h1[9], h1[7:3], 1'b0};
            end
            7'b001000?: begin op = `OP_BIT; sub = `BIT_EXT; a_zero = 1'b1; rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]};
                             rd_we = 1'b1; bp = {5'd0, 2'd1, 1'b1, 2'd0}; end                   // SXTH
            7'b001001?: begin op = `OP_BIT; sub = `BIT_EXT; a_zero = 1'b1; rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]};
                             rd_we = 1'b1; bp = {5'd0, 2'd0, 1'b1, 2'd0}; end                   // SXTB
            7'b001010?: begin op = `OP_BIT; sub = `BIT_EXT; a_zero = 1'b1; rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]};
                             rd_we = 1'b1; bp = {5'd0, 2'd1, 1'b0, 2'd0}; end                   // UXTH
            7'b001011?: begin op = `OP_BIT; sub = `BIT_EXT; a_zero = 1'b1; rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]};
                             rd_we = 1'b1; bp = {5'd0, 2'd0, 1'b0, 2'd0}; end                   // UXTB
            7'b010????: begin   // PUSH {list, LR}
              op = `OP_STM; ra = 4'd13; imm = {16'd0, 1'b0, h1[8], 6'd0, h1[7:0]}; cnt = popc16({1'b0, h1[8], 6'd0, h1[7:0]});
              mpre = 1'b1; madd = 1'b0; mwb = 1'b1; rd2 = 4'd13;
            end
            7'b0110011: begin   // CPS
              op = `OP_CPS; imm = {29'd0, h1[4], h1[1], h1[0]};
            end
            7'b101000?: begin op = `OP_BIT; sub = `BIT_REV;   rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]}; rd_we = 1'b1; end
            7'b101001?: begin op = `OP_BIT; sub = `BIT_REV16; rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]}; rd_we = 1'b1; end
            7'b101011?: begin op = `OP_BIT; sub = `BIT_REVSH; rb = {1'b0, h1[5:3]}; rd = {1'b0, h1[2:0]}; rd_we = 1'b1; end
            7'b110????: begin   // POP {list, PC}
              op = `OP_LDM; ra = 4'd13; imm = {16'd0, h1[8], 7'd0, h1[7:0]}; cnt = popc16({h1[8], 7'd0, h1[7:0]});
              mpre = 1'b0; madd = 1'b1; mwb = 1'b1; rd2 = 4'd13;
            end
            7'b1110???: begin op = `OP_BKPT; imm = {24'd0, h1[7:0]}; cond = 4'hE; end
            7'b1111???: begin
              if (h1[3:0] != 4'd0) begin   // IT
                op = `OP_HINT; sub = {1'b0, `HINT_NOP}; cond = 4'hE;
                it_next = h1[7:0];
              end else begin               // hints
                op = `OP_HINT;
                case (h1[7:4])
                  4'd1: sub = {1'b0, `HINT_YIELD};
                  4'd2: sub = {1'b0, `HINT_WFE};
                  4'd3: sub = {1'b0, `HINT_WFI};
                  4'd4: sub = {1'b0, `HINT_SEV};
                  default: sub = {1'b0, `HINT_NOP};
                endcase
              end
            end
            default: undef = 1'b1;
          endcase
        end
        6'b11000?: begin
          // STM Rn!, {list}
          op = `OP_STM; ra = {1'b0, h1[10:8]}; imm = {24'd0, h1[7:0]}; cnt = popc16({8'd0, h1[7:0]});
          mpre = 1'b0; madd = 1'b1; mwb = 1'b1; rd2 = {1'b0, h1[10:8]};
        end
        6'b11001?: begin
          // LDM Rn{!}, {list}: writeback unless Rn is in the list
          op = `OP_LDM; ra = {1'b0, h1[10:8]}; imm = {24'd0, h1[7:0]}; cnt = popc16({8'd0, h1[7:0]});
          mpre = 1'b0; madd = 1'b1; mwb = !h1[{1'b0, h1[10:8]}]; rd2 = {1'b0, h1[10:8]};
        end
        6'b1101??: begin
          // B<c>, UDF, SVC
          if (h1[11:8] == 4'b1110) undef = 1'b1;
          else if (h1[11:8] == 4'b1111) begin op = `OP_SVC; imm = {24'd0, h1[7:0]}; end
          else begin op = `OP_BR; cond = h1[11:8]; imm = off_b16c; end
        end
        6'b11100?: begin
          // B
          op = `OP_BR; imm = off_b16;
        end
        default: undef = 1'b1;
      endcase
    end else begin
      // =====================================================================
      // 32-bit
      // =====================================================================
      case (h1[12:11])
        // -------------------------------------------------------------------
        2'b01: begin
          if (h1[10:9] == 2'b00 && h1[6] == 1'b0) begin
            // load / store multiple
            ra = h1[3:0]; rd2 = h1[3:0]; mwb = h1[5]; imm = {16'd0, h2}; cnt = popc16(h2);
            op = h1[4] ? `OP_LDM : `OP_STM;
            case (h1[8:7])
              2'b01: begin mpre = 1'b0; madd = 1'b1; end      // IA
              2'b10: begin mpre = 1'b1; madd = 1'b0; end      // DB
              default: undef = 1'b1;
            endcase
          end else if (h1[10:9] == 2'b00 && h1[6] == 1'b1) begin
            // load / store dual or exclusive, table branch: op1 h1[8:7], op2 h1[5:4], op3 h2[7:4]
            ra = h1[3:0];
            if (h1[8:7] == 2'b00 && h1[5:4] == 2'b00) begin
              // STREX Rd, Rt, [Rn, #imm8 << 2]
              op = `OP_ST; mexcl = 1'b1; rc = h2[15:12]; rd = h2[11:8]; rd_we = 1'b1;
              use_imm = 1'b1; imm = {22'd0, h2[7:0], 2'b00};
            end else if (h1[8:7] == 2'b00 && h1[5:4] == 2'b01) begin
              // LDREX Rt, [Rn, #imm8 << 2]
              op = `OP_LD; mexcl = 1'b1; rd = h2[15:12]; rd_we = 1'b1;
              use_imm = 1'b1; imm = {22'd0, h2[7:0], 2'b00};
            end else if (h1[8] == 1'b1 || h1[5] == 1'b1) begin
              // LDRD / STRD (immediate, literal): P h1[8], U h1[7], W h1[5]
              op = h1[4] ? `OP_LD : `OP_ST; msize = 2'd3;
              mpre = h1[8]; madd = h1[7]; mwb = h1[5]; rd2 = h1[3:0];
              use_imm = 1'b1; imm = {22'd0, h2[7:0], 2'b00};
              rd = h2[15:12]; rc = h2[15:12]; rb = h2[11:8];    // Rt, Rt2
              rd_we = h1[4];
              if (h1[3:0] == 4'd15) a_align = 1'b1;
            end else if (h1[8:7] == 2'b01 && h1[5:4] == 2'b00) begin
              // STREXB / STREXH Rd = h2[3:0], Rt = h2[15:12]
              op = `OP_ST; mexcl = 1'b1; rc = h2[15:12]; rd = h2[3:0]; rd_we = 1'b1; use_imm = 1'b1;
              case (h2[7:4])
                4'b0100: msize = 2'd0;
                4'b0101: msize = 2'd1;
                default: undef = 1'b1;
              endcase
            end else if (h1[8:7] == 2'b01 && h1[5:4] == 2'b01) begin
              case (h2[7:4])
                4'b0000: begin op = `OP_TB; rb = h2[3:0]; sub = 5'd0; end                    // Rn + Rm
                4'b0001: begin op = `OP_TB; rb = h2[3:0]; sub = 5'd1; sh_amt = 8'd1; end     // Rn + Rm LSL 1
                4'b0100: begin op = `OP_LD; mexcl = 1'b1; msize = 2'd0; rd = h2[15:12]; rd_we = 1'b1; use_imm = 1'b1; end
                4'b0101: begin op = `OP_LD; mexcl = 1'b1; msize = 2'd1; rd = h2[15:12]; rd_we = 1'b1; use_imm = 1'b1; end
                default: undef = 1'b1;
              endcase
            end else undef = 1'b1;
          end else if (h1[10:9] == 2'b01) begin
            // data processing (shifted register): op h1[8:5], S h1[4], Rn h1[3:0], Rd h2[11:8], Rm h2[3:0]
            ra = h1[3:0]; rb = h2[3:0]; rd = h2[11:8]; rd_we = 1'b1; setflags = h1[4];
            sh_typ = ty_32;
            if (ty_32 == 2'b11 && i5_32 == 5'd0) sh_rrx = 1'b1;
            else sh_amt = (i5_32 == 5'd0 && ty_32 != 2'b00 && ty_32 != 2'b11) ? 8'd32 : {3'd0, i5_32};
            case (h1[8:5])
              4'b0000: begin aluop = `ALU_AND; if (h2[11:8] == 4'd15 && h1[4]) rd_we = 1'b0; end
              4'b0001: aluop = `ALU_BIC;
              4'b0010: aluop = (h1[3:0] == 4'd15) ? `ALU_MOV : `ALU_ORR;
              4'b0011: aluop = (h1[3:0] == 4'd15) ? `ALU_MVN : `ALU_ORN;
              4'b0100: begin aluop = `ALU_EOR; if (h2[11:8] == 4'd15 && h1[4]) rd_we = 1'b0; end
              4'b0110: begin
                // PKHBT (tb = 0, LSL) / PKHTB (tb = 1, ASR)
                op = `OP_BIT; sub = `BIT_PKH; setflags = 1'b0; bp = {9'd0, h2[5]};
                sh_typ = h2[5] ? 2'd2 : 2'd0;
                sh_rrx = 1'b0;
                sh_amt = (h2[5] && i5_32 == 5'd0) ? 8'd32 : {3'd0, i5_32};
                if (h1[4] || h2[4]) undef = 1'b1;
              end
              4'b1000: begin aluop = `ALU_ADD; if (h2[11:8] == 4'd15 && h1[4]) rd_we = 1'b0; end
              4'b1010: aluop = `ALU_ADC;
              4'b1011: aluop = `ALU_SBC;
              4'b1101: begin aluop = `ALU_SUB; if (h2[11:8] == 4'd15 && h1[4]) rd_we = 1'b0; end
              4'b1110: aluop = `ALU_RSB;
              default: undef = 1'b1;
            endcase
          end else begin
            // coprocessor (h1[10] = 1)
            decode_cp();
          end
        end
        // -------------------------------------------------------------------
        2'b10: begin
          if (h2[15] == 1'b0) begin
            if (h1[9] == 1'b0) begin
              // data processing (modified immediate)
              ra = h1[3:0]; rd = h2[11:8]; rd_we = 1'b1; setflags = h1[4];
              use_imm = 1'b1; imm = tei; imm_cv = tei_cv; imm_c = tei[31];
              case (h1[8:5])
                4'b0000: begin aluop = `ALU_AND; if (h2[11:8] == 4'd15 && h1[4]) rd_we = 1'b0; end
                4'b0001: aluop = `ALU_BIC;
                4'b0010: aluop = (h1[3:0] == 4'd15) ? `ALU_MOV : `ALU_ORR;
                4'b0011: aluop = (h1[3:0] == 4'd15) ? `ALU_MVN : `ALU_ORN;
                4'b0100: begin aluop = `ALU_EOR; if (h2[11:8] == 4'd15 && h1[4]) rd_we = 1'b0; end
                4'b1000: begin aluop = `ALU_ADD; if (h2[11:8] == 4'd15 && h1[4]) rd_we = 1'b0; end
                4'b1010: aluop = `ALU_ADC;
                4'b1011: aluop = `ALU_SBC;
                4'b1101: begin aluop = `ALU_SUB; if (h2[11:8] == 4'd15 && h1[4]) rd_we = 1'b0; end
                4'b1110: aluop = `ALU_RSB;
                default: undef = 1'b1;
              endcase
            end else begin
              // data processing (plain binary immediate): op h1[8:4]
              ra = h1[3:0]; rd = h2[11:8]; rd_we = 1'b1;
              case (h1[8:4])
                5'b00000: begin   // ADDW / ADR (add)
                  aluop = `ALU_ADD; use_imm = 1'b1; imm = {20'd0, i12};
                  if (h1[3:0] == 4'd15) a_align = 1'b1;
                end
                5'b01010: begin   // SUBW / ADR (subtract)
                  aluop = `ALU_SUB; use_imm = 1'b1; imm = {20'd0, i12};
                  if (h1[3:0] == 4'd15) a_align = 1'b1;
                end
                5'b00100: begin   // MOVW
                  op = `OP_BIT; sub = `BIT_MOVW; use_imm = 1'b1; imm = {16'd0, h1[3:0], i12};
                end
                5'b01100: begin   // MOVT: old Rd on port C
                  op = `OP_BIT; sub = `BIT_MOVT; use_imm = 1'b1; imm = {16'd0, h1[3:0], i12}; rc = h2[11:8];
                end
                5'b10000, 5'b10010: begin   // SSAT (LSL / ASR), SSAT16
                  op = `OP_BIT; rb = h1[3:0];
                  if (h1[5] && {h2[14:12], h2[7:6]} == 5'd0) begin
                    sub = `BIT_SSAT16; bp = {6'd0, h2[3:0]};
                  end else begin
                    sub = `BIT_SSAT; bp = {5'd0, h2[4:0]};
                    sh_typ = h1[5] ? 2'd2 : 2'd0; sh_amt = {3'd0, h2[14:12], h2[7:6]};
                  end
                end
                5'b11000, 5'b11010: begin   // USAT, USAT16
                  op = `OP_BIT; rb = h1[3:0];
                  if (h1[5] && {h2[14:12], h2[7:6]} == 5'd0) begin
                    sub = `BIT_USAT16; bp = {6'd0, h2[3:0]};
                  end else begin
                    sub = `BIT_USAT; bp = {5'd0, h2[4:0]};
                    sh_typ = h1[5] ? 2'd2 : 2'd0; sh_amt = {3'd0, h2[14:12], h2[7:6]};
                  end
                end
                5'b10100: begin   // SBFX: Rn rotated right by lsb
                  op = `OP_BIT; sub = `BIT_SBFX; bp = {h2[4:0], h2[14:12], h2[7:6]};
                  rb = h1[3:0]; sh_typ = 2'd3; sh_amt = {3'd0, h2[14:12], h2[7:6]};
                end
                5'b11100: begin   // UBFX
                  op = `OP_BIT; sub = `BIT_UBFX; bp = {h2[4:0], h2[14:12], h2[7:6]};
                  rb = h1[3:0]; sh_typ = 2'd3; sh_amt = {3'd0, h2[14:12], h2[7:6]};
                end
                5'b10110: begin   // BFI / BFC: Rn rotated left by lsb, old Rd on port C
                  op = `OP_BIT; sub = `BIT_BFI; bp = {h2[4:0], h2[14:12], h2[7:6]}; rc = h2[11:8];
                  rb = h1[3:0]; sh_typ = 2'd3; sh_amt = {3'd0, 5'd0 - {h2[14:12], h2[7:6]}};
                  if (h1[3:0] == 4'd15) begin use_imm = 1'b1; imm = 32'd0; end          // BFC
                end
                default: undef = 1'b1;
              endcase
            end
          end else begin
            // branches and miscellaneous control
            if (h2[12] == 1'b1) begin
              // B (T4) / BL
              op = `OP_BR; imm = off_b32;
              if (h2[14]) begin rd = 4'd14; rd_we = 1'b1; end
            end else if (h2[14] == 1'b1) begin
              undef = 1'b1;                                  // BLX (immediate): not in ARMv7-M
            end else if (h1[9:7] != 3'b111) begin
              // B<c> (T3)
              op = `OP_BR; cond = h1[9:6]; imm = off_b32c;
            end else begin
              casez (h1[10:4])
                7'b011100?: begin   // MSR
                  op = `OP_MSR; ra = h1[3:0]; imm = {20'd0, h2[11:10], 2'b00, h2[7:0]};
                end
                7'b0111010: begin   // hints
                  op = `OP_HINT;
                  case (h2[7:0])
                    8'd1: sub = {1'b0, `HINT_YIELD};
                    8'd2: sub = {1'b0, `HINT_WFE};
                    8'd3: sub = {1'b0, `HINT_WFI};
                    8'd4: sub = {1'b0, `HINT_SEV};
                    default: sub = {1'b0, `HINT_NOP};
                  endcase
                end
                7'b0111011: begin   // miscellaneous control
                  op = `OP_HINT;
                  case (h2[7:4])
                    4'b0010: sub = {1'b0, `HINT_CLREX};
                    4'b0100: sub = {1'b0, `HINT_DSB};
                    4'b0101: sub = {1'b0, `HINT_DMB};
                    4'b0110: sub = {1'b0, `HINT_ISB};
                    default: undef = 1'b1;
                  endcase
                end
                7'b011111?: begin   // MRS
                  op = `OP_MRS; rd = h2[11:8]; rd_we = 1'b1; imm = {24'd0, h2[7:0]};
                end
                default: undef = 1'b1;                       // includes UDF.W
              endcase
            end
          end
        end
        // -------------------------------------------------------------------
        default: begin   // 2'b11
          casez (h1[10:4])
            7'b000???0: begin
              // store single data item: h1[7:5]
              op = `OP_ST; ra = h1[3:0]; rc = h2[15:12];
              case (h1[6:5])
                2'b00: msize = 2'd0;
                2'b01: msize = 2'd1;
                2'b10: msize = 2'd2;
                default: undef = 1'b1;
              endcase
              if (h1[7]) begin
                use_imm = 1'b1; imm = {20'd0, h2[11:0]};                    // imm12
              end else if (h2[11]) begin
                use_imm = 1'b1; imm = {24'd0, h2[7:0]};                     // imm8, P U W
                mpre = h2[10]; madd = h2[9]; mwb = h2[8]; rd2 = h1[3:0];
                if (h2[10:8] == 3'b110) begin munpriv = 1'b1; mwb = 1'b0; end
                else if (!h2[10] && !h2[8]) undef = 1'b1;
              end else begin
                rb = h2[3:0]; sh_amt = {6'd0, h2[5:4]};                      // register, LSL #imm2
                if (h2[10:6] != 5'd0) undef = 1'b1;
              end
              if (h1[3:0] == 4'd15) undef = 1'b1;
            end
            7'b00??001, 7'b00??011, 7'b00??101: begin
              // loads: h1[6:5] size (00 byte, 01 half, 10 word), h1[8] signed, h1[7] imm12 form
              op = `OP_LD; ra = h1[3:0]; rd = h2[15:12]; rd_we = 1'b1;
              msize = (h1[6:5] == 2'b00) ? 2'd0 : (h1[6:5] == 2'b01) ? 2'd1 : 2'd2;
              msign = h1[8];
              if (h1[6:5] == 2'b10 && h1[8]) undef = 1'b1;
              if (h1[3:0] == 4'd15) begin
                use_imm = 1'b1; imm = {20'd0, h2[11:0]}; madd = h1[7]; a_align = 1'b1;   // literal
              end else if (h1[7]) begin
                use_imm = 1'b1; imm = {20'd0, h2[11:0]};                    // imm12
              end else if (h2[11]) begin
                use_imm = 1'b1; imm = {24'd0, h2[7:0]};                     // imm8, P U W
                mpre = h2[10]; madd = h2[9]; mwb = h2[8]; rd2 = h1[3:0];
                if (h2[10:8] == 3'b110) begin munpriv = 1'b1; mwb = 1'b0; end
                else if (!h2[10] && !h2[8]) undef = 1'b1;
              end else begin
                rb = h2[3:0]; sh_amt = {6'd0, h2[5:4]};                      // register, LSL #imm2
                if (h2[10:6] != 5'd0) undef = 1'b1;
              end
              // Rt = PC on byte / halfword loads: PLD, PLI, unallocated hints -> NOP
              if (h2[15:12] == 4'd15 && h1[6:5] != 2'b10) begin
                op = `OP_HINT; sub = {1'b0, `HINT_NOP}; rd_we = 1'b0; mwb = 1'b0;
              end
            end
            7'b010????: begin
              // data processing (register)
              ra = h1[3:0]; rb = h2[3:0]; rd = h2[11:8]; rd_we = 1'b1;
              if (h2[15:12] != 4'b1111) undef = 1'b1;
              if (h1[7] == 1'b0 && h2[7:4] == 4'b0000) begin
                // LSL / LSR / ASR / ROR (register): shift Rn (port B) by Rm (port C)
                aluop = `ALU_MOV; rb = h1[3:0]; rc = h2[3:0]; sh_reg = 1'b1; sh_typ = h1[6:5]; setflags = h1[4];
              end else if (h1[7] == 1'b0 && h2[7] == 1'b1) begin
                // SXTAH SXTH UXTAH UXTH SXTAB16 SXTB16 UXTAB16 UXTB16 SXTAB SXTB UXTAB UXTB
                op = `OP_BIT; sub = `BIT_EXT;
                sh_typ = 2'd3; sh_amt = {3'd0, h2[5:4], 3'b000};          // rotation by the shifter
                if (h1[3:0] == 4'd15) a_zero = 1'b1;
                case (h1[6:4])
                  3'b000: bp = {5'd0, 2'd1, 1'b1, h2[5:4]};
                  3'b001: bp = {5'd0, 2'd1, 1'b0, h2[5:4]};
                  3'b010: bp = {5'd0, 2'd2, 1'b1, h2[5:4]};
                  3'b011: bp = {5'd0, 2'd2, 1'b0, h2[5:4]};
                  3'b100: bp = {5'd0, 2'd0, 1'b1, h2[5:4]};
                  3'b101: bp = {5'd0, 2'd0, 1'b0, h2[5:4]};
                  default: undef = 1'b1;
                endcase
                if (h2[6]) undef = 1'b1;
              end else if (h1[7] == 1'b1 && h2[7] == 1'b0) begin
                // parallel add / subtract: op h1[6:4], prefix {U = h2[6], h2[5:4]: 0 basic, 1 Q, 2 H}
                op = `OP_BIT; sub = `BIT_PAR; bp = {4'd0, h2[6], h2[5:4], h1[6:4]};
                if (h2[5:4] == 2'b11 || h1[6:4] == 3'b011 || h1[6:4] == 3'b111) undef = 1'b1;
              end else if (h1[7:6] == 2'b10 && h2[7:6] == 2'b10) begin
                // miscellaneous operations: op1 h1[5:4], op2 h2[5:4]
                op = `OP_BIT;
                case ({h1[5:4], h2[5:4]})
                  4'b0000: begin sub = `BIT_QADD; bp = 10'd0; end              // QADD Rd, Rm, Rn
                  4'b0001: begin sub = `BIT_QADD; bp = 10'd2; end              // QDADD
                  4'b0010: begin sub = `BIT_QADD; bp = 10'd1; end              // QSUB
                  4'b0011: begin sub = `BIT_QADD; bp = 10'd3; end              // QDSUB
                  4'b0100: sub = `BIT_REV;
                  4'b0101: sub = `BIT_REV16;
                  4'b0110: sub = `BIT_RBIT;
                  4'b0111: sub = `BIT_REVSH;
                  4'b1000: sub = `BIT_SEL;
                  4'b1100: sub = `BIT_CLZ;
                  default: undef = 1'b1;
                endcase
              end else undef = 1'b1;
            end
            7'b0110???: begin
              // multiply, multiply accumulate, absolute difference: op1 h1[6:4], op2 h2[5:4], Ra h2[15:12]
              op = `OP_MUL; ra = h1[3:0]; rb = h2[3:0]; rc = h2[15:12]; rd = h2[11:8]; rd_we = 1'b1;
              bp[`MF_ACC] = (h2[15:12] != 4'd15);
              bp[`MF_SIGNED] = 1'b1;
              case (h1[6:4])
                3'b000: begin
                  sub = {2'b00, `MK_MUL};
                  if (h2[5:4] == 2'b01) begin bp[`MF_SUB] = 1'b1; bp[`MF_ACC] = 1'b1; end   // MLS
                  else if (h2[5:4] != 2'b00) undef = 1'b1;
                end
                3'b001: begin sub = {2'b00, `MK_SMLXY}; bp[`MF_N] = h2[5]; bp[`MF_M] = h2[4]; end
                3'b010: begin sub = {2'b00, `MK_SMLD}; bp[`MF_X] = h2[4]; if (h2[5]) undef = 1'b1; end
                3'b011: begin sub = {2'b00, `MK_SMLW}; bp[`MF_M] = h2[4]; if (h2[5]) undef = 1'b1; end
                3'b100: begin sub = {2'b00, `MK_SMLD}; bp[`MF_X] = h2[4]; bp[`MF_SUB] = 1'b1; if (h2[5]) undef = 1'b1; end
                3'b101: begin sub = {2'b00, `MK_SMMUL}; bp[`MF_ROUND] = h2[4]; if (h2[5]) undef = 1'b1; end
                3'b110: begin sub = {2'b00, `MK_SMMUL}; bp[`MF_ROUND] = h2[4]; bp[`MF_SUB] = 1'b1; bp[`MF_ACC] = 1'b1;
                              if (h2[5]) undef = 1'b1; end
                default: begin   // USAD8 / USADA8
                  op = `OP_BIT; sub = `BIT_USAD; bp = {9'd0, h2[15:12] != 4'd15};
                  if (h2[5:4] != 2'b00) undef = 1'b1;
                end
              endcase
              if (h2[7:6] != 2'b00) undef = 1'b1;
            end
            7'b0111???: begin
              // long multiply, long multiply accumulate, divide: op1 h1[6:4], op2 h2[7:4]
              op = `OP_MUL; ra = h1[3:0]; rb = h2[3:0]; rc = h2[15:12];
              rd = h2[15:12]; rd_we = 1'b1; rd2 = h2[11:8]; rd2_we = 1'b1; bp[`MF_LONG] = 1'b1;
              case ({h1[6:4], h2[7:4]})
                7'b000_0000: begin sub = {2'b00, `MK_MULL}; bp[`MF_SIGNED] = 1'b1; end            // SMULL
                7'b010_0000: begin sub = {2'b00, `MK_MULL}; end                                    // UMULL
                7'b100_0000: begin sub = {2'b00, `MK_MULL}; bp[`MF_SIGNED] = 1'b1; bp[`MF_ACC] = 1'b1; end  // SMLAL
                7'b110_0000: begin sub = {2'b00, `MK_MULL}; bp[`MF_ACC] = 1'b1; end                // UMLAL
                7'b110_0110: begin sub = {2'b00, `MK_MULL}; bp[`MF_UMAAL] = 1'b1; end              // UMAAL
                7'b100_1000, 7'b100_1001, 7'b100_1010, 7'b100_1011: begin                          // SMLALxy
                  sub = {2'b00, `MK_SMLXY}; bp[`MF_SIGNED] = 1'b1; bp[`MF_ACC] = 1'b1; bp[`MF_N] = h2[5]; bp[`MF_M] = h2[4];
                end
                7'b100_1100, 7'b100_1101: begin                                                    // SMLALD
                  sub = {2'b00, `MK_SMLD}; bp[`MF_SIGNED] = 1'b1; bp[`MF_ACC] = 1'b1; bp[`MF_X] = h2[4];
                end
                7'b101_1100, 7'b101_1101: begin                                                    // SMLSLD
                  sub = {2'b00, `MK_SMLD}; bp[`MF_SIGNED] = 1'b1; bp[`MF_ACC] = 1'b1; bp[`MF_X] = h2[4]; bp[`MF_SUB] = 1'b1;
                end
                7'b001_1111, 7'b011_1111: begin                                                    // SDIV / UDIV
                  op = `OP_DIV; sub = {4'd0, ~h1[5]}; rd = h2[11:8]; rd2_we = 1'b0; bp = 10'd0;
                  if (h2[15:12] != 4'd15) undef = 1'b1;
                end
                default: undef = 1'b1;
              endcase
            end
            7'b1??????: begin
              decode_cp();
            end
            default: undef = 1'b1;
          endcase
        end
      endcase
    end

    if (undef) begin
      op = `OP_UNDEF; rd_we = 1'b0; rd2_we = 1'b0; setflags = 1'b0; mwb = 1'b0;
    end
    // fetch fault on any halfword of the instruction
    if (e0 || (is32 && e1)) begin
      op = `OP_IFAULT; rd_we = 1'b0; rd2_we = 1'b0; setflags = 1'b0; mwb = 1'b0; cond = 4'hE;
    end
  end

  // ---------------- coprocessor space: FPv4-SP on CP10 / CP11 ----------------
  task decode_cp;
    begin
      if (h2[11:9] != 3'b101 || h1[12] == 1'b1) begin
        op = `OP_NOCP;                                   // other coprocessors, *2 encodings
      end else if (h1[11:9] == 3'b110) begin
        // extension register load / store, 64-bit transfers: P U D W L = h1[8:4]
        if (h1[8:5] == 4'b0010) begin
          // VMOV between two core registers and two S registers or one D register
          op = `OP_FPMV;
          fn = h2[8] ? {dM[3:0], 1'b0} : sM;
          if (h2[8] && dM[4]) undef = 1'b1;              // D16..D31 do not exist
          fm = fn + 5'd1; fd = fn;
          if (h1[4]) begin   // to core: Rt = S[m], Rt2 = S[m+1]
            sub = {1'b0, `FMV_TOR2}; rd = h2[15:12]; rd_we = 1'b1; rd2 = h1[3:0]; rd2_we = 1'b1;
          end else begin     // to FP: S[m] = Rt, S[m+1] = Rt2
            sub = {1'b0, `FMV_TOS2}; rb = h2[15:12]; ra = h1[3:0];
          end
          if (h2[7:6] != 2'b00 || h2[4] != 1'b1) undef = 1'b1;
        end else begin
          op = `OP_FPLS; ra = h1[3:0]; rd2 = h1[3:0]; fload = h1[4];
          fd = h2[8] ? {dD[3:0], 1'b0} : sD;
          if (h2[8] && dD[4]) undef = 1'b1;
          if (h1[8] && !h1[5]) begin
            // VLDR / VSTR: one S or D register, [Rn, #+/-imm8 << 2]
            mpre = 1'b1; madd = h1[7]; mwb = 1'b0; use_imm = 1'b1; imm = {22'd0, h2[7:0], 2'b00};
            cnt = h2[8] ? 6'd2 : 6'd1;
            if (h1[3:0] == 4'd15) a_align = 1'b1;
          end else begin
            // VLDM / VSTM / VPUSH / VPOP: IA (P = 0, U = 1) or DB (P = 1, U = 0, W = 1)
            mpre = h1[8]; madd = h1[7]; mwb = h1[5];
            cnt = h2[5:0];                                // words (2 per D register)
            use_imm = 1'b1; imm = {22'd0, h2[7:0], 2'b00};
            if (h1[8] == h1[7]) undef = 1'b1;
            if (h1[8] && !h1[5]) undef = 1'b1;
            if (h2[7:0] == 8'd0 || h2[7:0] > 8'd32) undef = 1'b1;
            if (h2[8] && h2[0]) undef = 1'b1;          // FLDMX / FSTMX: not supported
          end
        end
      end else if (h1[11:8] == 4'b1110 && h2[4] == 1'b0) begin
        // FP data processing: opc1 = {h1[7], h1[5:4]}, op = h2[6]
        op = `OP_FPDP; fn = sN; fm = sM; fd = sD;
        if (h2[8]) undef = 1'b1;                        // double precision
        case ({h1[7], h1[5:4]})
          3'b000: sub = h2[6] ? `FOP_MLS : `FOP_MLA;
          3'b001: sub = h2[6] ? `FOP_NMLA : `FOP_NMLS;
          3'b010: sub = h2[6] ? `FOP_NMUL : `FOP_MUL;
          3'b011: sub = h2[6] ? `FOP_SUB : `FOP_ADD;
          3'b100: begin sub = `FOP_DIV; if (h2[6]) undef = 1'b1; end
          3'b101: sub = h2[6] ? `FOP_FNMA : `FOP_FNMS;
          3'b110: sub = h2[6] ? `FOP_FMS : `FOP_FMA;
          default: begin
            if (!h2[6]) begin
              op = `OP_FPMV; sub = {1'b0, `FMV_IMM}; imm = fimm;
              if (h2[7] || h2[5]) undef = 1'b1;
            end else begin
              casez ({h1[3:0], h2[7]})
                5'b0000_0: begin op = `OP_FPMV; sub = {1'b0, `FMV_REG}; end
                5'b0000_1: begin op = `OP_FPMV; sub = {1'b0, `FMV_ABS}; end
                5'b0001_0: begin op = `OP_FPMV; sub = {1'b0, `FMV_NEG}; end
                5'b0001_1: sub = `FOP_SQRT;
                5'b0010_?: begin sub = `FOP_H2F; imm = {31'd0, h2[7]}; end
                5'b0011_?: begin sub = `FOP_F2H; imm = {31'd0, h2[7]}; end
                5'b010?_?: begin
                  sub = `FOP_CMP; imm = {30'd0, h1[0], h2[7]};
                  if (h1[0] && (h2[5] || h2[3:0] != 4'd0)) undef = 1'b1;
                end
                5'b1000_?: begin   // VCVT.F32.S32 / U32 (op = h2[7]: 1 signed), FPSCR rounding
                  sub = `FOP_I2F; imm = {23'd0, 1'b0, 1'b0, ~h2[7], 6'd0};
                end
                5'b101?_?, 5'b111?_?: begin
                  // VCVT between floating point and fixed point (in place, Sd): op h1[2], U h1[0],
                  // sx h2[7] (32-bit), fbits = size - imm4:i
                  fm = sD; fn = sD;
                  // to fixed: round toward zero; to float: FPSCR rounding mode
                  sub = h1[2] ? `FOP_F2I : `FOP_I2F;
                  imm = {23'd0, h1[2], ~h2[7], h1[0], (h2[7] ? 6'd32 : 6'd16) - {1'b0, h2[3:0], h2[5]}};
                  if (!h2[7] && {h2[3:0], h2[5]} > 5'd16) undef = 1'b1;
                end
                5'b110?_?: begin   // VCVT(R).S32/U32.F32: signed = h1[0], round to zero = h2[7]
                  sub = `FOP_F2I; imm = {23'd0, h2[7], 1'b0, ~h1[0], 6'd0};
                end
                default: undef = 1'b1;
              endcase
            end
          end
        endcase
      end else if (h1[11:8] == 4'b1110 && h2[4] == 1'b1) begin
        // 8, 16 and 32-bit transfers between core and FP registers: L h1[4], C h2[8], A h1[7:5]
        op = `OP_FPMV;
        if (h2[8] == 1'b0 && h1[7:5] == 3'b000) begin
          fn = sN; fd = sN;
          if (h1[4]) begin sub = {1'b0, `FMV_TOR}; rd = h2[15:12]; rd_we = 1'b1; end   // VMOV Rt, Sn
          else       begin sub = {1'b0, `FMV_TOS}; rb = h2[15:12]; end                 // VMOV Sn, Rt
          if (h2[6:5] != 2'b00 || h2[3:0] != 4'd0) undef = 1'b1;
        end else if (h2[8] == 1'b0 && h1[7:5] == 3'b111) begin
          if (h1[3:0] != 4'b0001) undef = 1'b1;                                         // FPSCR only
          if (h1[4]) begin sub = {1'b0, `FMV_VMRS}; rd = h2[15:12]; rd_we = (h2[15:12] != 4'd15); end
          else       begin sub = {1'b0, `FMV_VMSR}; rb = h2[15:12]; end
        end else if (h2[8] == 1'b1 && h1[7:6] == 2'b00 && h2[6:5] == 2'b00) begin
          // VMOV.32 Dd[x], Rt / VMOV.32 Rt, Dn[x]: x = h1[5]
          fn = {dN[3:0], h1[5]}; fd = fn;
          if (dN[4]) undef = 1'b1;
          if (h1[4]) begin sub = {1'b0, `FMV_TOR}; rd = h2[15:12]; rd_we = 1'b1; end
          else       begin sub = {1'b0, `FMV_TOS}; rb = h2[15:12]; end
        end else undef = 1'b1;
      end else begin
        undef = 1'b1;                                   // CDP etc. on CP10 / CP11 not used by FPv4
      end
    end
  endtask

endmodule

`default_nettype wire
