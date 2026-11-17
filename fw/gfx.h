/* gfx.h - drawing API on top of the display list (see gpu.h) */
#pragma once
#include <stdint.h>
#include "gpu.h"

enum { ALIGN_L = 0, ALIGN_C = 1, ALIGN_R = 2 };

void g_begin(int bank);
void g_end(void);
int  g_count(void);
extern int g_opa;                       /* global opacity 0..16, multiplied into every command */

int  isin(int a);                       /* a in 1/1024 turns, result Q14 */
int  icos(int a);

void g_shape2(int cx2, int cy2, int hw2, int hh2, int r2, int t2, uint16_t col, int opa);
void g_rect(int x, int y, int w, int h, int r, uint16_t col, int opa);
void g_outline2(int cx2, int cy2, int hw2, int hh2, int r2, int t2, uint16_t col, int opa);
void g_frame(int x, int y, int w, int h, int r, int t, uint16_t col, int opa);
void g_circle2(int cx2, int cy2, int r2, uint16_t col, int opa);
void g_arc2(int cx2, int cy2, int r2, int t2, int a0, int sweep, uint16_t col, int opa, int caps);
int  g_text(int x, int y, int font, uint16_t col, int opa, const char *s, int align);
int  g_text_w(int font, const char *s);
int  g_char_w(int c);                   /* advance of a small-font character */
void g_icon(int x, int y, int idx, uint16_t col, int opa);
void g_span(int x0, int x1, int y0, int y1, const uint32_t *cols, uint16_t col, int opa);
int  g_words(int n, volatile uint32_t **p);
void g_span_at(int addr, int x0, int x1, int y0, int y1, int fill, uint16_t col, int opa);
#define IMG_2X 1
#define IMG_2Y 2
#define IMG_PAL1 4
#define IMG_TRANSP 8
void g_image(int x, int y, int w, int h, int base, int stride, int rows, int r0, int flags, int opa);

/* small helpers for numbers */
char *fmt_int(char *p, int v);
char *fmt_fix(char *p, int v, int dec);         /* v / 10^dec with dec decimals */
char *fmt_2d(char *p, int v);                   /* two digits */
char *str_cat(char *p, const char *s);
