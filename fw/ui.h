/* ui.h - user interface: colours, focus, widgets, pages (after Sat Signal Lab's UI) */
#pragma once
#include <stdint.h>
#include "gfx.h"
#include "assets.h"

#define C_BG      RGB(9, 14, 20)
#define C_BAR     RGB(6, 10, 15)
#define C_CARD    RGB(17, 25, 34)
#define C_CARD_B  RGB(34, 48, 62)
#define C_PLOT    RGB(5, 9, 18)
#define C_GRID    RGB(30, 44, 60)
#define C_TEXT    RGB(226, 234, 240)
#define C_DIM     RGB(128, 146, 162)
#define C_FAINT   RGB(58, 74, 90)
#define C_TRACK   RGB(38, 52, 66)
#define C_GREEN   RGB(74, 222, 128)
#define C_GREEN_D RGB(20, 58, 40)
#define C_CYAN    RGB(56, 214, 236)
#define C_CYAN_D  RGB(18, 70, 84)
#define C_ORANGE  RGB(251, 146, 60)
#define C_YELLOW  RGB(250, 214, 60)
#define C_RED     RGB(248, 96, 96)
#define C_BLUE    RGB(80, 150, 255)
#define C_PURPLE  RGB(186, 140, 255)
#define C_DARK    RGB(6, 10, 14)
#define C_WHITE   RGB(255, 255, 255)

enum { P_BENCH, P_SCORES, P_CYCLES, P_ISA, P_CPU, NPAGES };

typedef struct {
    const char *name;
    uint8_t icon, nitems;
    uint32_t press;                     /* items that are buttons: the encoder push acts at once */
    void (*draw)(void);
    void (*act)(int k, int dir);
} page_t;

extern const page_t PAGES[NPAGES];
extern int T, page, fi;                 /* frames, page, focused item */
extern int enc_edit;
extern volatile int run_req;            /* benchmark the main loop should run (-1 none, NB = ISA, NB+1 all) */
extern int run_all;                     /* running the whole set */

void reg(int k, int x, int y, int w, int h, int r);
void card(int x, int y, int w, int h);
void title(int x, int y, const char *s);
void button(int k, int x, int y, int w, int h, const char *s, uint16_t col, int on);
void hbar(int x, int y, int w, int h, int frac, uint16_t col);
void show_toast(const char *s);
int  clampi(int v, int lo, int hi);
int  ease(int v, int target, int k);
void donut(int cx, int cy, int r, int t, const uint32_t *v, const uint16_t *col, int n);

/* numbers */
char *fmt_sig(char *p, float v, int sig);      /* 3 significant digits: 1.23, 12.3, 123, 1234 */

/* clock classes as drawn (colour, name), in drawing order */
#define NCLS 6
extern const uint8_t CLS_IDX[NCLS];
extern const uint16_t CLS_COL[NCLS];
extern const char *const CLS_NAME[NCLS];
void cls_vals(const uint32_t *cls, uint32_t *v);   /* NCLS values from the PERF classes */

/* pages */
void pg_bench(void);  void act_bench(int k, int dir);
void pg_scores(void); void act_scores(int k, int dir);
void pg_cycles(void); void act_cycles(int k, int dir);
void pg_isa(void);    void act_isa(int k, int dir);
void pg_cpu(void);    void act_cpu(int k, int dir);

void ui_init(void);
void ui_frame(int bank, int btn, int df);
extern uint16_t load_hist[128];         /* UI clocks per frame, as 1/1000 of a frame period */
extern int load_n;
extern int per_mhz;                     /* Scores: per MHz (1) or at the clock (0) */
