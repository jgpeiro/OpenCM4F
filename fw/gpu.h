/*
 * gpu.h - display-list renderer: command format (shared by firmware, C reference and RTL)
 * SPDX-License-Identifier: MIT
 *
 * The renderer draws one LCD line at a time into a line buffer: for each line it walks the
 * command list of the current bank in order (painter's algorithm) and blends every command
 * that covers the line. Colours are RGB565, coverage alpha 0..16.
 *
 * A command is 4 words (128 bits):
 *   w0  [31:28] op  [27:19] y0  [18:10] y1  [9:1] x0             (bounding box, inclusive)
 *   w1  [31:23] x1  [22:18] opacity 0..16   [15:0] colour
 *   w2, w3  parameters p[63:0] = {w3, w2}
 *
 *   op 0  END
 *   op 1  SHAPE  rounded rectangle / circle, filled or outline (half-pixel units)
 *                p[10:0] cx  p[20:11] cy  p[30:21] ex  p[40:31] ey  p[48:41] r  p[56:49] t
 *                (ex, ey: half extents minus r; r >= 1; t = 0 filled, else outline, t < r)
 *   op 2  ARC    ring segment, clockwise from vector S to vector E (screen y down)
 *                p[10:0] cx  p[20:11] cy  p[27:21] r  p[34:28] t  p[35] big (sweep > 180)
 *                p[42:36] sx  p[49:43] sy  p[56:50] ex  p[63:57] ey  (7-bit signed)
 *   op 3  TEXT   p[11:0] byte address in gdata  p[18:12] length  p[19] font (0 small, 1 large)
 *                bytes are glyph indices; the text starts at x0, row 0 at y0, clipped at x1
 *   op 4  ICON   p[4:0] icon number; 24 x 24 at (x0, y0), clipped at x1
 *   op 5  SPAN   p[9:0] word address in gdata; column x uses word addr + (x - x0):
 *                [15:0] top, [31:16] bottom of the covered span in 1/16 pixel (absolute y)
 *                p[10] fill: the bottom is the bottom of the bounding box (area under a trace)
 *   op 6  IMAGE  4-bit palette image from the image RAM (8 pixels per word, pixel 0 in bits 3:0)
 *                p[11:0] base word  p[17:12] stride (words per row)  p[25:18] rows H  p[33:26] first row r0
 *                p[34] 2x wide  p[35] 2x tall  p[36] palette 0/1  p[37] index 0 is transparent
 *                screen row y shows image row ((y - y0) >> 2x tall) + r0, minus H if >= H (ring buffer:
 *                a waterfall scrolls by changing r0); the colour is palette[index], opacity from w1
 */
#pragma once
#include <stdint.h>

#define OP_END   0
#define OP_SHAPE 1
#define OP_ARC   2
#define OP_TEXT  3
#define OP_ICON  4
#define OP_SPAN  5
#define OP_IMAGE 6

#define SCR_W 480
#define SCR_H 272
#define DL_CMDS 256          /* commands per bank */
#define GD_WORDS 1024        /* gdata words per bank */

#define W0(op, x0, y0, y1) (((uint32_t)(op) << 28) | ((uint32_t)(y0) << 19) | ((uint32_t)(y1) << 10) | ((uint32_t)(x0) << 1))
#define W1(x1, opa, col)   (((uint32_t)(x1) << 23) | ((uint32_t)(opa) << 18) | (uint32_t)(col))

#define RGB(r, g, b) ((uint16_t)((((r) >> 3) << 11) | (((g) >> 2) << 5) | ((b) >> 3)))
