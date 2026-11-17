/*
 * mathf.c - single-precision math functions for the benchmarks and the UI (no libc):
 * sinf cosf atanf atan2f expf logf sqrtf fabsf. Max error a few ulp, enough for Whetstone and graphics.
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include "mathf.h"

static inline float rnd_i(float x) { return (float)(int)(x + (x >= 0.0f ? 0.5f : -0.5f)); }   /* |x| < 2^31 */
static inline float as_f(uint32_t u) { union { uint32_t u; float f; } v = {u}; return v.f; }
static inline uint32_t as_u(float f) { union { float f; uint32_t u; } v = {f}; return v.u; }

float fabsf(float x) { return as_f(as_u(x) & 0x7FFFFFFFu); }
float sqrtf(float x) { float r; __asm("vsqrt.f32 %0, %1" : "=t"(r) : "t"(x)); return r; }

/* sin and cos on [-pi/4, pi/4] (minimax polynomials) */
static float sin_k(float x)
{
    float z = x * x;
    return x + x * z * (-1.6666654611e-1f + z * (8.3321608736e-3f + z * -1.9515295891e-4f));
}
static float cos_k(float x)
{
    float z = x * x;
    return 1.0f + z * (-0.5f + z * (4.166664568298827e-2f + z * (-1.388731625493765e-3f + z * 2.443315711809948e-5f)));
}
/* reduction by multiples of pi/2 (Cody-Waite, three parts) */
static float reduce(float x, int *q)
{
    float k = rnd_i(x * 0.63661977236f);
    *q = (int)k;
    return ((x - k * 1.5703125f) - k * 4.837512969970703125e-4f) - k * 7.549789948768648e-8f;
}
float sinf(float x)
{
    int q;
    float r = reduce(x, &q);
    switch (q & 3) {
    case 0: return sin_k(r);
    case 1: return cos_k(r);
    case 2: return -sin_k(r);
    default: return -cos_k(r);
    }
}
float cosf(float x)
{
    int q;
    float r = reduce(x, &q);
    switch (q & 3) {
    case 0: return cos_k(r);
    case 1: return -sin_k(r);
    case 2: return -cos_k(r);
    default: return sin_k(r);
    }
}

/* atan: reduce to [0, 1], then to [0, tan(pi/12)] */
float atanf(float x)
{
    int neg = x < 0.0f;
    if (neg) x = -x;
    int inv = x > 1.0f;
    if (inv) x = 1.0f / x;
    int sh = x > 0.2679491924f;
    if (sh) x = (x * 1.7320508076f - 1.0f) / (x + 1.7320508076f);
    float z = x * x;
    float r = x * (1.0f + z * (-0.3333333134f + z * (0.1999994069f + z * (-0.1428356618f + z * 0.1066281646f))));
    if (sh) r += 0.5235987756f;
    if (inv) r = 1.5707963268f - r;
    return neg ? -r : r;
}
float atan2f(float y, float x)
{
    if (x > 0.0f) return atanf(y / x);
    if (x < 0.0f) return y >= 0.0f ? atanf(y / x) + 3.1415926536f : atanf(y / x) - 3.1415926536f;
    return y > 0.0f ? 1.5707963268f : (y < 0.0f ? -1.5707963268f : 0.0f);
}

/* exp: x = k ln2 + r, |r| <= ln2/2 */
float expf(float x)
{
    if (x > 88.72f) return as_f(0x7F800000u);
    if (x < -103.9f) return 0.0f;
    float k = rnd_i(x * 1.4426950409f);
    float r = (x - k * 0.693145751953125f) - k * 1.428606765330187e-6f;
    float p = 1.0f + r * (1.0f + r * (0.5f + r * (1.6666667163e-1f + r * (4.1666418314e-2f + r * (8.3333337680e-3f +
              r * 1.3888889225e-3f)))));
    int e = (int)k;
    if (e < -126) { p *= as_f(0x00800000u); e += 126; return p * as_f((uint32_t)(e + 127) << 23); }
    return p * as_f((uint32_t)(e + 127) << 23);
}

/* log: x = 2^e m, m in [sqrt(1/2), sqrt(2)), log(m) = 2 atanh((m - 1) / (m + 1)) */
float logf(float x)
{
    if (!(x > 0.0f)) return x == 0.0f ? as_f(0xFF800000u) : as_f(0x7FC00000u);
    uint32_t u = as_u(x);
    int e = (int)(u >> 23) - 127;
    if ((u >> 23) == 0) { x *= 8388608.0f; u = as_u(x); e = (int)(u >> 23) - 150; }
    float m = as_f((u & 0x007FFFFFu) | 0x3F800000u);
    if (m > 1.41421356f) { m *= 0.5f; e++; }
    float s = (m - 1.0f) / (m + 1.0f), z = s * s;
    float l = 2.0f * s * (1.0f + z * (0.3333333433f + z * (0.1999966800f + z * (0.1428910941f + z * 0.1115075403f))));
    return l + (float)e * 0.6931471806f;
}
