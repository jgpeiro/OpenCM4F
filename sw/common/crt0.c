/*
 * crt0.c - vector table and reset handler for OpenCM4F programs (C runtime, no libc)
 * SPDX-License-Identifier: MIT
 *
 * The image is loaded in RAM, so .data needs no copy; .bss is cleared. The FPU (CP10, CP11) is
 * enabled before any C code runs. Handlers are weak: a program defines the ones it uses.
 */
#include <stdint.h>

extern uint32_t __bss_start, __bss_end, __stack_top;
int main(void);
void _exit(int code);

void Default_Handler(void);
#define WEAK __attribute__((weak, alias("Default_Handler")))
void NMI_Handler(void) WEAK;
void HardFault_Handler(void) WEAK;
void MemManage_Handler(void) WEAK;
void BusFault_Handler(void) WEAK;
void UsageFault_Handler(void) WEAK;
void SVC_Handler(void) WEAK;
void DebugMon_Handler(void) WEAK;
void PendSV_Handler(void) WEAK;
void SysTick_Handler(void) WEAK;
void IRQ0_Handler(void) WEAK;  void IRQ1_Handler(void) WEAK;  void IRQ2_Handler(void) WEAK;
void IRQ3_Handler(void) WEAK;  void IRQ4_Handler(void) WEAK;  void IRQ5_Handler(void) WEAK;
void IRQ6_Handler(void) WEAK;  void IRQ7_Handler(void) WEAK;  void IRQ8_Handler(void) WEAK;
void IRQ9_Handler(void) WEAK;  void IRQ10_Handler(void) WEAK; void IRQ11_Handler(void) WEAK;
void IRQ12_Handler(void) WEAK; void IRQ13_Handler(void) WEAK; void IRQ14_Handler(void) WEAK;
void IRQ15_Handler(void) WEAK;
void Reset_Handler(void);

__attribute__((section(".vectors"), used))
void (*const __vectors[32])(void) = {
    (void (*)(void))&__stack_top, Reset_Handler, NMI_Handler, HardFault_Handler, MemManage_Handler,
    BusFault_Handler, UsageFault_Handler, 0, 0, 0, 0, SVC_Handler, DebugMon_Handler, 0, PendSV_Handler,
    SysTick_Handler,
    IRQ0_Handler, IRQ1_Handler, IRQ2_Handler, IRQ3_Handler, IRQ4_Handler, IRQ5_Handler, IRQ6_Handler,
    IRQ7_Handler, IRQ8_Handler, IRQ9_Handler, IRQ10_Handler, IRQ11_Handler, IRQ12_Handler, IRQ13_Handler,
    IRQ14_Handler, IRQ15_Handler};

__attribute__((naked, noreturn)) void Reset_Handler(void)
{
    __asm volatile(
        "ldr r0, =0xE000ED88\n"          /* CPACR: CP10, CP11 full access */
        "ldr r1, [r0]\n"
        "orr r1, r1, #0x00F00000\n"
        "str r1, [r0]\n"
        "dsb\n"
        "isb\n"
        "ldr r0, =__bss_start\n"
        "ldr r1, =__bss_end\n"
        "movs r2, #0\n"
        "1: cmp r0, r1\n"
        "bhs 2f\n"
        "str r2, [r0], #4\n"
        "b 1b\n"
        "2: bl main\n"
        "bl _exit\n"
        "b .\n");
}

__attribute__((weak)) void Default_Handler(void)
{
    __asm volatile("bkpt #0xEE");
    for (;;) { }
}
