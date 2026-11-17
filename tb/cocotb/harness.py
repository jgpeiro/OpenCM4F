"""Common harness of the OpenCM4F core testbenches (tb_core.v): builds Thumb programs, loads them into the
test memory, resets and runs the core, and checks it in lockstep against Unicorn.
SPDX-License-Identifier: MIT"""
import os
import subprocess
import tempfile

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, ReadWrite

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UcError
from unicorn.arm_const import *

from armref import TARGET, CLANG

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
SW = os.path.join(ROOT, 'sw')

RAM_BYTES = 0x40000
STACK_TOP = 0x3F000
PROG_WORDS = 0x30000 // 4          # words written into the RAM before each program (code + data)

# vector table and start-up for assembly tests: FPU on, then the test at 'test_main'
STARTUP = """
.syntax unified
.thumb
.section .vectors, "a"
.word 0x0003F000
.word _start
.rept 14
.word default_handler
.endr
.rept 16
.word default_handler
.endr
.text
.thumb_func
.global _start
_start:
    ldr r0, =0xE000ED88
    mov r1, #0x00F00000
    str r1, [r0]
    dsb
    isb
    b test_main
.thumb_func
default_handler:
    bkpt #0xEE
.ltorg
"""

LINK_LD = """
ENTRY(_start)
SECTIONS {
    . = 0;
    .vectors : { KEEP(*(.vectors)) }
    .text : { *(.text*) *(.rodata*) }
    . = ALIGN(4);
    .data : { *(.data*) }
    .bss : { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; }
}
"""


def build_asm(body: str, startup: str = STARTUP):
    """Assembles and links a test program; returns (image bytes, symbol dict, listing)."""
    with tempfile.TemporaryDirectory() as d:
        with open(os.path.join(d, 't.s'), 'w') as f:
            f.write(startup + '\n.text\n.thumb_func\n.global test_main\ntest_main:\n' + body + '\n.ltorg\n')
        with open(os.path.join(d, 'link.ld'), 'w') as f:
            f.write(LINK_LD)
        r = subprocess.run([CLANG, *TARGET, '-c', 't.s', '-o', 't.o'], cwd=d, capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError('assembler: ' + r.stderr)
        r = subprocess.run(['ld.lld', '-T', 'link.ld', 't.o', '-o', 't.elf'], cwd=d, capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError('linker: ' + r.stderr)
        return elf_image(os.path.join(d, 't.elf'))


def elf_image(elf: str):
    with tempfile.TemporaryDirectory() as d:
        b = os.path.join(d, 't.bin')
        subprocess.run(['llvm-objcopy', '-O', 'binary', elf, b], check=True)
        with open(b, 'rb') as f:
            img = f.read()
    syms = {}
    out = subprocess.run(['llvm-nm', elf], capture_output=True, text=True).stdout
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3:
            syms[p[2]] = int(p[0], 16)
    lst = subprocess.run(['llvm-objdump', '-d', '--triple=thumbv7em', '--mattr=+vfp4d16sp,+dsp', elf],
                         capture_output=True, text=True).stdout
    return img, syms, lst


def build_c(sources, cflags=(), ldscript=None, extra_objs=()):
    """Compiles C / assembly sources for the core (bare metal, no libc); returns (image, symbols, listing)."""
    with tempfile.TemporaryDirectory() as d:
        objs = []
        for i, src in enumerate(sources):
            o = os.path.join(d, f'o{i}.o')
            subprocess.run([CLANG, *TARGET, '-ffreestanding', '-fno-builtin', '-nostdlib', *cflags, '-c', src, '-o', o],
                           check=True)
            objs.append(o)
        ld = ldscript or os.path.join(d, 'link.ld')
        if not ldscript:
            open(ld, 'w').write(LINK_LD)
        elf = os.path.join(d, 't.elf')
        subprocess.run(['ld.lld', '--gc-sections', '-T', ld, *objs, *extra_objs, '-o', elf], check=True)
        return elf_image(elf)


class Bench:
    """Drives tb_core: clock, reset, program loading, running to a BKPT / TOHOST, lockstep checking."""

    def __init__(self, dut):
        self.dut = dut
        self.cpu = dut.u_cpu
        self.mem = dut.u_mem.mem
        self.clock_started = False
        self.console = ''

    async def start(self, stall=0, seed=1):
        if not self.clock_started:
            cocotb.start_soon(Clock(self.dut.clk, 10, unit='ns').start())
            self.clock_started = True
        else:
            await FallingEdge(self.dut.clk)
        self.dut.stall.value = stall
        self.dut.seed.value = seed
        self.dut.halt_on_bkpt.value = 1
        self.dut.ext_irq_en.value = 1
        self.dut.rst_n.value = 0
        for _ in range(4):
            await RisingEdge(self.dut.clk)

    def load(self, img: bytes, words=None, clear=((0x27000, 0x29800), (0x3E000, 0x40000))):
        """Writes the image (padded to words) and zeroes the data and stack windows of the tests."""
        n = words if words is not None else max(len(img) + 3, 4) // 4
        img = img + bytes(4 * n - len(img)) if len(img) < 4 * n else img
        for i in range(n):
            self.mem[i].value = int.from_bytes(img[4 * i:4 * i + 4], 'little')
        for lo, hi in clear:
            for a in range(max(lo, 4 * n), hi, 4):
                self.mem[a >> 2].value = 0

    async def release(self):
        await RisingEdge(self.dut.clk)
        self.dut.rst_n.value = 1

    async def run(self, max_cycles=200000, on_cycle=None):
        """Runs until halted (BKPT), lockup or a TOHOST write; returns (reason, cycles)."""
        dut = self.dut
        for cyc in range(max_cycles):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if on_cycle is not None:
                on_cycle(cyc)
            if int(dut.u_mem.putc_we.value):
                self.console += chr(int(dut.u_mem.putc_char.value))
            if int(self.cpu.halted.value):
                return 'halt', cyc
            if int(self.cpu.lockup.value):
                return 'lockup', cyc
            if int(dut.u_mem.tohost_we.value):
                return f'tohost:{int(dut.u_mem.tohost.value)}', cyc
        return 'timeout', max_cycles

    def read_word(self, addr):
        return int(self.mem[addr >> 2].value)


class UcModel:
    """Unicorn Cortex-M4F with the same memory image (golden model for lockstep)."""

    def __init__(self, img: bytes):
        mu = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS, cpu=UC_CPU_ARM_CORTEX_M4)
        mu.mem_map(0, RAM_BYTES)
        mu.mem_map(0xE000E000, 0x1000)           # SCS writes (CPACR) are ignored here
        mu.mem_map(0xF0000000, 0x1000)           # test registers
        mu.mem_write(0, img)
        self.mu = mu
        sp = int.from_bytes(img[0:4], 'little')
        pc = int.from_bytes(img[4:8], 'little')
        mu.reg_write(UC_ARM_REG_SP, sp)
        mu.reg_write(UC_ARM_REG_PC, pc & ~1)
        mu.reg_write(UC_ARM_REG_XPSR, 0x01000000)     # QEMU resets with Z set; the architecture leaves it
        self.pc = pc & ~1
        # Unicorn ignores the first FPSCR write before a run: nothing to do here, FPSCR starts at 0

    def step(self):
        mu = self.mu
        pc = mu.reg_read(UC_ARM_REG_PC)
        mu.emu_start(pc | 1, 0xFFFFFFFF, count=1)
        return pc

    def regs(self):
        mu = self.mu
        r = [mu.reg_read(UC_ARM_REG_R0 + i) for i in range(13)]
        r.append(mu.reg_read(UC_ARM_REG_SP))
        r.append(mu.reg_read(UC_ARM_REG_LR))
        return r


class Lockstep:
    """Compares the core with Unicorn after every retired instruction."""

    NAMES = ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8', 'r9', 'r10', 'r11', 'r12', 'sp', 'lr']

    def __init__(self, bench: Bench, img: bytes, listing: str = '', stop_pc=None, max_errors=1):
        self.b = bench
        self.uc = UcModel(img)
        self.rf = [0] * 16                       # physical: 13 MSP, 15 PSP
        self.fp = [0] * 32
        self.retired = 0
        self.errors = []
        self.listing = listing
        self.stop_pc = stop_pc
        self.max_errors = max_errors
        self.done = False
        self.trace = []
        self.pending_it = None

    def insn_text(self, pc):
        for line in self.listing.splitlines():
            if line.strip().startswith(f'{pc:x}:'):
                return line.strip()
        return f'{pc:08x}'

    def cycle(self, cyc):
        cpu = self.b.cpu
        if self.done:
            return
        if int(cpu.trc_valid.value):
            self.retire()
        # register writes of this clock (seen after the comparison of the instruction retired now)
        if int(cpu.trc_rf_we.value):
            self.rf[int(cpu.trc_rf_wa.value)] = int(cpu.trc_rf_wd.value)
        if int(cpu.trc_fp_we.value):
            self.fp[int(cpu.trc_fp_wa.value)] = int(cpu.trc_fp_wd.value)

    def retire(self):
        cpu = self.b.cpu
        if True:
            pc = int(cpu.trc_pc.value)
            self.retired += 1
            if self.stop_pc is not None and pc == self.stop_pc:
                self.done = True
                return
            self.trace.append(pc)
            npc = int(cpu.u_core.arch_npc.value)
            mu = self.uc.mu
            try:
                upc = mu.reg_read(UC_ARM_REG_PC)
                if upc != pc and self.pending_it != upc:
                    pass
                if upc != npc:
                    mu.emu_start(upc | 1, npc, count=12)
            except UcError as e:
                self.errors.append(f'unicorn error at {mu.reg_read(UC_ARM_REG_PC):08x} (core at {pc:08x}): {e}')
                self.done = True
                return
            msgs = []
            if mu.reg_read(UC_ARM_REG_PC) != npc:
                msgs.append(f'next pc {npc:08x} != unicorn {mu.reg_read(UC_ARM_REG_PC):08x}')
            ur = self.uc.regs()
            ctl = int(cpu.trc_control.value)
            sp_phys = 15 if (ctl & 2) else 13
            mine = self.rf[:13] + [self.rf[sp_phys], self.rf[14]]
            for i in range(15):
                if mine[i] != ur[i]:
                    msgs.append(f'{self.NAMES[i]} {mine[i]:08x} != {ur[i]:08x}')
            xpsr = int(cpu.trc_xpsr.value)
            uxpsr = self.uc.mu.reg_read(UC_ARM_REG_XPSR)
            if (xpsr ^ uxpsr) & 0xF80F0000:
                msgs.append(f'xpsr {xpsr:08x} != {uxpsr:08x}')
            for i in range(32):
                us = self.uc.mu.reg_read(UC_ARM_REG_S0 + i)
                if self.fp[i] != us:
                    msgs.append(f's{i} {self.fp[i]:08x} != {us:08x}')
            fpscr = int(cpu.trc_fpscr.value)
            ufpscr = self.uc.mu.reg_read(UC_ARM_REG_FPSCR)
            if fpscr != ufpscr:
                msgs.append(f'fpscr {fpscr:08x} != {ufpscr:08x}')
            if msgs:
                prev = ' <- '.join(self.insn_text(p) for p in self.trace[-4:-1][::-1])
                self.errors.append(f'after {self.insn_text(pc)}: ' + ', '.join(msgs) + f'   [previous: {prev}]')
                if len(self.errors) >= self.max_errors:
                    self.done = True

    def compare_memory(self, lo, hi):
        """Compares a memory range of the core with Unicorn; returns a list of differences."""
        ub = self.uc.mu.mem_read(lo, hi - lo)
        diffs = []
        for a in range(lo, hi, 4):
            w = self.b.read_word(a)
            u = int.from_bytes(ub[a - lo:a - lo + 4], 'little')
            if w != u:
                diffs.append(f'[{a:08x}] {w:08x} != {u:08x}')
        return diffs


async def run_lockstep(dut, bench, img, listing, max_cycles=400000, mem_range=None, stall=0, seed=1, log=True):
    """Loads img, runs the core in lockstep with Unicorn until the BKPT; returns (errors, retired, cycles)."""
    await bench.start(stall=stall, seed=seed)
    bench.load(img, words=max(len(img) // 4 + 1, 0x800))
    ls = Lockstep(bench, img, listing)
    await bench.release()
    reason, cycles = await bench.run(max_cycles=max_cycles, on_cycle=ls.cycle)
    errs = list(ls.errors)
    if reason != 'halt':
        errs.append(f'ended with {reason} after {cycles} clocks, {ls.retired} instructions')
    elif (int(bench.cpu.u_core.x_insn.value) & 0xFF) != 0:
        sp = ls.rf[13]
        spc = bench.read_word(sp + 24) if sp + 28 < RAM_BYTES else 0
        errs.append(f'faulting instruction: {ls.insn_text(spc)}')
        errs.append(f'stopped in an exception handler (BKPT #{int(bench.cpu.u_core.x_insn.value) & 0xFF:#x}) '
                    f'at {int(bench.cpu.u_core.x_pc.value):08x}, cfsr={int(bench.cpu.u_core.u_scs.cfsr.value):08x}, '
                    f'ipsr={int(bench.cpu.u_core.ipsr.value)}, after {ls.retired} instructions')
    if mem_range and not errs:
        errs += ls.compare_memory(*mem_range)[:8]
    return errs, ls.retired, cycles
