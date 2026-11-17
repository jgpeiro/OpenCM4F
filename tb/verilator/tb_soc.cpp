// OpenCM4F SoC (CPU at 27 MHz, ROM, RAM, renderer and LCD at 54 MHz, encoder) with the firmware: loads fw/<dir>/firmware.bin
// into the code ROM, plays a script of button presses / encoder turns, captures the LCD frames from the
// pins and checks every line against the C reference rendering (host/raster.c) of the display list
// the renderer used for that frame.
// usage: tb_soc <frames> <out.raw|-> <script|-> [every] [firmware.bin]
//   script lines: <frame> <button> <frames>: S1 = 1, S2 = 2 (held), encoder push = 4 (held, with
//   contact bounce), encoder turn = 8 clockwise / 16 counter-clockwise: one detent per LCD frame
//   (the CLK and DT pins step through the quadrature cycle with bounce on each edge)
// environment: MAXCYC=<clocks> stop early
//   IDLE=<RAM address>[:<idle value>] a firmware variable that holds the idle value (default 0) when
//   nothing runs (run_all, from the map file): the script's frame numbers then count from the first
//   frame after the run ended (to look at the results whenever the benchmarks finish); AFTER=<n>
//   stops n frames later
#include "Vocm4_soc.h"
#include "Vocm4_soc___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
int raster_line(const uint32_t *dl, const uint32_t *gd, const uint32_t *img, const uint16_t *pal, uint16_t bg, int y,
                uint16_t *line);
#define S(n) (t->rootp->ocm4_soc__DOT__##n)
#define G(n) (t->rootp->ocm4_soc__DOT__u_gpu__DOT__##n)
struct Press { int f, b, n; };

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: tb_soc <frames> <out.raw|-> <script|-> [every] [firmware.bin]\n"); return 2; }
  int frames = atoi(argv[1]);
  FILE *fo = argv[2][0] == '-' ? NULL : fopen(argv[2], "wb");
  Press ps[1024]; int np = 0;
  if (argv[3][0] != '-') {
    FILE *fs = fopen(argv[3], "r");
    if (!fs) { perror(argv[3]); return 2; }
    while (np < 1024 && fscanf(fs, "%d %d %d", &ps[np].f, &ps[np].b, &ps[np].n) == 3) np++;
    fclose(fs);
  }
  int every = argc > 4 ? atoi(argv[4]) : 1;
  long maxcyc = getenv("MAXCYC") ? atol(getenv("MAXCYC")) : 0;
  Vocm4_soc *t = new Vocm4_soc;
  static uint32_t dl[1024], gd[1024], img0[1];
  static uint16_t pal[32], ref[480], got[272 * 480];
  uint16_t snap_bg = 0;
  int have_snap = 0, k = 0, prev_clk = 0, lcd_frames = 0, checked = 0, bad_frames = 0;
  long lines_checked = 0, bad_lines = 0, cyc = 0;
  unsigned last_cnt = 0;
  long turn_start = -1; int turn_dir = 0, enc_frame = -1;
  t->clk = 0; t->clk_pix = 0; t->rst_n = 0; t->rst_pix_n = 0; t->buttons = 0;
  t->enc_clk = 1; t->enc_dt = 1; t->enc_sw = 1;
  t->eval();                                     // runs the initial blocks (built-in ROM contents)
  if (argc > 5) {                                // firmware image over the built-in ROM contents (after the initial blocks)
    FILE *fb = fopen(argv[5], "rb");
    if (!fb) { perror(argv[5]); return 2; }
    static uint8_t img[1 << 17];
    size_t n = fread(img, 1, sizeof img, fb);
    fclose(fb);
    for (size_t i = 0; i < 8192; i++) {
      uint32_t w = 0;
      for (int b = 0; b < 4; b++) if (4 * i + b < n) w |= (uint32_t)img[4 * i + b] << (8 * b);
      S(rom)[i] = w;
    }
    printf("firmware %s: %zu bytes\n", argv[5], n);
  }
  for (int i = 0; i < 20; i++) { t->clk_pix ^= 1; if (i % 4 == 0 || i % 4 == 2) t->clk = (i % 4 == 0); t->eval(); }
  t->rst_n = 1; t->rst_pix_n = 1;
  int status = 0;
  long idle_addr = -1;
  uint32_t idle_val = 0;
  if (getenv("IDLE")) {
    char *e;
    idle_addr = strtol(getenv("IDLE"), &e, 0);
    if (*e == ':') idle_val = (uint32_t)strtoul(e + 1, 0, 0);
  }
  int idle_frame = idle_addr >= 0 ? -1 : 0, was_busy = 0;
  int stop_after = getenv("AFTER") ? atoi(getenv("AFTER")) : -1;     // frames to run after the end
  while (lcd_frames < frames && (!maxcyc || cyc < maxcyc) && !(stop_after >= 0 && idle_frame >= 0 && lcd_frames - idle_frame >= stop_after)) {
    if (idle_addr >= 0 && idle_frame < 0) {
      unsigned a = ((unsigned)idle_addr & 0xFFFF) >> 2;
      uint32_t v = S(ram0)[a] | (S(ram1)[a] << 8) | (S(ram2)[a] << 16) | ((uint32_t)S(ram3)[a] << 24);
      if (v != idle_val) was_busy = 1;
      else if (was_busy) { idle_frame = lcd_frames; printf("the benchmarks ended at frame %d\n", lcd_frames); }
    }
    int sf = idle_frame < 0 ? -1000000 : lcd_frames - idle_frame;          // frame number for the script
    int btn = 0;
    for (int i = 0; i < np; i++) if (sf >= ps[i].f && sf < ps[i].f + ps[i].n) btn |= ps[i].b;
    t->buttons = btn & 3;
    {                                            // encoder pins
      if (sf != enc_frame) {
        enc_frame = sf;
        if (btn & 24) { turn_start = cyc; turn_dir = (btn & 8) ? 1 : -1; }
      }
      int a = 1, b = 1;
      if (turn_start >= 0) {
        long d = cyc - turn_start;
        int ph = (int)(d / 20000), in = (int)(d % 20000);
        static const int CW[4][2] = {{0, 1}, {0, 0}, {1, 0}, {1, 1}};
        static const int CCW[4][2] = {{1, 0}, {0, 0}, {0, 1}, {1, 1}};
        if (ph >= 4) turn_start = -1;
        else {
          const int (*seq)[2] = turn_dir > 0 ? CW : CCW;
          a = seq[ph][0]; b = seq[ph][1];
          if (in < 600 && (in / 50) % 2) {       // bounce on the line that just changed
            int pa = ph ? seq[ph - 1][0] : 1, pb = ph ? seq[ph - 1][1] : 1;
            if (a != pa) a = !a;
            if (b != pb) b = !b;
          }
        }
      }
      t->enc_clk = a; t->enc_dt = b;
      static long sw_since = -1;
      int sw_dn = (btn & 4) != 0;
      if (sw_dn && sw_since < 0) sw_since = cyc;
      if (!sw_dn) sw_since = -1;
      t->enc_sw = sw_dn ? ((cyc - sw_since) < 2000 && ((cyc - sw_since) / 100) % 2) : 1;
    }
    static long watch = getenv("WATCH") ? strtol(getenv("WATCH"), 0, 0) : -1;
    if (watch >= 0 && !(cyc & 1) && S(d_awvalid) && S(d_awready) && (S(d_awaddr) & ~3u) == (unsigned)watch)
      printf("clock %ld: write %08x = %08x strb %x  (pc %08x)\n", cyc, (unsigned)S(d_awaddr), (unsigned)S(d_wdata),
             (unsigned)S(d_wstrb), (unsigned)S(u_cpu__DOT__u_core__DOT__x_pc));
    // clk_pix every clock (54 MHz), clk every other (27 MHz), rising edges together
    t->clk_pix = 1; if (!(cyc & 1)) t->clk = 1; t->eval();
    t->clk_pix = 0; if (cyc & 1) t->clk = 0; t->eval();
    cyc++;
    if (t->lockup) { printf("CPU LOCKUP at clock %ld, pc %08x\n", cyc, (unsigned)S(u_cpu__DOT__u_core__DOT__x_pc)); status = 1; break; }
    unsigned cnt = G(frame_cnt);
    if (cnt != last_cnt) {                       // the renderer just latched a bank: snapshot it
      last_cnt = cnt;
      int b = G(bank_l);
      for (int i = 0; i < 256; i++) {
        dl[4 * i] = S(dl0)[b * 256 + i]; dl[4 * i + 1] = S(dl1)[b * 256 + i];
        dl[4 * i + 2] = S(dl2)[b * 256 + i]; dl[4 * i + 3] = S(dl3)[b * 256 + i];
      }
      for (int i = 0; i < 1024; i++) gd[i] = S(gd)[b * 1024 + i];
      snap_bg = S(bg);
      have_snap = 1;
      k = 0;
    }
    if (prev_clk && !t->lcd_clk) {
      if (t->lcd_de && k < 272 * 480) {
        got[k++] = t->lcd_rgb;
        if (k == 272 * 480) {
          lcd_frames++;
          if (fo && lcd_frames % every == 0) fwrite(got, 2, 272 * 480, fo);
          if (have_snap && lcd_frames > 2) {
            int bad = 0;
            for (int y = 0; y < 272; y++) {
              raster_line(dl, gd, img0, pal, snap_bg, y, ref);
              int d = 0;
              for (int x = 0; x < 480; x++) d += got[y * 480 + x] != ref[x];
              lines_checked++;
              if (d) { bad_lines++; bad += d; }
            }
            checked++;
            if (bad) { bad_frames++; printf("frame %d: %d pixels differ from the reference\n", lcd_frames, bad); }
          }
          printf("lcd frame %d  %.3f s  line max %u clocks  overruns %u  pc %08x\n", lcd_frames, cyc / 54e6,
                 (unsigned)G(stat_max), (unsigned)G(stat_over), (unsigned)S(u_cpu__DOT__u_core__DOT__x_pc));
          if (getenv("PEEK")) {                    // PEEK=<RAM byte offset>: show that word
            unsigned a = strtoul(getenv("PEEK"), 0, 0) >> 2;
            printf("  RAM[%x] = %02x%02x%02x%02x\n", a * 4, S(ram3)[a], S(ram2)[a], S(ram1)[a], S(ram0)[a]);
          }
          fflush(stdout);
          have_snap = 0;
        }
      }
    }
    prev_clk = t->lcd_clk;
  }
  printf("%d LCD frames (%.3f s, %ld clocks), %d frames checked (%ld lines), %d frames / %ld lines differ, "
         "line max %u, overruns %u\n", lcd_frames, cyc / 54e6, cyc, checked, lines_checked, bad_frames, bad_lines,
         (unsigned)G(stat_max), (unsigned)G(stat_over));
  if (fo) fclose(fo);
  delete t;
  return status || bad_frames != 0;
}
