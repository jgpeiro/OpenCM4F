"""Unit tests of the multiplier (ocm4_mul) and the divider (ocm4_div) against Python models of the
ARMv7-M pseudo-code, with random and corner-case operands.
  run.py mul      every multiply kind and flag combination the decoder produces
  run.py div      SDIV / UDIV including division by zero and INT_MIN / -1
Environment: UNIT_VECTORS (default 20000), SEED.
SPDX-License-Identifier: MIT"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, FallingEdge

N = int(os.environ.get('UNIT_VECTORS', '20000'))
M32 = 0xFFFFFFFF
MK_MUL, MK_MULL, MK_SMLXY, MK_SMLW, MK_SMLD, MK_SMMUL = range(6)
F_ACC, F_SUB, F_X, F_N, F_M, F_ROUND, F_LONG, F_SIGNED, F_UMAAL = (1 << i for i in range(9))


def s32(v):
    v &= M32
    return v - (1 << 32) if v >> 31 else v


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v >> 15 else v


def mul_ref(kind, fl, a, b, c, d):
    """(lo, hi, q) of the pseudo-code; q is None where the instruction does not set Q"""
    q = None
    if kind == MK_MUL:                                   # MUL, MLA, MLS
        p = a * b
        r = (c - p) if fl & F_SUB else ((c + p) if fl & F_ACC else p)
        return r & M32, None, None
    if kind == MK_MULL:                                  # UMULL SMULL UMLAL SMLAL UMAAL
        sg = fl & F_SIGNED
        p = (s32(a) * s32(b)) if sg else (a * b)
        if fl & F_UMAAL:
            r = p + c + d
        elif fl & F_ACC:
            r = p + ((d << 32) | c)
        else:
            r = p
        r &= (1 << 64) - 1
        return r & M32, r >> 32, None
    if kind == MK_SMLXY:                                 # SMULxy SMLAxy SMLALxy
        x = s16(a >> 16) if fl & F_N else s16(a)
        y = s16(b >> 16) if fl & F_M else s16(b)
        p = x * y
        if fl & F_LONG:
            r = (p + ((d << 32) | c)) & ((1 << 64) - 1)
            return r & M32, r >> 32, None
        if fl & F_ACC:
            r = p + s32(c)
            return r & M32, None, not (-(1 << 31) <= r < (1 << 31))
        return p & M32, None, None
    if kind == MK_SMLW:                                  # SMULWy SMLAWy
        y = s16(b >> 16) if fl & F_M else s16(b)
        p = (s32(a) * y) >> 16
        if fl & F_ACC:
            r = p + s32(c)
            return r & M32, None, not (-(1 << 31) <= r < (1 << 31))
        return p & M32, None, None
    if kind == MK_SMLD:                                  # SMUAD SMUSD SMLAD SMLSD SMLALD SMLSLD
        bx = ((b >> 16) | (b << 16)) & M32 if fl & F_X else b
        p1 = s16(a) * s16(bx)
        p2 = s16(a >> 16) * s16(bx >> 16)
        p = p1 - p2 if fl & F_SUB else p1 + p2
        if fl & F_LONG:
            r = (p + ((d << 32) | c)) & ((1 << 64) - 1)
            return r & M32, r >> 32, None
        r = p + (s32(c) if fl & F_ACC else 0)
        return r & M32, None, not (-(1 << 31) <= r < (1 << 31))
    if kind == MK_SMMUL:                                 # SMMUL SMMLA SMMLS (R)
        p = s32(a) * s32(b)
        acc = (s32(c) << 32) if fl & F_ACC else 0
        r = acc - p if fl & F_SUB else acc + p
        if fl & F_ROUND:
            r += 0x80000000
        return (r >> 32) & M32, None, None
    raise ValueError(kind)


# the flag combinations the decoder produces for each kind
COMBOS = {
    MK_MUL: [0, F_ACC, F_ACC | F_SUB],
    MK_MULL: [F_LONG, F_LONG | F_SIGNED, F_LONG | F_ACC, F_LONG | F_ACC | F_SIGNED, F_LONG | F_UMAAL],
    MK_SMLXY: [n | m | acc for n in (0, F_N) for m in (0, F_M) for acc in (0, F_ACC, F_ACC | F_LONG)],
    MK_SMLW: [m | acc for m in (0, F_M) for acc in (0, F_ACC)],
    MK_SMLD: [x | s | acc for x in (0, F_X) for s in (0, F_SUB) for acc in (0, F_ACC, F_ACC | F_LONG)],
    MK_SMMUL: [F_SIGNED | s | r | acc for r in (0, F_ROUND) for (s, acc) in ((0, 0), (0, F_ACC), (F_SUB, F_ACC))],
}
SPECIAL = [0, 1, 2, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFF8000,
           0x00007FFF, 0x8000FFFF, 0x7FFF8000]


def operand(rng):
    return rng.choice(SPECIAL) if rng.random() < 0.25 else rng.getrandbits(32)


@cocotb.test()
async def mul_random(dut):
    if dut._name != 'ocm4_mul':
        return
    rng = random.Random(int(os.environ.get('SEED', '1')))
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.start.value = 0
    await FallingEdge(dut.clk)
    bad = 0
    kinds = list(COMBOS)
    for i in range(N):
        kind = kinds[i % len(kinds)]
        fl = rng.choice(COMBOS[kind])
        a, b, c, d = (operand(rng) for _ in range(4))
        dut.kind.value = kind
        dut.fl.value = fl
        dut.a.value = a
        dut.b.value = b
        dut.c.value = c
        dut.d.value = d
        dut.start.value = 1
        await RisingEdge(dut.clk)                        # products registered
        await FallingEdge(dut.clk)
        dut.start.value = 0
        await ReadOnly()
        lo, hi, q = int(dut.lo.value), int(dut.hi.value), int(dut.q_set.value)
        rlo, rhi, rq = mul_ref(kind, fl, a, b, c, d)
        if lo != rlo or (rhi is not None and hi != rhi) or (rq is not None and q != int(rq)):
            bad += 1
            if bad <= 10:
                dut._log.error(f'kind {kind} fl {fl:03x} a {a:08x} b {b:08x} c {c:08x} d {d:08x}: '
                               f'lo {lo:08x} hi {hi:08x} q {q}, expected {rlo:08x} {rhi} {rq}')
        await FallingEdge(dut.clk)
    dut._log.info(f'{N} multiplies, {bad} mismatches')
    assert bad == 0


def div_ref(sgn, n, d):
    if d == 0:
        return 0
    if not sgn:
        return n // d
    a, b = s32(n), s32(d)
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return q & M32                                       # INT_MIN / -1 wraps to INT_MIN


@cocotb.test()
async def div_random(dut):
    if dut._name != 'ocm4_div':
        return
    rng = random.Random(int(os.environ.get('SEED', '1')))
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.start.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)
    bad = clocks = 0
    for i in range(N):
        sgn = rng.getrandbits(1)
        n = operand(rng) >> rng.choice((0, 0, 8, 16, 24, 31))
        d = operand(rng) >> rng.choice((0, 8, 16, 24, 28, 31))
        if i < 8:
            n, d = [(0x80000000, M32), (5, 0), (M32, 1), (0, 7), (7, M32), (0x80000000, 1), (100, 7), (1, 2)][i]
        dut.sgn.value = sgn
        dut.n.value = n
        dut.d.value = d
        dut.start.value = 1
        await FallingEdge(dut.clk)
        dut.start.value = 0
        k = 0
        while True:
            await ReadOnly()
            if int(dut.done.value):
                break
            await FallingEdge(dut.clk)
            k += 1
            assert k < 40, 'divider hangs'
        clocks += k + 1
        q = int(dut.q.value)
        r = div_ref(sgn, n, d)
        if q != r:
            bad += 1
            if bad <= 10:
                dut._log.error(f'{"S" if sgn else "U"}DIV {n:08x} / {d:08x} = {q:08x}, expected {r:08x}')
        await FallingEdge(dut.clk)
    dut._log.info(f'{N} divisions, {bad} mismatches, {clocks / N:.1f} clocks on average')
    assert bad == 0
