/*
 * bm_isa.c - what the ARMv7E-M features buy: the same work with and without one feature, in clocks
 * per element (256 elements, PERF clock counters, exception clocks of the UI excluded)
 *   DSP  Q15 dot product: LDRSH + MLA per element  vs  LDR + SMLAD (two 16 x 16 MACs per instruction)
 *   DIV  32-bit unsigned division: shift-and-subtract loop  vs  UDIV
 *   FPU  float multiply-add: software floating point (C)  vs  VMUL + VADD (FPv4-SP)
 *   BIT  bit reverse + leading zeros: C loops  vs  RBIT + CLZ
 * Both versions must give the same results.
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include "bench.h"

const feat_t FEAT[NFEAT] = {
    {"DSP: Q15 MAC", "LDRSH + MLA", "SMLAD", 0},
    {"Divide", "C loop", "UDIV", 0},
    {"Float MAC", "soft float", "FPU", 0},
    {"Bit reverse", "C loop", "RBIT+CLZ", 0},
};
float feat_cpe[NFEAT][2];
uint8_t feat_ok[NFEAT];
int feat_done;

#define NE 256
#define BARRIER(x) __asm volatile("" : "+r"(x))

static uint32_t rs = 0x2545F491;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }

/* ---------------- DSP ---------------- */
__attribute__((noinline)) static int32_t dot_mla(const int16_t *a, const int16_t *b, int n)
{
    int32_t acc = 0;
    for (int i = 0; i < n; i++) {
        int32_t x = a[i], y = b[i];
        __asm("mla %0, %1, %2, %0" : "+r"(acc) : "r"(x), "r"(y));
    }
    return acc;
}
__attribute__((noinline)) static int32_t dot_smlad(const int16_t *a, const int16_t *b, int n)
{
    const uint32_t *p = (const uint32_t *)a, *q = (const uint32_t *)b;
    int32_t acc = 0;
    for (int i = 0; i < n / 2; i++) __asm("smlad %0, %1, %2, %0" : "+r"(acc) : "r"(p[i]), "r"(q[i]));
    return acc;
}

/* ---------------- DIV ---------------- */
__attribute__((noinline)) static uint32_t udiv_soft(uint32_t n, uint32_t d)
{
    uint32_t q = 0, r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        BARRIER(r);
        if (r >= d) { r -= d; q |= 1u << i; }
    }
    return q;
}
__attribute__((noinline)) static uint32_t div_soft(const uint32_t *n, const uint32_t *d, int k)
{
    uint32_t s = 0;
    for (int i = 0; i < k; i++) s += udiv_soft(n[i], d[i]);
    return s;
}
__attribute__((noinline)) static uint32_t div_hw(const uint32_t *n, const uint32_t *d, int k)
{
    uint32_t s = 0;
    for (int i = 0; i < k; i++) { uint32_t x = n[i]; BARRIER(x); s += x / d[i]; }
    return s;
}

/* ---------------- FPU: software single precision (normal numbers and zero, round to nearest even) ---------------- */
static uint32_t f_pack(uint32_t s, int e, uint32_t m, uint32_t sticky)
{
    /* m: significand with the leading one at bit 26 (3 guard bits), e: biased exponent of bit 26 */
    if (!m) return s << 31;
    while (m >= (1u << 27)) { sticky |= m & 1; m >>= 1; e++; }
    while (m < (1u << 26)) { m <<= 1; e--; }
    uint32_t rb = m & 7, keep = m >> 3;
    if (sticky) rb |= 1;
    if (rb > 4 || (rb == 4 && (keep & 1))) keep++;
    if (keep >> 24) { keep >>= 1; e++; }
    if (e <= 0) return s << 31;                       /* (no subnormals in this benchmark) */
    return (s << 31) | ((uint32_t)e << 23) | (keep & 0x7FFFFF);
}
__attribute__((noinline)) static uint32_t f_mul(uint32_t a, uint32_t b)
{
    uint32_t s = (a ^ b) >> 31;
    int ea = (a >> 23) & 255, eb = (b >> 23) & 255;
    if (!ea || !eb) return s << 31;
    uint64_t p = (uint64_t)((a & 0x7FFFFF) | 0x800000) * ((b & 0x7FFFFF) | 0x800000);   /* 47 or 48 bits */
    uint32_t hi = (uint32_t)(p >> 21), st = (p & 0x1FFFFF) != 0;                        /* leading one at 26/27 */
    return f_pack(s, ea + eb - 126, hi, st);
}
__attribute__((noinline)) static uint32_t f_add(uint32_t a, uint32_t b)
{
    if (!((a >> 23) & 255)) return b;
    if (!((b >> 23) & 255)) return a;
    if ((a & 0x7FFFFFFF) < (b & 0x7FFFFFFF)) { uint32_t t = a; a = b; b = t; }
    int ea = (a >> 23) & 255, eb = (b >> 23) & 255, d = ea - eb;
    uint32_t ma = ((a & 0x7FFFFF) | 0x800000) << 3, mb = ((b & 0x7FFFFF) | 0x800000) << 3, st = 0;
    if (d > 27) { st = 1; mb = 0; }
    else if (d) { st = (mb & ((1u << d) - 1)) != 0; mb >>= d; }
    uint32_t m;
    if ((a ^ b) >> 31) { m = ma - mb - st; }          /* the sticky bit borrows */
    else m = ma + mb;
    return f_pack(a >> 31, ea, m, st);
}
static inline uint32_t fbits(float f) { union { float f; uint32_t u; } v = {f}; return v.u; }
__attribute__((noinline)) static uint32_t fmac_soft(const float *a, const float *b, int n)
{
    uint32_t s = 0;
    for (int i = 0; i < n; i++) s = f_add(s, f_mul(fbits(a[i]), fbits(b[i])));
    return s;
}
#pragma clang fp contract(off)
__attribute__((noinline)) static uint32_t fmac_hw(const float *a, const float *b, int n)
{
    float s = 0.0f;
    for (int i = 0; i < n; i++) { float p = a[i] * b[i]; s = s + p; }
    return fbits(s);
}

/* ---------------- BIT ---------------- */
__attribute__((noinline)) static uint32_t bit_soft(const uint32_t *w, int n)
{
    uint32_t s = 0;
    for (int i = 0; i < n; i++) {
        uint32_t x = w[i], r = 0;
        for (int k = 0; k < 32; k++) { r = (r << 1) | (x & 1); x >>= 1; BARRIER(r); }
        uint32_t v = w[i], z = 32;
        while (v) { v >>= 1; z--; BARRIER(v); }
        s += r ^ z;
    }
    return s;
}
__attribute__((noinline)) static uint32_t bit_hw(const uint32_t *w, int n)
{
    uint32_t s = 0;
    for (int i = 0; i < n; i++) {
        uint32_t x = w[i];
        s += __builtin_arm_rbit(x) ^ (x ? (uint32_t)__builtin_clz(x) : 32u);
    }
    return s;
}

/* ---------------- timing ---------------- */
static uint32_t snap(void)
{
    uint32_t t = 0;
    PERF(PF_CTRL) = 0;
    for (int k = 0; k < NPC; k++) if (k != PC_EXC) t += PERF(PF_CNT(k));
    PERF(PF_CTRL) = 1;
    return t;
}

void isa_run(void)
{
    int16_t *qa = (int16_t *)scratch, *qb = qa + NE;
    uint32_t *un = scratch + NE, *ud = un + NE;
    float *fa = (float *)(scratch + 3 * NE), *fb = fa + NE;
    uint32_t *bw = scratch + 5 * NE;
    for (int i = 0; i < NE; i++) {
        qa[i] = (int16_t)rnd(); qb[i] = (int16_t)rnd();
        un[i] = rnd(); ud[i] = (rnd() >> (rnd() & 31)) | 1;
        fa[i] = (float)((int32_t)rnd() >> 8) * (1.0f / 8388608.0f);
        fb[i] = (float)((int32_t)rnd() >> 8) * (1.0f / 8388608.0f);
        bw[i] = rnd() >> (i & 31);
    }
    uint32_t t_snap = snap();
    t_snap = snap() - t_snap;                                 /* the cost of reading the counters */
    for (int f = 0; f < NFEAT; f++) {
        uint32_t r[2] = {0, 0};
        for (int v = 0; v < 2; v++) {
            uint32_t t0 = snap();
            switch (f * 2 + v) {
            case 0: r[v] = (uint32_t)dot_mla(qa, qb, NE); break;
            case 1: r[v] = (uint32_t)dot_smlad(qa, qb, NE); break;
            case 2: r[v] = div_soft(un, ud, NE); break;
            case 3: r[v] = div_hw(un, ud, NE); break;
            case 4: r[v] = fmac_soft(fa, fb, NE); break;
            case 5: r[v] = fmac_hw(fa, fb, NE); break;
            case 6: r[v] = bit_soft(bw, NE); break;
            default: r[v] = bit_hw(bw, NE); break;
            }
            uint32_t t1 = snap();
            feat_cpe[f][v] = (float)(t1 - t0 - t_snap) / NE;
        }
        feat_ok[f] = r[0] == r[1];
    }
    feat_done = 1;
}
