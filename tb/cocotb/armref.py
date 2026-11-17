"""Reference model helpers for the OpenCM4F testbenches: assembling Thumb code with clang / llvm-mc and
running it on Unicorn (QEMU's Cortex-M4 with FPU) as the golden model.
SPDX-License-Identifier: MIT"""
import functools
import os
import struct
import subprocess
import tempfile

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UcError
from unicorn.arm_const import *

CLANG = os.environ.get('CLANG', 'clang')
TARGET = ['--target=thumbv7em-none-eabihf', '-mcpu=cortex-m4', '-mfpu=fpv4-sp-d16', '-mfloat-abi=hard']


@functools.lru_cache(maxsize=None)
def assemble(src: str) -> bytes:
    """Assembles Thumb source (unified syntax) at address 0 and returns the raw bytes."""
    with tempfile.TemporaryDirectory() as d:
        s = os.path.join(d, 'a.s')
        o = os.path.join(d, 'a.o')
        b = os.path.join(d, 'a.bin')
        with open(s, 'w') as f:
            f.write('.syntax unified\n.thumb\n.text\n' + src + '\n')
        subprocess.run([CLANG, *TARGET, '-c', s, '-o', o], check=True, capture_output=True)
        subprocess.run(['llvm-objcopy', '-O', 'binary', '--only-section=.text', o, b], check=True)
        return open(b, 'rb').read()


def f2u(x: float) -> int:
    return struct.unpack('<I', struct.pack('<f', x))[0]


def u2f(u: int) -> float:
    return struct.unpack('<f', struct.pack('<I', u & 0xFFFFFFFF))[0]


S_REGS = [UC_ARM_REG_S0 + i for i in range(32)]
R_REGS = [UC_ARM_REG_R0 + i for i in range(13)] + [UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC]


class FpRef:
    """Runs single FP instructions on Unicorn: s0 = a, s1 = b, s2 = c (destination s2)."""

    def __init__(self):
        self.mu = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS, cpu=UC_CPU_ARM_CORTEX_M4)
        self.mu.mem_map(0, 0x10000)
        self.mu.reg_write(UC_ARM_REG_SP, 0x8000)
        self.loaded = None
        self.run('vmov.f32 s2, s1', 0, 0, 0, 0)      # Unicorn ignores an FPSCR written before its first run

    def run(self, insn: str, a: int, b: int, c: int, fpscr_ctl: int):
        code = assemble(insn + '\nnop\n')
        if self.loaded != insn:
            self.mu.mem_write(0x1000, code)
            self.loaded = insn
        mu = self.mu
        mu.reg_write(S_REGS[0], a)
        mu.reg_write(S_REGS[1], b)
        mu.reg_write(S_REGS[2], c)
        mu.reg_write(UC_ARM_REG_FPSCR, fpscr_ctl)
        n = len(code) - 2
        mu.emu_start(0x1000 | 1, 0x1000 + n)
        return mu.reg_read(S_REGS[2]), mu.reg_read(UC_ARM_REG_FPSCR)
