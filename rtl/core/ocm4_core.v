/*
 * ocm4_core - OpenCM4F processor core: ARMv7E-M (Thumb-2, DSP extension) with the FPv4-SP FPU
 * SPDX-License-Identifier: MIT
 *
 * Three stages:
 *   F  ocm4_fetch: AXI4-Lite instruction fetch into an eight-halfword queue
 *   D  ocm4_decode + register read with bypass from the write port: one micro-op per clock
 *   X  execute: ALU, shifter, bit / DSP unit, multiplier, divider, load / store sequencer, FPU,
 *      branches, special registers, exception entry and return; writes the register files
 * Branches resolve in X (the address of the target goes out on the bus in the same clock).
 *
 * Exceptions: NVIC with NUM_IRQ interrupts and PRIO_BITS priority bits (ocm4_scs), precise faults
 * (UsageFault, BusFault, HardFault escalation), SVCall, PendSV, SysTick, NMI; basic and extended
 * (FP) stack frames, 8-byte stack alignment, EXC_RETURN, two stack pointers, privilege levels.
 * Asynchronous exceptions are taken between instructions (LDM, STM, divisions finish first).
 */

`default_nettype none
`include "ocm4_defs.vh"

module ocm4_core #(
    parameter NUM_IRQ   = 16,
    parameter PRIO_BITS = 3
) (
    input  wire               clk,
    input  wire               rst_n,

    // instruction bus (AXI4-Lite, read only)
    output wire [31:0]        i_araddr,
    output wire [2:0]         i_arprot,
    output wire               i_arvalid,
    input  wire               i_arready,
    input  wire [31:0]        i_rdata,
    input  wire [1:0]         i_rresp,
    input  wire               i_rvalid,
    output wire               i_rready,

    // data bus (AXI4-Lite)
    output wire [31:0]        d_awaddr,
    output wire [2:0]         d_awprot,
    output wire               d_awvalid,
    input  wire               d_awready,
    output wire [31:0]        d_wdata,
    output wire [3:0]         d_wstrb,
    output wire               d_wvalid,
    input  wire               d_wready,
    input  wire [1:0]         d_bresp,
    input  wire               d_bvalid,
    output wire               d_bready,
    output wire [31:0]        d_araddr,
    output wire [2:0]         d_arprot,
    output wire               d_arvalid,
    input  wire               d_arready,
    input  wire [31:0]        d_rdata,
    input  wire [1:0]         d_rresp,
    input  wire               d_rvalid,
    output wire               d_rready,

    // interrupts and events
    input  wire [NUM_IRQ-1:0] irq,
    input  wire               nmi,
    input  wire               rxev,
    output reg                txev,

    // status
    input  wire               dbg_halt_on_bkpt,   // BKPT halts the core (as with a debugger attached)
    output wire               halted,
    output wire               lockup,
    output wire               sleeping,
    output wire               sysresetreq,

    // retirement trace (simulation and debug)
    output reg                trc_valid,
    output reg  [31:0]        trc_pc,
    output reg  [31:0]        trc_insn,
    output reg                trc_skip,           // condition failed
    output wire               trc_rf_we,
    output wire [3:0]         trc_rf_wa,          // physical: 13 MSP, 15 PSP
    output wire [31:0]        trc_rf_wd,
    output wire               trc_fp_we,
    output wire [4:0]         trc_fp_wa,
    output wire [31:0]        trc_fp_wd,
    output wire [31:0]        trc_xpsr,
    output wire [31:0]        trc_fpscr,
    output wire [2:0]         trc_control,

    // performance events (one clock each): [0] instruction retired, [1] fetch / branch bubble,
    // [2] load / store wait, [3] multiply / divide, [4] FPU, [5] exception entry / return, [6] sleep
    output reg  [6:0]         perf_ev
);

  // =====================================================================================
  // architectural state outside the register files
  // =====================================================================================
  reg         fN, fZ, fC, fV, fQ;
  reg  [3:0]  fGE;
  reg  [8:0]  ipsr;
  reg         epsr_t;
  reg         primask, faultmask;
  reg  [7:0]  basepri;
  reg         ctl_npriv, ctl_spsel, ctl_fpca;
  reg  [31:0] fpscr;
  reg         excl_mon;
  reg         event_reg;
  reg  [31:0] arch_npc;          // address of the next instruction to execute
  reg  [7:0]  arch_it;           // IT state of that instruction

  wire handler  = (ipsr != 9'd0);
  wire priv     = handler || !ctl_npriv;
  wire use_psp  = !handler && ctl_spsel;
  function [3:0] phys;
    input [3:0] r;
    input       psp;
    phys = (r == 4'd13 && psp) ? 4'd15 : r;
  endfunction

  // =====================================================================================
  // System Control Space
  // =====================================================================================
  wire        scs_acc, scs_wr, scs_priv;
  wire [19:0] scs_addr;
  wire [31:0] scs_wdata, scs_rdata;
  wire [3:0]  scs_wstrb;
  wire        scs_err;
  wire        exc_take;
  wire [8:0]  exc_take_num;
  wire        usg_can, bus_can, svc_can, hf_can, any_pending, ret_to_base;
  wire [31:0] vtor;
  wire        stkalign, div0_trp, unalign_trp, sleeponexit, sevonpend_ev;
  wire [3:0]  cpacr_fp;
  wire        fpccr_aspen, fpccr_lspen;
  wire [4:0]  fpdscr;
  reg         scs_activate, scs_deactivate;
  reg  [8:0]  scs_exc_num;
  reg  [31:0] cfsr_set;
  reg         hfsr_forced, hfsr_vecttbl, bfar_we;
  reg  [31:0] bfar_wd;
  wire        lsu_werr;
  reg         ev_cpi, ev_exc, ev_sleep, ev_lsu;

  ocm4_scs #(.NUM_IRQ(NUM_IRQ), .PRIO_BITS(PRIO_BITS)) u_scs (
      .clk(clk), .rst_n(rst_n),
      .acc(scs_acc), .wr(scs_wr), .addr(scs_addr), .wdata(scs_wdata), .wstrb(scs_wstrb), .priv(scs_priv),
      .rdata(scs_rdata), .err(scs_err),
      .irq(irq), .nmi(nmi),
      .ipsr(ipsr), .primask(primask), .faultmask(faultmask), .basepri(basepri),
      .exc_activate(scs_activate), .exc_deactivate(scs_deactivate), .exc_num(scs_exc_num),
      .pend_imprecise(lsu_werr), .cfsr_set(cfsr_set), .hfsr_forced(hfsr_forced), .hfsr_vecttbl(hfsr_vecttbl),
      .bfar_we(bfar_we), .bfar_wd(bfar_wd),
      .take(exc_take), .take_num(exc_take_num),
      .usg_can(usg_can), .bus_can(bus_can), .svc_can(svc_can), .hf_can(hf_can),
      .any_pending(any_pending), .ret_to_base(ret_to_base), .vtor(vtor), .stkalign(stkalign),
      .div0_trp(div0_trp), .unalign_trp(unalign_trp), .sleeponexit(sleeponexit), .sevonpend_ev(sevonpend_ev),
      .cpacr_fp(cpacr_fp), .fpccr_aspen(fpccr_aspen), .fpccr_lspen(fpccr_lspen), .fpdscr(fpdscr),
      .sysresetreq(sysresetreq),
      .ev_cpi(ev_cpi), .ev_exc(ev_exc), .ev_sleep(ev_sleep), .ev_lsu(ev_lsu), .ev_fold(1'b0), .halted(halted));

  // =====================================================================================
  // F: fetch
  // =====================================================================================
  reg         redir;
  reg  [31:0] redir_pc;
  wire [15:0] q_h0, q_h1;
  wire        q_v0, q_v1, q_e0, q_e1;
  wire [31:0] q_pc;
  wire [1:0]  consume;
  reg         fetch_en;

  ocm4_fetch u_fetch (
      .clk(clk), .rst_n(rst_n),
      .araddr(i_araddr), .arprot(i_arprot), .arvalid(i_arvalid), .arready(i_arready),
      .rdata(i_rdata), .rresp(i_rresp), .rvalid(i_rvalid), .rready(i_rready),
      .priv(priv), .enable(fetch_en), .redir(redir), .redir_pc(redir_pc),
      .hw0(q_h0), .hw1(q_h1), .v0(q_v0), .v1(q_v1), .e0(q_e0), .e1(q_e1), .pc0(q_pc), .consume(consume));

  // =====================================================================================
  // D: decode, register read
  // =====================================================================================
  reg  [7:0]  d_it;               // IT state of the instruction at the head of the queue
  wire        dv, d32;
  wire [4:0]  dop, dsub;
  wire [3:0]  daluop, dra, drb, drc, drd, drd2, dcond;
  wire        da_align, da_zero, duse_imm, dimm_c, dimm_cv, dsh_rrx, dsh_reg, dsetflags, drd_we, drd2_we;
  wire [31:0] dimm;
  wire [1:0]  dsh_typ, dmsize;
  wire [7:0]  dsh_amt, dit_next;
  wire [9:0]  dbp;
  wire        dmsign, dmpre, dmadd, dmwb, dmunpriv, dmexcl, dfload;
  wire [5:0]  dcnt;
  wire [4:0]  dfn, dfm, dfd;

  ocm4_decode u_dec (
      .h1(q_h0), .h2(q_h1), .v0(q_v0), .v1(q_v1), .e0(q_e0), .e1(q_e1), .itstate(d_it),
      .dvalid(dv), .is32(d32), .op(dop), .sub(dsub), .aluop(daluop), .ra(dra), .rb(drb), .rc(drc),
      .a_align(da_align), .a_zero(da_zero), .use_imm(duse_imm), .imm(dimm), .imm_c(dimm_c), .imm_cv(dimm_cv),
      .sh_typ(dsh_typ), .sh_amt(dsh_amt), .sh_rrx(dsh_rrx), .sh_reg(dsh_reg), .setflags(dsetflags),
      .rd(drd), .rd_we(drd_we), .rd2(drd2), .rd2_we(drd2_we), .cond(dcond), .bp(dbp),
      .msize(dmsize), .msign(dmsign), .mpre(dmpre), .madd(dmadd), .mwb(dmwb), .munpriv(dmunpriv), .mexcl(dmexcl),
      .cnt(dcnt), .fn(dfn), .fm(dfm), .fd(dfd), .fload(dfload), .it_next(dit_next));

  // register files
  reg         rf_we;
  reg  [3:0]  rf_wa;
  reg  [31:0] rf_wd;
  reg  [4:0]  rf_ws;               // what rf_wd carries (WS_*), set by the execute control
  localparam WS_ZERO = 5'd0, WS_ALU = 5'd1, WS_BIT = 5'd2, WS_MULLO = 5'd3, WS_MULHI = 5'd4, WS_DIV = 5'd5,
             WS_LINK = 5'd6, WS_ONE = 5'd7, WS_WB = 5'd8, WS_A = 5'd9, WS_LD = 5'd10, WS_LMWB = 5'd11,
             WS_MRS = 5'd12, WS_FA = 5'd13, WS_FB = 5'd14, WS_FPSCR = 5'd15, WS_MSBASE = 5'd16,
             WS_EXCRET = 5'd17, WS_RETSP = 5'd18;
  reg  [3:0]  rf_xa;
  wire [31:0] rf_a, rf_b, rf_c, rf_x;
  wire [3:0]  pa = phys(dra, use_psp), pb_ = phys(drb, use_psp), pc_ = phys(drc, use_psp);
  // SP[1:0] are zero: writes to MSP / PSP clear them
  wire [31:0] rf_wdm = (rf_wa == 4'd13 || rf_wa == 4'd15) ? {rf_wd[31:2], 2'b00} : rf_wd;
  ocm4_regfile #(.AW(4)) u_rf (
      .clk(clk), .we(rf_we), .wa(rf_wa), .wd(rf_wdm),
      .ra0(pa), .ra1(pb_), .ra2(pc_), .ra3(rf_xa), .rd0(rf_a), .rd1(rf_b), .rd2(rf_c), .rd3(rf_x));

  reg         fp_we;
  reg  [4:0]  fp_wa;
  reg  [31:0] fp_wd;
  reg  [3:0]  fp_ws;                // what fp_wd carries (FS_*)
  localparam FS_ZERO = 4'd0, FS_FPU = 4'd1, FS_B = 4'd2, FS_A = 4'd3, FS_IMM = 4'd4, FS_FB = 4'd5, FS_ABS = 4'd6,
             FS_NEG = 4'd7, FS_LD = 4'd8;
  reg  [4:0]  fp_xa;
  wire [31:0] fr_a, fr_b, fr_x;
  // S[d] is read in the execute stage (port 3, fp_xa = x_fd by default): the FPU's third operand
  ocm4_regfile #(.AW(5)) u_fp (
      .clk(clk), .we(fp_we), .wa(fp_wa), .wd(fp_wd),
      .ra0(dfn), .ra1(dfm), .ra2(5'd0), .ra3(fp_xa), .rd0(fr_a), .rd1(fr_b), .rd2(), .rd3(fr_x));

  wire [31:0] pc4  = q_pc + 32'd4;
  wire [31:0] pc4a = {pc4[31:2], 2'b00};
  wire [31:0] va = da_zero ? 32'd0 : (dra == 4'd15) ? (da_align ? pc4a : pc4) :
                   (rf_we && rf_wa == pa) ? rf_wdm : rf_a;
  wire [31:0] vb = (drb == 4'd15) ? pc4 : (rf_we && rf_wa == pb_) ? rf_wdm : rf_b;
  wire [31:0] vc = (drc == 4'd15) ? pc4 : (rf_we && rf_wa == pc_) ? rf_wdm : rf_c;
  wire [31:0] wfa = (fp_we && fp_wa == dfn) ? fp_wd : fr_a;
  wire [31:0] wfb = (fp_we && fp_wa == dfm) ? fp_wd : fr_b;

  // =====================================================================================
  // X: execute stage registers
  // =====================================================================================
  reg         x_valid;
  reg  [4:0]  x_op, x_sub;
  reg  [3:0]  x_aluop, x_cond, x_ra, x_rb, x_rc, x_rd, x_rd2;
  reg         x_use_imm, x_imm_c, x_imm_cv, x_sh_rrx, x_sh_reg, x_setflags, x_rd_we, x_rd2_we;
  reg  [31:0] x_imm, x_a, x_b, x_c, x_fa, x_fb, x_pc, x_insn;
  reg  [1:0]  x_sh_typ, x_msize;
  reg  [7:0]  x_sh_amt, x_it_cur, x_it_next;
  reg  [9:0]  x_bp;
  reg         x_msign, x_mpre, x_madd, x_mwb, x_munpriv, x_mexcl, x_fload, x_len32;
  reg  [5:0]  x_cnt;
  reg  [4:0]  x_fn, x_fm, x_fd;

  // execute FSM
  localparam XS_RESET = 4'd0, XS_RUN = 4'd1, XS_EXC = 4'd2, XS_RET = 4'd3, XS_SLEEP = 4'd4,
             XS_HALT = 4'd5, XS_LOCK = 4'd6;
  reg  [3:0]  xs;
  reg  [4:0]  step;
  reg         fpchk_done;      // ExecuteFPCheck done for the instruction in X

  // memory sequencer
  reg  [5:0]  ms_req, ms_rsp;  // requests issued, responses seen
  reg  [31:0] ms_base;
  reg  [15:0] ms_lreq, ms_lrsp;
  reg         ms_wbdone;       // base writeback done
  reg         ms_err;          // a response had a bus error
  reg  [31:0] ms_tmp;          // loaded value kept for later (TBB / vector / PC)

  // exception entry / return
  reg  [8:0]  ex_num;
  reg  [31:0] ex_ret;          // return address
  reg  [7:0]  ex_it;           // IT state at the return address
  reg  [31:0] ex_fp;           // frame pointer
  reg         ex_ext;          // extended (FP) frame
  reg         ex_align;        // stack was realigned (xPSR[9])
  reg         ex_psp;          // frame on the process stack
  reg         ex_thread;       // exception return: back to thread mode
  reg  [31:0] ex_xpsr;         // popped xPSR
  reg  [31:0] ex_excret;
  reg  [5:0]  ex_n;            // words in the frame
  reg         ex_fault_in_entry;

  // =====================================================================================
  // X: combinational execution
  // =====================================================================================
  // condition
  reg cond_pass;
  always @* begin
    case (x_cond)
      4'h0: cond_pass = fZ;
      4'h1: cond_pass = !fZ;
      4'h2: cond_pass = fC;
      4'h3: cond_pass = !fC;
      4'h4: cond_pass = fN;
      4'h5: cond_pass = !fN;
      4'h6: cond_pass = fV;
      4'h7: cond_pass = !fV;
      4'h8: cond_pass = fC && !fZ;
      4'h9: cond_pass = !fC || fZ;
      4'hA: cond_pass = (fN == fV);
      4'hB: cond_pass = (fN != fV);
      4'hC: cond_pass = !fZ && (fN == fV);
      4'hD: cond_pass = fZ || (fN != fV);
      default: cond_pass = 1'b1;
    endcase
  end

  // shifter, ALU, bit unit
  wire [31:0] sh_res;
  wire        sh_c;
  ocm4_shifter u_sh (.v(x_b), .typ(x_sh_typ), .amt(x_sh_reg ? x_c[7:0] : x_sh_amt), .rrx(x_sh_rrx), .cin(fC),
                     .res(sh_res), .cout(sh_c));
  wire [31:0] op2   = x_use_imm ? x_imm : sh_res;
  wire        op2_c = x_use_imm ? (x_imm_cv ? x_imm_c : fC) : sh_c;
  wire [31:0] alu_res;
  wire        alu_n, alu_z, alu_c, alu_v;
  ocm4_alu u_alu (.op(x_aluop), .a(x_a), .b(op2), .cin(fC), .sh_c(op2_c), .res(alu_res), .n(alu_n), .z(alu_z),
                  .c(alu_c), .v(alu_v));
  wire alu_arith = (x_aluop == `ALU_SUB) || (x_aluop == `ALU_RSB) || (x_aluop == `ALU_ADD) ||
                   (x_aluop == `ALU_ADC) || (x_aluop == `ALU_SBC);
  wire [31:0] bit_res;
  wire [3:0]  bit_ge;
  wire        bit_ge_we, bit_q;
  ocm4_bitops u_bit (.sub(x_sub), .imm(x_bp), .a(x_a), .b(x_b), .sh(sh_res), .c(x_c),
                     .ge(fGE), .res(bit_res), .ge_out(bit_ge), .ge_we(bit_ge_we), .q_set(bit_q));

  // multiplier, divider
  reg         mul_start, div_start;
  wire [31:0] mul_lo, mul_hi;
  wire        mul_q;
  ocm4_mul u_mul (.clk(clk), .start(mul_start), .kind(x_sub[2:0]), .fl(x_bp), .a(x_a), .b(x_b), .c(x_c), .d(rf_x),
                  .lo(mul_lo), .hi(mul_hi), .q_set(mul_q));
  wire        div_done;
  wire [31:0] div_q;
  ocm4_div u_div (.clk(clk), .rst_n(rst_n), .start(div_start), .sgn(x_sub[0]), .n(x_a), .d(x_b),
                  .done(div_done), .q(div_q));

  // FPU
  reg         fpu_start;
  wire        fpu_busy, fpu_done, fpu_cmp;
  wire [31:0] fpu_res;
  wire [7:0]  fpu_flags;
  wire [3:0]  fpu_nzcv;
  ocm4_fpu u_fpu (.clk(clk), .rst_n(rst_n), .start(fpu_start), .op(x_sub), .prm(x_imm[8:0]),
                  .a(x_fa), .b(x_fb), .c(fr_x), .ctl(fpscr[26:22]), .busy(fpu_busy), .done(fpu_done),
                  .res(fpu_res), .flags(fpu_flags), .nzcv(fpu_nzcv), .is_cmp(fpu_cmp));

  // load / store unit
  reg         lsu_req, lsu_wr, lsu_sign;
  reg  [31:0] lsu_addr, lsu_wdata;
  reg  [1:0]  lsu_as;               // address source (LA_*)
  reg  [3:0]  lsu_ws;               // store data source (LW_*)
  localparam LA_M = 2'd0, LA_SEQ = 2'd1, LA_VEC = 2'd2, LA_RST = 2'd3;
  localparam LW_ZERO = 4'd0, LW_C = 4'd1, LW_B = 4'd2, LW_PC4 = 4'd3, LW_RFX = 4'd4, LW_FRX = 4'd5, LW_RET = 4'd6,
             LW_XPSR = 4'd7, LW_FPSCR = 4'd8;
  reg  [1:0]  lsu_size;
  reg         lsu_priv;
  wire        lsu_ack, lsu_rvalid, lsu_rerr, lsu_idle;
  wire [31:0] lsu_rdata;
  ocm4_lsu u_lsu (
      .clk(clk), .rst_n(rst_n), .req(lsu_req), .wr(lsu_wr), .addr(lsu_addr), .size(lsu_size), .sign(lsu_sign),
      .wdata(lsu_wdata), .priv(lsu_priv), .ack(lsu_ack), .rvalid(lsu_rvalid), .rdata(lsu_rdata), .rerr(lsu_rerr),
      .werr(lsu_werr), .idle(lsu_idle),
      .m_awaddr(d_awaddr), .m_awprot(d_awprot), .m_awvalid(d_awvalid), .m_awready(d_awready),
      .m_wdata(d_wdata), .m_wstrb(d_wstrb), .m_wvalid(d_wvalid), .m_wready(d_wready),
      .m_bresp(d_bresp), .m_bvalid(d_bvalid), .m_bready(d_bready),
      .m_araddr(d_araddr), .m_arprot(d_arprot), .m_arvalid(d_arvalid), .m_arready(d_arready),
      .m_rdata(d_rdata), .m_rresp(d_rresp), .m_rvalid(d_rvalid), .m_rready(d_rready),
      .scs_acc(scs_acc), .scs_wr(scs_wr), .scs_addr(scs_addr), .scs_wdata(scs_wdata), .scs_wstrb(scs_wstrb),
      .scs_priv(scs_priv), .scs_rdata(scs_rdata), .scs_err(scs_err));

  // --- addresses ---
  wire [31:0] m_off    = x_use_imm ? x_imm : (x_b << x_sh_amt[1:0]);
  wire [31:0] m_offadr = x_a + (x_madd ? m_off : ~m_off) + {31'd0, !x_madd};
  wire [31:0] m_addr   = x_mpre ? m_offadr : x_a;
  wire [31:0] lm_bytes = {24'd0, x_cnt, 2'b00};
  wire [31:0] lm_wb    = x_a + (x_madd ? lm_bytes : ~lm_bytes) + {31'd0, !x_madd};
  wire [31:0] lm_start = x_mpre ? lm_wb : x_a;                                    // DB: base - 4n
  wire [31:0] seq_addr = ms_base + {24'd0, ms_req, 2'b00};                         // LDM STM VLDM frames

  // lowest set bit of a register list
  function [3:0] lowbit(input [15:0] l);
    integer k;
    reg f;
    begin
      lowbit = 4'd0; f = 1'b0;
      for (k = 0; k < 16; k = k + 1)
        if (!f && l[k]) begin lowbit = k[3:0]; f = 1'b1; end
    end
  endfunction
  wire [3:0] lreq_r = lowbit(ms_lreq);
  wire [3:0] lrsp_r = lowbit(ms_lrsp);

  // xPSR images
  wire [31:0] apsr_v = {fN, fZ, fC, fV, fQ, 7'd0, fGE, 16'd0};
  // stacked xPSR: IT state ex_it, T = 1, realignment flag
  wire [31:0] xpsr_stack = {fN, fZ, fC, fV, fQ, ex_it[1:0], epsr_t, 4'd0, fGE, ex_it[7:2], ex_align, ipsr};

  // FP access (CPACR CP10 / CP11) and the FP checks
  wire fp_access = (cpacr_fp[1:0] == 2'b11) || (cpacr_fp[1:0] == 2'b01 && priv);
  wire is_fp_op  = (x_op == `OP_FPDP) || (x_op == `OP_FPLS) || (x_op == `OP_FPMV);

  // EXC_RETURN check for writes of PC in handler mode
  function is_excret(input [31:0] v);
    is_excret = (v[31:28] == 4'hF);
  endfunction

  // =====================================================================================
  // X: actions of this clock
  // =====================================================================================
  reg         x_done;              // instruction leaves X this clock (normally)
  reg         x_branch;            // ... and execution continues at x_target
  reg  [31:0] x_target;
  reg         x_bx;                // interworking branch (bit 0 = T)
  reg         x_serial;            // ... continue at the next instruction, refetched
  reg         x_fault;             // synchronous exception this clock
  reg  [8:0]  x_fault_num;
  reg  [31:0] x_fault_ret;
  reg  [7:0]  x_fault_it;
  reg  [31:0] x_cfsr;
  reg  [31:0] x_bfar;              // address of a precise BusFault
  reg         x_hf_forced;
  reg         x_excret;            // exception return starts (value x_target)
  reg         x_sleep, x_halt;
  reg         set_nz, set_c, set_v, set_q, set_ge;
  reg         n_n, n_z, n_c, n_v, n_q;
  reg  [3:0]  n_ge;
  reg         wr_fpscr;
  reg  [31:0] n_fpscr;
  reg         wr_spec;             // MSR / CPS / FP check: special register update (see below)
  reg  [5:0]  step_n;
  reg         ms_start;            // initialise the memory sequencer
  reg  [31:0] ms_start_base;
  reg  [15:0] ms_start_list;
  reg         ms_issue, ms_resp;   // a request was acknowledged / a response consumed
  reg         excl_set, excl_clr;
  reg         ev_set, ev_clr;
  reg         fpchk;               // ExecuteFPCheck update this clock

  // fault helper: UsageFault with escalation
  task usage_fault(input [4:0] bitn);
    begin
      x_fault = 1'b1;
      x_cfsr = 32'd1 << (16 + bitn);
      if (usg_can) x_fault_num = `EXC_USAGE;
      else begin x_fault_num = `EXC_HARDFAULT; x_hf_forced = 1'b1; end
      x_fault_ret = x_pc; x_fault_it = x_it_cur;
    end
  endtask
  task bus_fault(input [31:0] adr);
    begin
      x_fault = 1'b1;
      x_bfar = adr;
      x_cfsr = 32'h0000_8200;              // BFARVALID, PRECISERR
      if (bus_can) x_fault_num = `EXC_BUSFAULT;
      else begin x_fault_num = `EXC_HARDFAULT; x_hf_forced = 1'b1; end
      x_fault_ret = x_pc; x_fault_it = x_it_cur;
    end
  endtask

  // load result handling shared by single loads and LDM: writes PC as an interworking branch
  wire [31:0] ld_val = lsu_rdata;

  // which special register MSR writes (decoded here, applied in the clocked block)
  wire [7:0]  sysm = x_imm[7:0];

  always @* begin
    x_done = 1'b0; x_branch = 1'b0; x_target = 32'd0; x_bx = 1'b0; x_serial = 1'b0;
    x_fault = 1'b0; x_fault_num = `EXC_HARDFAULT; x_fault_ret = x_pc; x_fault_it = x_it_cur; x_cfsr = 32'd0;
    x_bfar = 32'd0;
    x_hf_forced = 1'b0; x_excret = 1'b0; x_sleep = 1'b0; x_halt = 1'b0;
    set_nz = 1'b0; set_c = 1'b0; set_v = 1'b0; set_q = 1'b0; set_ge = 1'b0;
    n_n = fN; n_z = fZ; n_c = fC; n_v = fV; n_q = 1'b1; n_ge = fGE;
    wr_fpscr = 1'b0; n_fpscr = fpscr; wr_spec = 1'b0;
    step_n = step + 5'd1;
    rf_we = 1'b0; rf_wa = 4'd0; rf_ws = WS_ZERO; rf_xa = 4'd0;
    fp_we = 1'b0; fp_wa = 5'd0; fp_ws = FS_ZERO; fp_xa = x_fd;
    lsu_req = 1'b0; lsu_wr = 1'b0; lsu_as = LA_M; lsu_size = 2'd2; lsu_sign = 1'b0; lsu_ws = LW_ZERO;
    lsu_priv = priv;
    mul_start = 1'b0; div_start = 1'b0; fpu_start = 1'b0;
    ms_start = 1'b0; ms_start_base = 32'd0; ms_start_list = 16'd0; ms_issue = 1'b0; ms_resp = 1'b0;
    excl_set = 1'b0; excl_clr = 1'b0; ev_set = 1'b0; ev_clr = 1'b0; fpchk = 1'b0;

    if (xs == XS_RUN && x_valid) begin
      if (step == 5'd0 && !epsr_t) begin
        // executing with T = 0: INVSTATE
        usage_fault(5'd1);
      end else if (x_op == `OP_IFAULT) begin
        x_fault = 1'b1; x_cfsr = 32'h0000_0100;                         // IBUSERR
        if (bus_can) x_fault_num = `EXC_BUSFAULT; else begin x_fault_num = `EXC_HARDFAULT; x_hf_forced = 1'b1; end
      end else if (!cond_pass && x_op != `OP_BKPT) begin
        x_done = 1'b1;                                                    // condition failed: no effect
      end else if (is_fp_op && step == 5'd0 && !fp_access) begin
        usage_fault(5'd3);                                                // NOCP
      end else if (is_fp_op && !fpchk_done && fpccr_aspen && !ctl_fpca) begin
        fpchk = 1'b1;                                                     // ExecuteFPCheck: one clock
        step_n = step;
      end else begin
        case (x_op)
          // -------------------------------------------------------------------------
          `OP_ALU: begin
            x_done = 1'b1;
            if (x_rd_we) begin
              if (x_rd == 4'd15) begin
                x_branch = 1'b1; x_target = {alu_res[31:1], 1'b0};      // ALUWritePC = BranchWritePC
              end else begin
                rf_we = 1'b1; rf_wa = phys(x_rd, use_psp); rf_ws = WS_ALU;
              end
            end
            if (x_setflags) begin
              set_nz = 1'b1; n_n = alu_n; n_z = alu_z;
              set_c = 1'b1; n_c = alu_c;
              if (alu_arith) begin set_v = 1'b1; n_v = alu_v; end
            end
          end
          // -------------------------------------------------------------------------
          `OP_BIT: begin
            x_done = 1'b1;
            rf_we = x_rd_we; rf_wa = phys(x_rd, use_psp); rf_ws = WS_BIT;
            if (bit_ge_we) begin set_ge = 1'b1; n_ge = bit_ge; end
            if (bit_q) set_q = 1'b1;
          end
          // -------------------------------------------------------------------------
          `OP_MUL: begin
            rf_xa = phys(x_rd2, use_psp);                                 // RdHi for the accumulation
            if (step == 5'd0) begin
              mul_start = 1'b1;
            end else if (step == 5'd1) begin
              rf_we = 1'b1; rf_wa = phys(x_rd, use_psp); rf_ws = WS_MULLO;
              if (mul_q) set_q = 1'b1;
              if (x_bp[`MF_SETNZ]) begin set_nz = 1'b1; n_n = mul_lo[31]; n_z = (mul_lo == 32'd0); end
              if (!x_bp[`MF_LONG]) x_done = 1'b1;
            end else begin
              rf_we = 1'b1; rf_wa = phys(x_rd2, use_psp); rf_ws = WS_MULHI;
              x_done = 1'b1;
            end
          end
          // -------------------------------------------------------------------------
          `OP_DIV: begin
            if (step == 5'd0) begin
              if (x_b == 32'd0 && div0_trp) usage_fault(5'd9);            // DIVBYZERO
              else div_start = 1'b1;
            end else begin
              step_n = 5'd1;
              if (div_done) begin
                rf_we = 1'b1; rf_wa = phys(x_rd, use_psp); rf_ws = WS_DIV;
                x_done = 1'b1;
              end
            end
          end
          // -------------------------------------------------------------------------
          `OP_BR: begin
            x_done = 1'b1;
            if (x_sub[1:0] == 2'd0 || (x_sub[1:0] == 2'd1 && x_a == 32'd0) || (x_sub[1:0] == 2'd2 && x_a != 32'd0)) begin
              x_branch = 1'b1; x_target = x_pc + 32'd4 + x_imm;
            end
            if (x_rd_we) begin                                            // BL
              rf_we = 1'b1; rf_wa = 4'd14; rf_ws = WS_LINK;
            end
          end
          `OP_BX: begin
            x_done = 1'b1;
            if (handler && is_excret(x_b)) begin
              x_excret = 1'b1; x_target = x_b;
            end else begin
              x_branch = 1'b1; x_bx = 1'b1; x_target = x_b;
            end
            if (x_rd_we) begin                                            // BLX
              rf_we = 1'b1; rf_wa = 4'd14; rf_ws = WS_LINK;
            end
          end
          // -------------------------------------------------------------------------
          `OP_LD, `OP_ST, `OP_TB: begin
            // single, dual and exclusive loads and stores, table branches
            begin : ldst
              reg [31:0] adr;
              reg        two;
              reg        misal;
              two = (x_msize == 2'd3);
              adr = m_addr;                                                // TBB / TBH: Rn + Rm (LSL 1)
              misal = (x_msize == 2'd3 || x_mexcl) ?
                        ((x_msize == 2'd1 && adr[0]) || ((x_msize == 2'd2 || x_msize == 2'd3) && adr[1:0] != 2'b00)) :
                        (unalign_trp && ((x_msize == 2'd1 && adr[0]) || (x_msize == 2'd2 && adr[1:0] != 2'b00)));
              if (x_op == `OP_TB) misal = (x_sub[0] && adr[0] && unalign_trp);
              if (step == 5'd0 && misal) begin
                usage_fault(5'd8);                                        // UNALIGNED
              end else if (x_op == `OP_ST && x_mexcl && step == 5'd0 && !excl_mon) begin
                // STREX without the monitor: status 1, no store
                rf_we = 1'b1; rf_wa = phys(x_rd, use_psp); rf_ws = WS_ONE;
                x_done = 1'b1;
              end else begin
                step_n = step;
                // requests
                if (ms_req < (two ? 6'd2 : 6'd1)) begin
                  lsu_req = 1'b1;
                  lsu_wr = (x_op == `OP_ST);
                  lsu_as = LA_M;
                  lsu_size = (x_op == `OP_TB) ? {1'b0, x_sub[0]} : (two ? 2'd2 : x_msize);
                  lsu_sign = x_msign;
                  lsu_ws = (two && ms_req[0]) ? LW_B : LW_C;
                  lsu_priv = priv && !x_munpriv;
                  if (lsu_ack) ms_issue = 1'b1;
                  // base writeback in the clock of the first request
                  if (lsu_ack && ms_req == 6'd0 && x_mwb) begin
                    rf_we = 1'b1; rf_wa = phys(x_rd2, use_psp); rf_ws = WS_WB;
                  end
                end
                if (x_op == `OP_ST) begin
                  if (lsu_ack && ms_req == (two ? 6'd1 : 6'd0)) begin
                    x_done = 1'b1;
                    if (x_mexcl) begin
                      excl_clr = 1'b1;
                      rf_we = 1'b1; rf_wa = phys(x_rd, use_psp); rf_ws = WS_ZERO;
                    end
                  end
                end else if (lsu_rvalid) begin
                  ms_resp = 1'b1;
                  if (lsu_rerr) begin
                    bus_fault(adr + ((two && ms_rsp[0]) ? 32'd4 : 32'd0));
                    if (ms_wbdone) begin rf_we = 1'b1; rf_wa = phys(x_rd2, use_psp); rf_ws = WS_A; end   // restore base
                  end else if (x_op == `OP_TB) begin
                    x_done = 1'b1; x_branch = 1'b1;
                    x_target = x_pc + 32'd4 + {ld_val[30:0], 1'b0};
                  end else if (two && ms_rsp == 6'd0) begin
                    rf_we = 1'b1; rf_wa = phys(x_rd, use_psp); rf_ws = WS_LD;
                  end else begin
                    x_done = 1'b1;
                    if (x_mexcl) excl_set = 1'b1;
                    if ((two ? x_rb : x_rd) == 4'd15) begin
                      // LoadWritePC
                      if (handler && is_excret(ld_val)) begin x_excret = 1'b1; x_target = ld_val; end
                      else begin x_branch = 1'b1; x_bx = 1'b1; x_target = ld_val; end
                    end else begin
                      rf_we = 1'b1; rf_wa = phys(two ? x_rb : x_rd, use_psp); rf_ws = WS_LD;
                    end
                  end
                end
              end
            end
          end
          // -------------------------------------------------------------------------
          `OP_LDM, `OP_STM: begin
            if (step == 5'd0 && x_a[1:0] != 2'b00) usage_fault(5'd8);
            else if (step == 5'd0) begin
              // set up: list in ms_lreq / ms_lrsp, start address
              ms_start = 1'b1; ms_start_base = lm_start; ms_start_list = x_imm[15:0];
              if (x_cnt == 6'd0) x_done = 1'b1;
            end else begin
              step_n = step;
              rf_xa = phys(lreq_r, use_psp);
              if (ms_lreq != 16'd0) begin
                lsu_req = 1'b1;
                lsu_wr = (x_op == `OP_STM);
                lsu_as = LA_SEQ;
                lsu_size = 2'd2;
                lsu_ws = (lreq_r == 4'd15) ? LW_PC4 : LW_RFX;
                if (lsu_ack) ms_issue = 1'b1;
                if (lsu_ack && ms_req == 6'd0 && x_mwb) begin
                  rf_we = 1'b1; rf_wa = phys(x_rd2, use_psp); rf_ws = WS_LMWB;
                end
              end
              if (x_op == `OP_STM) begin
                if (lsu_ack && ms_req + 6'd1 == x_cnt) x_done = 1'b1;
              end else if (lsu_rvalid) begin
                ms_resp = 1'b1;
                if (lsu_rerr) begin
                  bus_fault(ms_base + {24'd0, ms_rsp, 2'b00});
                  if (ms_wbdone) begin rf_we = 1'b1; rf_wa = phys(x_rd2, use_psp); rf_ws = WS_A; end
                end else if (lrsp_r == 4'd15) begin
                  x_done = 1'b1;
                  if (handler && is_excret(ld_val)) begin x_excret = 1'b1; x_target = ld_val; end
                  else begin x_branch = 1'b1; x_bx = 1'b1; x_target = ld_val; end
                end else begin
                  rf_we = 1'b1; rf_wa = phys(lrsp_r, use_psp); rf_ws = WS_LD;
                  if (ms_rsp + 6'd1 == x_cnt) x_done = 1'b1;
                end
              end
            end
          end
          // -------------------------------------------------------------------------
          `OP_MRS: begin
            x_done = 1'b1;
            rf_we = 1'b1; rf_wa = phys(x_rd, use_psp);
            rf_ws = WS_MRS;
            rf_xa = (sysm[2:0] == 3'd0) ? 4'd13 : 4'd15;                  // MSP / PSP
          end
          `OP_MSR: begin
            x_done = 1'b1;
            wr_spec = 1'b1;
            if (sysm[7:3] == 5'd0) begin
              if (x_imm[11]) begin set_nz = 1'b1; set_c = 1'b1; set_v = 1'b1; set_q = 1'b1;
                                   n_n = x_a[31]; n_z = x_a[30]; n_c = x_a[29]; n_v = x_a[28]; n_q = x_a[27]; end
              if (x_imm[10]) begin set_ge = 1'b1; n_ge = x_a[19:16]; end
            end else if (priv && sysm == 8'd8) begin
              rf_we = 1'b1; rf_wa = 4'd13; rf_ws = WS_A;
            end else if (priv && sysm == 8'd9) begin
              rf_we = 1'b1; rf_wa = 4'd15; rf_ws = WS_A;
            end
            if (sysm == 8'd20) x_serial = 1'b1;                           // CONTROL: refetch
          end
          `OP_CPS: begin
            x_done = 1'b1;
            wr_spec = 1'b1;
          end
          // -------------------------------------------------------------------------
          `OP_HINT: begin
            case (x_sub[3:0])
              `HINT_WFI: begin
                if (any_pending) x_done = 1'b1;
                else x_sleep = 1'b1;
              end
              `HINT_WFE: begin
                if (event_reg) begin ev_clr = 1'b1; x_done = 1'b1; end
                else if (any_pending) x_done = 1'b1;
                else x_sleep = 1'b1;
              end
              `HINT_SEV: begin ev_set = 1'b1; x_done = 1'b1; end
              `HINT_CLREX: begin excl_clr = 1'b1; x_done = 1'b1; end
              `HINT_DSB, `HINT_DMB: begin
                if (lsu_idle) x_done = 1'b1;
                step_n = step;
              end
              `HINT_ISB: begin x_done = 1'b1; x_serial = 1'b1; end
              default: x_done = 1'b1;
            endcase
          end
          `OP_SVC: begin
            x_fault = 1'b1;
            x_fault_ret = x_pc + 32'd2; x_fault_it = x_it_next;
            if (svc_can) x_fault_num = `EXC_SVCALL;
            else begin x_fault_num = `EXC_HARDFAULT; x_hf_forced = 1'b1; end
          end
          `OP_BKPT: begin
            if (dbg_halt_on_bkpt) x_halt = 1'b1;
            else begin x_fault = 1'b1; x_fault_num = `EXC_HARDFAULT; x_hf_forced = 1'b1; end
          end
          `OP_UNDEF: usage_fault(5'd0);                                   // UNDEFINSTR
          `OP_NOCP:  usage_fault(5'd3);                                   // NOCP
          // -------------------------------------------------------------------------
          `OP_FPDP: begin
            if (step == 5'd0) fpu_start = 1'b1;
            else begin
              step_n = 5'd1;
              if (fpu_done) begin
                x_done = 1'b1;
                wr_fpscr = 1'b1;
                n_fpscr = fpscr | {24'd0, fpu_flags};
                if (fpu_cmp) n_fpscr[31:28] = fpu_nzcv;
                else begin fp_we = 1'b1; fp_wa = x_fd; fp_ws = FS_FPU; end
              end
            end
          end
          `OP_FPMV: begin
            case (x_sub[3:0])
              `FMV_TOS: begin x_done = 1'b1; fp_we = 1'b1; fp_wa = x_fd; fp_ws = FS_B; end
              `FMV_TOR: begin x_done = 1'b1; rf_we = 1'b1; rf_wa = phys(x_rd, use_psp); rf_ws = WS_FA; end
              `FMV_TOS2: begin
                fp_we = 1'b1;
                if (step == 5'd0) begin fp_wa = x_fd; fp_ws = FS_B; end
                else begin fp_wa = x_fd + 5'd1; fp_ws = FS_A; x_done = 1'b1; end
              end
              `FMV_TOR2: begin
                rf_we = 1'b1;
                if (step == 5'd0) begin rf_wa = phys(x_rd, use_psp); rf_ws = WS_FA; end
                else begin rf_wa = phys(x_rd2, use_psp); rf_ws = WS_FB; x_done = 1'b1; end
              end
              `FMV_VMRS: begin
                x_done = 1'b1;
                if (x_rd_we) begin rf_we = 1'b1; rf_wa = phys(x_rd, use_psp); rf_ws = WS_FPSCR; end
                else begin
                  set_nz = 1'b1; set_c = 1'b1; set_v = 1'b1;
                  n_n = fpscr[31]; n_z = fpscr[30]; n_c = fpscr[29]; n_v = fpscr[28];
                end
              end
              `FMV_VMSR: begin
                x_done = 1'b1; wr_fpscr = 1'b1; n_fpscr = x_b & 32'hF7C0_009F;
              end
              `FMV_IMM: begin x_done = 1'b1; fp_we = 1'b1; fp_wa = x_fd; fp_ws = FS_IMM; end
              `FMV_REG: begin x_done = 1'b1; fp_we = 1'b1; fp_wa = x_fd; fp_ws = FS_FB; end
              `FMV_ABS: begin x_done = 1'b1; fp_we = 1'b1; fp_wa = x_fd; fp_ws = FS_ABS; end
              `FMV_NEG: begin x_done = 1'b1; fp_we = 1'b1; fp_wa = x_fd; fp_ws = FS_NEG; end
              default: x_done = 1'b1;
            endcase
          end
          `OP_FPLS: begin
            if (step == 5'd0) begin
              if (m_addr[1:0] != 2'b00) usage_fault(5'd8);
              else begin
                ms_start = 1'b1; ms_start_base = m_addr;
              end
            end else begin
              step_n = step;
              fp_xa = x_fd + ms_req[4:0];
              if (ms_req < x_cnt) begin
                lsu_req = 1'b1;
                lsu_wr = !x_fload;
                lsu_as = LA_SEQ;
                lsu_size = 2'd2;
                lsu_ws = LW_FRX;
                if (lsu_ack) ms_issue = 1'b1;
                if (lsu_ack && ms_req == 6'd0 && x_mwb) begin
                  rf_we = 1'b1; rf_wa = phys(x_rd2, use_psp); rf_ws = WS_WB;
                end
              end
              if (!x_fload) begin
                if (lsu_ack && ms_req + 6'd1 == x_cnt) x_done = 1'b1;
              end else if (lsu_rvalid) begin
                ms_resp = 1'b1;
                if (lsu_rerr) begin
                  bus_fault(ms_base + {24'd0, ms_rsp, 2'b00});
                  if (ms_wbdone) begin rf_we = 1'b1; rf_wa = phys(x_rd2, use_psp); rf_ws = WS_A; end
                end else begin
                  fp_we = 1'b1; fp_wa = x_fd + ms_rsp[4:0]; fp_ws = FS_LD;
                  if (ms_rsp + 6'd1 == x_cnt) x_done = 1'b1;
                end
              end
            end
          end
          default: x_done = 1'b1;
        endcase
      end
    end

    // ---------------------------------------------------------------------------------
    // exception entry: stack the frame, read the vector, set up the handler
    //   step 0: frame pointer; 1: push ex_n words; 2: vector read; 3: SP; 4: LR, go
    // ---------------------------------------------------------------------------------
    if (xs == XS_EXC) begin
      step_n = step;
      rf_xa = (ms_req < 6'd4) ? {2'b00, ms_req[1:0]} : (ms_req == 6'd4) ? 4'd12 : 4'd14;
      fp_xa = ms_req[4:0] - 5'd8;
      case (step)
        5'd0: begin
          rf_xa = use_psp ? 4'd15 : 4'd13;                               // the stack in use
          step_n = 5'd1;
        end
        5'd1: begin
          if (ms_req < ex_n) begin
            lsu_req = 1'b1; lsu_wr = 1'b1; lsu_size = 2'd2; lsu_priv = priv;
            lsu_as = LA_SEQ;
            lsu_ws = (ms_req < 6'd6) ? LW_RFX : (ms_req == 6'd6) ? LW_RET : (ms_req == 6'd7) ? LW_XPSR :
                     (ms_req < 6'd24) ? LW_FRX : (ms_req == 6'd24) ? LW_FPSCR : LW_ZERO;
            if (lsu_ack) ms_issue = 1'b1;
          end else step_n = 5'd2;
        end
        5'd2: begin
          // vector: one read once all writes have been accepted
          if (ms_rsp == 6'd0) begin
            lsu_req = (ms_req == ex_n); lsu_wr = 1'b0; lsu_size = 2'd2; lsu_priv = 1'b1;
            lsu_as = LA_VEC;
            if (lsu_ack) ms_issue = 1'b1;
          end
          if (lsu_rvalid) begin
            ms_resp = 1'b1;
            step_n = 5'd3;
          end
        end
        5'd3: begin
          rf_we = 1'b1; rf_wa = ex_psp ? 4'd15 : 4'd13; rf_ws = WS_MSBASE;
          step_n = 5'd4;
        end
        default: begin
          rf_we = 1'b1; rf_wa = 4'd14; rf_ws = WS_EXCRET;
        end
      endcase
    end

    // ---------------------------------------------------------------------------------
    // exception return: pop the frame
    //   step 0: frame pointer; 1: read ex_n words (R0-R3, R12, LR, PC, xPSR, S0-S15, FPSCR); 2: SP
    // ---------------------------------------------------------------------------------
    if (xs == XS_RET) begin
      step_n = step;
      case (step)
        5'd0: begin
          rf_xa = ex_psp ? 4'd15 : 4'd13;
          step_n = 5'd1;
        end
        5'd1: begin
          if (ms_req < ex_n) begin
            lsu_req = 1'b1; lsu_wr = 1'b0; lsu_size = 2'd2; lsu_priv = 1'b1;
            lsu_as = LA_SEQ;
            if (lsu_ack) ms_issue = 1'b1;
          end
          if (lsu_rvalid) begin
            ms_resp = 1'b1;
            if (ms_rsp < 6'd4) begin rf_we = 1'b1; rf_wa = {2'b00, ms_rsp[1:0]}; rf_ws = WS_LD; end
            else if (ms_rsp == 6'd4) begin rf_we = 1'b1; rf_wa = 4'd12; rf_ws = WS_LD; end
            else if (ms_rsp == 6'd5) begin rf_we = 1'b1; rf_wa = 4'd14; rf_ws = WS_LD; end
            else if (ms_rsp >= 6'd8 && ms_rsp < 6'd24) begin fp_we = 1'b1; fp_wa = ms_rsp[4:0] - 5'd8; fp_ws = FS_LD; end
            if (ms_rsp + 6'd1 == ex_n) step_n = 5'd2;
          end
        end
        default: begin
          rf_we = 1'b1; rf_wa = ex_psp ? 4'd15 : 4'd13;
          rf_ws = WS_RETSP;
        end
      endcase
    end

    // ---------------------------------------------------------------------------------
    // reset: SP from address 0, PC from address 4
    // ---------------------------------------------------------------------------------
    if (xs == XS_RESET) begin
      step_n = step;
      if (ms_req < 6'd2) begin
        lsu_req = 1'b1; lsu_wr = 1'b0; lsu_size = 2'd2; lsu_priv = 1'b1;
        lsu_as = LA_RST;                                               // reset vector: SP, PC
        if (lsu_ack) ms_issue = 1'b1;
      end
      if (lsu_rvalid) begin
        ms_resp = 1'b1;
        if (ms_rsp == 6'd0) begin rf_we = 1'b1; rf_wa = 4'd13; rf_ws = WS_LD; end
      end
    end
  end

  // =====================================================================================
  // D -> X issue
  // =====================================================================================
  // X takes a new instruction when it is empty or its instruction completes without changing
  // the flow; a pending exception stops issue so that X empties and the exception is taken
  wire x_free  = (xs == XS_RUN) && (!x_valid || (x_done && !x_branch && !x_serial && !x_excret && !x_fault));
  wire d_go    = x_free && dv && !exc_take && !redir;
  assign consume = d_go ? (d32 ? 2'd2 : 2'd1) : 2'd0;

  // next PC after the instruction in X
  wire [31:0] x_seq_pc = x_pc + (x_len32 ? 32'd4 : 32'd2);

  // =====================================================================================
  // clocked
  // =====================================================================================
  // exception entry parameters for the exception taken now
  wire [31:0] sp_cur   = rf_x;                     // read in step 0 of XS_EXC
  wire        ext_frm  = ctl_fpca;
  wire [31:0] fs_bytes = ext_frm ? 32'd104 : 32'd32;

  assign halted   = (xs == XS_HALT);
  assign lockup   = (xs == XS_LOCK);
  assign sleeping = (xs == XS_SLEEP);

  assign trc_rf_we = rf_we;
  assign trc_rf_wa = rf_wa;
  assign trc_rf_wd = rf_wdm;
  assign trc_fp_we = fp_we;
  assign trc_fp_wa = fp_wa;
  assign trc_fp_wd = fp_wd;
  assign trc_xpsr  = {fN, fZ, fC, fV, fQ, arch_it[1:0], epsr_t, 4'd0, fGE, arch_it[7:2], 1'b0, ipsr};
  assign trc_fpscr = fpscr;
  assign trc_control = {ctl_fpca, ctl_spsel, ctl_npriv};

  // register write data: one parallel multiplexer
  wire [31:0] mrs_val =
      (sysm[7:3] == 5'd0) ? ((sysm[2] ? 32'd0 : apsr_v) | (sysm[0] ? {23'd0, ipsr} : 32'd0)) :
      (sysm[7:3] == 5'd1) ? ((priv && sysm[2:1] == 2'd0) ? rf_x : 32'd0) :
      (sysm == 8'd16) ? {31'd0, primask} :
      (sysm == 8'd17 || sysm == 8'd18) ? {24'd0, basepri} :
      (sysm == 8'd19) ? {31'd0, faultmask} :
      (sysm == 8'd20) ? {29'd0, ctl_fpca, ctl_spsel, ctl_npriv} : 32'd0;
  always @* begin
    case (rf_ws)
      WS_ALU:    rf_wd = alu_res;
      WS_BIT:    rf_wd = bit_res;
      WS_MULLO:  rf_wd = mul_lo;
      WS_MULHI:  rf_wd = mul_hi;
      WS_DIV:    rf_wd = div_q;
      WS_LINK:   rf_wd = x_seq_pc | 32'd1;
      WS_ONE:    rf_wd = 32'd1;
      WS_WB:     rf_wd = m_offadr;
      WS_A:      rf_wd = x_a;
      WS_LD:     rf_wd = ld_val;
      WS_LMWB:   rf_wd = lm_wb;
      WS_MRS:    rf_wd = mrs_val;
      WS_FA:     rf_wd = x_fa;
      WS_FB:     rf_wd = x_fb;
      WS_FPSCR:  rf_wd = fpscr;
      WS_MSBASE: rf_wd = ms_base;
      WS_EXCRET: rf_wd = ex_excret;
      WS_RETSP:  rf_wd = ms_base + {24'd0, ex_n + {5'd0, ex_xpsr[9]}, 2'b00};
      default:   rf_wd = 32'd0;
    endcase
  end

  // FP write data, store data, load / store address
  always @* begin
    case (fp_ws)
      FS_FPU: fp_wd = fpu_res;
      FS_B:   fp_wd = x_b;
      FS_A:   fp_wd = x_a;
      FS_IMM: fp_wd = x_imm;
      FS_FB:  fp_wd = x_fb;
      FS_ABS: fp_wd = {1'b0, x_fb[30:0]};
      FS_NEG: fp_wd = {~x_fb[31], x_fb[30:0]};
      FS_LD:  fp_wd = ld_val;
      default: fp_wd = 32'd0;
    endcase
    case (lsu_ws)
      LW_C:     lsu_wdata = x_c;
      LW_B:     lsu_wdata = x_b;
      LW_PC4:   lsu_wdata = x_pc + 32'd4;
      LW_RFX:   lsu_wdata = rf_x;
      LW_FRX:   lsu_wdata = fr_x;
      LW_RET:   lsu_wdata = ex_ret;
      LW_XPSR:  lsu_wdata = xpsr_stack;
      LW_FPSCR: lsu_wdata = fpscr;
      default:  lsu_wdata = 32'd0;
    endcase
    case (lsu_as)
      LA_M:    lsu_addr = m_addr + {29'd0, ms_req[0], 2'b00};
      LA_SEQ:  lsu_addr = seq_addr;
      LA_VEC:  lsu_addr = {vtor[31:7], ex_num[4:0], 2'b00};
      default: lsu_addr = {29'd0, ms_req[0], 2'b00};
    endcase
  end

  // exception to start (asynchronous at an instruction boundary, or a fault of X)
  wire take_async = (xs == XS_RUN) && !x_valid && exc_take && !redir;

  always @(posedge clk) begin
    redir <= 1'b0;
    trc_valid <= 1'b0;
    txev <= 1'b0;
    scs_activate <= 1'b0;
    scs_deactivate <= 1'b0;
    cfsr_set <= 32'd0;
    hfsr_forced <= 1'b0;
    hfsr_vecttbl <= 1'b0;
    bfar_we <= 1'b0;
    perf_ev <= 7'd0;
    ev_cpi <= 1'b0; ev_exc <= 1'b0; ev_sleep <= 1'b0; ev_lsu <= 1'b0;
    if (!rst_n) begin
      fN <= 1'b0; fZ <= 1'b0; fC <= 1'b0; fV <= 1'b0; fQ <= 1'b0; fGE <= 4'd0;
      ipsr <= 9'd0; epsr_t <= 1'b1; primask <= 1'b0; faultmask <= 1'b0; basepri <= 8'd0;
      ctl_npriv <= 1'b0; ctl_spsel <= 1'b0; ctl_fpca <= 1'b0;
      fpscr <= 32'd0; excl_mon <= 1'b0; event_reg <= 1'b0;
      arch_npc <= 32'd0; arch_it <= 8'd0;
      d_it <= 8'd0;
      x_valid <= 1'b0;
      xs <= XS_RESET; step <= 5'd0;
      ms_req <= 6'd0; ms_rsp <= 6'd0; ms_wbdone <= 1'b0;
      fetch_en <= 1'b0;
      fpchk_done <= 1'b0;
      redir_pc <= 32'd0;
      trc_pc <= 32'd0; trc_insn <= 32'd0; trc_skip <= 1'b0;
    end else begin
      // ------------------------------------------------ flags, special registers
      if (set_nz) begin fN <= n_n; fZ <= n_z; end
      if (set_c) fC <= n_c;
      if (set_v) fV <= n_v;
      if (set_q) fQ <= n_q;
      if (set_ge) fGE <= n_ge;
      if (wr_fpscr) fpscr <= n_fpscr;
      if (excl_set) excl_mon <= 1'b1;
      if (excl_clr) excl_mon <= 1'b0;
      if (ev_set) begin event_reg <= 1'b1; txev <= 1'b1; end
      if (ev_clr) event_reg <= 1'b0;
      if (rxev || sevonpend_ev) event_reg <= 1'b1;
      if (fpchk) begin
        fpscr[26:22] <= fpdscr;
        ctl_fpca <= 1'b1;
        fpchk_done <= 1'b1;
      end
      if (wr_spec && xs == XS_RUN && x_valid) begin
        if (x_op == `OP_CPS && priv) begin
          if (x_imm[1]) primask <= x_imm[2];
          if (x_imm[0] && (!x_imm[2] || ipsr != 9'd3 && ipsr != 9'd2)) faultmask <= x_imm[2];
        end
        if (x_op == `OP_MSR && priv) begin
          case (sysm)
            8'd16: primask <= x_a[0];
            8'd17: basepri <= x_a[7:0] & {{PRIO_BITS{1'b1}}, {(8 - PRIO_BITS){1'b0}}};
            8'd18: if ((x_a[7:0] & {{PRIO_BITS{1'b1}}, {(8 - PRIO_BITS){1'b0}}}) != 8'd0 &&
                       ((x_a[7:0] & {{PRIO_BITS{1'b1}}, {(8 - PRIO_BITS){1'b0}}}) < basepri || basepri == 8'd0))
                     basepri <= x_a[7:0] & {{PRIO_BITS{1'b1}}, {(8 - PRIO_BITS){1'b0}}};
            8'd19: if (ipsr != 9'd3 && ipsr != 9'd2) faultmask <= x_a[0];
            8'd20: begin
              ctl_npriv <= x_a[0];
              if (!handler) ctl_spsel <= x_a[1];
              ctl_fpca <= x_a[2];
            end
            default: ;
          endcase
        end
      end

      // ------------------------------------------------ memory sequencer
      if (ms_start) begin
        ms_base <= ms_start_base;
        ms_lreq <= ms_start_list;
        ms_lrsp <= ms_start_list;
        ms_req <= 6'd0; ms_rsp <= 6'd0;
      end else begin
        if (ms_issue) begin
          ms_req <= ms_req + 6'd1;
          ms_lreq <= ms_lreq & ~(16'd1 << lreq_r);
        end
        if (ms_resp) begin
          ms_rsp <= ms_rsp + 6'd1;
          ms_lrsp <= ms_lrsp & ~(16'd1 << lrsp_r);
        end
      end
      if (ms_issue && ms_req == 6'd0 && x_mwb && xs == XS_RUN) ms_wbdone <= 1'b1;

      // ------------------------------------------------ D: IT state
      if (d_go) d_it <= dit_next;

      // ------------------------------------------------ X
      case (xs)
        XS_RESET: begin
          if (lsu_rvalid) begin
            if (ms_rsp == 6'd1) begin
              // PC from the reset vector
              redir <= 1'b1; redir_pc <= {ld_val[31:1], 1'b0};
              epsr_t <= ld_val[0];
              arch_npc <= {ld_val[31:1], 1'b0};
              fetch_en <= 1'b1;
              xs <= XS_RUN; step <= 5'd0;
              ms_req <= 6'd0; ms_rsp <= 6'd0;
            end
          end
        end

        XS_RUN: begin
          if (x_valid) begin
            step <= step_n;
            if (x_done) begin
              // retire
              trc_valid <= 1'b1; trc_pc <= x_pc; trc_insn <= x_insn; trc_skip <= !cond_pass;
              perf_ev[0] <= 1'b1;
              x_valid <= 1'b0;
              step <= 5'd0;
              fpchk_done <= 1'b0;
              ms_req <= 6'd0; ms_rsp <= 6'd0; ms_wbdone <= 1'b0;
              arch_it <= x_it_next;
              if (x_branch) begin
                redir <= 1'b1; redir_pc <= {x_target[31:1], 1'b0};
                arch_npc <= {x_target[31:1], 1'b0};
                if (x_bx) epsr_t <= x_target[0];
                d_it <= 8'd0; arch_it <= 8'd0;
              end else if (x_serial) begin
                redir <= 1'b1; redir_pc <= x_seq_pc;
                arch_npc <= x_seq_pc;
                d_it <= x_it_next;
              end else begin
                arch_npc <= x_seq_pc;
              end
              if (x_excret) begin
                // exception return: pop the frame of the stack in EXC_RETURN
                xs <= XS_RET; step <= 5'd0;
                ex_excret <= x_target;
                ex_psp <= x_target[2];
                ex_thread <= x_target[3];
                ex_ext <= !x_target[4];
                ex_n <= !x_target[4] ? 6'd26 : 6'd8;
                scs_deactivate <= 1'b1; scs_exc_num <= ipsr;
                if (ipsr != 9'd2) faultmask <= 1'b0;
                d_it <= 8'd0;
                if (x_target[27:5] != 23'h7FFFFF ||
                    (x_target[3:0] != 4'b0001 && x_target[3:0] != 4'b1001 && x_target[3:0] != 4'b1101)) begin
                  // invalid EXC_RETURN: INVPC UsageFault, return address = the faulting instruction
                  xs <= XS_EXC; step <= 5'd0;
                  scs_deactivate <= 1'b0;
                  ex_num <= usg_can ? `EXC_USAGE : `EXC_HARDFAULT;
                  if (!usg_can) hfsr_forced <= 1'b1;
                  cfsr_set <= 32'h0004_0000;
                  ex_ret <= x_pc; ex_it <= x_it_cur;
                  arch_npc <= x_pc;
                end
              end
            end else if (x_fault) begin
              // synchronous exception: the instruction does not complete
              x_valid <= 1'b0; step <= 5'd0; fpchk_done <= 1'b0;
              ms_req <= 6'd0; ms_rsp <= 6'd0; ms_wbdone <= 1'b0;
              cfsr_set <= x_cfsr;
              if (x_hf_forced) hfsr_forced <= 1'b1;
              if (x_cfsr[15]) begin bfar_we <= 1'b1; bfar_wd <= x_bfar; end
              if (!hf_can && x_fault_num == `EXC_HARDFAULT) begin
                xs <= XS_LOCK;
              end else begin
                xs <= XS_EXC; step <= 5'd0;
                ex_num <= x_fault_num; ex_ret <= x_fault_ret; ex_it <= x_fault_it;
              end
              trc_valid <= (x_op == `OP_SVC); trc_pc <= x_pc; trc_insn <= x_insn; trc_skip <= 1'b0;
            end else if (x_sleep) begin
              xs <= XS_SLEEP;
            end else if (x_halt) begin
              xs <= XS_HALT;
            end
          end
          // a new instruction enters X
          if (d_go) begin
            x_valid <= 1'b1;
            step <= 5'd0;
            x_op <= dop; x_sub <= dsub; x_aluop <= daluop; x_cond <= dcond;
            x_ra <= dra; x_rb <= drb; x_rc <= drc; x_rd <= drd; x_rd2 <= drd2;
            x_use_imm <= duse_imm; x_imm <= dimm; x_imm_c <= dimm_c; x_imm_cv <= dimm_cv;
            x_sh_typ <= dsh_typ; x_sh_amt <= dsh_amt; x_sh_rrx <= dsh_rrx; x_sh_reg <= dsh_reg;
            x_setflags <= dsetflags; x_rd_we <= drd_we; x_rd2_we <= drd2_we; x_bp <= dbp;
            x_msize <= dmsize; x_msign <= dmsign; x_mpre <= dmpre; x_madd <= dmadd; x_mwb <= dmwb;
            x_munpriv <= dmunpriv; x_mexcl <= dmexcl; x_cnt <= dcnt; x_fload <= dfload;
            x_fn <= dfn; x_fm <= dfm; x_fd <= dfd;
            x_a <= va; x_b <= (dop == `OP_BIT && duse_imm) ? dimm : vb; x_c <= vc; x_fa <= wfa; x_fb <= wfb;
            x_pc <= q_pc; x_len32 <= d32; x_insn <= d32 ? {q_h0, q_h1} : {16'd0, q_h0};
            x_it_cur <= d_it; x_it_next <= dit_next;
            ms_req <= 6'd0; ms_rsp <= 6'd0; ms_wbdone <= 1'b0;
          end
          // an interrupt between instructions
          if (take_async && !d_go) begin
            xs <= XS_EXC; step <= 5'd0;
            ex_num <= exc_take_num; ex_ret <= arch_npc; ex_it <= arch_it;
          end
        end

        XS_EXC: begin
          step <= step_n;
          perf_ev[5] <= 1'b1; ev_exc <= 1'b1;
          case (step)
            5'd0: begin
              // the stack in use now; frame size; 8-byte alignment
              ex_psp <= use_psp;
              ex_ext <= ext_frm;
              ex_n <= ext_frm ? 6'd26 : 6'd8;
              ex_align <= stkalign && sp_cur[2];
              ex_fp <= (sp_cur - fs_bytes) & ~{29'd0, stkalign && sp_cur[2], 2'b00};
              ms_base <= (sp_cur - fs_bytes) & ~{29'd0, stkalign && sp_cur[2], 2'b00};
              ex_excret <= {27'h7FFFFFF, !ext_frm, !handler, use_psp && !handler, 2'b01};
              ms_req <= 6'd0; ms_rsp <= 6'd0;
              x_valid <= 1'b0;
            end
            5'd2: begin
              if (lsu_rvalid) ms_tmp <= ld_val;
            end
            5'd4: begin
              // into the handler
              ipsr <= ex_num;
              ctl_spsel <= 1'b0;
              ctl_fpca <= 1'b0;
              epsr_t <= ms_tmp[0];
              excl_mon <= 1'b0;
              event_reg <= 1'b1;
              scs_activate <= 1'b1; scs_exc_num <= ex_num;
              redir <= 1'b1; redir_pc <= {ms_tmp[31:1], 1'b0};
              arch_npc <= {ms_tmp[31:1], 1'b0}; arch_it <= 8'd0;
              d_it <= 8'd0;
              xs <= XS_RUN; step <= 5'd0;
              ms_req <= 6'd0; ms_rsp <= 6'd0;
            end
            default: ;
          endcase
        end

        XS_RET: begin
          step <= step_n;
          perf_ev[5] <= 1'b1; ev_exc <= 1'b1;
          case (step)
            5'd0: begin
              ex_fp <= rf_x;
              ms_base <= rf_x;
              ms_req <= 6'd0; ms_rsp <= 6'd0;
            end
            5'd1: begin
              if (lsu_rvalid) begin
                if (ms_rsp == 6'd6) ms_tmp <= ld_val;
                if (ms_rsp == 6'd7) ex_xpsr <= ld_val;
                if (ms_rsp == 6'd24) fpscr <= ld_val & 32'hF7C0_009F;
              end
            end
            default: begin
              // back to the interrupted code
              fN <= ex_xpsr[31]; fZ <= ex_xpsr[30]; fC <= ex_xpsr[29]; fV <= ex_xpsr[28]; fQ <= ex_xpsr[27];
              fGE <= ex_xpsr[19:16];
              ipsr <= ex_thread ? 9'd0 : ex_xpsr[8:0];
              epsr_t <= ex_xpsr[24];
              ctl_spsel <= ex_thread ? ex_psp : 1'b0;
              ctl_fpca <= ex_ext;
              excl_mon <= 1'b0;
              event_reg <= 1'b1;
              redir <= 1'b1; redir_pc <= {ms_tmp[31:1], 1'b0};
              arch_npc <= {ms_tmp[31:1], 1'b0};
              arch_it <= {ex_xpsr[15:10], ex_xpsr[26:25]};
              d_it <= {ex_xpsr[15:10], ex_xpsr[26:25]};
              ms_req <= 6'd0; ms_rsp <= 6'd0;
              xs <= (ex_thread && sleeponexit) ? XS_SLEEP : XS_RUN;
              step <= 5'd0;
            end
          endcase
        end

        XS_SLEEP: begin
          perf_ev[6] <= 1'b1; ev_sleep <= 1'b1;
          if (any_pending || (x_valid && x_op == `OP_HINT && x_sub[3:0] == `HINT_WFE && (event_reg || rxev))) begin
            xs <= XS_RUN;
            if (x_valid) begin
              // the WFI / WFE completes
              trc_valid <= 1'b1; trc_pc <= x_pc; trc_insn <= x_insn; trc_skip <= 1'b0;
              x_valid <= 1'b0; step <= 5'd0;
              arch_npc <= x_seq_pc; arch_it <= x_it_next;
              if (x_sub[3:0] == `HINT_WFE) event_reg <= 1'b0;
            end
          end
        end

        default: ;   // XS_HALT, XS_LOCK: stay
      endcase

      // performance events
      if (xs == XS_RUN) begin
        if (!x_valid) perf_ev[1] <= 1'b1;
        else if (!x_done) begin
          case (x_op)
            `OP_LD, `OP_ST, `OP_LDM, `OP_STM, `OP_TB, `OP_FPLS: begin perf_ev[2] <= 1'b1; ev_lsu <= 1'b1; end
            `OP_MUL, `OP_DIV: begin perf_ev[3] <= 1'b1; ev_cpi <= 1'b1; end
            `OP_FPDP: begin perf_ev[4] <= 1'b1; ev_cpi <= 1'b1; end
            default: ev_cpi <= 1'b1;
          endcase
        end
      end
    end
  end

endmodule

`default_nettype wire
