"""Directed instruction tests of OpenCM4F, each run in lockstep with Unicorn (every register, flag, FP
register and FPSCR compared after every instruction).
SPDX-License-Identifier: MIT"""
import os

import cocotb

from harness import Bench, build_asm, run_lockstep

DATA = 0x28000

T = {}

T['alu16'] = """
    movs r0, #5
    movs r1, #200
    adds r2, r0, r1
    subs r3, r0, r1
    adds r2, #17
    subs r2, #3
    cmp r0, #5
    lsls r4, r1, #24
    lsrs r5, r4, #3
    asrs r6, r4, #31
    lsrs r7, r1, #32
    asrs r7, r4, #32
    movs r0, #0
    subs r0, r0, #1
    adcs r1, r0
    sbcs r2, r3
    ands r4, r2
    eors r5, r6
    orrs r6, r7
    bics r7, r1
    mvns r0, r2
    rsbs r1, r2, #0
    muls r3, r1, r3
    tst r3, r1
    cmn r0, r1
    movs r2, #33
    lsls r4, r2
    rors r1, r2
    movs r2, #255
    asrs r6, r2
    lsrs r5, r2
    mov r8, r1
    add r8, r3
    mov r12, r8
    cmp r12, r1
    add r2, sp, #16
    add r3, pc, #8
    sub sp, #16
    add sp, #16
    bkpt #0
"""

T['alu32'] = """
    ldr r0, =0x12345678
    ldr r1, =0x87654321
    adds.w r2, r0, r1, lsl #3
    subs.w r3, r0, r1, lsr #7
    rsb r4, r0, r1, asr #31
    adc r5, r0, #0x00FF00FF
    sbcs r6, r1, #0xFF000000
    ands r7, r0, r1, ror #13
    orr r8, r0, #0x3FC
    orn r9, r1, r0
    eors r10, r0, r1, rrx
    bic r11, r1, #0x80000000
    mvns r12, r0, lsl #1
    teq r0, r1
    tst r1, #0x80000000
    cmp.w r0, r1, asr #2
    cmn r0, #255
    movs.w r2, r1, lsr #1
    mov.w r3, #0xAB00AB00
    mvn r4, #0x00AB00AB
    addw r5, r0, #0xFFF
    subw r6, r1, #0x123
    movw r7, #0xBEEF
    movt r7, #0xDEAD
    lsl.w r8, r0, r2
    lsrs.w r9, r1, r3
    asr.w r10, r1, r7
    rors.w r11, r0, r1
    adr.w r12, lab
lab:
    adds r0, r0, r0
    adcs.w r1, r1, r1
    rsbs r2, r0, #100
    sbc.w r3, r0, r1, lsl #31
    bkpt #0
"""

T['bitops'] = """
    ldr r0, =0x80F0100F
    ldr r1, =0x00012345
    ldr r2, =0x7FFFFFFF
    clz r3, r0
    clz r4, r1
    rbit r5, r0
    rev r6, r0
    rev16 r7, r0
    revsh r8, r0
    rev r9, r1
    sxtb r10, r0
    sxth r11, r0
    uxtb r12, r0, ror #8
    uxth r3, r0, ror #16
    sxtab r4, r1, r0, ror #24
    uxtah r5, r1, r0
    sxtb16 r6, r0, ror #8
    uxtb16 r7, r0
    sxtab16 r8, r1, r0
    uxtab16 r9, r1, r0, ror #16
    ubfx r10, r0, #4, #12
    sbfx r11, r0, #28, #4
    sbfx r12, r0, #0, #32
    mov r3, r1
    bfi r3, r0, #8, #4
    bfc r3, #0, #3
    ssat r4, #8, r1
    usat r5, #7, r0
    ssat r6, #16, r0, asr #4
    usat r7, #31, r1, lsl #10
    ssat16 r8, #4, r0
    usat16 r9, #3, r0
    pkhbt r10, r0, r1, lsl #16
    pkhtb r11, r0, r1, asr #8
    pkhtb r12, r0, r1
    qadd r3, r0, r2
    qsub r4, r0, r2
    qdadd r5, r2, r2
    qdsub r6, r0, r2
    usad8 r7, r0, r1
    usada8 r8, r0, r1, r2
    mrs r9, apsr
    msr APSR_nzcvq, r0
    mrs r10, apsr
    bkpt #0
"""

T['simd'] = """
    ldr r0, =0x7FFF8001
    ldr r1, =0x80017FFF
    ldr r2, =0x12FE80FF
    ldr r3, =0x7F0180FE
    sadd16 r4, r0, r1
    sel r5, r2, r3
    ssub16 r4, r0, r1
    sasx r5, r0, r1
    ssax r6, r0, r1
    sadd8 r7, r2, r3
    sel r8, r2, r3
    ssub8 r7, r2, r3
    qadd16 r8, r0, r1
    qsub16 r9, r0, r1
    qasx r10, r0, r1
    qsax r11, r0, r1
    qadd8 r12, r2, r3
    qsub8 r4, r2, r3
    shadd16 r5, r0, r1
    shsub16 r6, r0, r1
    shasx r7, r0, r1
    shsax r8, r0, r1
    shadd8 r9, r2, r3
    shsub8 r10, r2, r3
    uadd16 r11, r0, r1
    sel r12, r2, r3
    usub16 r4, r0, r1
    uasx r5, r0, r1
    usax r6, r0, r1
    uadd8 r7, r2, r3
    usub8 r8, r2, r3
    sel r9, r2, r3
    uqadd16 r10, r0, r1
    uqsub16 r11, r0, r1
    uqasx r12, r0, r1
    uqsax r4, r0, r1
    uqadd8 r5, r2, r3
    uqsub8 r6, r2, r3
    uhadd16 r7, r0, r1
    uhsub16 r8, r0, r1
    uhasx r9, r0, r1
    uhsax r10, r0, r1
    uhadd8 r11, r2, r3
    uhsub8 r12, r2, r3
    mrs r4, apsr
    bkpt #0
"""

T['mul'] = """
    ldr r0, =0x87654321
    ldr r1, =0x12345678
    ldr r2, =0x7FFF8000
    ldr r3, =0x80007FFF
    mul r4, r0, r1
    mla r5, r0, r1, r2
    mls r6, r0, r1, r2
    umull r7, r8, r0, r1
    smull r9, r10, r0, r1
    umlal r7, r8, r0, r1
    smlal r9, r10, r0, r1
    umaal r7, r8, r0, r1
    smulbb r4, r2, r3
    smulbt r5, r2, r3
    smultb r6, r2, r3
    smultt r11, r2, r3
    smlabb r12, r2, r3, r0
    smlatt r4, r2, r3, r1
    smulwb r5, r0, r3
    smulwt r6, r0, r3
    smlawb r11, r0, r3, r1
    smlawt r12, r0, r2, r1
    smuad r4, r2, r3
    smuadx r5, r2, r3
    smusd r6, r2, r3
    smusdx r11, r2, r3
    smlad r12, r2, r3, r0
    smladx r4, r2, r3, r0
    smlsd r5, r2, r3, r0
    smlsdx r6, r2, r3, r1
    smlald r7, r8, r2, r3
    smlaldx r9, r10, r2, r3
    smlsld r7, r8, r2, r3
    smlsldx r9, r10, r2, r3
    smlalbb r7, r8, r2, r3
    smlalbt r9, r10, r2, r3
    smlaltb r7, r8, r2, r3
    smlaltt r9, r10, r2, r3
    smmul r4, r0, r1
    smmulr r5, r0, r1
    smmla r6, r0, r1, r2
    smmlar r11, r0, r1, r2
    smmls r12, r0, r1, r2
    smmlsr r4, r0, r1, r2
    ldr r0, =0x80008000
    smuad r5, r0, r0
    mrs r6, apsr
    sdiv r7, r1, r2
    udiv r8, r0, r2
    sdiv r9, r0, r3
    movs r4, #0
    udiv r10, r0, r4
    sdiv r11, r0, r4
    ldr r5, =0x80000000
    mvn r6, #0
    sdiv r12, r5, r6
    movs r0, #7
    movs r1, #100
    udiv r2, r1, r0
    sdiv r3, r0, r1
    bkpt #0
"""

T['ldst'] = f"""
    ldr r9, ={DATA:#x}
    ldr r0, =0x11223344
    ldr r1, =0xA5B6C7D8
    str r0, [r9]
    str r1, [r9, #4]
    strb r1, [r9, #9]
    strh r0, [r9, #10]
    ldr r2, [r9]
    ldrb r3, [r9, #4]
    ldrh r4, [r9, #6]
    ldrsb r5, [r9, #7]
    ldrsh r6, [r9, #4]
    ldr r7, [r9, #8]
    movs r2, #4
    ldr r3, [r9, r2]
    ldrb r4, [r9, r2]
    str r0, [r9, r2, lsl #2]
    ldr.w r5, [r9, r2, lsl #2]
    ldr r6, [r9, #-4]!
    ldr r7, [r9], #8
    str r1, [r9, #12]!
    strb r0, [r9], #-3
    ldrh r8, [r9, #1]
    ldr r10, [r9, #1]
    str r1, [r9, #3]
    ldrh r11, [r9, #3]
    strh r0, [r9, #7]
    ldr r12, [r9, #5]
    ldrsh r2, [r9, #7]
    bic r9, r9, #3
    ldrd r3, r4, [r9, #-8]
    strd r0, r1, [r9, #16]!
    ldrd r5, r6, [r9], #-16
    ldr r7, lit
    ldrb r8, lit
    ldrsh r10, lit
    ldr.w r11, [r9, #0xFFF]
    ldrt r12, [r9, #4]
    strt r0, [r9, #8]
    ldrsbt r2, [r9, #9]
    pld [r9, #64]
    ldrex r3, [r9]
    strex r4, r1, [r9]
    strex r5, r0, [r9]
    ldrexb r6, [r9]
    strexb r7, r0, [r9]
    ldrexh r8, [r9]
    clrex
    strexh r10, r0, [r9]
    ldr r11, [r9]
    bkpt #0
.align 2
lit: .word 0x9ABCDEF0
"""

T['ldm'] = f"""
    ldr r9, ={DATA:#x}
    movs r0, #1
    movs r1, #2
    movs r2, #3
    movs r3, #4
    mov r4, #5
    mov r8, #9
    stmia r9!, {{r0-r3}}
    stmdb r9!, {{r0, r2, r4, r8}}
    ldmia r9, {{r5-r7, r10}}
    ldmdb r9, {{r11, r12}}
    push {{r0-r7, lr}}
    push.w {{r8, r10, r11}}
    pop.w {{r0, r1, r2}}
    pop {{r3-r7}}
    pop {{r1, r2, r3, r4}}
    push {{r0}}
    pop {{r12}}
    str r0, [sp, #-4]!
    ldr r1, [sp], #4
    mov r10, sp
    stmia r10, {{r0-r2}}
    ldmia.w r10!, {{r3-r5}}
    movs r7, r10
    ldm r7!, {{r0, r1}}
    ldm r7, {{r6, r7}}
    bkpt #0
"""

T['branch'] = """
    movs r0, #0
    movs r1, #10
loop:
    adds r0, r0, r1
    subs r1, #1
    bne loop
    cmp r0, #55
    beq.w ok1
    movs r2, #1
ok1:
    bl func
    movs r3, #3
    cbz r3, skip
    adds r3, #1
skip:
    cbnz r3, skip2
    movs r4, #9
skip2:
    adr r5, func2
    adds r5, #1
    blx r5
    adr r6, tgt
    adds r6, #1
    bx r6
    movs r7, #99
tgt:
    ldr r5, =tbl
    movs r1, #2
    tbb [r5, r1]
t0: movs r7, #10
    b tdone
t1: movs r7, #11
    b tdone
t2: movs r7, #12
tdone:
    ldr r5, =tblh
    movs r1, #1
    tbh [r5, r1, lsl #1]
h0: movs r8, #20
    b hdone
h1: movs r8, #21
hdone:
    movs r1, #5
    cmp r1, #3
    bgt.w gt
    movs r2, #7
gt: blt lt
    mov r3, pc
lt: b.w fwd
    nop
fwd:
    push {lr}
    bl func3
    pop {lr}
    ldr r0, =ret_here + 1
    push {r0}
    pop {pc}
    nop
ret_here:
    ldr r0, =ret2 + 1
    str r0, [sp, #-4]!
    ldr pc, [sp], #4
    nop
ret2:
    movs r1, #4
    add pc, r1
    nop
    nop
    nop
    nop
    bkpt #0
func:
    movs r2, #42
    bx lr
func2:
    movs r4, #43
    bx lr
func3:
    push {r4, lr}
    movs r4, #44
    pop {r4, pc}
.align 2
tbl: .byte (t0 - t0) / 2, (t1 - t0) / 2, (t2 - t0) / 2, 0
tblh: .hword (h0 - h0) / 2, (h1 - h0) / 2
"""

T['it'] = """
    movs r0, #5
    movs r1, #7
    cmp r0, r1
    ite lt
    movlt r2, #1
    movge r2, #2
    itttt ge
    addge r3, r0, r1
    subge r4, r0, r1
    movge r5, #1
    movge r6, #2
    ittee eq
    moveq r7, #1
    addeq r7, #1
    movne r7, #3
    addne r7, r7, #4
    cmp r1, r0
    itt hi
    addhi r8, r1, r0
    lslhi r8, r8, #2
    it cc
    movcc r9, #1
    ite mi
    addmi r10, r0, r1
    subpl r10, r0, r1
    movs r0, #0
    cmp r0, #0
    itet eq
    addeq r0, #1
    addne r0, #2
    addeq r0, #4
    cmp r0, #5
    it ne
    bne.w bad
    itt eq
    moveq r11, #1
    beq good
bad:
    movs r12, #1
good:
    ldr r9, =0x28000
    cmp r0, #5
    itt eq
    ldreq r1, [r9]
    streq r0, [r9, #4]
    it ne
    ldrne r1, [r9, #8]
    bkpt #0
"""

T['fp'] = """
    ldr r0, =0x40490FDB
    ldr r1, =0x3F800000
    ldr r2, =0xC2C80000
    vmov s0, r0
    vmov s1, r1
    vmov s2, s3, r2, r0
    vadd.f32 s4, s0, s1
    vsub.f32 s5, s0, s2
    vmul.f32 s6, s0, s0
    vdiv.f32 s7, s1, s0
    vsqrt.f32 s8, s0
    vmla.f32 s4, s0, s1
    vmls.f32 s5, s0, s1
    vnmla.f32 s6, s0, s1
    vnmls.f32 s7, s0, s1
    vfma.f32 s8, s0, s1
    vfms.f32 s9, s0, s1
    vfnma.f32 s10, s0, s1
    vfnms.f32 s11, s0, s1
    vnmul.f32 s12, s0, s2
    vabs.f32 s13, s2
    vneg.f32 s14, s0
    vmov.f32 s15, #-2.5
    vmov.f32 s16, s15
    vcmp.f32 s0, s1
    vmrs APSR_nzcv, fpscr
    vcmpe.f32 s2, #0
    vmrs r3, fpscr
    vcvt.s32.f32 s17, s2
    vcvt.u32.f32 s18, s0
    vcvtr.s32.f32 s19, s0
    vcvt.f32.s32 s20, s17
    vcvt.f32.u32 s21, s18
    vcvt.s16.f32 s22, s22, #4
    vcvt.f32.s16 s22, s22, #4
    vcvtb.f16.f32 s23, s0
    vcvtt.f16.f32 s23, s2
    vcvtb.f32.f16 s24, s23
    vcvtt.f32.f16 s25, s23
    vmov r4, s4
    vmov r5, r6, s5, s6
    vmov d13, r0, r1
    vmov r7, r8, d13
    vmov.32 d14[1], r2
    vmov.32 r9, d14[1]
    ldr r10, =0x28000
    vstr s4, [r10]
    vstr d2, [r10, #8]
    vldr s30, [r10]
    vldr d15, [r10, #8]
    vstmia r10!, {s0-s7}
    vldmdb r10!, {s8-s15}
    vpush {s16-s19}
    vpush {d10-d11}
    vpop {d12-d13}
    vpop {s20-s23}
    vldr s31, flit
    ldr r11, =0x03C00000
    vmsr fpscr, r11
    vadd.f32 s26, s0, s1
    vdiv.f32 s27, s1, s2
    vmrs r12, fpscr
    bkpt #0
.align 2
flit: .word 0x3E99999A
"""


@cocotb.test()
async def isa_directed(dut):
    bench = Bench(dut)
    only = os.environ.get('ISA_ONLY')
    stall = int(os.environ.get('STALL', '0'))
    fails = []
    for name, body in T.items():
        if only and only != name:
            continue
        img, syms, lst = build_asm(body)
        errs, n, cyc = await run_lockstep(dut, bench, img, lst, mem_range=(0x27000, 0x29000), stall=stall)
        if errs:
            fails.append(name)
            for e in errs[:6]:
                dut._log.error(f'{name}: {e}')
        else:
            dut._log.info(f'{name:8s} ok: {n} instructions, {cyc} clocks')
    assert not fails, f'failed: {fails}'
