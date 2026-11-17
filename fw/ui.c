/*
 * ui.c - OpenCM4F Bench user interface: frame, input (rotary encoder and the two buttons), focus ring,
 * widgets, status bar, page tabs, toast; the frame interrupt handler that keeps the UI alive while a
 * benchmark runs; the fault screen. The pages are in pg_*.c. (Structure from Sat Signal Lab.)
 * SPDX-License-Identifier: MIT
 *
 * Rotary encoder:  turn           next / previous control (the green ring moves)
 *                  press          on a button: act; on a value: edit mode (orange ring), turn to change
 *                  hold 0.5 s     to the page tabs: turn to choose a page, press to use it
 * Buttons:         S1 click       next control      S1 hold   next page
 *                  S2 click       act / increase    S2 hold   decrease
 */
#include "ui.h"
#include "hw.h"
#include "bench.h"

const page_t PAGES[NPAGES] = {
    /*  name      icon      items  press (bit k: item k is a button) */
    {"Bench", IC_GAUGE, 11, 0x000007FE, pg_bench, act_bench},
    {"Scores", IC_BARS, 2, 0x00000002, pg_scores, act_scores},
    {"Cycles", IC_STACK, 1, 0x00000000, pg_cycles, act_cycles},
    {"ISA", IC_BOLT, 2, 0x00000002, pg_isa, act_isa},
    {"CPU", IC_CHIP, 1, 0x00000000, pg_cpu, act_cpu},
};

int T, page, fi;
volatile int run_req = -1;
int run_all;
static int fade = 16, tab_y2 = 50;
static int ring[4], ring_t[4], ring_r, ring_set;
static char toast[48];
static int toast_t;
static int s1_cnt, s2_cnt, s1_long, s2_long, s1_prev, s2_prev;
uint16_t load_hist[128];
int load_n;

#define LONG 30
#define ENC_STEPS 4                     /* quarter steps per detent (KY-040: 4) */
#define ENC_DIR   1
int enc_edit;
static int enc_last = -1, enc_acc, enc_sw_prev, enc_sw_cnt, enc_sw_long;

int ease(int v, int target, int k)
{
    int d = target - v;
    if (d == 0) return v;
    int s = d / k;
    if (s == 0) s = d > 0 ? 1 : -1;
    return v + s;
}

int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

void show_toast(const char *s)
{
    int i = 0;
    for (; s[i] && i < 47; i++) toast[i] = s[i];
    toast[i] = 0;
    toast_t = 90;
}

/* ---------------- widgets ---------------- */
void reg(int k, int x, int y, int w, int h, int r)
{
    if (k != fi) return;
    ring_t[0] = (x - 3) * 16; ring_t[1] = (y - 3) * 16; ring_t[2] = (w + 6) * 16; ring_t[3] = (h + 6) * 16;
    ring_r = r + 3;
    ring_set = 1;
}

void card(int x, int y, int w, int h)
{
    g_rect(x, y, w, h, 6, C_CARD, 16);
    g_frame(x, y, w, h, 6, 1, C_CARD_B, 16);
}

void title(int x, int y, const char *s) { g_text(x, y, 0, C_DIM, 16, s, ALIGN_L); }

void button(int k, int x, int y, int w, int h, const char *s, uint16_t col, int on)
{
    int f = k == fi;
    g_rect(x, y, w, h, 6, on ? col : (f ? C_GREEN_D : C_CARD), on ? 5 : 16);
    g_frame(x, y, w, h, 6, 1, on || f ? col : C_CARD_B, 16);
    g_text(x + w / 2, y + (h - 15) / 2, 0, on || f ? C_TEXT : C_DIM, 16, s, ALIGN_C);
    reg(k, x, y, w, h, 6);
}

void hbar(int x, int y, int w, int h, int frac, uint16_t col)
{
    frac = clampi(frac, 0, 1024);
    g_rect(x, y, w, h, h / 2, C_TRACK, 16);
    int fw = (w * frac) >> 10;
    if (fw >= h) g_rect(x, y, fw, h, h / 2, col, 16);
    else if (fw > 0) g_rect(x, y, h, h, h / 2, col, (16 * fw) / h);
}

/* donut chart: n segments of v[] (clockwise from the top), outer radius r, ring thickness t (pixels) */
void donut(int cx, int cy, int r, int t, const uint32_t *v, const uint16_t *col, int n)
{
    uint32_t tot = 0;
    for (int i = 0; i < n; i++) tot += v[i];
    g_arc2(2 * cx, 2 * cy, 2 * r, 2 * t, 0, 1024, C_TRACK, 16, 0);
    if (!tot) return;
    int a = -256;                               /* the top */
    for (int i = 0; i < n; i++) {
        int sw = (int)((float)v[i] * 1024.0f / (float)tot + 0.5f);
        if (sw > 3) g_arc2(2 * cx, 2 * cy, 2 * r, 2 * t, a & 1023, sw - (sw > 8 ? 3 : 1), col[i], 16, 0);
        a += sw;
    }
}

/* ---------------- numbers ---------------- */
char *fmt_sig(char *p, float v, int sig)
{
    if (v != v) return str_cat(p, "-");
    if (v < 0) { *p++ = '-'; v = -v; }
    int ip = 1;
    float t = 10.0f;
    while (v >= t && ip < 9) { ip++; t *= 10.0f; }
    int dec = clampi(sig - ip, 0, 4);
    float m = 1.0f;
    for (int i = 0; i < dec; i++) m *= 10.0f;
    return fmt_fix(p, (int)(v * m + 0.5f), dec);
}

/* clock classes, drawing order: retire, bubbles, load/store, mul/div, FPU, other (+exceptions, sleep) */
const uint8_t CLS_IDX[NCLS] = {PC_RETIRE, PC_BUBBLE, PC_LSU, PC_MULDIV, PC_FPU, PC_OTHER};
const uint16_t CLS_COL[NCLS] = {C_GREEN, C_CYAN, C_BLUE, C_PURPLE, C_ORANGE, C_FAINT};
const char *const CLS_NAME[NCLS] = {"Retire", "Fetch/branch", "Load/store", "Mul/div", "FPU", "Other"};
void cls_vals(const uint32_t *cls, uint32_t *v)
{
    for (int i = 0; i < NCLS; i++) v[i] = cls[CLS_IDX[i]];
    v[NCLS - 1] += cls[PC_SLEEP];
}

/* ---------------- status bar and page tabs ---------------- */
static void draw_frame(void)
{
    char b[48], *p;
    g_rect(0, 0, SCR_W, 22, 0, C_BAR, 16);
    int busy = bench_cur >= 0;
    int pulse = 10 + ((isin(T * 12) * 6) >> 14);
    g_circle2(22, 22, 12, busy ? C_ORANGE : C_GREEN, pulse / 2);
    g_circle2(22, 22, 7, busy ? C_ORANGE : C_GREEN, 16);
    g_text(20, 4, 0, C_TEXT, 16, "OpenCM4F Bench", ALIGN_L);
    p = str_cat(b, "Cortex-M4F  ");
    p = fmt_int(p, (int)(clk_hz / 1000000));
    str_cat(p, " MHz");
    int w = g_text_w(0, b) + 16;
    g_rect(124, 4, w, 15, 7, C_CYAN_D, 16);
    g_text(124 + w / 2, 4, 0, C_CYAN, 16, b, ALIGN_C);
    if (busy) {
        int i = bench_cur;
        p = str_cat(b, i == NB ? "ISA features" : BENCH[i].name);
        p = str_cat(p, bench_phase ? "  running " : "  calibrating ");
        if (bench_phase && bench_expect) {
            uint32_t e = bench_elapsed();
            int pc = (int)((float)e * 100.0f / (float)bench_expect);
            p = fmt_int(p, clampi(pc, 0, 99));
            str_cat(p, " %");
        }
        g_text(472, 4, 0, C_ORANGE, 16, b, ALIGN_R);
    } else {
        int n = 0;
        for (int i = 0; i < NB; i++) n += RES[i].state == 2;
        p = fmt_int(b, n);
        p = str_cat(p, " / 8 done   ");
        str_cat(p, bench_quick ? "quick" : "full");
        g_text(472, 4, 0, C_DIM, 16, b, ALIGN_R);
    }
    g_rect(0, 22, 63, SCR_H - 22, 0, C_BAR, 16);
    tab_y2 = ease(tab_y2, 2 * (25 + page * 49), 3);
    g_rect(4, tab_y2 / 2, 55, 46, 7, C_GREEN_D, 16);
    g_frame(4, tab_y2 / 2, 55, 46, 7, 1, C_GREEN, 16);
    for (int k = 0; k < NPAGES; k++) {
        int y = 25 + k * 49;
        g_icon(20, y + 3, PAGES[k].icon, k == page ? C_GREEN : C_DIM, 16);
        g_text(31, y + 28, 0, k == page ? C_TEXT : C_DIM, 16, PAGES[k].name, ALIGN_C);
    }
    reg(0, 4, 25 + page * 49, 55, 46, 7);
}

/* ---------------- input ---------------- */
static void go_page(int p)
{
    page = (p + NPAGES) % NPAGES;
    fi = 0;
    fade = 0;
}

static void act(int dir)
{
    if (fi == 0) { go_page(page + (dir > 0 ? 1 : -1)); return; }
    PAGES[page].act(fi, dir);
}

static int enc_detents(uint32_t e)
{
    int cnt = (int)(e & 0xFFFF);
    if (enc_last < 0) enc_last = cnt;
    int d = (int16_t)(cnt - enc_last);
    enc_last = cnt;
    enc_acc += d * ENC_DIR;
    int det = 0;
    while (enc_acc >= ENC_STEPS) { det++; enc_acc -= ENC_STEPS; }
    while (enc_acc <= -ENC_STEPS) { det--; enc_acc += ENC_STEPS; }
    if (((e >> 17) & 3) == 3) {                  /* at rest in a detent: round */
        if (2 * enc_acc >= ENC_STEPS) det++;
        else if (2 * enc_acc <= -ENC_STEPS) det--;
        enc_acc = 0;
    }
    return det;
}

static void encoder(int df)
{
    uint32_t e = IO(IO_ENC);
    int det = enc_detents(e);
    int sw = (e >> 16) & 1;
    int click = 0, hold = 0;
    if (sw) {
        int before = enc_sw_cnt;
        enc_sw_cnt += df;
        if (before < LONG && enc_sw_cnt >= LONG) { enc_sw_long = 1; hold = 1; }
    } else if (enc_sw_prev) {
        if (!enc_sw_long) click = 1;
        enc_sw_cnt = 0; enc_sw_long = 0;
    }
    enc_sw_prev = sw;
    if (hold) {
        fi = 0; enc_edit = 1;
        show_toast("Turn to choose a page, press to use it");
        return;
    }
    if (click) {
        if (enc_edit) enc_edit = 0;
        else if ((PAGES[page].press >> fi) & 1) PAGES[page].act(fi, +1);
        else if (fi == 0) enc_edit = 1;
        else PAGES[page].act(fi, +1);
    }
    if (!det) return;
    int n = det > 0 ? det : -det, dir = det > 0 ? 1 : -1;
    if (!enc_edit) {
        int m = PAGES[page].nitems;
        fi = ((fi + det) % m + m) % m;
        return;
    }
    for (int i = 0; i < n && i < 8; i++) {
        if (fi == 0) { page = (page + dir + NPAGES) % NPAGES; fade = 0; continue; }
        PAGES[page].act(fi, dir);
    }
}

static void input(int btn, int df)
{
    int s1 = btn & 1, s2 = (btn >> 1) & 1;
    if (s1 || s2) enc_edit = 0;
    if (s1) {
        int before = s1_cnt;
        s1_cnt += df;
        if (before < LONG && s1_cnt >= LONG) { s1_long = 1; go_page(page + 1); }
    } else if (s1_prev) {
        if (!s1_long) fi = (fi + 1) % PAGES[page].nitems;
        s1_cnt = 0; s1_long = 0;
    }
    if (s2) {
        int before = s2_cnt;
        s2_cnt += df;
        if (before < LONG && s2_cnt >= LONG) { s2_long = 1; act(-1); }
    } else if (s2_prev) {
        if (!s2_long) act(+1);
        s2_cnt = 0; s2_long = 0;
    }
    s1_prev = s1; s2_prev = s2;
    encoder(df);
}

void ui_init(void)
{
    ring[0] = 4 * 16; ring[1] = 25 * 16; ring[2] = 55 * 16; ring[3] = 46 * 16;
    fi = 1;
}

void ui_frame(int bank, int btn, int df)
{
    uint32_t c0 = DWT_CYCCNT;
    T += df;
    input(btn, df);
    if (fade < 16) fade += 2 * df;
    if (fade > 16) fade = 16;
    if (toast_t > 0) toast_t -= df;

    g_begin(bank);
    IO(IO_BG) = C_BG;
    ring_set = 0;
    draw_frame();
    g_opa = fade;
    PAGES[page].draw();
    g_opa = 16;
    if (ring_set)
        for (int k = 0; k < 4; k++) ring[k] = ease(ring[k], ring_t[k], 3);
    int pulse = 12 + ((isin(T * 14) * 4) >> 14);
    g_outline2(ring[0] / 8 + ring[2] / 16, ring[1] / 8 + ring[3] / 16, ring[2] / 16, ring[3] / 16, 2 * ring_r,
               enc_edit ? 6 : 4, enc_edit ? C_ORANGE : C_GREEN, enc_edit ? 16 : pulse);
    if (toast_t > 0) {
        int in = toast_t > 75 ? (90 - toast_t) : toast_t < 15 ? toast_t : 15;
        int w = g_text_w(0, toast) + 24, y = 246 + (15 - in);
        g_rect(272 - w / 2, y, w, 20, 10, C_DARK, in);
        g_frame(272 - w / 2, y, w, 20, 10, 1, C_GREEN, in);
        g_text(272, y + 3, 0, C_TEXT, in, toast, ALIGN_C);
    }
    g_end();
    /* clocks this frame took to build, in 1/1000 of the frame period (57.7 Hz) */
    uint32_t used = DWT_CYCCNT - c0;
    uint32_t per = 468000;                      /* a frame: 520 x 300 x 6 renderer clocks = 468000 CPU clocks */
    load_hist[load_n & 127] = (uint16_t)clampi((int)((float)used * 1000.0f / (float)per), 0, 1000);
    load_n++;
}

/* ---------------- frame interrupt (while a benchmark runs) ---------------- */
int cur_bank;
static uint32_t isr_sel_frame, isr_last;

void ui_isr_frame(void)
{
    IO(IO_IRQ) = 0x101;                         /* clear the frame flag (stay enabled) */
    uint32_t f = IO(IO_FRAME);
    if (f == isr_sel_frame) return;             /* the bank selected last is not on screen yet */
    int df = (int)(f - isr_last);
    if (df > 4) df = 4;
    if (df < 1) df = 1;
    isr_last = f;
    ui_frame(cur_bank, (int)IO(IO_BUTTONS), df);
    IO(IO_BANK) = (uint32_t)cur_bank;
    isr_sel_frame = IO(IO_FRAME);
    cur_bank ^= 1;
}

/* main loop: build a frame into the free bank, show it from the next frame start on, run what the UI
   asked for (the UI then runs from the frame interrupt) */
void ui_loop(void)
{
    uint32_t last = IO(IO_FRAME);
    int df = 1;
    for (;;) {
        ui_frame(cur_bank, (int)IO(IO_BUTTONS), df);
        IO(IO_BANK) = (uint32_t)cur_bank;
        uint32_t f0 = IO(IO_FRAME);
        while (IO(IO_FRAME) == f0) { }
        uint32_t now = IO(IO_FRAME);
        df = (int)(now - last);
        if (df > 4) df = 4;
        last = now;
        cur_bank ^= 1;
        if (run_req >= 0) {
            int r = run_req;
            run_req = -1;
            isr_sel_frame = now;
            isr_last = now;
            if (r == NB + 1) {                  /* everything */
                run_all = 1;
                for (int i = 0; i <= NB && run_all; i++) bench_run(i);
                run_all = 0;
                show_toast("All benchmarks done");
            } else {
                bench_run(r);
                if (r < NB) show_toast(RES[r].valid ? "Done: results check out" : "Done: WRONG RESULTS");
            }
            last = IO(IO_FRAME);
            /* wait for a frame start so that the bank the interrupt selected is on screen */
            uint32_t f1 = IO(IO_FRAME);
            while (IO(IO_FRAME) == f1) { }
        }
    }
}

/* ---------------- faults: stacked frame on a red screen ---------------- */
static char *hex8(char *p, uint32_t v)
{
    for (int i = 7; i >= 0; i--) { int d = (v >> (4 * i)) & 15; *p++ = (char)(d < 10 ? '0' + d : 'A' + d - 10); }
    *p = 0;
    return p;
}

void fault_report(uint32_t *frame, uint32_t exc)
{
    irq_disable();
    int bank = 0;
    for (;;) {
        char b[40], *p;
        g_begin(bank);
        IO(IO_BG) = RGB(80, 10, 10);
        p = str_cat(b, "Fault ");
        p = fmt_int(p, (int)(exc & 511));
        p = str_cat(p, "  PC ");
        p = hex8(p, frame[6]);
        p = str_cat(p, "  LR ");
        hex8(p, frame[5]);
        g_text(20, 20, 0, C_WHITE, 16, b, ALIGN_L);
        p = str_cat(b, "CFSR ");
        p = hex8(p, REG32(0xE000ED28));
        p = str_cat(p, "  BFAR ");
        hex8(p, REG32(0xE000ED38));
        g_text(20, 40, 0, C_WHITE, 16, b, ALIGN_L);
        g_end();
        IO(IO_BANK) = (uint32_t)bank;
        uint32_t f0 = IO(IO_FRAME);
        while (IO(IO_FRAME) == f0) { }
        bank ^= 1;
    }
}
