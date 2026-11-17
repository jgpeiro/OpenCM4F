"""C programs on OpenCM4F (tb_core): self-checking tests (exit code through TOHOST, console through PUTC)
and benchmarks. The programs are built with clang + lld from sw/.
SPDX-License-Identifier: MIT"""
import os

import cocotb

from harness import Bench, build_c, SW

COMMON = [os.path.join(SW, 'common', f) for f in ('crt0.c', 'minilib.c', 'tb_io.c')]
CFLAGS = ['-O2', '-Wall', '-I' + os.path.join(SW, 'common')]
LD = os.path.join(SW, 'common', 'link_tb.ld')

PROGRAMS = {
    'exc_test': ([os.path.join(SW, 'tests', 'exc_test.c')], 400000),
}
if os.environ.get('PROG_SRC'):                     # ad-hoc: PROG_SRC=file.c
    PROGRAMS = {'adhoc': ([os.environ['PROG_SRC']], int(os.environ.get('MAXC', '200000')))}


async def run_program(dut, bench, name, srcs, max_cycles, stall=0, extra_cflags=()):
    img, syms, lst = build_c(COMMON + srcs, cflags=CFLAGS + list(extra_cflags), ldscript=LD)
    await bench.start(stall=stall)
    bench.dut.halt_on_bkpt.value = 1
    bench.load(img, words=len(img) // 4 + 1, clear=((len(img) + 3 & ~3, 0x40000),))
    bench.console = ''
    await bench.release()
    reason, cycles = await bench.run(max_cycles=max_cycles)
    return reason, cycles, bench.console, syms, lst


@cocotb.test()
async def c_programs(dut):
    bench = Bench(dut)
    only = os.environ.get('PROG')
    stall = int(os.environ.get('STALL', '0'))
    fails = []
    for name, (srcs, maxc) in PROGRAMS.items():
        if only and only != name:
            continue
        reason, cycles, out, syms, lst = await run_program(dut, bench, name, srcs, maxc, stall=stall)
        for line in out.splitlines():
            dut._log.info(f'{name}: {line}')
        if reason != 'tohost:0':
            fails.append(name)
            dut._log.error(f'{name}: ended with {reason} after {cycles} clocks')
            if reason == 'halt':
                pc = int(bench.cpu.u_core.x_pc.value)
                dut._log.error(f'halted at {pc:08x} ipsr={int(bench.cpu.u_core.ipsr.value)} '
                               f'cfsr={int(bench.cpu.u_core.u_scs.cfsr.value):08x}')
        else:
            dut._log.info(f'{name}: pass, {cycles} clocks')
    assert not fails
