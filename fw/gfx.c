/*
 * gfx.c - drawing API (from Sat Signal Lab): turns shapes, arcs, text, icons and spans into display-list commands
 * SPDX-License-Identifier: MIT
 */
#include "gfx.h"
#include "hw.h"
#include "assets.h"
#include "mathf.h"

static volatile uint32_t *dl, *gd;
static int ncmd, gbyte;                 /* commands written, gdata bytes used */
int g_opa = 16;

/* a in 1/1024 turns -> sin in Q14 */
int isin(int a) { return (int)(sinf((float)(a & 1023) * (6.2831853f / 1024.0f)) * 16384.0f); }
int icos(int a) { return isin(a + 256); }

void g_begin(int bank)
{
    dl = DL_BASE(bank);
    gd = GD_BASE(bank);
    ncmd = 0;
    gbyte = 0;
    g_opa = 16;
}

int g_count(void) { return ncmd; }

static void emit(uint32_t w0, uint32_t w1, uint32_t w2, uint32_t w3)
{
    if (ncmd >= DL_CMDS - 1) return;
    volatile uint32_t *p = dl + 4 * ncmd;
    p[0] = w0; p[1] = w1; p[2] = w2; p[3] = w3;
    ncmd++;
}

void g_end(void)
{
    volatile uint32_t *p = dl + 4 * ncmd;
    p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0;
}

static int clip_x0 = 0, clip_y0 = 0, clip_x1 = SCR_W - 1, clip_y1 = SCR_H - 1;    /* extra bbox limit */

static int box(int op, int x0, int y0, int x1, int y1, uint16_t col, int opa, uint32_t w2, uint32_t w3)
{
    if (x0 < clip_x0) x0 = clip_x0;
    if (y0 < clip_y0) y0 = clip_y0;
    if (x1 > clip_x1) x1 = clip_x1;
    if (y1 > clip_y1) y1 = clip_y1;
    opa = (opa * g_opa) >> 4;
    if (opa <= 0) return 0;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > SCR_W - 1) x1 = SCR_W - 1;
    if (y1 > SCR_H - 1) y1 = SCR_H - 1;
    if (x0 > x1 || y0 > y1) return 0;
    emit(W0(op, x0, y0, y1), W1(x1, opa, col), w2, w3);
    return 1;
}

/* rounded rectangle in half pixels: centre (cx2, cy2), half sizes hw2, hh2, radius r2, outline t2 */
void g_shape2(int cx2, int cy2, int hw2, int hh2, int r2, int t2, uint16_t col, int opa)
{
    if (r2 < 1) r2 = 1;
    if (r2 > hw2) r2 = hw2;
    if (r2 > hh2) r2 = hh2;
    if (r2 < 1) return;
    if (t2 >= r2) t2 = r2 - 1;
    int ex = hw2 - r2, ey = hh2 - r2;
    int x0 = (cx2 - hw2 - 1) >> 1, x1 = (cx2 + hw2) >> 1;
    int y0 = (cy2 - hh2 - 1) >> 1, y1 = (cy2 + hh2) >> 1;
    uint32_t lo = (uint32_t)(cx2 & 2047) | ((uint32_t)(cy2 & 1023) << 11) | ((uint32_t)(ex & 1023) << 21);
    /* p[40:31] ey: bit 31 of w2 is ey[0], ey[9:1] go to w3[8:0] */
    lo |= (uint32_t)(ey & 1) << 31;
    uint32_t hi = ((uint32_t)(ey & 1023) >> 1) | ((uint32_t)(r2 & 255) << 9) | ((uint32_t)(t2 & 255) << 17);
    box(OP_SHAPE, x0, y0, x1, y1, col, opa, lo, hi);
}

void g_rect(int x, int y, int w, int h, int r, uint16_t col, int opa)
{
    g_shape2(2 * x + w, 2 * y + h, w, h, 2 * r, 0, col, opa);
}

/* outline of a rounded rectangle, split into top and bottom bands and two side strips with the
   same geometry: the same pixels as one command, but the renderer skips the empty inside */
void g_outline2(int cx2, int cy2, int hw2, int hh2, int r2, int t2, uint16_t col, int opa)
{
    int x0 = (cx2 - hw2 - 1) >> 1, x1 = (cx2 + hw2) >> 1, y0 = (cy2 - hh2 - 1) >> 1, y1 = (cy2 + hh2) >> 1;
    int rp = r2 / 2 + 2, tp = t2 / 2 + 2;     /* rows / columns that can hold corner or edge pixels */
    if (y1 - y0 < 2 * rp + 2 || x1 - x0 < 2 * rp + 2) { g_shape2(cx2, cy2, hw2, hh2, r2, t2, col, opa); return; }
    clip_y1 = y0 + tp;                                       /* top edge, full width */
    g_shape2(cx2, cy2, hw2, hh2, r2, t2, col, opa);
    clip_y1 = SCR_H - 1; clip_y0 = y1 - tp;                  /* bottom edge */
    g_shape2(cx2, cy2, hw2, hh2, r2, t2, col, opa);
    clip_y0 = y0 + tp + 1; clip_y1 = y1 - tp - 1;            /* left and right columns, corners included */
    clip_x1 = x0 + rp;
    g_shape2(cx2, cy2, hw2, hh2, r2, t2, col, opa);
    clip_x1 = SCR_W - 1; clip_x0 = x1 - rp;
    g_shape2(cx2, cy2, hw2, hh2, r2, t2, col, opa);
    clip_x0 = 0; clip_y0 = 0; clip_x1 = SCR_W - 1; clip_y1 = SCR_H - 1;
}

void g_frame(int x, int y, int w, int h, int r, int t, uint16_t col, int opa)
{
    if (r <= t) r = t + 1;
    g_outline2(2 * x + w, 2 * y + h, w, h, 2 * r, 2 * t, col, opa);
}

void g_circle2(int cx2, int cy2, int r2, uint16_t col, int opa)
{
    g_shape2(cx2, cy2, r2, r2, r2, 0, col, opa);
}

static uint32_t v7(int v) { return (uint32_t)v & 127; }

/* ring segment: outer radius r2, thickness t2 (half pixels), from angle a0 clockwise by sweep
   (1024 = full turn, 0 = +x axis), optional round caps */
void g_arc2(int cx2, int cy2, int r2, int t2, int a0, int sweep, uint16_t col, int opa, int caps)
{
    if (sweep <= 0) return;
    if (r2 > 127) r2 = 127;
    if (t2 >= r2) t2 = r2 - 1;
    int a1 = a0 + (sweep >= 1024 ? 0 : sweep);
    int big = sweep > 512;
    int sx = (icos(a0) * 63 + 8192) >> 14, sy = (isin(a0) * 63 + 8192) >> 14;
    int ex = (icos(a1) * 63 + 8192) >> 14, ey = (isin(a1) * 63 + 8192) >> 14;
    uint32_t lo = (uint32_t)(cx2 & 2047) | ((uint32_t)(cy2 & 1023) << 11) | ((uint32_t)r2 << 21) |
                  ((uint32_t)(t2 & 15) << 28);
    uint32_t hi = ((uint32_t)t2 >> 4) | ((uint32_t)big << 3) | (v7(sx) << 4) | (v7(sy) << 11) | (v7(ex) << 18) |
                  (v7(ey) << 25);
    int x0 = (cx2 - r2 - 1) >> 1, x1 = (cx2 + r2) >> 1, y0 = (cy2 - r2 - 1) >> 1, y1 = (cy2 + r2) >> 1;
    box(OP_ARC, x0, y0, x1, y1, col, opa, lo, hi);
    if (caps && sweep < 1024) {
        int rm = r2 - t2 / 2, rc = t2 / 2;
        g_circle2(cx2 + ((icos(a0) * rm + 8192) >> 14), cy2 + ((isin(a0) * rm + 8192) >> 14), rc, col, opa);
        g_circle2(cx2 + ((icos(a1) * rm + 8192) >> 14), cy2 + ((isin(a1) * rm + 8192) >> 14), rc, col, opa);
    }
}

static inline int glyph(int font, unsigned char c)
{
    if (font) return large_map[c & 127];
    if (c == 0xB0) return DEG_SMALL - 32;
    if (c < 32 || c > 126) return 0;
    return c - 32;
}

int g_char_w(int c) { return font_w[glyph(0, (unsigned char)c)]; }

int g_text_w(int font, const char *s)
{
    int w = 0;
    for (; *s; s++) w += font_w[(font ? 96 : 0) + glyph(font, (unsigned char)*s)];
    return w;
}

int g_text(int x, int y, int font, uint16_t col, int opa, const char *s, int align)
{
    int start = gbyte, n = 0, w = 0;
    const unsigned char *wtab = font_w + (font ? 96 : 0);
    uint32_t word = 0;
    for (; s[n] && n < 127 && gbyte < 4000; n++) {     /* one pass: glyph bytes and width */
        int g = glyph(font, (unsigned char)s[n]);
        w += wtab[g];
        word |= (uint32_t)g << (8 * (gbyte & 3));
        gbyte++;
        if ((gbyte & 3) == 0) { gd[(gbyte >> 2) - 1] = word; word = 0; }
    }
    if (gbyte & 3) { gd[gbyte >> 2] = word; gbyte = (gbyte + 3) & ~3; }
    if (n == 0) return 0;
    if (align == ALIGN_C) x -= w / 2;
    else if (align == ALIGN_R) x -= w;
    box(OP_TEXT, x, y, x + w - 1, y + (font ? FONT_L_H : FONT_S_H) - 1, col, opa,
        (uint32_t)start | ((uint32_t)n << 12) | ((uint32_t)font << 19), 0);
    return w;
}

void g_icon(int x, int y, int idx, uint16_t col, int opa)
{
    if (x < 0 || y < 0) return;
    box(OP_ICON, x, y, x + 23, y + 23, col, opa, (uint32_t)idx, 0);
}

/* per-column spans [top, bottom) in 1/16 pixel, for columns x0..x1 */
void g_span(int x0, int x1, int y0, int y1, const uint32_t *cols, uint16_t col, int opa)
{
    int n = x1 - x0 + 1, a = (gbyte + 3) >> 2;
    if (n <= 0 || a + n > GD_WORDS) return;
    for (int i = 0; i < n; i++) gd[a + i] = cols[i];
    gbyte = (a + n) * 4;
    box(OP_SPAN, x0, y0, x1, y1, col, opa, (uint32_t)a, 0);
}

/* allocates n gdata words for span columns; returns their word address or -1 */
int g_words(int n, volatile uint32_t **p)
{
    int a = (gbyte + 3) >> 2;
    if (n <= 0 || a + n > GD_WORDS) return -1;
    gbyte = (a + n) * 4;
    *p = gd + a;
    return a;
}

void g_span_at(int addr, int x0, int x1, int y0, int y1, int fill, uint16_t col, int opa)
{
    if (addr < 0) return;
    box(OP_SPAN, x0, y0, x1, y1, col, opa, (uint32_t)addr | ((uint32_t)fill << 10), 0);
}

/* 4-bit palette image (see gpu.h); flags: IMG_2X, IMG_2Y, IMG_PAL1, IMG_TRANSP */
void g_image(int x, int y, int w, int h, int base, int stride, int rows, int r0, int flags, int opa)
{
    uint32_t lo = (uint32_t)(base & 4095) | ((uint32_t)(stride & 63) << 12) | ((uint32_t)(rows & 255) << 18) |
                  ((uint32_t)(r0 & 63) << 26);
    uint32_t hi = ((uint32_t)(r0 & 255) >> 6) | ((uint32_t)(flags & 15) << 2);
    box(OP_IMAGE, x, y, x + w - 1, y + h - 1, 0, opa, lo, hi);
}

/* ---------------- number formatting (no libc) ---------------- */
char *fmt_int(char *p, int v)
{
    char t[12];
    int n = 0;
    if (v < 0) { *p++ = '-'; v = -v; }
    do { t[n++] = '0' + v % 10; v /= 10; } while (v);
    while (n) *p++ = t[--n];
    *p = 0;
    return p;
}

char *fmt_fix(char *p, int v, int dec)
{
    int m = 1;
    for (int i = 0; i < dec; i++) m *= 10;
    if (v < 0) { *p++ = '-'; v = -v; }
    p = fmt_int(p, v / m);
    if (dec) {
        *p++ = '.';
        int f = v % m;
        for (int d = m / 10; d; d /= 10) { *p++ = '0' + (f / d) % 10; }
        *p = 0;
    }
    return p;
}

char *fmt_2d(char *p, int v)
{
    *p++ = '0' + (v / 10) % 10;
    *p++ = '0' + v % 10;
    *p = 0;
    return p;
}

char *str_cat(char *p, const char *s)
{
    while (*s) *p++ = *s++;
    *p = 0;
    return p;
}
