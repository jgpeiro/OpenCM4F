/*
 * bench.h - benchmark table, timing with the PERF clock counters, results
 * SPDX-License-Identifier: MIT
 */
#pragma once
#include <stdint.h>
#include "hw.h"

enum { B_COREMARK, B_DHRY, B_WHET, B_FFT, B_MATMUL, B_FIR, B_SHA, B_CRC, NB };

typedef struct {
    const char *name, *unit, *info;
    uint16_t col;
    uint8_t self_timed;             /* the benchmark calls t_begin / t_end itself (CoreMark) */
    float work;                     /* score units per run unit: score = work * units / seconds */
    float ref;                      /* published Cortex-M4 score per MHz (0: none) */
    float full_s;                   /* run time in "full" mode, seconds */
    void (*init)(void);
    int (*run)(uint32_t n);         /* n units; 1 if the results check out */
} bench_t;

typedef struct {
    uint32_t cls[NPC];              /* timed clocks by class (exception entry/return of the UI not counted) */
    uint32_t clocks;                /* timed clocks */
    uint32_t n;                     /* run units */
    uint32_t instr;                 /* instructions */
    float score;                    /* at the system clock */
    uint8_t state;                  /* 0 not run, 1 running, 2 done */
    uint8_t valid;                  /* results checked */
    uint8_t runs;                   /* runs so far */
} result_t;

extern const bench_t BENCH[NB];
extern result_t RES[NB];
extern volatile int bench_cur;      /* benchmark running (-1: none) */
extern volatile int bench_phase;    /* 0 calibrate, 1 measure */
extern volatile uint32_t bench_expect;   /* clocks the measured run should take */
extern int bench_quick;             /* 1: short runs (CoreMark result not valid: < 10 s) */
extern uint32_t clk_hz;

void bench_init(void);
void bench_run(int i);              /* blocks; the UI keeps running from the frame interrupt */
uint32_t bench_elapsed(void);       /* timed clocks of the current run so far */
void t_begin(void);
void t_end(void);

/* ISA feature micro-benchmarks (bm_isa.c): clocks per element without and with the feature */
enum { F_DSP, F_DIV, F_FPU, F_BIT, NFEAT };
typedef struct { const char *name, *base, *feat; uint16_t col; } feat_t;
extern const feat_t FEAT[NFEAT];
extern float feat_cpe[NFEAT][2];    /* clocks per element: [0] plain code, [1] with the feature */
extern uint8_t feat_ok[NFEAT];
extern int feat_done;
void isa_run(void);

/* kernels (bm_*.c) */
int  coremark_run(uint32_t n);
void coremark_init(void);
extern char cm_log[640];
void dhry_init(void);
int  dhry_run(int n);
int  dhry_run_u(uint32_t n);
void whet_init(void);
int  whet_run(uint32_t n);
void fft_init(void);
int  fft_run(uint32_t n);
void mm_init(void);
int  mm_run(uint32_t n);
void fir_init(void);
int  fir_run(uint32_t n);
void sha_init(void);
int  sha_run(uint32_t n);
void crc_init(void);
int  crc_run(uint32_t n);

/* scratch memory shared by the kernels (one benchmark at a time) */
#define SCRATCH_WORDS 1536
extern uint32_t scratch[SCRATCH_WORDS];
