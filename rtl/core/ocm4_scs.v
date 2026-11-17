/*
 * ocm4_scs - System Control Space of OpenCM4F (0xE000_0000 .. 0xE00F_FFFF, private peripheral bus):
 *   NVIC (NUM_IRQ interrupts, PRIO_BITS priority bits), SCB, SysTick, DWT cycle counter (CYCCNT),
 *   FP control registers (CPACR, FPCCR, FPCAR, FPDSCR, MVFR0/1), CoreDebug DEMCR
 * SPDX-License-Identifier: MIT
 *
 * Priorities are kept as "levels": 0 NMI, 1 HardFault (and FAULTMASK), 2 + priority for the
 * configurable exceptions (priority 0 .. 2^PRIO_BITS - 1), 15 = thread mode with nothing active.
 * The highest pending exception is chosen one clock ahead (registered); whether it preempts is
 * decided against the current execution priority in the same clock (take, take_num).
 */

`default_nettype none
`include "ocm4_defs.vh"

module ocm4_scs #(
    parameter NUM_IRQ   = 16,       // 1 .. 16
    parameter PRIO_BITS = 3         // 2 .. 4
) (
    input  wire               clk,
    input  wire               rst_n,

    // register access (word address, byte strobes; data already in its byte lanes)
    input  wire               acc,          // access this clock (read or write)
    input  wire               wr,
    input  wire [19:0]        addr,         // offset in the PPB (0xE00x_xxxx)
    input  wire [31:0]        wdata,
    input  wire [3:0]         wstrb,
    input  wire               priv,
    output reg  [31:0]        rdata,        // valid in the clock after acc
    output reg                err,          // ditto: unprivileged access -> BusFault

    // interrupt inputs
    input  wire [NUM_IRQ-1:0] irq,
    input  wire               nmi,

    // core state
    input  wire [8:0]         ipsr,
    input  wire               primask,
    input  wire               faultmask,
    input  wire [7:0]         basepri,

    // exception bookkeeping from the core
    input  wire               exc_activate,     // exception entry done: active, not pending
    input  wire               exc_deactivate,   // exception return
    input  wire [8:0]         exc_num,
    input  wire               pend_imprecise,   // imprecise BusFault (write error)
    input  wire [31:0]        cfsr_set,         // fault status bits to set
    input  wire               hfsr_forced,
    input  wire               hfsr_vecttbl,
    input  wire               bfar_we,
    input  wire [31:0]        bfar_wd,

    // to the core
    output wire               take,             // a pending exception preempts now
    output wire [8:0]         take_num,
    output wire               usg_can,          // UsageFault can be taken now (else HardFault)
    output wire               bus_can,
    output wire               svc_can,
    output wire               hf_can,           // HardFault can be taken (else lockup)
    output wire               any_pending,      // for WFI / WFE wake-up
    output wire               ret_to_base,      // one active exception or none
    output wire [31:0]        vtor,
    output wire               stkalign,
    output wire               div0_trp,
    output wire               unalign_trp,
    output wire               sleeponexit,
    output wire               sevonpend_ev,     // SEVONPEND: an interrupt became pending
    output wire [3:0]         cpacr_fp,         // CP11:CP10 access bits
    output wire               fpccr_aspen,
    output wire               fpccr_lspen,
    output wire [4:0]         fpdscr,           // FPDSCR[26:22] (AHP DN FZ RMode)
    output reg                sysresetreq,

    // DWT events (one clock each)
    input  wire               ev_cpi,
    input  wire               ev_exc,
    input  wire               ev_sleep,
    input  wire               ev_lsu,
    input  wire               ev_fold,
    input  wire               halted
);

  localparam NI = NUM_IRQ;
  localparam [PRIO_BITS-1:0] PZ = {PRIO_BITS{1'b0}};

  // ---------------- registers ----------------
  reg [31:0]          vtor_r;
  reg [2:0]           prigroup;
  reg                 sleeponexit_r, sleepdeep, sevonpend;
  reg                 stkalign_r, bfhfnmign, div0_r, unalign_r, usersetmpend, nonbasethrdena;
  reg [PRIO_BITS-1:0] pr_mem, pr_bus, pr_usg, pr_svc, pr_pendsv, pr_systick;
  reg [PRIO_BITS-1:0] pr_irq [0:NI-1];
  reg                 ena_usg, ena_bus, ena_mem;
  reg                 pend_nmi, pend_hf, pend_mem, pend_bus, pend_usg, pend_svc, pend_pendsv, pend_systick;
  reg [NI-1:0]        pend_irq, en_irq, irq_prev;
  reg                 act_nmi, act_hf, act_mem, act_bus, act_usg, act_svc, act_mon, act_pendsv, act_systick;
  reg [NI-1:0]        act_irq;
  reg [31:0]          cfsr, bfar;     // MMFAR and BFAR are one physical register (as in the Cortex-M4)
  reg                 hf_forced, hf_vecttbl;
  reg [3:0]           cpacr;
  reg                 aspen, lspen;
  reg [31:3]          fpcar;
  reg [4:0]           fpdscr_r;
  reg [9:0]           actlr;
  reg                 trcena;
  // SysTick
  reg                 st_en, st_int, st_flag;
  reg [23:0]          st_reload, st_cur;
  // DWT
  reg                 cyc_en;
  reg [31:0]          cyccnt;
  reg                 nmi_prev;

  assign vtor        = vtor_r;
  assign stkalign    = stkalign_r;
  assign div0_trp    = div0_r;
  assign unalign_trp = unalign_r;
  assign sleeponexit = sleeponexit_r;
  assign cpacr_fp    = cpacr;
  assign fpccr_aspen = aspen;
  assign fpccr_lspen = lspen;
  assign fpdscr      = fpdscr_r;

  // ---------------- priorities ----------------
  // group priority mask from PRIGROUP: the priority field is [7:8-PRIO_BITS]; bits [PRIGROUP:0]
  // are subpriority
  reg [PRIO_BITS-1:0] gmask;
  integer gi;
  always @* begin
    for (gi = 0; gi < PRIO_BITS; gi = gi + 1)
      gmask[gi] = ((8 - PRIO_BITS + gi) > prigroup);
  end
  function [3:0] lvl(input [PRIO_BITS-1:0] p);
    lvl = 4'd2 + {{(4 - PRIO_BITS){1'b0}}, p};
  endfunction

  // ---------------- candidates by exception number (0..31): levels, group levels ----------------
  reg [31:0] c_pend, c_act;
  reg [3:0]  c_lv [0:31];
  reg [3:0]  c_gl [0:31];
  integer ci;
  always @* begin
    c_pend = 32'd0; c_act = 32'd0;
    for (ci = 0; ci < 32; ci = ci + 1) begin c_lv[ci] = 4'd15; c_gl[ci] = 4'd15; end
    c_lv[2] = 4'd0; c_gl[2] = 4'd0; c_pend[2] = pend_nmi; c_act[2] = act_nmi;
    c_lv[3] = 4'd1; c_gl[3] = 4'd1; c_pend[3] = pend_hf;  c_act[3] = act_hf;
    c_lv[4] = lvl(pr_mem);     c_gl[4] = lvl(pr_mem & gmask);     c_pend[4] = pend_mem;     c_act[4] = act_mem;
    c_lv[5] = lvl(pr_bus);     c_gl[5] = lvl(pr_bus & gmask);     c_pend[5] = pend_bus;     c_act[5] = act_bus;
    c_lv[6] = lvl(pr_usg);     c_gl[6] = lvl(pr_usg & gmask);     c_pend[6] = pend_usg;     c_act[6] = act_usg;
    c_lv[11] = lvl(pr_svc);    c_gl[11] = lvl(pr_svc & gmask);    c_pend[11] = pend_svc;    c_act[11] = act_svc;
    c_lv[14] = lvl(pr_pendsv); c_gl[14] = lvl(pr_pendsv & gmask); c_pend[14] = pend_pendsv; c_act[14] = act_pendsv;
    c_lv[15] = lvl(pr_systick); c_gl[15] = lvl(pr_systick & gmask); c_pend[15] = pend_systick; c_act[15] = act_systick;
    for (ci = 0; ci < NI && ci < 16; ci = ci + 1) begin
      c_lv[16 + ci] = lvl(pr_irq[ci]);
      c_gl[16 + ci] = lvl(pr_irq[ci] & gmask);
      c_pend[16 + ci] = pend_irq[ci] && en_irq[ci];
      c_act[16 + ci] = act_irq[ci];
    end
  end

  // execution priority: minimum group level of the active exceptions (tree), then the masks
  reg [3:0] mt [0:62];
  integer mi;
  always @* begin
    for (mi = 0; mi < 32; mi = mi + 1) mt[31 + mi] = c_act[mi] ? c_gl[mi] : 4'd15;
    for (mi = 30; mi >= 0; mi = mi - 1) mt[mi] = (mt[2 * mi + 1] < mt[2 * mi + 2]) ? mt[2 * mi + 1] : mt[2 * mi + 2];
  end
  reg [3:0] exec_lvl;
  always @* begin
    exec_lvl = mt[0];
    if (basepri[7 -: PRIO_BITS] != PZ && lvl(basepri[7 -: PRIO_BITS] & gmask) < exec_lvl)
      exec_lvl = lvl(basepri[7 -: PRIO_BITS] & gmask);
    if (primask && exec_lvl > 4'd2) exec_lvl = 4'd2;
    if (faultmask && exec_lvl > 4'd1) exec_lvl = 4'd1;
  end

  assign usg_can = ena_usg && (lvl(pr_usg & gmask) < exec_lvl);
  assign bus_can = ena_bus && (lvl(pr_bus & gmask) < exec_lvl);
  assign svc_can = (lvl(pr_svc & gmask) < exec_lvl);
  assign hf_can  = (exec_lvl > 4'd1);

  // highest pending exception: smallest level, then smallest number (tree, left wins ties); registered
  reg        pv [0:62];
  reg [3:0]  pl [0:62];
  reg [3:0]  pg [0:62];
  reg [4:0]  pn [0:62];
  integer ti;
  always @* begin
    for (ti = 0; ti < 32; ti = ti + 1) begin
      pv[31 + ti] = c_pend[ti]; pl[31 + ti] = c_lv[ti]; pg[31 + ti] = c_gl[ti]; pn[31 + ti] = ti[4:0];
    end
    for (ti = 30; ti >= 0; ti = ti - 1) begin
      if (pv[2 * ti + 1] && (!pv[2 * ti + 2] || pl[2 * ti + 1] <= pl[2 * ti + 2])) begin
        pv[ti] = 1'b1; pl[ti] = pl[2 * ti + 1]; pg[ti] = pg[2 * ti + 1]; pn[ti] = pn[2 * ti + 1];
      end else begin
        pv[ti] = pv[2 * ti + 2]; pl[ti] = pl[2 * ti + 2]; pg[ti] = pg[2 * ti + 2]; pn[ti] = pn[2 * ti + 2];
      end
    end
  end
  reg  [3:0] best_glvl;
  reg  [8:0] best_num;
  reg        best_v;
  always @(posedge clk) begin
    if (!rst_n) begin
      best_v <= 1'b0; best_glvl <= 4'd15; best_num <= 9'd0;
    end else begin
      best_v <= pv[0]; best_glvl <= pg[0]; best_num <= {4'd0, pn[0]};
    end
  end
  assign take        = best_v && (best_glvl < exec_lvl);
  assign take_num    = best_num;
  assign any_pending = best_v;

  wire [NI+8:0] actv = {act_irq, act_nmi, act_hf, act_mem, act_bus, act_usg, act_svc, act_mon, act_pendsv, act_systick};
  assign ret_to_base = ((actv & (actv - 1'b1)) == {(NI + 9){1'b0}});

  // ---------------- register map ----------------
  // byte-lane write helper
  function [31:0] bw(input [31:0] old, input [31:0] nw, input [3:0] st);
    bw = {st[3] ? nw[31:24] : old[31:24], st[2] ? nw[23:16] : old[23:16],
          st[1] ? nw[15:8] : old[15:8], st[0] ? nw[7:0] : old[7:0]};
  endfunction

  wire [31:0] stcsr_v = {15'd0, st_flag, 13'd0, 1'b1, st_int, st_en};
  // priority byte of IRQ i
  function [7:0] pb(input [PRIO_BITS-1:0] p);
    pb = {p, {(8 - PRIO_BITS){1'b0}}};
  endfunction

  // pending / active / enable as 32-bit words
  wire [31:0] w_en   = {{(32 - NI){1'b0}}, en_irq};
  wire [31:0] w_pend = {{(32 - NI){1'b0}}, pend_irq};
  wire [31:0] w_act  = {{(32 - NI){1'b0}}, act_irq};
  wire        isr_pending = |(pend_irq);
  wire [31:0] icsr_v = {pend_nmi, 2'b00, pend_pendsv, 1'b0, pend_systick, 1'b0, 1'b0, isr_pending, 1'b0,
                        best_v ? best_num : 9'd0, ret_to_base, 2'b00, ipsr};
  wire [31:0] shcsr_v = {13'd0, ena_usg, ena_bus, ena_mem, pend_svc, pend_bus, pend_mem, pend_usg,
                         act_systick, act_pendsv, 1'b0, act_mon, act_svc, 3'b000, act_usg, 1'b0, act_bus, act_mem};

  reg [31:0] rd_c;
  integer ri;
  always @* begin
    rd_c = 32'd0;
    casez (addr)
      20'hE004: rd_c = {27'd0, 5'd0} | ((NI - 1) / 32);                        // ICTR
      20'hE008: rd_c = {22'd0, actlr};
      20'hE010: rd_c = stcsr_v;
      20'hE014: rd_c = {8'd0, st_reload};
      20'hE018: rd_c = {8'd0, st_cur};
      20'hE01C: rd_c = 32'hC000_0000;                                           // NOREF, SKEW
      20'hE100: rd_c = w_en;                                                    // ISER0
      20'hE180: rd_c = w_en;                                                    // ICER0
      20'hE200: rd_c = w_pend;                                                  // ISPR0
      20'hE280: rd_c = w_pend;                                                  // ICPR0
      20'hE300: rd_c = w_act;                                                   // IABR0
      20'hED00: rd_c = 32'h410F_C241;                                           // CPUID
      20'hED04: rd_c = icsr_v;
      20'hED08: rd_c = vtor_r;
      20'hED0C: rd_c = {16'hFA05, 5'd0, prigroup, 8'd0};
      20'hED10: rd_c = {27'd0, sevonpend, 1'b0, sleepdeep, sleeponexit_r, 1'b0};
      20'hED14: rd_c = {22'd0, stkalign_r, bfhfnmign, 3'd0, div0_r, unalign_r, 1'b0, usersetmpend, nonbasethrdena};
      20'hED18: rd_c = {8'd0, pb(pr_usg), pb(pr_bus), pb(pr_mem)};
      20'hED1C: rd_c = {pb(pr_svc), 24'd0};
      20'hED20: rd_c = {pb(pr_systick), pb(pr_pendsv), 16'd0};
      20'hED24: rd_c = shcsr_v;
      20'hED28: rd_c = cfsr;
      20'hED2C: rd_c = {1'b0, hf_forced, 28'd0, hf_vecttbl, 1'b0};
      20'hED34, 20'hED38: rd_c = bfar;
      20'hED40: rd_c = 32'h0000_0030;                                           // ID_PFR0
      20'hED44: rd_c = 32'h0000_0200;                                           // ID_PFR1
      20'hED48: rd_c = 32'h0010_0000;                                           // ID_DFR0
      20'hED50: rd_c = 32'h0010_0030;                                           // ID_MMFR0
      20'hED58: rd_c = 32'h0100_0000;                                           // ID_MMFR2
      20'hED60: rd_c = 32'h0114_1110;                                           // ID_ISAR0
      20'hED64: rd_c = 32'h0211_2000;
      20'hED68: rd_c = 32'h2123_2231;
      20'hED6C: rd_c = 32'h0111_1131;
      20'hED70: rd_c = 32'h0131_0132;
      20'hED88: rd_c = {8'd0, cpacr, 20'd0};                                    // CPACR
      20'hEDF0: rd_c = {14'd0, 1'b0, halted, 16'd0};                            // DHCSR (S_HALT)
      20'hEDFC: rd_c = {7'd0, trcena, 24'd0};                                   // DEMCR
      20'hEF34: rd_c = {aspen, lspen, 30'd0};                                   // FPCCR
      20'hEF38: rd_c = {fpcar, 3'd0};
      20'hEF3C: rd_c = {5'd0, fpdscr_r, 22'd0};
      20'hEF40: rd_c = 32'h1011_0021;                                           // MVFR0
      20'hEF44: rd_c = 32'h1100_0011;                                           // MVFR1
      // DWT_CTRL: no comparators, NOTRCPKT, NOEXTTRIG, NOPRFCNT (no profiling counters), CYCCNT
      20'h1000: rd_c = {4'd0, 1'b1, 1'b1, 1'b0, 1'b1, 23'd0, cyc_en};
      20'h1004: rd_c = cyccnt;
      default: begin
        if (addr[19:8] == 12'h0E4) begin                                        // NVIC_IPR
          for (ri = 0; ri < NI; ri = ri + 1)
            if (addr[7:2] == ri[7:2]) rd_c[8 * (ri & 3) +: 8] = pb(pr_irq[ri]);
        end
      end
    endcase
  end

  wire do_wr = acc && wr && priv;
  wire [31:0] wv = wdata;

  // ---------------- state update ----------------
  integer k;
  always @(posedge clk) begin
    if (!rst_n) begin
      vtor_r <= 32'd0; prigroup <= 3'd0;
      sleeponexit_r <= 1'b0; sleepdeep <= 1'b0; sevonpend <= 1'b0;
      stkalign_r <= 1'b1; bfhfnmign <= 1'b0; div0_r <= 1'b0; unalign_r <= 1'b0; usersetmpend <= 1'b0;
      nonbasethrdena <= 1'b0;
      pr_mem <= PZ; pr_bus <= PZ; pr_usg <= PZ; pr_svc <= PZ; pr_pendsv <= PZ; pr_systick <= PZ;
      for (k = 0; k < NI; k = k + 1) pr_irq[k] <= PZ;
      ena_usg <= 1'b0; ena_bus <= 1'b0; ena_mem <= 1'b0;
      pend_nmi <= 1'b0; pend_hf <= 1'b0; pend_mem <= 1'b0; pend_bus <= 1'b0; pend_usg <= 1'b0;
      pend_svc <= 1'b0; pend_pendsv <= 1'b0; pend_systick <= 1'b0;
      pend_irq <= {NI{1'b0}}; en_irq <= {NI{1'b0}}; irq_prev <= {NI{1'b0}};
      act_nmi <= 1'b0; act_hf <= 1'b0; act_mem <= 1'b0; act_bus <= 1'b0; act_usg <= 1'b0; act_svc <= 1'b0;
      act_mon <= 1'b0; act_pendsv <= 1'b0; act_systick <= 1'b0; act_irq <= {NI{1'b0}};
      cfsr <= 32'd0; bfar <= 32'd0; hf_forced <= 1'b0; hf_vecttbl <= 1'b0;
      cpacr <= 4'd0; aspen <= 1'b1; lspen <= 1'b1; fpcar <= 29'd0; fpdscr_r <= 5'd0; actlr <= 10'd0;
      trcena <= 1'b0;
      st_en <= 1'b0; st_int <= 1'b0; st_flag <= 1'b0; st_reload <= 24'd0; st_cur <= 24'd0;
      cyc_en <= 1'b0;
      cyccnt <= 32'd0;
      sysresetreq <= 1'b0; nmi_prev <= 1'b0;
      rdata <= 32'd0; err <= 1'b0;
    end else begin
      // ---- reads (registered) ----
      rdata <= rd_c;
      err   <= acc && !priv && !(wr && addr == 20'hEF00 && usersetmpend);
      if (acc && !wr && priv && addr == 20'hE010) st_flag <= 1'b0;             // COUNTFLAG clears on read

      // ---- interrupt lines: a rising edge pends, a high level pends while not active ----
      irq_prev <= irq;
      pend_irq <= pend_irq | (irq & ~irq_prev) | (irq & ~act_irq);
      nmi_prev <= nmi;
      if (nmi && !nmi_prev) pend_nmi <= 1'b1;

      // ---- SysTick ----
      if (st_en) begin
        if (st_cur == 24'd0) st_cur <= st_reload;
        else begin
          st_cur <= st_cur - 24'd1;
          if (st_cur == 24'd1) begin
            st_flag <= 1'b1;
            if (st_int) pend_systick <= 1'b1;
          end
        end
      end

      // ---- DWT ----
      if (trcena && cyc_en && !halted) cyccnt <= cyccnt + 32'd1;

      // ---- faults from the core ----
      cfsr <= cfsr | cfsr_set;
      if (hfsr_forced) hf_forced <= 1'b1;
      if (hfsr_vecttbl) hf_vecttbl <= 1'b1;
      if (bfar_we) bfar <= bfar_wd;
      if (pend_imprecise) begin
        cfsr[10] <= 1'b1;                                                        // IMPRECISERR
        if (ena_bus) pend_bus <= 1'b1; else pend_hf <= 1'b1;
        if (!ena_bus) hf_forced <= 1'b1;
      end

      // ---- exception entry / return ----
      if (exc_activate) begin
        case (exc_num)
          `EXC_NMI:       begin act_nmi <= 1'b1; pend_nmi <= 1'b0; end
          `EXC_HARDFAULT: begin act_hf <= 1'b1; pend_hf <= 1'b0; end
          `EXC_MEMMANAGE: begin act_mem <= 1'b1; pend_mem <= 1'b0; end
          `EXC_BUSFAULT:  begin act_bus <= 1'b1; pend_bus <= 1'b0; end
          `EXC_USAGE:     begin act_usg <= 1'b1; pend_usg <= 1'b0; end
          `EXC_SVCALL:    begin act_svc <= 1'b1; pend_svc <= 1'b0; end
          `EXC_PENDSV:    begin act_pendsv <= 1'b1; pend_pendsv <= 1'b0; end
          `EXC_SYSTICK:   begin act_systick <= 1'b1; pend_systick <= 1'b0; end
          default: begin
            for (k = 0; k < NI; k = k + 1)
              if (exc_num == 9'd16 + k[8:0]) begin
                act_irq[k] <= 1'b1;
                pend_irq[k] <= irq[k] & irq_prev[k] & 1'b0;  // cleared; a held level pends again after return
              end
          end
        endcase
      end
      if (exc_deactivate) begin
        case (exc_num)
          `EXC_NMI:       act_nmi <= 1'b0;
          `EXC_HARDFAULT: act_hf <= 1'b0;
          `EXC_MEMMANAGE: act_mem <= 1'b0;
          `EXC_BUSFAULT:  act_bus <= 1'b0;
          `EXC_USAGE:     act_usg <= 1'b0;
          `EXC_SVCALL:    act_svc <= 1'b0;
          `EXC_PENDSV:    act_pendsv <= 1'b0;
          `EXC_SYSTICK:   act_systick <= 1'b0;
          default: begin
            for (k = 0; k < NI; k = k + 1)
              if (exc_num == 9'd16 + k[8:0]) act_irq[k] <= 1'b0;
          end
        endcase
      end

      // ---- register writes ----
      if (do_wr) begin
        casez (addr)
          20'hE008: actlr <= {wv[9:8], 5'd0, wv[2:0]} & 10'h307;
          20'hE010: begin
            if (wstrb[0]) begin st_en <= wv[0]; st_int <= wv[1]; end
          end
          20'hE014: st_reload <= bw({8'd0, st_reload}, wv, wstrb) & 32'h00FF_FFFF;
          20'hE018: begin st_cur <= 24'd0; st_flag <= 1'b0; end                  // any write clears
          20'hE100: en_irq <= en_irq | wv[NI-1:0];
          20'hE180: en_irq <= en_irq & ~wv[NI-1:0];
          20'hE200: pend_irq <= pend_irq | wv[NI-1:0];
          20'hE280: pend_irq <= pend_irq & ~wv[NI-1:0];
          20'hED04: begin
            if (wv[31]) pend_nmi <= 1'b1;
            if (wv[28]) pend_pendsv <= 1'b1;
            if (wv[27]) pend_pendsv <= 1'b0;
            if (wv[26]) pend_systick <= 1'b1;
            if (wv[25]) pend_systick <= 1'b0;
          end
          20'hED08: vtor_r <= bw(vtor_r, wv, wstrb) & 32'hFFFF_FF80;
          20'hED0C: begin
            if (wv[31:16] == 16'h05FA) begin
              prigroup <= wv[10:8];
              if (wv[2]) sysresetreq <= 1'b1;
            end
          end
          20'hED10: if (wstrb[0]) begin sevonpend <= wv[4]; sleepdeep <= wv[2]; sleeponexit_r <= wv[1]; end
          20'hED14: begin
            if (wstrb[1]) begin stkalign_r <= wv[9]; bfhfnmign <= wv[8]; end
            if (wstrb[0]) begin div0_r <= wv[4]; unalign_r <= wv[3]; usersetmpend <= wv[1]; nonbasethrdena <= wv[0]; end
          end
          20'hED18: begin
            if (wstrb[0]) pr_mem <= wv[7 -: PRIO_BITS];
            if (wstrb[1]) pr_bus <= wv[15 -: PRIO_BITS];
            if (wstrb[2]) pr_usg <= wv[23 -: PRIO_BITS];
          end
          20'hED1C: if (wstrb[3]) pr_svc <= wv[31 -: PRIO_BITS];
          20'hED20: begin
            if (wstrb[2]) pr_pendsv <= wv[23 -: PRIO_BITS];
            if (wstrb[3]) pr_systick <= wv[31 -: PRIO_BITS];
          end
          20'hED24: begin
            if (wstrb[2]) begin ena_usg <= wv[18]; ena_bus <= wv[17]; ena_mem <= wv[16]; end
            if (wstrb[1]) begin pend_svc <= wv[15]; pend_bus <= wv[14]; pend_mem <= wv[13]; pend_usg <= wv[12];
                                act_systick <= wv[11]; act_pendsv <= wv[10]; act_mon <= wv[8]; end
            if (wstrb[0]) begin act_svc <= wv[7]; act_usg <= wv[3]; act_bus <= wv[1]; act_mem <= wv[0]; end
          end
          20'hED28: cfsr <= (cfsr | cfsr_set) & ~(wv & {wstrb[3] ? 8'hFF : 8'h00, wstrb[2] ? 8'hFF : 8'h00,
                                                      wstrb[1] ? 8'hFF : 8'h00, wstrb[0] ? 8'hFF : 8'h00});
          20'hED2C: begin
            if (wstrb[3] && wv[30]) hf_forced <= 1'b0;
            if (wstrb[0] && wv[1]) hf_vecttbl <= 1'b0;
          end
          20'hED34, 20'hED38: bfar <= bw(bfar, wv, wstrb);
          20'hED88: if (wstrb[2]) cpacr <= wv[23:20];
          20'hEDFC: if (wstrb[3]) trcena <= wv[24];
          20'hEF00: begin                                                        // STIR
            for (k = 0; k < NI; k = k + 1)
              if (wv[8:0] == k[8:0]) pend_irq[k] <= 1'b1;
          end
          20'hEF34: if (wstrb[3]) begin aspen <= wv[31]; lspen <= wv[30]; end
          20'hEF38: fpcar <= bw({fpcar, 3'd0}, wv, wstrb) >> 3;
          20'hEF3C: fpdscr_r <= bw({5'd0, fpdscr_r, 22'd0}, wv, wstrb) >> 22;
          20'h1000: if (wstrb[0]) cyc_en <= wv[0];
          20'h1004: cyccnt <= bw(cyccnt, wv, wstrb);
          default: begin
            if (addr[19:8] == 12'h0E4) begin
              for (k = 0; k < NI; k = k + 1)
                if (addr[7:2] == k[7:2] && wstrb[k & 3]) pr_irq[k] <= wv[8 * (k & 3) + 7 -: PRIO_BITS];
            end
          end
        endcase
      end
    end
  end

  assign sevonpend_ev = sevonpend && |(irq & ~irq_prev & ~pend_irq);

endmodule

`default_nettype wire
