/*
 * raster.c - C reference of the hardware renderer (rtl/gpu.v), bit for bit
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include "raster.h"
#include "../fw/gpu.h"
#include "../fw/assets.h"
#include "assets_data.h"
#include "rec.h"

static inline int clamp16(int a) { return a < 0 ? 0 : (a > 16 ? 16 : a); }

static inline uint16_t blend(uint16_t d, uint16_t s, int a)
{
    if (a <= 0) return d;
    int dr = d >> 11, dg = (d >> 5) & 63, db = d & 31;
    int sr = s >> 11, sg = (s >> 5) & 63, sb = s & 31;
    int r = (dr * (16 - a) + sr * a + 8) >> 4;
    int g = (dg * (16 - a) + sg * a + 8) >> 4;
    int b = (db * (16 - a) + sb * a + 8) >> 4;
    return (uint16_t)((r << 11) | (g << 5) | b);
}

/* coverage of a rounded shape of radius r at squared distance d2 (half-pixel units) */
static inline int cov(int r, int d2)
{
    int diff = (r + 1) * (r + 1) - d2;
    if (diff <= 0) return 0;
    long long v = ((long long)diff * rec_tab[r]) >> 12;
    return v > 16 ? 16 : (int)v;
}

static inline int a4to16(int a) { return a + (a >> 3); }

static inline int sx7(uint32_t v) { v &= 127; return (v & 64) ? (int)v - 128 : (int)v; }

int raster_line(const uint32_t *dl, const uint32_t *gd, const uint32_t *img, const uint16_t *pal, uint16_t bg, int y,
                uint16_t *line)
{
    int cost = 0;
    for (int x = 0; x < SCR_W; x++) line[x] = bg;
    const uint8_t *gb = (const uint8_t *)gd;
    for (int i = 0; i < DL_CMDS; i++) {
        uint32_t w0 = dl[4 * i], w1 = dl[4 * i + 1], w2 = dl[4 * i + 2], w3 = dl[4 * i + 3];
        uint64_t p = ((uint64_t)w3 << 32) | w2;
        int op = w0 >> 28;
        cost += 1;
        if (op == OP_END) break;
        int y0 = (w0 >> 19) & 511, y1 = (w0 >> 10) & 511, x0 = (w0 >> 1) & 511;
        int x1 = w1 >> 23, opa = (w1 >> 18) & 31;
        uint16_t col = w1 & 0xFFFF;
        if (y < y0 || y > y1) continue;
        cost += GPU_COST_ACTIVE;
        int py = 2 * y + 1;
        if (op == OP_SHAPE || op == OP_ARC) {
            int cx, cy, ex, ey, r, t, big = 0, sxv = 0, syv = 0, exv = 0, eyv = 0;
            cx = p & 2047; cy = (p >> 11) & 1023;
            if (op == OP_SHAPE) {
                ex = (p >> 21) & 1023; ey = (p >> 31) & 1023; r = (p >> 41) & 255; t = (p >> 49) & 255;
            } else {
                ex = ey = 0; r = (p >> 21) & 127; t = (p >> 28) & 127; big = (p >> 35) & 1;
                sxv = sx7(p >> 36); syv = sx7(p >> 43); exv = sx7(p >> 50); eyv = sx7(p >> 57);
            }
            int ady = py - cy; if (ady < 0) ady = -ady;
            int dy = ady - ey; if (dy < 0) dy = 0; if (dy > 255) dy = 255;
            int dys = py - cy;
            for (int x = x0; x <= x1; x++) {
                cost++;
                int px = 2 * x + 1;
                int adx = px - cx; if (adx < 0) adx = -adx;
                int dx = adx - ex; if (dx < 0) dx = 0; if (dx > 255) dx = 255;
                int d2 = dx * dx + dy * dy;
                int a = cov(r, d2);
                if (t) { a -= cov(r - t, d2); if (a < 0) a = 0; }
                if (op == OP_ARC) {
                    int dxs = px - cx;
                    int c1 = sxv * dys - syv * dxs;
                    int c2 = dxs * eyv - dys * exv;
                    int in = big ? (c1 >= 0 || c2 >= 0) : (c1 >= 0 && c2 >= 0);
                    if (!in) a = 0;
                }
                a = (a * opa) >> 4;
                line[x] = blend(line[x], col, a);
            }
        } else if (op == OP_TEXT) {
            int addr = p & 4095, len = (p >> 12) & 127, font = (p >> 19) & 1;
            int H = font ? FONT_L_H : FONT_S_H, row = y - y0;
            if (row >= H) continue;
            int xc = x0;
            for (int k = 0; k < len && xc <= x1; k++) {
                int g = gb[(addr + k) & 4095];
                if (font) { if (g > 13) g = 0; } else if (g > 95) g = 0;
                int w = font_w[font ? 96 + g : g];
                cost += GPU_COST_CHAR;
                for (int c = 0; c < w; c++) {
                    int x = xc + c;
                    if (x > x1) break;
                    cost++;
                    int a4 = font ? font_l_bm[(g * FONT_L_H + row) * 16 + c] : font_s_bm[(g * FONT_S_H + row) * FONT_S_STRIDE + c];
                    int a = (a4to16(a4) * opa) >> 4;
                    line[x] = blend(line[x], col, a);
                }
                xc += w;
            }
        } else if (op == OP_ICON) {
            int idx = p & 31, row = y - y0;
            if (row >= 24) continue;
            for (int c = 0; c < 24; c++) {
                int x = x0 + c;
                if (x > x1) break;
                cost++;
                int a = (a4to16(icon_bm[(idx * 24 + row) * 24 + c]) * opa) >> 4;
                line[x] = blend(line[x], col, a);
            }
        } else if (op == OP_SPAN) {
            int addr = p & 1023, fill = (p >> 10) & 1;
            int top = 16 * y, bot = top + 16;
            for (int x = x0; x <= x1; x++) {
                cost++;
                uint32_t w = gd[(addr + x - x0) & 1023];
                int lo = w & 0xFFFF, hi = fill ? 16 * (y1 + 1) : (int)(w >> 16);
                int a = (hi < bot ? hi : bot) - (lo > top ? lo : top);
                a = (clamp16(a) * opa) >> 4;
                line[x] = blend(line[x], col, a);
            }
        } else if (op == OP_IMAGE) {
            int base = p & 4095, stride = (p >> 12) & 63, H = (p >> 18) & 255, r0 = (p >> 26) & 255;
            int sx = (p >> 34) & 1, sy = (p >> 35) & 1, psel = (p >> 36) & 1, transp = (p >> 37) & 1;
            int row = ((y - y0) >> sy) + r0;
            if (row >= H) row -= H;
            int rb = base + row * stride;
            for (int x = x0; x <= x1; x++) {
                cost++;
                int c = (x - x0) >> sx;
                uint32_t w = img[(rb + (c >> 3)) & 4095];
                int nib = (w >> (4 * (c & 7))) & 15;
                if (transp && nib == 0) continue;
                line[x] = blend(line[x], pal[16 * psel + nib], opa);
            }
        }
    }
    return cost;
}

int raster_frame(const uint32_t *dl, const uint32_t *gd, const uint32_t *img, const uint16_t *pal, uint16_t bg,
                 uint16_t *fb)
{
    int worst = 0;
    for (int y = 0; y < SCR_H; y++) {
        int c = raster_line(dl, gd, img, pal, bg, y, fb + y * SCR_W);
        if (c > worst) worst = c;
    }
    return worst;
}
