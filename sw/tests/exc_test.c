/*
 * exc_test.c - self-checking test of OpenCM4F exceptions, NVIC, SysTick, faults, FP context
 * stacking, stacks, privilege, WFI / WFE and the system registers. Runs on tb/axil_mem.v:
 * IRQ lines and NMI are driven through the test registers. Exit code 0 = pass, else the
 * number of the first failed check.
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include "cm4.h"

int printf(const char *f, ...);
#define TB_IRQ (*(volatile uint32_t *)0xF0000008)
#define TB_NMI (*(volatile uint32_t *)0xF0000010)
#define BAD_ADDR ((volatile uint32_t *)0x60000000)       /* answers SLVERR */

static int fails, checks, first_fail;
static void check(int id, int cond)
{
    checks++;
    if (!cond) {
        fails++;
        if (!first_fail) first_fail = id;
        printf("FAIL %d\n", id);
    }
}

/* ---------------- handlers ---------------- */
volatile uint32_t svc_num, svc_arg, svc_lr, pendsv_cnt, systick_cnt, irq_log[16], irq_n, nmi_cnt;
volatile uint32_t uf_cfsr, uf_cnt, bf_cfsr, bf_bfar, bf_cnt, hf_hfsr, hf_cnt, hf_cfsr, last_lr, last_ipsr;
volatile uint32_t fp_handler_ran, nested_basepri;

/* SVC: the stacked frame gives r0 and the PC after SVC; the immediate is in the instruction */
__attribute__((used)) void svc_c(uint32_t *frame, uint32_t lr)
{
    uint16_t *pc = (uint16_t *)frame[6];
    svc_num = pc[-1] & 0xFF;
    svc_arg = frame[0];
    frame[0] = frame[0] * 3;                 /* return value */
    svc_lr = lr;
    if (svc_num == 1) __set_CONTROL(__get_CONTROL() & ~1u);   /* back to privileged thread mode */
}
__attribute__((naked)) void SVC_Handler(void)
{
    __asm volatile("tst lr, #4\n ite eq\n mrseq r0, msp\n mrsne r0, psp\n mov r1, lr\n b svc_c\n");
}

void PendSV_Handler(void) { pendsv_cnt++; last_ipsr = __get_IPSR(); }
void SysTick_Handler(void) { systick_cnt++; }
void NMI_Handler(void) { nmi_cnt++; TB_NMI = 0; }

static void log_irq(int n) { irq_log[irq_n++ & 15] = n; }
void IRQ3_Handler(void)
{
    log_irq(3);
    TB_IRQ &= ~(1u << 3);
    if (TB_IRQ & 0x100) {                    /* nested test: raise IRQ5 (higher priority) here */
        TB_IRQ = (1u << 5);
        __dsb();
        for (volatile int i = 0; i < 20; i++) { }
        log_irq(33);                          /* after IRQ5 returned */
    }
}
void IRQ5_Handler(void) { log_irq(5); TB_IRQ &= ~(1u << 5); }
void IRQ6_Handler(void) { log_irq(6); TB_IRQ &= ~(1u << 6); nested_basepri = __get_BASEPRI(); }
void IRQ7_Handler(void) { log_irq(7); TB_IRQ &= ~(1u << 7); }

/* faults: skip the faulting 16- or 32-bit instruction */
static void skip_insn(uint32_t *frame)
{
    uint16_t h = *(uint16_t *)frame[6];
    frame[6] += ((h >> 11) >= 0x1D) ? 4 : 2;
}
__attribute__((used)) void usage_c(uint32_t *frame)
{
    uf_cfsr = SCB_CFSR;
    SCB_CFSR = uf_cfsr;                       /* write 1 to clear */
    uf_cnt++;
    if (uf_cfsr & (1u << 17)) {               /* INVSTATE: continue at the return label (Thumb) */
        frame[6] = frame[5] & ~1u;            /* stacked LR holds the return address */
        frame[7] |= 1u << 24;
    } else if (uf_cfsr & (1u << 19)) {        /* NOCP: enable the FPU and retry */
        SCB_CPACR |= 0xF << 20;
    } else {
        skip_insn(frame);
    }
}
__attribute__((naked)) void UsageFault_Handler(void)
{
    __asm volatile("tst lr, #4\n ite eq\n mrseq r0, msp\n mrsne r0, psp\n b usage_c\n");
}
__attribute__((used)) void bus_c(uint32_t *frame)
{
    bf_cfsr = SCB_CFSR;
    bf_bfar = SCB_BFAR;
    SCB_CFSR = bf_cfsr;
    bf_cnt++;
    if (bf_cfsr & (1u << 9)) skip_insn(frame);            /* precise: skip the load */
}
__attribute__((naked)) void BusFault_Handler(void)
{
    __asm volatile("tst lr, #4\n ite eq\n mrseq r0, msp\n mrsne r0, psp\n b bus_c\n");
}
__attribute__((used)) void hard_c(uint32_t *frame, uint32_t lr)
{
    hf_hfsr = SCB_HFSR;
    hf_cfsr = SCB_CFSR;
    SCB_HFSR = hf_hfsr;
    SCB_CFSR = hf_cfsr;
    hf_cnt++;
    last_lr = lr;
    if (hf_cfsr & (1u << 16)) skip_insn(frame);              /* escalated UDF; an escalated SVC has returned */
}
__attribute__((naked)) void HardFault_Handler(void)
{
    __asm volatile("tst lr, #4\n ite eq\n mrseq r0, msp\n mrsne r0, psp\n mov r1, lr\n b hard_c\n");
}

/* an interrupt handler that uses the FP registers: clobbers s0..s15 */
void IRQ8_Handler(void)
{
    __asm volatile("mov %0, lr" : "=r"(last_lr));
    TB_IRQ &= ~(1u << 8);
    __asm volatile(
        "vmov.f32 s0, #1.0\n vmov.f32 s1, s0\n vmov.f32 s2, s0\n vmov.f32 s3, s0\n"
        "vmov.f32 s4, s0\n vmov.f32 s5, s0\n vmov.f32 s6, s0\n vmov.f32 s7, s0\n"
        "vmov.f32 s8, s0\n vmov.f32 s9, s0\n vmov.f32 s10, s0\n vmov.f32 s11, s0\n"
        "vmov.f32 s12, s0\n vmov.f32 s13, s0\n vmov.f32 s14, s0\n vmov.f32 s15, s0\n"
        "vmrs r0, fpscr\n orr r0, r0, #0x00C00000\n vmsr fpscr, r0\n" ::: "r0", "memory");
    fp_handler_ran = 1;
}

/* ---------------- tests ---------------- */
static uint32_t do_svc(uint32_t x)
{
    register uint32_t r0 __asm("r0") = x;
    __asm volatile("svc #42" : "+r"(r0) :: "memory");
    return r0;
}

static void wait_cycles(int n) { for (volatile int i = 0; i < n; i++) { } }

static uint32_t psp_stack[64] __attribute__((aligned(8)));
static volatile uint32_t psp_seen, psp_svc;
/* runs fn() in thread mode on the process stack */
__attribute__((naked)) uint32_t run_on_psp(uint32_t (*fn)(void), uint32_t *top)
{
    __asm volatile(
        "push {r4, lr}\n"
        "msr psp, r1\n"
        "mrs r4, control\n"
        "orr r2, r4, #2\n"
        "msr control, r2\n"
        "isb\n"
        "blx r0\n"
        "msr control, r4\n"
        "isb\n"
        "pop {r4, pc}\n");
}
static uint32_t on_psp(void)
{
    uint32_t sp;
    __asm volatile("mov %0, sp" : "=r"(sp));
    psp_seen = sp;
    psp_svc = do_svc(9);                       /* exception taken from the process stack */
    return __get_CONTROL();
}

static void (*ram_vectors[32])(void) __attribute__((aligned(128)));
volatile uint32_t relocated_hit;
void Relocated_IRQ7(void) { relocated_hit++; TB_IRQ &= ~(1u << 7); }

int main(void)
{
    printf("exc_test\n");

    /* ---- identification ---- */
    check(1, SCB_CPUID == 0x410FC241);
    check(2, FPU_MVFR0 == 0x10110021 && FPU_MVFR1 == 0x11000011);
    check(3, SCB_ID_ISAR0 == 0x01141110 && SCB_ID_PFR0 == 0x30);
    check(4, (ICTR & 0xF) == 0);
    check(5, (SCB_CCR & (1u << 9)) != 0);                     /* STKALIGN */
    check(6, (FPU_FPCCR >> 30) == 3);                         /* ASPEN, LSPEN */

    /* ---- SVC ---- */
    uint32_t r = do_svc(7);
    check(10, svc_num == 42 && svc_arg == 7 && r == 21);
    check(11, svc_lr == 0xFFFFFFF9 || svc_lr == 0xFFFFFFE9);

    /* ---- PendSV ---- */
    SCB_ICSR = ICSR_PENDSVSET;
    __dsb(); __isb();
    check(20, pendsv_cnt == 1 && last_ipsr == 14);

    /* ---- SysTick ---- */
    SYST_RVR = 199;
    SYST_CVR = 0;
    SYST_CSR = 7;                                              /* enable, interrupt, core clock */
    while (systick_cnt < 3) __wfi();
    SYST_CSR = 0;
    check(30, systick_cnt == 3);
    check(31, (SYST_CSR & (1u << 16)) != 0);                   /* COUNTFLAG set, cleared by the read */
    check(32, (SYST_CSR & (1u << 16)) == 0);

    /* ---- external interrupts, priorities, nesting ---- */
    NVIC_IPR(3) = 0xC0;                                        /* IRQ3 low priority */
    NVIC_IPR(5) = 0x40;                                        /* IRQ5 high */
    NVIC_IPR(6) = 0x80;
    NVIC_IPR(7) = 0x80;
    NVIC_ISER = (1u << 3) | (1u << 5) | (1u << 6) | (1u << 7);
    check(40, (NVIC_ISER & 0xE8) == 0xE8);
    check(41, NVIC_IPR(5) == 0x40 && NVIC_IPR(3) == 0xC0);
    irq_n = 0;
    TB_IRQ = (1u << 3) | 0x100;                                /* IRQ3, which raises IRQ5 inside */
    wait_cycles(200);
    TB_IRQ = 0;
    check(42, irq_n == 3 && irq_log[0] == 3 && irq_log[1] == 5 && irq_log[2] == 33);
    if (irq_n != 3) printf("irq_n=%d log %d %d %d %d\n", irq_n, irq_log[0], irq_log[1], irq_log[2], irq_log[3]);

    /* two pending at once: taken in priority order */
    irq_n = 0;
    __disable_irq();
    TB_IRQ = (1u << 3) | (1u << 5);
    wait_cycles(20);
    check(43, (NVIC_ISPR & 0x28) == 0x28);                     /* both pending, masked by PRIMASK */
    check(44, irq_n == 0);
    __enable_irq();
    wait_cycles(100);
    check(45, irq_n == 2 && irq_log[0] == 5 && irq_log[1] == 3);

    /* BASEPRI masks priority >= 0x80 */
    irq_n = 0;
    __set_BASEPRI(0x80);
    TB_IRQ = 1u << 6;
    wait_cycles(50);
    check(50, irq_n == 0 && (NVIC_ISPR & (1u << 6)));
    __set_BASEPRI_MAX(0xC0);                                   /* lower priority: ignored */
    check(51, __get_BASEPRI() == 0x80);
    __set_BASEPRI(0);
    wait_cycles(50);
    check(52, irq_n == 1 && irq_log[0] == 6);

    /* software trigger (STIR) and ISPR */
    irq_n = 0;
    NVIC_STIR = 7;
    wait_cycles(30);
    check(53, irq_n == 1 && irq_log[0] == 7);
    NVIC_ISPR = 1u << 7;
    wait_cycles(30);
    check(54, irq_n == 2);
    NVIC_ICER = 1u << 7;
    NVIC_ISPR = 1u << 7;
    wait_cycles(30);
    check(55, irq_n == 2 && (NVIC_ISPR & (1u << 7)));
    NVIC_ICPR = 1u << 7;
    check(56, (NVIC_ISPR & (1u << 7)) == 0);

    /* NMI */
    TB_NMI = 1;
    wait_cycles(30);
    check(60, nmi_cnt == 1);

    /* ---- faults ---- */
    SCB_SHCSR |= SHCSR_USGFAULTENA | SHCSR_BUSFAULTENA;
    /* undefined instruction */
    __asm volatile("udf #3");
    check(70, uf_cnt == 1 && (uf_cfsr & (1u << 16)));
    /* division by zero trap */
    SCB_CCR |= CCR_DIV_0_TRP;
    volatile uint32_t zero = 0, x = 5;
    volatile uint32_t q = x / zero;
    (void)q;
    check(71, uf_cnt == 2 && (uf_cfsr & (1u << 25)));
    SCB_CCR &= ~CCR_DIV_0_TRP;
    q = x / zero;
    check(72, uf_cnt == 2 && q == 0);
    /* unaligned trap */
    static uint32_t words[4];
    volatile uint32_t *ua = (volatile uint32_t *)((uint8_t *)words + 1);
    q = *ua;                                                   /* allowed */
    check(73, uf_cnt == 2);
    SCB_CCR |= CCR_UNALIGN_TRP;
    q = *ua;
    check(74, uf_cnt == 3 && (uf_cfsr & (1u << 24)));
    SCB_CCR &= ~CCR_UNALIGN_TRP;
    /* INVSTATE: BX to an even address */
    __asm volatile(
        "adr r0, 1f\n"                        /* even address of the label */
        "adr lr, 1f\n"
        "orr lr, lr, #1\n"
        "bx r0\n"
        ".align 2\n"
        "1:\n" ::: "r0", "lr", "memory");
    check(75, uf_cnt == 4 && (uf_cfsr & (1u << 17)));
    /* NOCP */
    SCB_CPACR &= ~(0xFu << 20);
    __dsb(); __isb();
    __asm volatile("vmov.f32 s0, #2.0" ::: "memory");
    check(76, uf_cnt == 5 && (uf_cfsr & (1u << 19)));
    /* precise bus fault on a load */
    q = *BAD_ADDR;
    check(80, bf_cnt == 1 && (bf_cfsr & (1u << 9)) && (bf_cfsr & (1u << 15)) && bf_bfar == 0x60000000);
    /* imprecise bus fault on a store */
    *BAD_ADDR = 1;
    __dsb();
    wait_cycles(10);
    check(81, bf_cnt == 2 && (bf_cfsr & (1u << 10)));
    /* escalation: UsageFault disabled -> HardFault, FORCED */
    SCB_SHCSR &= ~SHCSR_USGFAULTENA;
    __asm volatile("udf #4");
    check(85, hf_cnt == 1 && (hf_hfsr & (1u << 30)) && (hf_cfsr & (1u << 16)));
    SCB_SHCSR |= SHCSR_USGFAULTENA;
    /* SVC while masked by PRIMASK... is still taken (SVC is synchronous, priority 0 > PRIMASK level? no:
       PRIMASK raises execution priority to 0, SVC priority 0 cannot preempt -> HardFault) */
    __disable_irq();
    do_svc(1);
    __enable_irq();
    check(86, hf_cnt == 2 && (hf_hfsr & (1u << 30)));

    /* ---- FP context stacking ---- */
    __asm volatile(
        "vmov.f32 s0, #0.5\n vmov.f32 s1, #1.5\n vmov.f32 s2, #2.5\n vmov.f32 s3, #3.5\n"
        "vmov.f32 s4, #4.5\n vmov.f32 s5, #5.5\n vmov.f32 s6, #6.5\n vmov.f32 s7, #7.5\n"
        "vmov.f32 s8, #8.5\n vmov.f32 s9, #9.5\n vmov.f32 s10, #10.5\n vmov.f32 s11, #11.5\n"
        "vmov.f32 s12, #12.5\n vmov.f32 s13, #13.5\n vmov.f32 s14, #14.5\n vmov.f32 s15, #15.5\n" ::: "memory");
    check(90, (__get_CONTROL() & 4) != 0);                     /* FPCA set by the FP instructions */
    NVIC_IPR(8) = 0x40;
    NVIC_ISER = 1u << 8;
    TB_IRQ = 1u << 8;
    wait_cycles(60);
    float f[16];
    __asm volatile("vstmia %0, {s0-s15}" :: "r"(f) : "memory");
    int same = 1;
    for (int i = 0; i < 16; i++) if (f[i] != 0.5f + i) same = 0;
    check(91, fp_handler_ran == 1);
    check(92, same);                                           /* restored from the extended frame */
    check(93, last_lr == 0xFFFFFFE9);
    check(94, (__get_FPSCR() & 0x00C00000) == 0);             /* FPSCR restored */

    /* ---- process stack ---- */
    uint32_t ctl = run_on_psp(on_psp, &psp_stack[64]);
    check(100, psp_seen > (uint32_t)psp_stack && psp_seen <= (uint32_t)&psp_stack[64]);
    check(101, psp_svc == 27 && (svc_lr & 0xF) == 0xD);
    check(102, (ctl & 2) != 0 && (__get_CONTROL() & 2) == 0);

    /* ---- unprivileged thread mode ---- */
    __set_CONTROL(__get_CONTROL() | 1);
    bf_cnt = 0;
    volatile uint32_t id = SCB_CPUID;                         /* SCS from unprivileged: BusFault */
    (void)id;
    __disable_irq();                                           /* CPS ignored when unprivileged */
    uint32_t pm = __get_PRIMASK();
    check(110, bf_cnt == 1 && pm == 0);
    /* back to privileged through SVC: the handler clears nPRIV */
    __asm volatile("svc #1" ::: "r0", "memory");
    check(111, (__get_CONTROL() & 1) == 0);
    id = SCB_CPUID;
    check(112, bf_cnt == 1 && id == 0x410FC241);
    if (bf_cnt != 1 || id != 0x410FC241) printf("bf_cnt=%d id=%x\n", bf_cnt, id);

    /* ---- VTOR relocation ---- */
    void (*const volatile *vt)(void) = (void (*const volatile *)(void))(uintptr_t)SCB_VTOR;   /* table at 0 */
    for (int i = 0; i < 32; i++) ram_vectors[i] = vt[i];
    ram_vectors[16 + 7] = Relocated_IRQ7;
    SCB_VTOR = (uint32_t)ram_vectors;
    __dsb();
    NVIC_ISER = 1u << 7;
    NVIC_STIR = 7;
    wait_cycles(40);
    check(120, relocated_hit == 1 && SCB_VTOR == (uint32_t)ram_vectors);
    SCB_VTOR = 0;

    /* ---- WFE / SEV ---- */
    __sev();
    __wfe();                                                   /* event register set: returns */
    check(130, 1);

    /* ---- DWT cycle counter ---- */
    dwt_start();
    uint32_t c0 = DWT_CYCCNT;
    wait_cycles(10);
    uint32_t c1 = DWT_CYCCNT;
    check(140, c1 > c0 + 20);

    printf("%d checks, %d failed\n", checks, fails);
    return first_fail;
}
