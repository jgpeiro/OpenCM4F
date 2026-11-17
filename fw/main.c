/*
 * main.c - OpenCM4F Bench: CPU benchmarks with a UI on the 480x272 LCD (rotary encoder, S1, S2)
 * SPDX-License-Identifier: MIT
 */
#include "hw.h"
#include "ui.h"
#include "bench.h"

void ui_loop(void);

int main(void)
{
    SCB_CCR |= 1u << 9;                 /* STKALIGN: 8-byte aligned exception frames */
    bench_init();
    ui_init();
#ifdef SIM_RUN
    run_req = SIM_RUN;                  /* simulation: start a run at once */
#endif
    ui_loop();
    return 0;
}
