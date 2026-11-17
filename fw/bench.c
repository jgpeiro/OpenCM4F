/*
 * bench.c - benchmark table and runner. Timing uses the PERF clock counters of the SoC: every clock
 * is counted in one class (retire, bubble, load/store, mul/div, FPU, exception, ...). While a
 * benchmark runs, the UI keeps drawing from the frame interrupt; its handler stops the counters on
 * entry and starts them again on return, and the exception entry/return clocks are not counted, so
 * the results do not depend on the UI.
 * SPDX-License-Identifier: MIT
 */
#include "bench.h"
#include "ui.h"

#ifndef SIM
#define CAL_MIN 2000000u           /* calibration: at least this many clocks */
#else
#define CAL_MIN 1000u
#endif

/* score = work x units / seconds; "ref": published Cortex-M4 figures per MHz (ARM: CoreMark 3.40 /
   MHz with an optimizing compiler, Dhrystone 1.25 DMIPS / MHz) */
const bench_t BENCH[NB] = {
    {"CoreMark", "iter/s", "EEMBC CoreMark 1.0: lists, matrices, state machine, CRC", C_CYAN, 1,
     1.0f, 3.40f, 11.0f, coremark_init, coremark_run},
    {"Dhrystone", "DMIPS", "Dhrystone 2.1: integer, strings, records (VAX MIPS = 1757 /s)", C_GREEN, 0,
     1.0f / 1757.0f, 1.25f, 2.0f, dhry_init, dhry_run_u},
    {"Whetstone", "MWIPS", "Whetstone, single precision: FPU, sin, cos, atan, exp, log, sqrt", C_ORANGE, 0,
     1.0f, 0.0f, 2.0f, whet_init, whet_run},
    {"FFT-256", "MFLOPS", "256-point complex FFT, float, radix 2 (5 N log2 N flops)", C_PURPLE, 0,
     10240e-6f, 0.0f, 2.0f, fft_init, fft_run},
    {"MatMul", "MFLOPS", "16 x 16 matrix product, float (2 N^3 flops)", C_BLUE, 0,
     8192e-6f, 0.0f, 2.0f, mm_init, mm_run},
    {"FIR Q15", "MMAC/s", "32-tap FIR, Q15, 2 MACs per SMLAD (DSP extension)", C_YELLOW, 0,
     8192e-6f, 0.0f, 2.0f, fir_init, fir_run},
    {"SHA-256", "MB/s", "SHA-256 of 1 KB: 32-bit rotates, adds, logic", C_RED, 0,
     1024e-6f, 0.0f, 2.0f, sha_init, sha_run},
    {"CRC-32", "MB/s", "CRC-32 of 4 KB, 256-entry table: loads", C_TEXT, 0,
     4096e-6f, 0.0f, 2.0f, crc_init, crc_run},
};

result_t RES[NB];
volatile int bench_cur = -1;
volatile int bench_phase;
volatile uint32_t bench_expect;
int bench_quick;
uint32_t clk_hz = 54000000;

int dhry_run_u(uint32_t n) { return dhry_run((int)n); }

/* ---------------- timing ---------------- */
static uint32_t t0[NPC], acc[NPC];
uint32_t t_last;                   /* clocks of the last t_begin .. t_end */
static uint32_t t_start_sum;
static volatile int timing;

static void pf_read(uint32_t *c)
{
    PERF(PF_CTRL) = 0;
    for (int k = 0; k < NPC; k++) c[k] = PERF(PF_CNT(k));
    PERF(PF_CTRL) = 1;
}

static uint32_t sum_noexc(const uint32_t *c)
{
    uint32_t s = 0;
    for (int k = 0; k < NPC; k++) if (k != PC_EXC) s += c[k];
    return s;
}

void t_begin(void)
{
    pf_read(t0);
    t_start_sum = sum_noexc(t0);
    timing = 1;
}

void t_end(void)
{
    uint32_t c[NPC];
    pf_read(c);
    timing = 0;
    uint32_t t = 0;
    for (int k = 0; k < NPC; k++) {
        uint32_t d = c[k] - t0[k];
        if (k == PC_EXC) continue;
        acc[k] += d;
        t += d;
    }
    t_last = t;
}

/* clocks of the current measurement so far (read from the frame interrupt: the counters are stopped) */
uint32_t bench_elapsed(void)
{
    if (!timing) return 0;
    uint32_t s = 0;
    for (int k = 0; k < NPC; k++) if (k != PC_EXC) s += PERF(PF_CNT(k));
    return s - t_start_sum;
}

/* ---------------- frame interrupt: the UI runs here while a benchmark runs ---------------- */
void ui_isr_frame(void);

void IRQ0_Handler(void);
__attribute__((naked)) void IRQ0_Handler(void)
{
    __asm volatile(
        "ldr r0, =0x40030000\n"          /* PERF CTRL = 0: stop counting */
        "movs r1, #0\n"
        "str r1, [r0]\n"
        "push {r4, lr}\n"
        "bl ui_isr_frame\n"
        "pop {r4, lr}\n"
        "ldr r0, =0x40030000\n"
        "movs r1, #1\n"
        "str r1, [r0]\n"                 /* counting again */
        "bx lr\n");
}

static void irq_on(void)
{
    IO(IO_IRQ) = 0x101;                  /* clear the flag, enable */
    NVIC_ICPR = 1;
    NVIC_ISER = 1;
}
static void irq_off(void)
{
    NVIC_ICER = 1;
    IO(IO_IRQ) = 0x100;
    __asm volatile("dsb\n isb" ::: "memory");
}

void bench_init(void)
{
    clk_hz = IO(IO_CLK);
    PERF(PF_CTRL) = 1;
#if defined(SIM) || defined(QUICK)
    bench_quick = 1;
#endif
}

/* one measurement of n units: clocks by class into r */
static int measure(int i, uint32_t n, result_t *r)
{
    const bench_t *b = &BENCH[i];
    for (int k = 0; k < NPC; k++) acc[k] = 0;
    int ok;
    if (b->self_timed) ok = b->run(n);
    else { t_begin(); ok = b->run(n); t_end(); }
    uint32_t t = 0;
    for (int k = 0; k < NPC; k++) { r->cls[k] = acc[k]; t += acc[k]; }
    r->clocks = t;
    r->instr = acc[PC_RETIRE];
    r->n = n;
    return ok;
}

void bench_run(int i)
{
    if (i < 0 || i > NB) return;
    bench_cur = i;
    irq_on();
    if (i == NB) {                       /* the ISA feature pairs */
        bench_phase = 1;
        bench_expect = 2000000;
        isa_run();
    } else {
        const bench_t *b = &BENCH[i];
        result_t r;
        RES[i].state = 1;
        b->init();
        /* calibration: double the units until it takes CAL_MIN clocks */
        bench_phase = 0;
        bench_expect = CAL_MIN;
        uint32_t n = 1;
        int ok = measure(i, n, &r);
        while (r.clocks < CAL_MIN && n < (1u << 20)) {
            n *= 2;
            bench_expect = r.clocks * 2;
            ok = measure(i, n, &r);
        }
        /* the measured run */
#ifdef SIM
        float secs = 0.002f;
#else
        float secs = bench_quick ? 0.25f : b->full_s;
        if (bench_quick && i == B_COREMARK) secs = 1.0f;
#endif
        float per = (float)r.clocks / (float)n;
        uint32_t units = (uint32_t)(secs * (float)clk_hz / per) + 1;
        if (units > n) {
            bench_phase = 1;
            bench_expect = (uint32_t)(per * (float)units);
            b->init();
            ok = measure(i, units, &r);
        }
        r.valid = (uint8_t)ok;
        r.score = b->work * (float)r.n * (float)clk_hz / (float)r.clocks;
        r.state = 2;
        r.runs = (uint8_t)(RES[i].runs + 1);
        RES[i] = r;
    }
    irq_off();
    bench_cur = -1;
}
