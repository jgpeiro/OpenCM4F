/*
 * minilib.c - the few C library functions the compiler and the programs need (no libc):
 * mem* and str*, the AEABI memory helpers, 64-bit division, a small printf
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

void *memcpy(void *d, const void *s, size_t n)
{
    uint8_t *p = d;
    const uint8_t *q = s;
    if ((((uintptr_t)p | (uintptr_t)q) & 3) == 0) {
        while (n >= 4) { *(uint32_t *)p = *(const uint32_t *)q; p += 4; q += 4; n -= 4; }
    }
    while (n--) *p++ = *q++;
    return d;
}
void *memmove(void *d, const void *s, size_t n)
{
    uint8_t *p = d;
    const uint8_t *q = s;
    if (p < q) while (n--) *p++ = *q++;
    else { p += n; q += n; while (n--) *--p = *--q; }
    return d;
}
void *memset(void *d, int c, size_t n)
{
    uint8_t *p = d;
    while (n && ((uintptr_t)p & 3)) { *p++ = (uint8_t)c; n--; }
    uint32_t w = (uint8_t)c * 0x01010101u;
    while (n >= 4) { *(uint32_t *)p = w; p += 4; n -= 4; }
    while (n--) *p++ = (uint8_t)c;
    return d;
}
int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *p = a, *q = b;
    for (; n; n--, p++, q++) if (*p != *q) return *p - *q;
    return 0;
}
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
int strcmp(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return (uint8_t)*a - (uint8_t)*b; }
char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)) { } return r; }

/* AEABI memory helpers (the compiler emits calls to these) */
void __aeabi_memcpy(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy4(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memcpy8(void *d, const void *s, size_t n) { memcpy(d, s, n); }
void __aeabi_memmove(void *d, const void *s, size_t n) { memmove(d, s, n); }
void __aeabi_memmove4(void *d, const void *s, size_t n) { memmove(d, s, n); }
void __aeabi_memmove8(void *d, const void *s, size_t n) { memmove(d, s, n); }
void __aeabi_memset(void *d, size_t n, int c) { memset(d, c, n); }
void __aeabi_memset4(void *d, size_t n, int c) { memset(d, c, n); }
void __aeabi_memset8(void *d, size_t n, int c) { memset(d, c, n); }
void __aeabi_memclr(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr4(void *d, size_t n) { memset(d, 0, n); }
void __aeabi_memclr8(void *d, size_t n) { memset(d, 0, n); }

/* 64-bit division: quotient in r0:r1, remainder in r2:r3 */
static uint64_t udivmod64(uint64_t n, uint64_t d, uint64_t *rem)
{
    uint64_t q = 0, r = 0;
    if (d == 0) { *rem = n; return ~0ull; }
    if ((d >> 32) == 0 && (n >> 32) == 0) { *rem = (uint32_t)n % (uint32_t)d; return (uint32_t)n / (uint32_t)d; }
    for (int i = 63; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) { r -= d; q |= 1ull << i; }
    }
    *rem = r;
    return q;
}
void __udivmod64_c(uint64_t n, uint64_t d, uint64_t *out) { out[0] = udivmod64(n, d, &out[1]); }
void __sdivmod64_c(int64_t n, int64_t d, int64_t *out)
{
    uint64_t un = n < 0 ? -(uint64_t)n : (uint64_t)n, ud = d < 0 ? -(uint64_t)d : (uint64_t)d, r;
    uint64_t q = udivmod64(un, ud, &r);
    out[0] = ((n < 0) != (d < 0)) ? -(int64_t)q : (int64_t)q;
    out[1] = n < 0 ? -(int64_t)r : (int64_t)r;
}
/* n in r0:r1, d in r2:r3 -> quotient r0:r1, remainder r2:r3 */
__attribute__((naked)) void __aeabi_uldivmod(void)
{
    __asm volatile(
        "push {r4, lr}\n"
        "sub sp, sp, #24\n"
        "add r4, sp, #8\n"
        "str r4, [sp]\n"
        "bl __udivmod64_c\n"
        "ldm r4, {r0, r1, r2, r3}\n"
        "add sp, sp, #24\n"
        "pop {r4, pc}\n");
}
__attribute__((naked)) void __aeabi_ldivmod(void)
{
    __asm volatile(
        "push {r4, lr}\n"
        "sub sp, sp, #24\n"
        "add r4, sp, #8\n"
        "str r4, [sp]\n"
        "bl __sdivmod64_c\n"
        "ldm r4, {r0, r1, r2, r3}\n"
        "add sp, sp, #24\n"
        "pop {r4, pc}\n");
}

/* ---------------- small printf ---------------- */
void putchar_raw(int c);
static void out_str(const char *s) { while (*s) putchar_raw(*s++); }
static void out_num(uint32_t v, int base, int width, int zero, int neg)
{
    char b[12];
    int n = 0;
    do { int d = v % base; b[n++] = d < 10 ? '0' + d : 'a' + d - 10; v /= base; } while (v);
    if (neg) b[n++] = '-';
    while (n < width) { putchar_raw(zero ? '0' : ' '); width--; }
    while (n) putchar_raw(b[--n]);
}
int printf(const char *f, ...)
{
    va_list ap;
    va_start(ap, f);
    for (; *f; f++) {
        if (*f != '%') { putchar_raw(*f); continue; }
        f++;
        int zero = 0, width = 0;
        if (*f == '0') { zero = 1; f++; }
        while (*f >= '0' && *f <= '9') width = width * 10 + *f++ - '0';
        while (*f == 'l') f++;
        switch (*f) {
        case 'd': { int v = va_arg(ap, int); out_num(v < 0 ? -(uint32_t)v : (uint32_t)v, 10, width, zero, v < 0); break; }
        case 'u': out_num(va_arg(ap, uint32_t), 10, width, zero, 0); break;
        case 'x': out_num(va_arg(ap, uint32_t), 16, width, zero, 0); break;
        case 's': out_str(va_arg(ap, const char *)); break;
        case 'c': putchar_raw(va_arg(ap, int)); break;
        default: putchar_raw(*f); break;
        }
    }
    va_end(ap);
    return 0;
}
