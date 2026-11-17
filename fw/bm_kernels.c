/*
 * bm_kernels.c - the smaller benchmarks of the firmware, each with a self-check:
 *   Whetstone (single precision), FFT-256 (complex float, radix 2), MatMul 16x16 float,
 *   FIR Q15 (32 taps, DSP SIMD: SMLAD), SHA-256, CRC-32 (table)
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include "bench.h"
#include "mathf.h"

uint32_t scratch[SCRATCH_WORDS];

static uint32_t lcg_s;
static uint32_t lcg(void) { lcg_s = lcg_s * 1664525u + 1013904223u; return lcg_s; }

static int near(float a, float b, float rel)
{
    float d = fabsf(a - b), m = fabsf(b);
    return d <= rel * (m > 1.0f ? m : 1.0f);
}

/* =====================================================================================
 * Whetstone, single precision (after the classic C version by Painter Engineering).
 * One unit = the eleven modules with LOOP = 10, i.e. 1000 Whetstone instructions x 1000:
 * one MWIPS = one unit per second.
 * ===================================================================================== */
#define W_LOOP 10
static float wT, wT1, wT2, wE1[5];
static int wJ, wK, wL;
static float w_x11, w_x7, w_y7, w_z8, w_e2;

__attribute__((noinline)) static void wPA(float E[])
{
    int j = 0;
    do {
        E[1] = (E[1] + E[2] + E[3] - E[4]) * wT;
        E[2] = (E[1] + E[2] - E[3] + E[4]) * wT;
        E[3] = (E[1] - E[2] + E[3] + E[4]) * wT;
        E[4] = (-E[1] + E[2] + E[3] + E[4]) / wT2;
        j++;
    } while (j < 6);
}
__attribute__((noinline)) static void wP0(void) { wE1[wJ] = wE1[wK]; wE1[wK] = wE1[wL]; wE1[wL] = wE1[wJ]; }
__attribute__((noinline)) static void wP3(float X, float Y, float *Z)
{
    float X1 = X, Y1 = Y;
    X1 = wT * (X1 + Y1);
    Y1 = wT * (X1 + Y1);
    *Z = (X1 + Y1) / wT2;
}

static void whet_once(void)
{
    int N2 = 12 * W_LOOP, N3 = 14 * W_LOOP, N4 = 345 * W_LOOP, N6 = 210 * W_LOOP, N7 = 32 * W_LOOP;
    int N8 = 899 * W_LOOP, N9 = 616 * W_LOOP, N11 = 93 * W_LOOP;
    float X, Y, Z;
    wT = 0.499975f; wT1 = 0.50025f; wT2 = 2.0f;
    /* module 2: array elements */
    wE1[1] = 1.0f; wE1[2] = -1.0f; wE1[3] = -1.0f; wE1[4] = -1.0f;
    for (int i = 1; i <= N2; i++) {
        wE1[1] = (wE1[1] + wE1[2] + wE1[3] - wE1[4]) * wT;
        wE1[2] = (wE1[1] + wE1[2] - wE1[3] + wE1[4]) * wT;
        wE1[3] = (wE1[1] - wE1[2] + wE1[3] + wE1[4]) * wT;
        wE1[4] = (-wE1[1] + wE1[2] + wE1[3] + wE1[4]) * wT;
    }
    /* module 3: array as parameter */
    for (int i = 1; i <= N3; i++) wPA(wE1);
    w_e2 = wE1[2];
    /* module 4: conditional jumps */
    wJ = 1;
    for (int i = 1; i <= N4; i++) {
        wJ = (wJ == 1) ? 2 : 3;
        wJ = (wJ > 2) ? 0 : 1;
        wJ = (wJ < 1) ? 1 : 0;
    }
    /* module 6: integer arithmetic */
    wJ = 1; wK = 2; wL = 3;
    for (int i = 1; i <= N6; i++) {
        wJ = wJ * (wK - wJ) * (wL - wK);
        wK = wL * wK - (wL - wJ) * wK;
        wL = (wL - wK) * (wK + wJ);
        wE1[wL - 1] = (float)(wJ + wK + wL);
        wE1[wK - 1] = (float)(wJ * wK * wL);
    }
    /* module 7: trigonometric functions */
    X = 0.5f; Y = 0.5f;
    for (int i = 1; i <= N7; i++) {
        X = wT * atanf(wT2 * sinf(X) * cosf(X) / (cosf(X + Y) + cosf(X - Y) - 1.0f));
        Y = wT * atanf(wT2 * sinf(Y) * cosf(Y) / (cosf(X + Y) + cosf(X - Y) - 1.0f));
    }
    w_x7 = X; w_y7 = Y;
    /* module 8: procedure calls */
    X = 1.0f; Y = 1.0f; Z = 1.0f;
    for (int i = 1; i <= N8; i++) wP3(X, Y, &Z);
    w_z8 = Z;
    /* module 9: array references */
    wJ = 1; wK = 2; wL = 3;
    wE1[1] = (float)wJ; wE1[2] = (float)wK; wE1[3] = (float)wL;
    for (int i = 1; i <= N9; i++) wP0();
    /* module 11: standard functions */
    X = 0.75f;
    for (int i = 1; i <= N11; i++) X = sqrtf(expf(logf(X) / wT1));
    w_x11 = X;
}

void whet_init(void) {}
int whet_run(uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) whet_once();
    /* reference values: the same code and mathf.c in single precision on a PC (gcc, x86-64) */
    return near(w_x7, 0.4904145f, 1e-4f) && near(w_y7, 0.4903998f, 1e-4f) && near(w_z8, 0.9999375f, 1e-5f) &&
           near(w_x11, 0.8346557f, 1e-4f) && near(w_e2, -0.4474322f, 1e-4f) && wJ == 1 && wK == 2 && wL == 3;
}

/* =====================================================================================
 * FFT: 256-point complex, radix-2 decimation in time, in place; one unit = one transform
 * (5 N log2 N = 10240 flops). Input: cos(2 pi 5 n / N) + 0.5 sin(2 pi 17 n / N).
 * ===================================================================================== */
#define FFT_N 256
#define FFT_LOG 8
static float *fft_re(void) { return (float *)scratch; }               /* 256 + 256 floats */
static float *fft_im(void) { return (float *)scratch + FFT_N; }
static float *fft_cs(void) { return (float *)scratch + 2 * FFT_N; }   /* cos, sin: 128 + 128 */
static float *fft_x0(void) { return (float *)scratch + 3 * FFT_N; }   /* input, real */

void fft_init(void)
{
    float *cs = fft_cs(), *x0 = fft_x0();
    for (int k = 0; k < FFT_N / 2; k++) {
        float a = 6.2831853f * (float)k / FFT_N;
        cs[k] = cosf(a);
        cs[FFT_N / 2 + k] = -sinf(a);
    }
    for (int n = 0; n < FFT_N; n++)
        x0[n] = cosf(6.2831853f * 5.0f * n / FFT_N) + 0.5f * sinf(6.2831853f * 17.0f * n / FFT_N);
}

static void fft_once(void)
{
    float *re = fft_re(), *im = fft_im(), *cs = fft_cs(), *x0 = fft_x0();
    for (unsigned n = 0; n < FFT_N; n++) {               /* bit-reversed copy of the input */
        unsigned r = __builtin_arm_rbit(n) >> (32 - FFT_LOG);
        re[r] = x0[n];
        im[r] = 0.0f;
    }
    for (int len = 2, tw = FFT_N / 2; len <= FFT_N; len <<= 1, tw >>= 1) {
        int h = len >> 1;
        for (int j = 0; j < h; j++) {
            float wr = cs[j * tw], wi = cs[FFT_N / 2 + j * tw];
            for (int i = j; i < FFT_N; i += len) {
                int k = i + h;
                float tr = re[k] * wr - im[k] * wi;
                float ti = re[k] * wi + im[k] * wr;
                re[k] = re[i] - tr; im[k] = im[i] - ti;
                re[i] += tr; im[i] += ti;
            }
        }
    }
}

int fft_run(uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) fft_once();
    float *re = fft_re(), *im = fft_im();
    /* bin 5: N/2 (real), bin 17: -j N/4, everything else ~0 */
    int ok = near(re[5], 128.0f, 1e-3f) && near(re[FFT_N - 5], 128.0f, 1e-3f) && near(im[17], -64.0f, 1e-3f) &&
             near(im[FFT_N - 17], 64.0f, 1e-3f);
    for (int k = 0; k < FFT_N; k++)
        if (k != 5 && k != FFT_N - 5 && k != 17 && k != FFT_N - 17 && (fabsf(re[k]) > 1e-3f || fabsf(im[k]) > 1e-3f))
            ok = 0;
    return ok;
}

/* =====================================================================================
 * MatMul: C = A x B, 16 x 16 single precision; one unit = 2 N^3 = 8192 flops
 * ===================================================================================== */
#define MM_N 16
static float *mm_a(void) { return (float *)scratch; }
static float *mm_b(void) { return (float *)scratch + MM_N * MM_N; }
static float *mm_c(void) { return (float *)scratch + 2 * MM_N * MM_N; }

void mm_init(void)
{
    float *a = mm_a(), *b = mm_b();
    for (int i = 0; i < MM_N; i++)
        for (int j = 0; j < MM_N; j++) {
            a[i * MM_N + j] = (float)((i * 3 + j * 5) % 11 - 5) * 0.25f;     /* exact in binary */
            b[i * MM_N + j] = (float)((i * 7 + j * 2) % 13 - 6) * 0.5f;
        }
}

static void mm_once(void)
{
    const float *a = mm_a(), *b = mm_b();
    float *c = mm_c();
    for (int i = 0; i < MM_N; i++)
        for (int j = 0; j < MM_N; j++) {
            float s = 0.0f;
            for (int k = 0; k < MM_N; k++) s += a[i * MM_N + k] * b[k * MM_N + j];
            c[i * MM_N + j] = s;
        }
}

int mm_run(uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) mm_once();
    /* all values are small multiples of 1/8: the sums are exact, compare with integer arithmetic */
    const float *c = mm_c();
    for (int i = 0; i < MM_N; i++)
        for (int j = 0; j < MM_N; j++) {
            int s = 0;
            for (int k = 0; k < MM_N; k++) s += ((i * 3 + k * 5) % 11 - 5) * ((k * 7 + j * 2) % 13 - 6);
            if (c[i * MM_N + j] != (float)s * 0.125f) return 0;
        }
    return 1;
}

/* =====================================================================================
 * FIR, Q15: 32 taps, 256 outputs per unit, two taps per SMLAD (dual 16-bit multiply-accumulate)
 * ===================================================================================== */
#define FIR_T 32
#define FIR_N 256
static int16_t *fir_x(void) { return (int16_t *)scratch; }                    /* FIR_N + FIR_T samples */
static int16_t *fir_h(void) { return (int16_t *)scratch + FIR_N + FIR_T; }    /* taps */
static int32_t *fir_y(void) { return (int32_t *)scratch + (FIR_N + 2 * FIR_T) / 2; }

void fir_init(void)
{
    int16_t *x = fir_x(), *h = fir_h();
    lcg_s = 12345;
    for (int i = 0; i < FIR_N + FIR_T; i++) x[i] = (int16_t)(lcg() >> 17) - 16384;
    for (int i = 0; i < FIR_T; i++) h[i] = (int16_t)((i < FIR_T / 2 ? i + 1 : FIR_T - i) * 1000 - 7000);
}

static inline uint32_t smlad(uint32_t a, uint32_t b, uint32_t acc)
{
    uint32_t r;
    __asm("smlad %0, %1, %2, %3" : "=r"(r) : "r"(a), "r"(b), "r"(acc));
    return r;
}

static void fir_once(void)
{
    const int16_t *x = fir_x(), *h = fir_h();
    int32_t *y = fir_y();
    for (int n = 0; n < FIR_N; n += 2) {               /* two outputs per pass, taps in pairs */
        const uint32_t *hp = (const uint32_t *)h;
        const int16_t *xp = x + n;
        uint32_t a0 = 0, a1 = 0;
        for (int k = 0; k < FIR_T; k += 4) {
            uint32_t h0 = hp[0], h1 = hp[1];
            uint32_t x0 = *(const uint32_t *)(xp + k), x1 = *(const uint32_t *)(xp + k + 2);
            uint32_t xo = *(const uint32_t *)(xp + k + 1);        /* unaligned pair (LDR) */
            uint32_t xo2 = *(const uint32_t *)(xp + k + 3);
            a0 = smlad(x0, h0, a0);
            a0 = smlad(x1, h1, a0);
            a1 = smlad(xo, h0, a1);
            a1 = smlad(xo2, h1, a1);
            hp += 2;
        }
        y[n] = (int32_t)a0;
        y[n + 1] = (int32_t)a1;
    }
}

int fir_run(uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) fir_once();
    const int16_t *x = fir_x(), *h = fir_h();
    const int32_t *y = fir_y();
    for (int k = 0; k < FIR_N; k++) {
        int32_t s = 0;
        for (int t = 0; t < FIR_T; t++) s += x[k + t] * h[t];
        if (s != y[k]) return 0;
    }
    return 1;
}

/* =====================================================================================
 * SHA-256 of a 1 KB message; one unit = one hash (1 KB plus padding)
 * ===================================================================================== */
static const uint32_t SHA_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
#define SHA_LEN 1024
static uint32_t sha_h[8];

static inline uint32_t ror(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

static void sha_block(uint32_t *st, const uint8_t *p)
{
    uint32_t w[64];
    for (int i = 0; i < 16; i++) w[i] = __builtin_bswap32(*(const uint32_t *)(p + 4 * i));
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], h = st[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = h + (ror(e, 6) ^ ror(e, 11) ^ ror(e, 25)) + ((e & f) ^ (~e & g)) + SHA_K[i] + w[i];
        uint32_t t2 = (ror(a, 2) ^ ror(a, 13) ^ ror(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    st[0] += a; st[1] += b; st[2] += c; st[3] += d; st[4] += e; st[5] += f; st[6] += g; st[7] += h;
}

static void sha256(const uint8_t *msg, uint32_t len, uint32_t *st)
{
    static const uint32_t H0[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                   0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint8_t last[128];
    for (int i = 0; i < 8; i++) st[i] = H0[i];
    uint32_t full = len & ~63u;
    for (uint32_t o = 0; o < full; o += 64) sha_block(st, msg + o);
    uint32_t r = len - full, nb = r < 56 ? 64 : 128;
    for (uint32_t i = 0; i < nb; i++) last[i] = i < r ? msg[full + i] : (i == r ? 0x80 : 0);
    uint64_t bits = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++) last[nb - 1 - i] = (uint8_t)(bits >> (8 * i));
    for (uint32_t o = 0; o < nb; o += 64) sha_block(st, last + o);
}

static uint8_t *sha_msg(void) { return (uint8_t *)scratch; }

static void fill_msg(void)
{
    uint8_t *m = sha_msg();
    lcg_s = 1;
    for (int i = 0; i < SHA_LEN; i++) m[i] = (uint8_t)(lcg() >> 24);
}

void sha_init(void) { fill_msg(); }
int sha_run(uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) sha256(sha_msg(), SHA_LEN, sha_h);
    /* SHA-256 of the 1 KB message (tools/kernels_ref.py) and of "abc" */
    static const uint32_t REF[8] = {SHA_REF};
    static const uint32_t ABC[8] = {0xba7816bf, 0x8f01cfea, 0x414140de, 0x5dae2223,
                                    0xb00361a3, 0x96177a9c, 0xb410ff61, 0xf20015ad};
    int ok = 1;
    for (int i = 0; i < 8; i++) ok &= sha_h[i] == REF[i];
    sha256((const uint8_t *)"abc", 3, sha_h);
    for (int i = 0; i < 8; i++) ok &= sha_h[i] == ABC[i];
    return ok;
}

/* =====================================================================================
 * CRC-32 (IEEE 802.3, reflected, table driven); one unit = 4 KB
 * ===================================================================================== */
static const uint32_t *crc_table(void) { return scratch + 256; }       /* 256 words after the 1 KB message */

void crc_init(void)
{
    fill_msg();
    uint32_t *t = scratch + 256;
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        t[i] = c;
    }
}

static uint32_t crc32(const uint8_t *p, uint32_t len, uint32_t c)
{
    const uint32_t *t = crc_table();
    c = ~c;
    for (uint32_t i = 0; i < len; i++) c = t[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return ~c;
}

int crc_run(uint32_t n)
{
    uint32_t c = 0;
    for (uint32_t i = 0; i < n; i++) {
        c = 0;
        for (int k = 0; k < 4; k++) c = crc32(sha_msg(), SHA_LEN, c);
    }
    return c == CRC_REF && crc32((const uint8_t *)"123456789", 9, 0) == 0xCBF43926u;
}
