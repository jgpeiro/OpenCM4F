"""cocotb test of ocm4_fpu against Unicorn (QEMU Cortex-M4F): every FPv4 data-processing operation,
random and special operands, all rounding modes, FZ, DN and AHP. Results, NZCV and the cumulative
exception flags must match bit for bit.
SPDX-License-Identifier: MIT"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

from armref import FpRef

N = int(os.environ.get('FPU_VECTORS', '400'))           # vectors per operation
SEED = int(os.environ.get('SEED', '1'))

# op name -> (asm, op code, prm)
OPS = [
    ('vadd', 'vadd.f32 s2, s0, s1', 0, 0), ('vsub', 'vsub.f32 s2, s0, s1', 1, 0),
    ('vmul', 'vmul.f32 s2, s0, s1', 2, 0), ('vnmul', 'vnmul.f32 s2, s0, s1', 3, 0),
    ('vmla', 'vmla.f32 s2, s0, s1', 4, 0), ('vmls', 'vmls.f32 s2, s0, s1', 5, 0),
    ('vnmla', 'vnmla.f32 s2, s0, s1', 6, 0), ('vnmls', 'vnmls.f32 s2, s0, s1', 7, 0),
    ('vfma', 'vfma.f32 s2, s0, s1', 8, 0), ('vfms', 'vfms.f32 s2, s0, s1', 9, 0),
    ('vfnma', 'vfnma.f32 s2, s0, s1', 10, 0), ('vfnms', 'vfnms.f32 s2, s0, s1', 11, 0),
    ('vdiv', 'vdiv.f32 s2, s0, s1', 12, 0), ('vsqrt', 'vsqrt.f32 s2, s1', 13, 0),
    ('vcmp', 'vcmp.f32 s2, s1', 14, 0), ('vcmpe', 'vcmpe.f32 s2, s1', 14, 1),
    ('vcmp0', 'vcmp.f32 s2, #0', 14, 2), ('vcmpe0', 'vcmpe.f32 s2, #0', 14, 3),
    ('vcvt.s32.f32', 'vcvt.s32.f32 s2, s1', 15, 0x100), ('vcvt.u32.f32', 'vcvt.u32.f32 s2, s1', 15, 0x140),
    ('vcvtr.s32.f32', 'vcvtr.s32.f32 s2, s1', 15, 0x000), ('vcvtr.u32.f32', 'vcvtr.u32.f32 s2, s1', 15, 0x040),
    ('vcvt.f32.s32', 'vcvt.f32.s32 s2, s1', 16, 0x000), ('vcvt.f32.u32', 'vcvt.f32.u32 s2, s1', 16, 0x040),
    ('vcvtb.f16.f32', 'vcvtb.f16.f32 s2, s1', 17, 0), ('vcvtt.f16.f32', 'vcvtt.f16.f32 s2, s1', 17, 1),
    ('vcvtb.f32.f16', 'vcvtb.f32.f16 s2, s1', 18, 0), ('vcvtt.f32.f16', 'vcvtt.f32.f16 s2, s1', 18, 1),
]
# fixed point (in place on s2): (asm, op, unsigned, 16-bit, fbits)
for fb in (1, 7, 16):
    OPS.append((f'vcvt.s16.f32 #{fb}', f'vcvt.s16.f32 s2, s2, #{fb}', 15, 0x100 | 0x80 | fb))
    OPS.append((f'vcvt.u16.f32 #{fb}', f'vcvt.u16.f32 s2, s2, #{fb}', 15, 0x100 | 0xC0 | fb))
    OPS.append((f'vcvt.f32.s16 #{fb}', f'vcvt.f32.s16 s2, s2, #{fb}', 16, 0x80 | fb))
    OPS.append((f'vcvt.f32.u16 #{fb}', f'vcvt.f32.u16 s2, s2, #{fb}', 16, 0xC0 | fb))
for fb in (1, 13, 31, 32):
    OPS.append((f'vcvt.s32.f32 #{fb}', f'vcvt.s32.f32 s2, s2, #{fb}', 15, 0x100 | (fb & 63)))
    OPS.append((f'vcvt.u32.f32 #{fb}', f'vcvt.u32.f32 s2, s2, #{fb}', 15, 0x100 | 0x40 | (fb & 63)))
    OPS.append((f'vcvt.f32.s32 #{fb}', f'vcvt.f32.s32 s2, s2, #{fb}', 16, fb & 63))
    OPS.append((f'vcvt.f32.u32 #{fb}', f'vcvt.f32.u32 s2, s2, #{fb}', 16, 0x40 | (fb & 63)))

SPECIAL = [0x00000000, 0x80000000, 0x7F800000, 0xFF800000, 0x7FC00000, 0xFFC00000, 0x7F800001, 0xFFA00000,
           0x7FBFFFFF, 0x00000001, 0x80000001, 0x007FFFFF, 0x807FFFFF, 0x00800000, 0x80800000, 0x7F7FFFFF,
           0xFF7FFFFF, 0x3F800000, 0xBF800000, 0x40000000, 0x3F7FFFFF, 0x3F800001, 0x4B000000, 0x4F000000,
           0xCF000000, 0x4F800000, 0x5F000000, 0x47000000, 0xC7000000, 0x3F000000, 0xBF000000, 0x3FC00000]


def rnd_operand(rng: random.Random, near=None):
    r = rng.random()
    if r < 0.18:
        return rng.choice(SPECIAL)
    if r < 0.30:
        return rng.getrandbits(32)
    if r < 0.42:                                   # subnormal
        return (rng.getrandbits(1) << 31) | rng.getrandbits(23)
    if r < 0.55 and near is not None:             # close to the other operand (cancellation)
        return (near ^ rng.getrandbits(rng.choice((1, 3, 8, 20)))) ^ (rng.getrandbits(1) << 31)
    if r < 0.65:                                   # integers and halves
        v = rng.randint(-70000, 70000) / rng.choice((1, 2, 4, 1024))
        import struct
        return struct.unpack('<I', struct.pack('<f', v))[0]
    if r < 0.75:                                   # near the overflow / underflow edges
        e = rng.choice((1, 2, 3, 24, 25, 100, 150, 252, 253, 254))
        return (rng.getrandbits(1) << 31) | (e << 23) | rng.getrandbits(23)
    e = rng.randint(100, 154)
    return (rng.getrandbits(1) << 31) | (e << 23) | rng.getrandbits(23)


async def run_op(dut, op, prm, a, b, c, ctl):
    dut.op.value = op
    dut.prm.value = prm
    dut.a.value = a
    dut.b.value = b
    dut.c.value = c
    dut.ctl.value = ctl
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(100):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.done.value):
            res = int(dut.res.value)
            flags = int(dut.flags.value)
            nzcv = int(dut.nzcv.value)
            iscmp = int(dut.is_cmp.value)
            await RisingEdge(dut.clk)
            return res, flags, nzcv, iscmp
    raise AssertionError('FPU did not finish')


@cocotb.test()
async def fpu_vs_unicorn(dut):
    rng = random.Random(SEED)
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.start.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    ref = FpRef()
    fails = 0
    total = 0
    only = os.environ.get('FPU_ONLY')
    for name, asm, op, prm in OPS:
        if only and only not in name:
            continue
        nfail = 0
        for i in range(N):
            a = rnd_operand(rng)
            b = rnd_operand(rng, near=a)
            c = rnd_operand(rng, near=a if rng.random() < 0.5 else None)
            if 'f32.f16' in asm and rng.random() < 0.5:   # half inputs: specials in both halves
                b = (rng.choice((0x7C00, 0xFC00, 0x7E00, 0x7D00, 0x0001, 0x03FF, 0x3C00, 0x7BFF, 0x0400)) << 16) | \
                    rng.choice((0x7C00, 0xFC00, 0x7E00, 0x7D00, 0x8001, 0x83FF, 0xBC00, 0xFBFF, 0x0400))
            if ', s2, #' in asm:
                b = c                                     # fixed point is in place
            rmode = rng.randrange(4)
            fz = int(rng.random() < 0.3)
            dn = int(rng.random() < 0.3)
            ahp = int(rng.random() < 0.3) if 'f16' in asm else 0
            ctl = (ahp << 4) | (dn << 3) | (fz << 2) | rmode
            fpscr = ctl << 22
            exp_res, exp_fpscr = ref.run(asm, a, b, c, fpscr)
            res, flags, nzcv, iscmp = await run_op(dut, op, prm, a, b, c, ctl)
            total += 1
            exp_flags = exp_fpscr & 0x9F
            ok = flags == exp_flags
            if iscmp:
                ok = ok and nzcv == (exp_fpscr >> 28)
            else:
                ok = ok and res == exp_res
            if not ok:
                fails += 1
                nfail += 1
                if nfail <= 6:
                    dut._log.error(f'{name}: a={a:08x} b={b:08x} c={c:08x} ctl={ctl:05b} -> '
                                   f'res={res:08x} flags={flags:02x} nzcv={nzcv:x} | expected '
                                   f'res={exp_res:08x} flags={exp_flags:02x} nzcv={exp_fpscr >> 28:x}')
        dut._log.info(f'{name:22s} {N - nfail}/{N} ok')
    dut._log.info(f'total {total} vectors, {fails} mismatches')
    assert fails == 0
