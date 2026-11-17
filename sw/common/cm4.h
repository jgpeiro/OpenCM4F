/*
 * cm4.h - OpenCM4F core registers (System Control Space) and intrinsics, CMSIS style
 * SPDX-License-Identifier: MIT
 */
#pragma once
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(a))
#define REG8(a)  (*(volatile uint8_t *)(a))

/* SysTick */
#define SYST_CSR   REG32(0xE000E010)
#define SYST_RVR   REG32(0xE000E014)
#define SYST_CVR   REG32(0xE000E018)
#define SYST_CALIB REG32(0xE000E01C)
/* NVIC */
#define NVIC_ISER  REG32(0xE000E100)
#define NVIC_ICER  REG32(0xE000E180)
#define NVIC_ISPR  REG32(0xE000E200)
#define NVIC_ICPR  REG32(0xE000E280)
#define NVIC_IABR  REG32(0xE000E300)
#define NVIC_IPR(n) REG8(0xE000E400 + (n))
#define NVIC_STIR  REG32(0xE000EF00)
#define ICTR       REG32(0xE000E004)
/* SCB */
#define SCB_CPUID  REG32(0xE000ED00)
#define SCB_ICSR   REG32(0xE000ED04)
#define SCB_VTOR   REG32(0xE000ED08)
#define SCB_AIRCR  REG32(0xE000ED0C)
#define SCB_SCR    REG32(0xE000ED10)
#define SCB_CCR    REG32(0xE000ED14)
#define SCB_SHPR(n) REG8(0xE000ED18 + (n) - 4)        /* n = exception number 4..15 */
#define SCB_SHCSR  REG32(0xE000ED24)
#define SCB_CFSR   REG32(0xE000ED28)
#define SCB_HFSR   REG32(0xE000ED2C)
#define SCB_MMFAR  REG32(0xE000ED34)
#define SCB_BFAR   REG32(0xE000ED38)
#define SCB_ID_PFR0 REG32(0xE000ED40)
#define SCB_ID_ISAR0 REG32(0xE000ED60)
#define SCB_CPACR  REG32(0xE000ED88)
/* FPU */
#define FPU_FPCCR  REG32(0xE000EF34)
#define FPU_FPCAR  REG32(0xE000EF38)
#define FPU_FPDSCR REG32(0xE000EF3C)
#define FPU_MVFR0  REG32(0xE000EF40)
#define FPU_MVFR1  REG32(0xE000EF44)
/* DWT, CoreDebug */
#define DWT_CTRL   REG32(0xE0001000)
#define DWT_CYCCNT REG32(0xE0001004)
#define DWT_CPICNT REG32(0xE0001008)
#define DWT_EXCCNT REG32(0xE000100C)
#define DWT_SLEEPCNT REG32(0xE0001010)
#define DWT_LSUCNT REG32(0xE0001014)
#define DEMCR      REG32(0xE000EDFC)

#define ICSR_PENDSVSET (1u << 28)
#define ICSR_PENDSTSET (1u << 26)
#define ICSR_NMIPENDSET (1u << 31)
#define SHCSR_USGFAULTENA (1u << 18)
#define SHCSR_BUSFAULTENA (1u << 17)
#define SHCSR_MEMFAULTENA (1u << 16)
#define CCR_DIV_0_TRP (1u << 4)
#define CCR_UNALIGN_TRP (1u << 3)

static inline void __enable_irq(void)  { __asm volatile("cpsie i" ::: "memory"); }
static inline void __disable_irq(void) { __asm volatile("cpsid i" ::: "memory"); }
static inline void __enable_fault_irq(void)  { __asm volatile("cpsie f" ::: "memory"); }
static inline void __disable_fault_irq(void) { __asm volatile("cpsid f" ::: "memory"); }
static inline void __dsb(void) { __asm volatile("dsb" ::: "memory"); }
static inline void __isb(void) { __asm volatile("isb" ::: "memory"); }
static inline void __wfi(void) { __asm volatile("wfi" ::: "memory"); }
static inline void __wfe(void) { __asm volatile("wfe" ::: "memory"); }
static inline void __sev(void) { __asm volatile("sev" ::: "memory"); }
static inline uint32_t __get_CONTROL(void) { uint32_t r; __asm volatile("mrs %0, control" : "=r"(r)); return r; }
static inline void __set_CONTROL(uint32_t v) { __asm volatile("msr control, %0\n isb" :: "r"(v) : "memory"); }
static inline uint32_t __get_PSP(void) { uint32_t r; __asm volatile("mrs %0, psp" : "=r"(r)); return r; }
static inline void __set_PSP(uint32_t v) { __asm volatile("msr psp, %0" :: "r"(v) : "memory"); }
static inline uint32_t __get_MSP(void) { uint32_t r; __asm volatile("mrs %0, msp" : "=r"(r)); return r; }
static inline uint32_t __get_IPSR(void) { uint32_t r; __asm volatile("mrs %0, ipsr" : "=r"(r)); return r; }
static inline uint32_t __get_PRIMASK(void) { uint32_t r; __asm volatile("mrs %0, primask" : "=r"(r)); return r; }
static inline uint32_t __get_BASEPRI(void) { uint32_t r; __asm volatile("mrs %0, basepri" : "=r"(r)); return r; }
static inline void __set_BASEPRI(uint32_t v) { __asm volatile("msr basepri, %0" :: "r"(v) : "memory"); }
static inline void __set_BASEPRI_MAX(uint32_t v) { __asm volatile("msr basepri_max, %0" :: "r"(v) : "memory"); }
static inline uint32_t __get_FAULTMASK(void) { uint32_t r; __asm volatile("mrs %0, faultmask" : "=r"(r)); return r; }
static inline uint32_t __get_FPSCR(void) { uint32_t r; __asm volatile("vmrs %0, fpscr" : "=r"(r)); return r; }
static inline void __set_FPSCR(uint32_t v) { __asm volatile("vmsr fpscr, %0" :: "r"(v) : "memory"); }

static inline void dwt_start(void) { DEMCR |= 1u << 24; DWT_CYCCNT = 0; DWT_CTRL |= 1u; }
