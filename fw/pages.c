/*
 * pages.c - the five pages: Bench (list, run, details with a donut of the clock classes),
 * Scores (bullet chart per MHz against published Cortex-M4 figures), Cycles (100 % stacked bars
 * of the clock classes, CPI), ISA (with / without a feature, speed-up), CPU (what the core is,
 * pipeline diagram, live UI frame-time chart)
 * SPDX-License-Identifier: MIT
 */
#include "ui.h"
#include "hw.h"
#include "bench.h"

int per_mhz = 1;
static const char *const CLS_SHORT[NCLS] = {"Retire", "Fetch", "Ld/St", "Mul/Div", "FPU", "Other"};

static void busy_toast(void) { show_toast("A benchmark is running"); }

static float mhz(void) { return (float)clk_hz * 1e-6f; }

/* draws s word-wrapped in width w, at most n lines of 15 pixels; returns the lines used */
static int wrap(int x, int y, int w, const char *s, uint16_t col, int n)
{
    char line[64];
    int ln = 0;
    while (*s && ln < n) {
        int len = 0, lw = 0, sp = -1;
        while (s[len] && len < 63) {
            int cw = g_char_w(s[len]);
            if (lw + cw > w) break;
            if (s[len] == ' ') sp = len;
            lw += cw;
            len++;
        }
        int end = (s[len] && sp > 0) ? sp : len;
        for (int i = 0; i < end; i++) line[i] = s[i];
        line[end] = 0;
        g_text(x, y + ln * 15, 0, col, 16, line, ALIGN_L);
        s += end;
        while (*s == ' ') s++;
        ln++;
    }
    return ln;
}

static char *pct(char *p, uint32_t v, uint32_t tot)
{
    p = fmt_int(p, tot ? (int)((float)v * 100.0f / (float)tot + 0.5f) : 0);
    return str_cat(p, "%");
}

/* =====================================================================================
 * Bench
 * ===================================================================================== */
static int last_sel;

void act_bench(int k, int dir)
{
    (void)dir;
    if (k >= 1 && k <= 10 && bench_cur >= 0) { busy_toast(); return; }
    if (k >= 1 && k <= NB) run_req = k - 1;
    else if (k == 9) run_req = NB + 1;
    else if (k == 10) bench_quick ^= 1;
}

void pg_bench(void)
{
    char b[48], *p;
    /* list */
    card(68, 26, 206, 242);
    title(78, 30, "Benchmark");
    g_text(264, 30, 0, C_DIM, 16, per_mhz ? "per MHz" : "score", ALIGN_R);
    for (int i = 0; i < NB; i++) {
        int y = 50 + i * 22, f = fi == i + 1, run = bench_cur == i;
        const result_t *r = &RES[i];
        if (f || run) g_rect(72, y - 2, 198, 20, 5, run ? C_CYAN_D : C_GREEN_D, 16);
        g_rect(76, y + 3, 3, 11, 1, BENCH[i].col, 16);
        g_text(84, y, 0, f || run ? C_TEXT : C_DIM, 16, BENCH[i].name, ALIGN_L);
        if (run && bench_phase && bench_expect) {
            uint32_t e = bench_elapsed();
            hbar(170, y + 6, 92, 6, (int)((float)e * 1024.0f / (float)bench_expect), C_CYAN);
        } else if (run) {
            g_text(264, y, 0, C_CYAN, 16, "...", ALIGN_R);
        } else if (r->state == 2) {
            p = fmt_sig(b, per_mhz ? r->score / mhz() : r->score, 3);
            g_text(264, y, 0, r->valid ? BENCH[i].col : C_RED, 16, b, ALIGN_R);
            if (r->valid) g_circle2(2 * 166, 2 * (y + 8), 3, C_GREEN, 12);
        } else {
            g_text(264, y, 0, C_FAINT, 16, "-", ALIGN_R);
        }
        reg(i + 1, 72, y - 2, 198, 20, 5);
    }
    button(9, 76, 230, 92, 30, run_all ? "Running..." : "Run all", C_GREEN, run_all);
    button(10, 174, 230, 92, 30, bench_quick ? "Quick runs" : "Full runs", C_CYAN, 0);

    /* details */
    int d = bench_cur >= 0 && bench_cur < NB ? bench_cur : (fi >= 1 && fi <= NB ? fi - 1 : last_sel);
    last_sel = d;
    const bench_t *bb = &BENCH[d];
    const result_t *r = &RES[d];
    card(280, 26, 196, 242);
    g_text(290, 30, 0, bb->col, 16, bb->name, ALIGN_L);
    g_text(466, 30, 0, C_DIM, 16, bb->unit, ALIGN_R);
    int running = bench_cur == d;
    if (running) {
        uint32_t e = bench_elapsed();
        int pc = bench_expect ? clampi((int)((float)e * 100.0f / (float)bench_expect), 0, 99) : 0;
        g_arc2(2 * 378, 2 * 132, 2 * 52, 2 * 10, 0, 1024, C_TRACK, 16, 0);
        if (bench_phase) g_arc2(2 * 378, 2 * 132, 2 * 52, 2 * 10, -256 & 1023, clampi(pc * 1024 / 100, 4, 1023), bb->col, 16, 1);
        else g_arc2(2 * 378, 2 * 132, 2 * 52, 2 * 10, (T * 24) & 1023, 160, bb->col, 16, 1);
        p = fmt_int(b, pc);
        if (bench_phase) g_text(378, 122, 1, C_TEXT, 16, b, ALIGN_C);
        g_text(378, 196, 0, C_DIM, 16, bench_phase ? "measuring" : "calibrating", ALIGN_C);
        wrap(290, 218, 178, bb->info, C_DIM, 3);
        return;
    }
    if (r->state != 2) {
        g_text(290, 56, 1, C_FAINT, 16, "-", ALIGN_L);
        wrap(290, 92, 178, bb->info, C_DIM, 4);
        g_text(378, 220, 0, C_DIM, 16, "Press to run", ALIGN_C);
        return;
    }
    p = fmt_sig(b, r->score, 4);
    int w = g_text(290, 52, 1, C_TEXT, 16, b, ALIGN_L);
    g_text(296 + w, 55, 0, C_DIM, 16, "@", ALIGN_L);
    p = fmt_int(b, (int)(clk_hz / 1000000));
    str_cat(p, " MHz");
    g_text(308 + w, 55, 0, C_DIM, 16, b, ALIGN_L);
    p = fmt_sig(b, r->score / mhz(), 3);
    p = str_cat(p, " / MHz");
    g_text(290, 74, 0, bb->col, 16, b, ALIGN_L);
    if (bb->ref > 0.0f) {
        p = str_cat(b, "M4 ");
        p = fmt_sig(p, bb->ref, 3);
        g_text(466, 74, 0, C_DIM, 16, b, ALIGN_R);
    }
    /* donut of the clock classes, legend */
    uint32_t v[NCLS], tot = 0;
    cls_vals(r->cls, v);
    for (int i = 0; i < NCLS; i++) tot += v[i];
    donut(330, 140, 40, 13, v, CLS_COL, NCLS);
    p = fmt_sig(b, (float)r->clocks / (float)(r->instr ? r->instr : 1), 3);
    g_text(330, 125, 0, C_TEXT, 16, b, ALIGN_C);
    g_text(330, 140, 0, C_DIM, 16, "CPI", ALIGN_C);
    for (int i = 0; i < NCLS; i++) {
        int y = 96 + i * 15;
        g_circle2(2 * 384, 2 * (y + 8), 7, CLS_COL[i], 16);
        g_text(392, y, 0, C_DIM, 16, CLS_SHORT[i], ALIGN_L);
        pct(b, v[i], tot);
        g_text(468, y, 0, C_TEXT, 16, b, ALIGN_R);
    }
    /* checks */
    if (d == B_COREMARK) {
        float secs = (float)r->clocks / (float)clk_hz;
        p = str_cat(b, r->valid ? "CRCs ok, " : "CRC ERROR, ");
        p = fmt_sig(p, secs, 3);
        str_cat(p, secs >= 10.0f ? " s: valid" : " s (< 10 s)");
        g_text(290, 196, 0, r->valid ? (secs >= 10.0f ? C_GREEN : C_YELLOW) : C_RED, 16, b, ALIGN_L);
    } else {
        g_text(290, 196, 0, r->valid ? C_GREEN : C_RED, 16, r->valid ? "Results check out" : "WRONG RESULTS", ALIGN_L);
    }
    p = fmt_sig(b, (float)r->instr * 1e-6f, 3);
    p = str_cat(p, " M instr, ");
    p = fmt_sig(p, (float)r->clocks * 1e-6f, 3);
    str_cat(p, " M clk");
    g_text(290, 214, 0, C_DIM, 16, b, ALIGN_L);
    p = str_cat(b, "run ");
    p = fmt_int(p, r->runs);
    p = str_cat(p, ", ");
    p = fmt_int(p, (int)r->n);
    str_cat(p, " units");
    g_text(290, 232, 0, C_FAINT, 16, b, ALIGN_L);
}

/* =====================================================================================
 * Scores: one row per benchmark, bar = score per MHz on its own scale, tick = Cortex-M4
 * ===================================================================================== */
void act_scores(int k, int dir) { (void)dir; if (k == 1) per_mhz ^= 1; }

void pg_scores(void)
{
    char b[48], *p;
    card(68, 26, 408, 242);
    g_text(78, 30, 0, C_TEXT, 16, per_mhz ? "Score per MHz" : "Score at the system clock", ALIGN_L);
    button(1, 372, 29, 96, 20, per_mhz ? "per MHz" : "absolute", C_CYAN, 0);
    for (int i = 0; i < NB; i++) {
        int y = 58 + i * 24;
        const result_t *r = &RES[i];
        const bench_t *bb = &BENCH[i];
        g_text(78, y, 0, C_TEXT, 16, bb->name, ALIGN_L);
        float v = r->state == 2 ? r->score : 0.0f, ref = bb->ref;
        if (per_mhz) v /= mhz(); else ref *= mhz();
        float mx = (v > ref ? v : ref) * 1.25f;
        g_rect(160, y + 4, 200, 9, 4, C_TRACK, 16);
        if (v > 0.0f) {
            int w = (int)(200.0f * v / mx);
            g_rect(160, y + 4, w < 9 ? 9 : w, 9, 4, bb->col, 16);
        }
        if (ref > 0.0f) {
            int x = 160 + (int)(200.0f * ref / mx);
            g_rect(x - 1, y, 3, 17, 1, C_WHITE, 14);
        }
        if (r->state == 2) {
            p = fmt_sig(b, v, 3);
            int w = g_text(368, y, 0, r->valid ? C_TEXT : C_RED, 16, b, ALIGN_L);
            g_text(372 + w, y, 0, C_DIM, 16, bb->unit, ALIGN_L);
        } else {
            g_text(368, y, 0, C_FAINT, 16, "not run", ALIGN_L);
        }
    }
    g_rect(160, 252, 3, 12, 1, C_WHITE, 14);
    g_text(168, 250, 0, C_DIM, 16, "Cortex-M4, published by ARM (Keil MDK / IAR)", ALIGN_L);
}

/* =====================================================================================
 * Cycles: 100 % stacked bars of the clock classes, CPI
 * ===================================================================================== */
void act_cycles(int k, int dir) { (void)k; (void)dir; }

void pg_cycles(void)
{
    char b[32];
    card(68, 26, 408, 242);
    g_text(78, 30, 0, C_TEXT, 16, "Where the clocks go", ALIGN_L);
    g_text(466, 30, 0, C_DIM, 16, "CPI", ALIGN_R);
    for (int i = 0; i < NB; i++) {
        int y = 56 + i * 22;
        const result_t *r = &RES[i];
        g_text(78, y, 0, C_TEXT, 16, BENCH[i].name, ALIGN_L);
        int x = 160, W = 250;
        if (r->state != 2) {
            g_rect(x, y + 3, W, 11, 3, C_TRACK, 16);
            g_text(466, y, 0, C_FAINT, 16, "-", ALIGN_R);
            continue;
        }
        uint32_t v[NCLS], tot = 0;
        cls_vals(r->cls, v);
        for (int k = 0; k < NCLS; k++) tot += v[k];
        int acc = 0, x0 = x;
        for (int k = 0; k < NCLS; k++) {
            acc += (int)v[k];
            int x1 = x + (int)((float)acc * (float)W / (float)(tot ? tot : 1));
            if (x1 > x0) g_rect(x0, y + 3, x1 - x0, 11, 0, CLS_COL[k], 16);
            x0 = x1;
        }
        fmt_sig(b, (float)r->clocks / (float)(r->instr ? r->instr : 1), 3);
        g_text(466, y, 0, C_TEXT, 16, b, ALIGN_R);
    }
    for (int k = 0; k < NCLS; k++) {
        int x = 80 + k * 66;
        g_rect(x, 238, 10, 10, 2, CLS_COL[k], 16);
        g_text(x + 14, 235, 0, C_DIM, 16, CLS_SHORT[k], ALIGN_L);
    }
    g_text(78, 252, 0, C_FAINT, 16, "Retire = 1 clock per instruction; the rest are stalls", ALIGN_L);
}

/* =====================================================================================
 * ISA: clocks per element with and without a feature
 * ===================================================================================== */
void act_isa(int k, int dir)
{
    (void)dir;
    if (k != 1) return;
    if (bench_cur >= 0) { busy_toast(); return; }
    run_req = NB;
}

void pg_isa(void)
{
    char b[32];
    card(68, 26, 408, 242);
    g_text(78, 30, 0, C_TEXT, 16, "ISA features: clocks per element", ALIGN_L);
    button(1, 396, 29, 72, 20, bench_cur == NB ? "..." : "Run", C_GREEN, bench_cur == NB);
    for (int f = 0; f < NFEAT; f++) {
        int y = 56 + f * 52;
        g_text(78, y, 0, C_TEXT, 16, FEAT[f].name, ALIGN_L);
        g_text(78, y + 17, 0, C_DIM, 16, FEAT[f].base, ALIGN_L);
        g_text(78, y + 32, 0, C_GREEN, 16, FEAT[f].feat, ALIGN_L);
        float c0 = feat_cpe[f][0], c1 = feat_cpe[f][1];
        if (!feat_done) {
            g_rect(160, y + 21, 190, 8, 4, C_TRACK, 16);
            g_rect(160, y + 36, 190, 8, 4, C_TRACK, 16);
            continue;
        }
        float mx = c0 > c1 ? c0 : c1;
        int w0 = (int)(190.0f * c0 / mx), w1 = (int)(190.0f * c1 / mx);
        g_rect(160, y + 21, w0 < 8 ? 8 : w0, 8, 4, C_FAINT, 16);
        g_rect(160, y + 36, w1 < 8 ? 8 : w1, 8, 4, C_GREEN, 16);
        fmt_sig(b, c0, 3);
        g_text(166 + (w0 < 8 ? 8 : w0), y + 17, 0, C_DIM, 16, b, ALIGN_L);
        fmt_sig(b, c1, 3);
        g_text(166 + (w1 < 8 ? 8 : w1), y + 32, 0, C_TEXT, 16, b, ALIGN_L);
        b[0] = 'x';
        fmt_sig(b + 1, c1 > 0.0f ? c0 / c1 : 0.0f, 3);
        g_text(466, y + 18, 1, feat_ok[f] ? C_GREEN : C_RED, 16, b, ALIGN_R);
        if (!feat_ok[f]) g_text(466, y, 0, C_RED, 16, "mismatch", ALIGN_R);
    }
}

/* =====================================================================================
 * CPU
 * ===================================================================================== */
void act_cpu(int k, int dir) { (void)k; (void)dir; }

static char *hex8(char *p, uint32_t v)
{
    for (int i = 7; i >= 0; i--) { int d = (v >> (4 * i)) & 15; *p++ = (char)(d < 10 ? '0' + d : 'A' + d - 10); }
    *p = 0;
    return p;
}

static int prio_bits;

static void unit(int x, int y, int w, const char *s, uint16_t col)
{
    g_rect(x, y, w, 18, 4, col, 5);
    g_frame(x, y, w, 18, 4, 1, col, 16);
    g_text(x + w / 2, y + 1, 0, C_TEXT, 16, s, ALIGN_C);
}

void pg_cpu(void)
{
    char b[48], *p;
    if (!prio_bits) {                                     /* implemented priority bits */
        uint32_t old = NVIC_IPR0;
        NVIC_IPR0 = 0xFF;
        uint32_t v = NVIC_IPR0 & 0xFF;
        NVIC_IPR0 = old;
        while (v & 0x80) { prio_bits++; v <<= 1; }
    }
    card(68, 26, 200, 242);
    g_text(78, 30, 0, C_TEXT, 16, "OpenCM4F", ALIGN_L);
    uint32_t id = SCB_CPUID;
    p = str_cat(b, "CPUID ");
    hex8(p, id);
    g_text(78, 50, 0, C_DIM, 16, b, ALIGN_L);
    p = str_cat(b, ((id >> 4) & 0xFFF) == 0xC24 ? "Cortex-M4 r" : "unknown r");
    p = fmt_int(p, (int)((id >> 20) & 15));
    p = str_cat(p, "p");
    fmt_int(p, (int)(id & 15));
    g_text(78, 66, 0, C_CYAN, 16, b, ALIGN_L);
    g_text(78, 86, 0, C_TEXT, 16, "ARMv7E-M, Thumb-2", ALIGN_L);
    g_text(78, 102, 0, (SCB_ID_ISAR3 & 0xF) >= 3 ? C_TEXT : C_DIM, 16, "DSP: SIMD, saturation, MACs", ALIGN_L);
    g_text(78, 118, 0, (FPU_MVFR0 & 0xF0) ? C_TEXT : C_DIM, 16,
           (FPU_MVFR0 & 0xF0) ? "FPv4-SP FPU, 32 regs" : "no FPU", ALIGN_L);
    p = str_cat(b, "NVIC ");
    p = fmt_int(p, (int)(32 * ((ICTR & 15) + 1)));
    p = str_cat(p, " max, ");
    p = fmt_int(p, 1 << prio_bits);
    str_cat(p, " levels");
    g_text(78, 134, 0, C_TEXT, 16, b, ALIGN_L);
    uint32_t ms = IO(IO_MEMSZ);
    p = str_cat(b, "ROM ");
    p = fmt_int(p, (int)(ms >> 26));
    p = str_cat(p, " KB, RAM ");
    p = fmt_int(p, (int)((ms & 0xFFFF) >> 10));
    str_cat(p, " KB");
    g_text(78, 150, 0, C_TEXT, 16, b, ALIGN_L);
    g_text(78, 166, 0, C_TEXT, 16, "AXI4-Lite I and D buses", ALIGN_L);
    g_text(78, 182, 0, C_TEXT, 16, "SysTick, DWT cycle counter", ALIGN_L);
    p = str_cat(b, "Clock ");
    p = fmt_int(p, (int)(clk_hz / 1000000));
    str_cat(p, " MHz, Tang Nano 20K");
    g_text(78, 198, 0, C_TEXT, 16, b, ALIGN_L);
    g_text(78, 222, 0, C_DIM, 16, "GW2AR-18 FPGA, 480x272 LCD,", ALIGN_L);
    g_text(78, 238, 0, C_DIM, 16, "display-list renderer", ALIGN_L);

    /* pipeline */
    card(276, 26, 200, 126);
    g_text(286, 30, 0, C_DIM, 16, "Pipeline", ALIGN_L);
    static const char *const ST[3] = {"Fetch", "Decode", "Execute"};
    for (int s = 0; s < 3; s++) {
        int x = 286 + s * 62;
        unit(x, 50, 54, ST[s], s == 2 ? C_GREEN : C_CYAN);
        if (s < 2) g_rect(x + 54, 58, 8, 2, 0, C_DIM, 16);
    }
    int ph = (T >> 2) % 3;                               /* an instruction moving through */
    g_circle2(2 * (313 + ph * 62), 2 * 76, 4, C_YELLOW, 16);
    static const char *const EU[6] = {"ALU", "MUL", "DIV", "LSU", "FPU", "SCS"};
    for (int u = 0; u < 6; u++) unit(286 + (u % 3) * 62, 84 + (u / 3) * 22, 54, EU[u], u == 4 ? C_ORANGE : C_FAINT);
    g_text(286, 130, 0, C_FAINT, 16, "I-bus: 8 halfword queue", ALIGN_L);

    /* UI frame time */
    card(276, 158, 200, 110);
    g_text(286, 162, 0, C_DIM, 16, "UI frame time", ALIGN_L);
    int last = load_hist[(load_n - 1) & 127];
    p = fmt_int(b, last / 10);
    *p++ = '.';
    p = fmt_int(p, last % 10);
    str_cat(p, " %");
    g_text(466, 162, 0, C_TEXT, 16, b, ALIGN_R);
    int x0 = 300, y0 = 184, h = 76;
    g_rect(x0, y0, 128, h, 3, C_PLOT, 16);
    for (int k = 1; k < 4; k++) g_rect(x0, y0 + k * h / 4, 128, 1, 0, C_GRID, 16);
    g_text(x0 - 4, y0 - 6, 0, C_FAINT, 16, "40", ALIGN_R);
    g_text(x0 - 4, y0 + h - 10, 0, C_FAINT, 16, "0", ALIGN_R);
    volatile uint32_t *w;
    int a = g_words(128, &w);
    if (a >= 0) {
        int top = y0 * 16, bot = (y0 + h) * 16;
        for (int i = 0; i < 128; i++) {
            int v = load_hist[(load_n + i) & 127];                 /* oldest first */
            int yy = bot - v * h * 16 / 400;                         /* 0..40 % of a frame */
            yy = clampi(yy, top, bot - 16);
            w[i] = (uint32_t)yy | ((uint32_t)bot << 16);
        }
        g_span_at(a, x0, x0 + 127, y0, y0 + h - 1, 0, C_CYAN, 6);      /* area under the curve */
    }
    int b2 = g_words(128, &w);
    if (b2 >= 0) {
        int top = y0 * 16, bot = (y0 + h) * 16;
        for (int i = 0; i < 128; i++) {
            int v = load_hist[(load_n + i) & 127];
            int yy = clampi(bot - v * h * 16 / 400, top, bot - 16);
            w[i] = (uint32_t)(yy - 8) | ((uint32_t)(yy + 16) << 16);
        }
        g_span_at(b2, x0, x0 + 127, y0, y0 + h - 1, 0, C_CYAN, 16);
    }
    g_text(x0 + 64, y0 + h - 16, 0, C_FAINT, 16, "% of a frame (17.3 ms)", ALIGN_C);
}
