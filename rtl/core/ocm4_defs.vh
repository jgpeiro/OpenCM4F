// ocm4_defs.vh - shared constants of the OpenCM4F core (micro-op classes and unit operations)
// SPDX-License-Identifier: MIT

// ---------------- micro-op classes (u_op) ----------------
`define OP_ALU    5'd0    // data processing through the ALU (and writes to PC with ADD/MOV hi)
`define OP_BIT    5'd1    // bit / DSP unit (u_sub = BIT_*)
`define OP_MUL    5'd2    // multiplier (u_sub = MK_*, flags in u_imm)
`define OP_DIV    5'd3    // SDIV / UDIV (u_sub[0] = signed)
`define OP_LD     5'd4    // single / dual / exclusive load
`define OP_ST     5'd5    // single / dual / exclusive store
`define OP_LDM    5'd6    // LDM, POP
`define OP_STM    5'd7    // STM, PUSH
`define OP_BR     5'd8    // B, B<c>, BL, CBZ, CBNZ (target = PC + imm)
`define OP_BX     5'd9    // BX, BLX (register)
`define OP_TB     5'd10   // TBB, TBH
`define OP_MRS    5'd11
`define OP_MSR    5'd12
`define OP_CPS    5'd13
`define OP_HINT   5'd14   // u_sub = HINT_*
`define OP_SVC    5'd15
`define OP_BKPT   5'd16
`define OP_UNDEF  5'd17   // UsageFault UNDEFINSTR
`define OP_IFAULT 5'd18   // instruction fetch bus error: BusFault IBUSERR
`define OP_FPDP   5'd19   // FPU arithmetic (u_sub = FOP_*)
`define OP_FPLS   5'd20   // VLDR, VSTR, VLDM, VSTM, VPUSH, VPOP
`define OP_FPMV   5'd21   // FP register moves (u_sub = FMV_*)
`define OP_NOCP   5'd22   // coprocessor other than CP10/CP11: UsageFault NOCP

// ---------------- ALU operations ----------------
`define ALU_AND 4'd0
`define ALU_EOR 4'd1
`define ALU_SUB 4'd2
`define ALU_RSB 4'd3
`define ALU_ADD 4'd4
`define ALU_ADC 4'd5
`define ALU_SBC 4'd6
`define ALU_ORN 4'd7
`define ALU_ORR 4'd8
`define ALU_MOV 4'd9
`define ALU_BIC 4'd10
`define ALU_MVN 4'd11

// ---------------- bit / DSP unit (u_sub) ----------------
`define BIT_MOVW   5'd0
`define BIT_MOVT   5'd1
`define BIT_BFI    5'd2    // imm[4:0] lsb, imm[9:5] msb; a = Rn (0 for BFC), c = Rd
`define BIT_UBFX   5'd3    // imm[4:0] lsb, imm[9:5] width-1
`define BIT_SBFX   5'd4
`define BIT_CLZ    5'd5
`define BIT_RBIT   5'd6
`define BIT_REV    5'd7
`define BIT_REV16  5'd8
`define BIT_REVSH  5'd9
`define BIT_EXT    5'd10   // imm[1:0] rot, imm[2] signed, imm[4:3] 0 byte 1 half 2 byte16; a = Rn or 0
`define BIT_SSAT   5'd11   // imm[4:0] saturate to imm+1 bits (signed); operand = shifted Rm
`define BIT_USAT   5'd12   // imm[4:0] saturate to imm bits (unsigned)
`define BIT_SSAT16 5'd13
`define BIT_USAT16 5'd14
`define BIT_PKH    5'd15   // imm[0] 1 = PKHTB
`define BIT_SEL    5'd16
`define BIT_PAR    5'd17   // parallel add/sub: imm[2:0] op, imm[5:3] prefix
`define BIT_QADD   5'd18   // imm[0] sub, imm[1] double
`define BIT_USAD   5'd19   // USAD8 / USADA8 (c = Ra, 0 for USAD8)

// parallel add/sub op (h1[6:4]) and prefix ({U, h2[5:4]})
`define PAR_ADD8  3'd0
`define PAR_ADD16 3'd1
`define PAR_ASX   3'd2
`define PAR_SUB8  3'd4
`define PAR_SUB16 3'd5
`define PAR_SAX   3'd6

// ---------------- multiplier kinds (u_sub) and flags (u_imm) ----------------
`define MK_MUL   3'd0   // 32 x 32 -> 32 (MUL, MLA, MLS)
`define MK_MULL  3'd1   // 32 x 32 -> 64 (SMULL, UMULL, SMLAL, UMLAL, UMAAL)
`define MK_SMLXY 3'd2   // 16 x 16 (SMULxy, SMLAxy, SMLALxy)
`define MK_SMLW  3'd3   // 32 x 16 -> top 32 (SMULWy, SMLAWy)
`define MK_SMLD  3'd4   // dual 16 x 16 (SMUAD, SMLAD, SMUSD, SMLSD, SMLALD, SMLSLD)
`define MK_SMMUL 3'd5   // 32 x 32 -> top 32 (SMMUL, SMMLA, SMMLS, R)
`define MF_ACC    0     // accumulate
`define MF_SUB    1     // subtract (MLS, SMLSD, SMMLS)
`define MF_X      2     // exchange halves of Rm
`define MF_N      3     // top half of Rn
`define MF_M      4     // top half of Rm
`define MF_ROUND  5
`define MF_LONG   6     // 64-bit result (RdLo, RdHi)
`define MF_SIGNED 7
`define MF_UMAAL  8
`define MF_SETNZ  9     // MULS (16-bit, outside IT): N and Z

// ---------------- hints (u_sub) ----------------
`define HINT_NOP   4'd0
`define HINT_YIELD 4'd1
`define HINT_WFE   4'd2
`define HINT_WFI   4'd3
`define HINT_SEV   4'd4
`define HINT_CLREX 4'd5
`define HINT_DSB   4'd6
`define HINT_DMB   4'd7
`define HINT_ISB   4'd8

// ---------------- FPU operations (u_sub for OP_FPDP) ----------------
`define FOP_ADD   5'd0
`define FOP_SUB   5'd1
`define FOP_MUL   5'd2
`define FOP_NMUL  5'd3
`define FOP_MLA   5'd4    // d + rnd(n*m)
`define FOP_MLS   5'd5    // d - rnd(n*m)
`define FOP_NMLA  5'd6    // -d - rnd(n*m)
`define FOP_NMLS  5'd7    // -d + rnd(n*m)
`define FOP_FMA   5'd8    // d + n*m
`define FOP_FMS   5'd9    // d + (-n)*m
`define FOP_FNMA  5'd10   // -d + (-n)*m
`define FOP_FNMS  5'd11   // -d + n*m
`define FOP_DIV   5'd12
`define FOP_SQRT  5'd13
`define FOP_CMP   5'd14   // imm[0] E (quiet NaN raises IOC), imm[1] compare with zero
`define FOP_F2I   5'd15   // float -> fixed: imm[5:0] fbits, imm[6] unsigned, imm[7] 16-bit, imm[8] round to zero
`define FOP_I2F   5'd16   // fixed -> float: imm[5:0] fbits, imm[6] unsigned, imm[7] 16-bit, imm[8] round to nearest (unused by VFP)
`define FOP_F2H   5'd17   // imm[0] top half
`define FOP_H2F   5'd18   // imm[0] top half

// ---------------- FP moves (u_sub for OP_FPMV) ----------------
`define FMV_TOS   4'd0    // S[fd] = Rt (b)
`define FMV_TOR   4'd1    // Rt = S[fn] (fa)
`define FMV_TOS2  4'd2    // S[fd] = Rt (b), S[fd+1] = Rt2 (a)
`define FMV_TOR2  4'd3    // Rt = S[fn] (fa), Rt2 = S[fn+1] (fb)
`define FMV_VMRS  4'd4    // Rt = FPSCR, Rt = 15: APSR.NZCV = FPSCR.NZCV
`define FMV_VMSR  4'd5    // FPSCR = Rt (b)
`define FMV_IMM   4'd6    // S[fd] = imm
`define FMV_REG   4'd7    // S[fd] = S[fm]
`define FMV_ABS   4'd8
`define FMV_NEG   4'd9

// ---------------- exception numbers ----------------
`define EXC_RESET     9'd1
`define EXC_NMI       9'd2
`define EXC_HARDFAULT 9'd3
`define EXC_MEMMANAGE 9'd4
`define EXC_BUSFAULT  9'd5
`define EXC_USAGE     9'd6
`define EXC_SVCALL    9'd11
`define EXC_DEBUGMON  9'd12
`define EXC_PENDSV    9'd14
`define EXC_SYSTICK   9'd15
