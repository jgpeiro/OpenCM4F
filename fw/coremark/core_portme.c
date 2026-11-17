/*
 * core_portme.c - CoreMark port for the OpenCM4F benchmark firmware (based on barebones/core_portme.c,
 * Copyright 2018 EEMBC, Apache License 2.0)
 */
#include <stdarg.h>
#include "coremark.h"
#include "core_portme.h"
#include "../bench.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = 1;       /* iterations, set by coremark_run */
volatile ee_s32 seed5_volatile = 0;

static CORE_TICKS ticks;                  /* timed clocks of the last run (bench.c) */
extern uint32_t t_last;

void start_time(void) { t_begin(); }
void stop_time(void) { t_end(); ticks = t_last; }
CORE_TICKS get_time(void) { return ticks; }
secs_ret time_in_secs(CORE_TICKS t) { return (secs_ret)(t / clk_hz); }

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; (void)argv;
    p->portable_id = 1;
}
void portable_fini(core_portable *p) { p->portable_id = 0; }

/* ---------------- log: what CoreMark prints ---------------- */
char cm_log[640];
static int cm_n;

static void lput(int c) { if (cm_n < (int)sizeof(cm_log) - 1) { cm_log[cm_n++] = (char)c; cm_log[cm_n] = 0; } }
static void lnum(uint32_t v, int base, int width, int zero, int neg)
{
    char b[12];
    int n = 0;
    do { int d = (int)(v % (uint32_t)base); b[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v /= (uint32_t)base; } while (v);
    if (neg) b[n++] = '-';
    while (n < width) { lput(zero ? '0' : ' '); width--; }
    while (n) lput(b[--n]);
}
int ee_printf(const char *f, ...)
{
    va_list ap;
    va_start(ap, f);
    for (; *f; f++) {
        if (*f != '%') { lput(*f); continue; }
        f++;
        int zero = 0, width = 0;
        if (*f == '0') { zero = 1; f++; }
        while (*f >= '0' && *f <= '9') width = width * 10 + *f++ - '0';
        while (*f == 'l') f++;
        switch (*f) {
        case 'd': { int v = va_arg(ap, int); lnum(v < 0 ? -(uint32_t)v : (uint32_t)v, 10, width, zero, v < 0); break; }
        case 'u': lnum(va_arg(ap, uint32_t), 10, width, zero, 0); break;
        case 'x': lnum(va_arg(ap, uint32_t), 16, width, zero, 0); break;
        case 's': { const char *s = va_arg(ap, const char *); while (*s) lput(*s++); break; }
        case 'c': lput(va_arg(ap, int)); break;
        default: lput(*f); break;
        }
    }
    va_end(ap);
    return 0;
}

int coremark_main(void);

static int has(const char *s)
{
    for (int i = 0; cm_log[i]; i++) {
        int k = 0;
        while (s[k] && cm_log[i + k] == s[k]) k++;
        if (!s[k]) return 1;
    }
    return 0;
}

void coremark_init(void) {}

/* n iterations; 1 if the CRCs are the known ones (the 10 s rule is the caller's business) */
int coremark_run(uint32_t n)
{
    cm_n = 0;
    cm_log[0] = 0;
    seed4_volatile = (ee_s32)n;
    coremark_main();
    return !has("ERROR! l") && !has("ERROR! m") && !has("ERROR! s") && has("2K performance run");
}
