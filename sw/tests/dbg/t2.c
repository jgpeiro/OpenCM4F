#include <stdint.h>
#include "cm4.h"
int printf(const char *f, ...);
volatile uint32_t bf_cnt, svc_num;
__attribute__((used)) void bus_c(uint32_t *frame)
{
    uint32_t c = SCB_CFSR; SCB_CFSR = c; bf_cnt++;
    uint16_t h = *(uint16_t *)frame[6];
    printf("bus fault pc=%x cfsr=%x\n", frame[6], c);
    frame[6] += ((h >> 11) >= 0x1D) ? 4 : 2;
}
__attribute__((naked)) void BusFault_Handler(void) { __asm volatile("tst lr, #4\n ite eq\n mrseq r0, msp\n mrsne r0, psp\n b bus_c\n"); }
__attribute__((used)) void svc_c(uint32_t *frame, uint32_t lr)
{
    uint16_t *pc = (uint16_t *)frame[6];
    svc_num = pc[-1] & 0xFF;
    printf("svc %d lr=%x ctl=%x pc=%x\n", svc_num, lr, __get_CONTROL(), frame[6]);
    if (svc_num == 1) __set_CONTROL(__get_CONTROL() & ~1u);
}
__attribute__((naked)) void SVC_Handler(void) { __asm volatile("tst lr, #4\n ite eq\n mrseq r0, msp\n mrsne r0, psp\n mov r1, lr\n b svc_c\n"); }
int main(void)
{
    SCB_SHCSR |= SHCSR_BUSFAULTENA;
    __set_CONTROL(__get_CONTROL() | 1);
    printf("ctl=%x\n", __get_CONTROL());
    volatile uint32_t id = SCB_CPUID;
    printf("after fault: bf=%d id=%x\n", bf_cnt, id);
    __asm volatile("svc #1" ::: "r0", "memory");
    printf("after svc: ctl=%x\n", __get_CONTROL());
    id = SCB_CPUID;
    printf("bf=%d id=%x\n", bf_cnt, id);
    return 0;
}
