/*
 * crt0.c - vector table and reset handler (no libc): copies .data from the ROM, clears .bss,
 * turns on the FPU (CP10, CP11) and the DWT cycle counter, calls main
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>

extern uint32_t __data_start, __data_end, __data_load, __bss_start, __bss_end, __stack_top;
int main(void);

void Default_Handler(void);
void Fault_Handler(void);
#define WEAK __attribute__((weak, alias("Default_Handler")))
void NMI_Handler(void) WEAK;
void SVC_Handler(void) WEAK;
void PendSV_Handler(void) WEAK;
void SysTick_Handler(void) WEAK;
void IRQ0_Handler(void) WEAK;
void Reset_Handler(void);

__attribute__((section(".vectors"), used))
void (*const __vectors[24])(void) = {
    (void (*)(void))&__stack_top, Reset_Handler, NMI_Handler, Fault_Handler, Fault_Handler, Fault_Handler,
    Fault_Handler, 0, 0, 0, 0, SVC_Handler, Default_Handler, 0, PendSV_Handler, SysTick_Handler,
    IRQ0_Handler, Default_Handler, Default_Handler, Default_Handler, Default_Handler, Default_Handler,
    Default_Handler, Default_Handler};

__attribute__((naked, noreturn)) void Reset_Handler(void)
{
    __asm volatile(
        "ldr r0, =0xE000ED88\n"          /* CPACR: CP10, CP11 full access */
        "ldr r1, [r0]\n"
        "orr r1, r1, #0x00F00000\n"
        "str r1, [r0]\n"
        "dsb\n"
        "isb\n"
        "ldr r0, =__data_start\n"        /* .data: ROM -> RAM */
        "ldr r1, =__data_end\n"
        "ldr r2, =__data_load\n"
        "1: cmp r0, r1\n"
        "bhs 2f\n"
        "ldr r3, [r2], #4\n"
        "str r3, [r0], #4\n"
        "b 1b\n"
        "2: ldr r0, =__bss_start\n"      /* .bss = 0 */
        "ldr r1, =__bss_end\n"
        "movs r2, #0\n"
        "3: cmp r0, r1\n"
        "bhs 4f\n"
        "str r2, [r0], #4\n"
        "b 3b\n"
        "4: ldr r0, =0xE000EDFC\n"       /* DEMCR.TRCENA, DWT_CTRL.CYCCNTENA */
        "ldr r1, [r0]\n"
        "orr r1, r1, #0x01000000\n"
        "str r1, [r0]\n"
        "ldr r0, =0xE0001000\n"
        "ldr r1, [r0]\n"
        "orr r1, r1, #1\n"
        "str r1, [r0]\n"
        "bl main\n"
        "b .\n");
}

void fault_report(uint32_t *frame, uint32_t exc);

/* faults: the stacked frame (MSP or PSP) goes to fault_report (ui.c), which shows it on the LCD */
__attribute__((naked)) void Fault_Handler(void)
{
    __asm volatile(
        "tst lr, #4\n"
        "ite eq\n"
        "mrseq r0, msp\n"
        "mrsne r0, psp\n"
        "mrs r1, ipsr\n"
        "b fault_report\n");
}

__attribute__((weak)) void Default_Handler(void)
{
    __asm volatile("mrs r1, ipsr\n mov r0, sp\n b fault_report\n");
}
