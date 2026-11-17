// Renders display lists with the RTL renderer and compares every LCD pixel with the C reference.
//   usage: tb_gpu <snapshots.bin>          snapshots from the PC build (sat_host ... dump)
//          tb_gpu -random <n> [seed]       random lists of every command, heavily overlapping
// A snapshot is dl[1024] gd[1024] bg img[3072] pal[16] (32-bit words; pal holds 2 colours per word).
#include "Vgpu_wrap.h"
#include "Vgpu_wrap___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
int raster_frame(const uint32_t *dl, const uint32_t *gd, const uint32_t *img, const uint16_t *pal,
                            uint16_t bg, uint16_t *fb);
#define R(n) (t->rootp->gpu_wrap__DOT__##n)
static uint32_t rs = 1;
static int opmask = 0x7E;
static uint32_t rnd() { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }
static int rr(int a, int b) { return a + (int)(rnd() % (unsigned)(b - a + 1)); }
#define W0(op, x0, y0, y1) (((uint32_t)(op) << 28) | ((uint32_t)(y0) << 19) | ((uint32_t)(y1) << 10) | ((uint32_t)(x0) << 1))
#define W1(x1, opa, col)   (((uint32_t)(x1) << 23) | ((uint32_t)(opa) << 18) | (uint32_t)(col))
static void make_random(uint32_t *dl, uint32_t *gd, uint32_t *img, uint16_t *pal, uint32_t *bg) {
  for (int i = 0; i < 1024; i++) gd[i] = rnd();
  for (int i = 0; i < 3072; i++) img[i] = rnd();
  for (int i = 0; i < 32; i++) pal[i] = (uint16_t)rnd();
  *bg = rnd() & 0xFFFF;
  int n = (opmask >> 10) & 1 ? 1 : rr(20, 250);
  for (int i = 0; i < n; i++) {
    int op; do op = rr(1, 6); while (!((opmask >> op) & 1));
    int x0 = rr(0, 470), x1 = rr(x0, x0 + rr(0, getenv("TINY") ? 2 : 200)); if (x1 > 479) x1 = 479;   // TINY: stress back-to-back commands
    int y0 = rr(0, 260), y1 = rr(y0, y0 + rr(0, 120)); if (y1 > 271) y1 = 271;
    uint32_t w2 = rnd(), w3 = rnd();
    if (op == 1) {           // valid shape: r >= 1, t < r
      int r = rr(1, 60), tt = rr(0, 1) ? 0 : rr(1, r - 1 > 0 ? r - 1 : 1); if (tt >= r) tt = 0;
      int cx = rr(0, 2000), cy = rr(0, 600), ex = rr(0, 300), ey = rr(0, 300);
      w2 = (uint32_t)cx | ((uint32_t)cy << 11) | ((uint32_t)ex << 21) | ((uint32_t)(ey & 1) << 31);
      w3 = ((uint32_t)ey >> 1) | ((uint32_t)r << 9) | ((uint32_t)tt << 17);
    } else if (op == 2) {    // valid arc: t < r
      int r = rr(2, 127), tt = rr(1, r - 1), cx = rr(0, 2000), cy = rr(0, 600);
      w2 = (uint32_t)cx | ((uint32_t)cy << 11) | ((uint32_t)r << 21) | ((uint32_t)(tt & 15) << 28);
      w3 = ((uint32_t)tt >> 4) | ((uint32_t)rr(0, 1) << 3) | ((rnd() & 0x0FFFFFFFu) << 4);
    } else if (op == 3) {
      int len = rr(1, 40), font = (opmask >> 8) & 1 ? 0 : rr(0, 1);
      w2 = (uint32_t)rr(0, 3000) | ((uint32_t)len << 12) | ((uint32_t)font << 19); w3 = 0;
      if (font) for (int k = 0; k < 1024; k++) {}
    } else if (op == 4) { w2 = (uint32_t)rr(0, 6); w3 = 0; x1 = x0 + 23 > 479 ? 479 : x0 + 23; if (y1 > y0 + 30) y1 = y0 + 30; }
    else if (op == 5) { w2 = (uint32_t)rr(0, 700) | ((uint32_t)rr(0, 1) << 10); w3 = 0; }
    else if (op == 6) {
      int H = rr(1, 70), r0 = rr(0, H - 1), stride = rr(1, 40), base = rr(0, 3072 - H * stride);
      int fl = rr(0, 15), sx = fl & 1, sy = (fl >> 1) & 1;
      w2 = (uint32_t)base | ((uint32_t)stride << 12) | ((uint32_t)H << 18) | ((uint32_t)(r0 & 63) << 26);
      w3 = ((uint32_t)r0 >> 6) | ((uint32_t)fl << 2);
      if (x1 - x0 > (stride * 8 << sx) - 1) x1 = x0 + (stride * 8 << sx) - 1;
      if (y1 - y0 > (H << sy) - 1) y1 = y0 + (H << sy) - 1;
    }
    if (getenv("SHOW")) printf("op %d x %d..%d y %d..%d w2 %08x w3 %08x\n", op, x0, x1, y0, y1, w2, w3);
    dl[4 * i] = W0(op, x0, y0, y1); dl[4 * i + 1] = W1(x1, rr(0, 16), rnd() & 0xFFFF); dl[4 * i + 2] = w2; dl[4 * i + 3] = w3;
  }
  for (int w = 0; w < 4; w++) dl[4 * n + w] = 0;
  // text bytes: small glyphs 0..95, large 0..13
  for (int i = 0; i < 1024; i++) { uint32_t v = 0; for (int b = 0; b < 4; b++) v |= (uint32_t)rr(0, (i & 1) ? 95 : 13) << (8 * b); gd[i] = v; }
}
int main(int argc, char **argv) {
  FILE *f = NULL; int nrand = 0;
  if (!strcmp(argv[1], "-random")) { nrand = atoi(argv[2]); if (argc > 3) rs = (uint32_t)atoi(argv[3]); if (argc > 4) opmask = strtol(argv[4], 0, 0); }
  else f = fopen(argv[1], "rb");
  static uint32_t dl[1024], gd[1024], img[3072], palw[16];
  static uint16_t pal[32];
  static uint16_t ref[272 * 480], got[272 * 480];
  uint32_t bg;
  Vgpu_wrap *t = new Vgpu_wrap;
  int snap = 0, bad_total = 0;
  for (;;) {
    if (f) {
      if (!(fread(dl, 4, 1024, f) == 1024 && fread(gd, 4, 1024, f) == 1024 && fread(&bg, 4, 1, f) == 1 &&
            fread(img, 4, 3072, f) == 3072 && fread(palw, 4, 16, f) == 16)) break;
      for (int i = 0; i < 16; i++) { pal[2 * i] = palw[i] & 0xFFFF; pal[2 * i + 1] = palw[i] >> 16; }
    } else {
      if (snap >= nrand) break;
      make_random(dl, gd, img, pal, &bg);
    }
    raster_frame(dl, gd, img, pal, (uint16_t)bg, ref);
    for (int i = 0; i < 256; i++)
      for (int w = 0; w < 4; w++) R(dl)[i][w] = dl[4 * i + w];         // bank 0
    for (int i = 0; i < 1024; i++) R(gd)[i] = gd[i];
    for (int i = 0; i < 3072; i++) R(img)[i] = img[i];
    t->bank_sel = 0; t->bg = bg;
    t->clk = 0; t->rst_n = 0;
    t->eval();
    for (int i = 0; i < 32; i++) { t->pal_we = 1; t->pal_wa = i; t->pal_wd = pal[i]; t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    t->pal_we = 0;
    for (int i = 0; i < 20; i++) { t->clk ^= 1; t->eval(); }
    t->rst_n = 1;
    int k = 0, prev_clk = 0, prev_vs = 1, frames = 0, done = 0;
    long cyc = 0;
    while (!done && cyc < 30000000) {
      t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++;
      if (prev_clk && !t->lcd_clk) {
        if (t->lcd_de && frames >= 1 && k < 272 * 480) got[k++] = t->lcd_rgb;
        if (prev_vs && !t->lcd_vs) { frames++; if (frames == 2) done = 1; k = 0; }
        prev_vs = t->lcd_vs;
      }
      prev_clk = t->lcd_clk;
    }
    int bad = 0, first = -1;
    for (int i = 0; i < 272 * 480; i++) if (got[i] != ref[i]) { if (first < 0) first = i; bad++; }
    if (bad || snap % 10 == 0) {
      printf("list %d: %d pixels differ (max line %u clocks, overruns %u)", snap, bad, t->stat_max, t->stat_over);
      if (first >= 0) printf("  first at (%d,%d) rtl %04x ref %04x", first % 480, first / 480, got[first], ref[first]);
      printf("\n");
    }
    bad_total += bad;
    if (bad && getenv("DUMP")) { FILE *o = fopen(getenv("DUMP"), "wb"); fwrite(got, 2, 272 * 480, o); fwrite(ref, 2, 272 * 480, o); fclose(o); }
    snap++;
  }
  printf("%d lists, %d differing pixels in all\n", snap, bad_total);
  delete t;
  return bad_total != 0;
}
