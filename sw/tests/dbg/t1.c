#include <stdint.h>
#include "cm4.h"
int printf(const char *f, ...);
volatile uint32_t bf_cnt, bf_cfsr, bf_bfar, bf_pc;
__attribute__((used)) void bus_c(uint32_t *frame)
{
    bf_cfsr = SCB_CFSR; bf_bfar = SCB_BFAR; SCB_CFSR = bf_cfsr; bf_cnt++;
    bf_pc = frame[6];
    uint16_t h = *(uint16_t *)frame[6];
    frame[6] += ((h >> 11) >= 0x1D) ? 4 : 2;
}
__attribute__((naked)) void BusFault_Handler(void) { __asm volatile("tst lr, #4\n ite eq\n mrseq r0, msp\n mrsne r0, psp\n b bus_c\n"); }
int main(void)
{
    NVIC_IPR(3) = 0xC0;
    NVIC_IPR(5) = 0x40;
    printf("ipr3=%x ipr5=%x word=%x\n", NVIC_IPR(3), NVIC_IPR(5), REG32(0xE000E404));
    SCB_SHCSR |= SHCSR_BUSFAULTENA;
    printf("shcsr=%x\n", SCB_SHCSR);
    volatile uint32_t q = *(volatile uint32_t *)0x60000000;
    printf("bf_cnt=%d cfsr=%x bfar=%x pc=%x q=%x\n", bf_cnt, bf_cfsr, bf_bfar, bf_pc, q);
    return 0;
}
