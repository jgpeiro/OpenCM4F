/*
 * hw.h - memory map of the OpenCM4F SoC on the Tang Nano 20K (rtl/soc/ocm4_soc.v)
 * SPDX-License-Identifier: MIT
 *
 *   0x0000_0000  code ROM, 32 KB (vectors, code, constants; read only)
 *   0x2000_0000  data RAM, 24 KB (data, bss, stack)
 *   0x4000_0000  display list, 2 banks x 256 commands x 16 bytes (write only)
 *   0x4001_0000  gdata, 2 banks x 4 KB: text bytes and span words (write only)
 *   0x4002_0000  I/O
 *       +0x00  FRAME   (r)  frame counter, increments when the renderer starts a frame (about 58 Hz: 520 x 300 pixel clocks of 6 x 54 MHz)
 *       +0x04  BUTTONS (r)  bit 0 = S1, bit 1 = S2 (1 = pressed, synchronised)
 *       +0x08  BANK    (w)  bank the renderer uses from the next frame on
 *       +0x0C  BG      (w)  background colour (RGB565)
 *       +0x10  STATUS  (r)  [15:0] most clocks one line needed, [31:16] overrun lines
 *       +0x18  ENC     (r)  rotary encoder: [15:0] quarter steps, [16] pressed, [17] CLK, [18] DT
 *       +0x1C  IRQ     (rw) [0] frame IRQ enable, [8] frame flag (r: pending, w 1: clear)
 *       +0x20  CLK_HZ  (r)  CPU clock in Hz (27 MHz; the renderer runs at twice that)
 *       +0x24  MEMSZ   (r)  [31:16] ROM bytes, [15:0] RAM bytes
 *       +0x80  PALETTE (w)  2 x 16 colours for the IMAGE command (not used: no image RAM)
 *   0x4003_0000  PERF: clock counters by class, counting while CTRL[0] = 1; every clock is in one class
 *       +0x00 CTRL (rw: [0] run)   +0x40 + 4 k: clocks of class k (PC_*), 32 bits, wrapping
 */
#pragma once
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(a))

#define DL_BASE(b) ((volatile uint32_t *)(0x40000000u + (b) * 4096u))
#define GD_BASE(b) ((volatile uint32_t *)(0x40010000u + (b) * 4096u))
#define IO(n)      REG32(0x40020000u + (n))
#define PERF(n)    REG32(0x40030000u + (n))

#define IO_FRAME   0x00
#define IO_BUTTONS 0x04
#define IO_BANK    0x08
#define IO_BG      0x0C
#define IO_STATUS  0x10
#define IO_ENC     0x18
#define IO_IRQ     0x1C
#define IO_CLK     0x20
#define IO_MEMSZ   0x24

#define PF_CTRL   0x00
#define PF_CNT(k) (0x40 + 4 * (k))
enum {                  /* clock classes */
    PC_OTHER,           /* execute stage busy with a multi-cycle ALU / branch / system step */
    PC_RETIRE,          /* an instruction completes (one per instruction) */
    PC_BUBBLE,          /* execute stage empty: fetch latency, taken branches */
    PC_LSU,             /* waiting for loads and stores */
    PC_MULDIV,          /* multiply / divide steps */
    PC_FPU,             /* FPU steps */
    PC_EXC,             /* exception entry and return */
    PC_SLEEP,           /* WFI / WFE */
    NPC
};

/* Cortex-M system registers */
#define SCB_CPUID   REG32(0xE000ED00)
#define SCB_ICSR    REG32(0xE000ED04)
#define SCB_CCR     REG32(0xE000ED14)
#define SCB_CPACR   REG32(0xE000ED88)
#define SCB_ID_ISAR0 REG32(0xE000ED60)
#define SCB_ID_ISAR3 REG32(0xE000ED6C)
#define NVIC_ISER   REG32(0xE000E100)
#define NVIC_ICER   REG32(0xE000E180)
#define NVIC_ICPR   REG32(0xE000E280)
#define NVIC_IPR0   REG32(0xE000E400)
#define ICTR        REG32(0xE000E004)
#define FPU_FPCCR   REG32(0xE000EF34)
#define FPU_MVFR0   REG32(0xE000EF40)
#define FPU_MVFR1   REG32(0xE000EF44)
#define DWT_CTRL    REG32(0xE0001000)
#define DWT_CYCCNT  REG32(0xE0001004)
#define DEMCR       REG32(0xE000EDFC)

static inline void irq_enable(void)  { __asm volatile("cpsie i" ::: "memory"); }
static inline void irq_disable(void) { __asm volatile("cpsid i" ::: "memory"); }
