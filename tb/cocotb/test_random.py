"""Constrained-random instruction streams for OpenCM4F, checked in lockstep against Unicorn.

Every program initialises the integer and FP registers, flags and FPSCR randomly, then runs a few hundred
random instructions from every group of the ARMv7E-M + FPv4-SP instruction set (16- and 32-bit encodings,
IT blocks, forward branches, CBZ / CBNZ, BL, loads and stores of every size and addressing mode incl.
unaligned ones, LDM / STM / PUSH / POP, exclusives, DSP, multiply / divide, FP arithmetic, conversions
and transfers). The bus stalls randomly. Registers, flags, FP registers and FPSCR are compared after
every instruction and the data memory at the end.
Environment: RANDOM_PROGRAMS (default 40), RANDOM_LEN (default 300), SEED.
SPDX-License-Identifier: MIT"""
import os
import random

import cocotb

from harness import Bench, build_asm, run_lockstep

D = ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8', 'r11', 'r12']   # free data registers (LR: BL)
L = ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7']
CONDS = ['eq', 'ne', 'cs', 'cc', 'mi', 'pl', 'vs', 'vc', 'hi', 'ls', 'ge', 'lt', 'gt', 'le']
INV = {'eq': 'ne', 'ne': 'eq', 'cs': 'cc', 'cc': 'cs', 'mi': 'pl', 'pl': 'mi', 'vs': 'vc', 'vc': 'vs', 'hi': 'ls',
       'ls': 'hi', 'ge': 'lt', 'lt': 'ge', 'gt': 'le', 'le': 'gt'}
DATA = 0x28000


class Gen:
    def __init__(self, rng: random.Random):
        self.r = rng
        self.lines = []
        self.lab = 0
        self.depth = 0          # words pushed on the stack
        self.fdepth = 0
        self.subs = []

    def reg(self, pool=D, excl=()):
        return self.r.choice([x for x in pool if x not in excl])

    def mod_imm(self):
        r = self.r
        k = r.randrange(5)
        b = r.randrange(256)
        if k == 0:
            return b
        if k == 1:
            return b * 0x00010001
        if k == 2:
            return b * 0x01000100
        if k == 3:
            return b * 0x01010101
        v = 0x80 | r.randrange(128)
        return (v << r.randrange(25)) & 0xFFFFFFFF

    def shift(self):
        r = self.r
        t = r.choice(['lsl', 'lsr', 'asr', 'ror', 'rrx', None])
        if t is None:
            return ''
        if t == 'rrx':
            return ', rrx'
        n = r.randint(1, 31) if t in ('lsl', 'ror') else r.randint(1, 32)
        return f', {t} #{n}'

    # ---------------- instruction groups (each returns a list of lines) ----------------
    def g_dp16(self, c=''):
        r = self.r
        a, b, d = self.reg(L), self.reg(L), self.reg(L)
        s = 's' if not c else ''
        return [r.choice([
            f'add{s}{c} {d}, {a}, {b}', f'sub{s}{c} {d}, {a}, {b}', f'add{s}{c} {d}, {a}, #{r.randrange(8)}',
            f'sub{s}{c} {d}, {a}, #{r.randrange(8)}', f'mov{s}{c} {d}, #{r.randrange(256)}',
            f'add{s}{c} {d}, #{r.randrange(256)}', f'sub{s}{c} {d}, #{r.randrange(256)}',
            f'lsl{s}{c} {d}, {a}, #{r.randrange(32)}', f'lsr{s}{c} {d}, {a}, #{r.randint(1, 32)}',
            f'asr{s}{c} {d}, {a}, #{r.randint(1, 32)}', f'and{s}{c} {d}, {a}', f'eor{s}{c} {d}, {a}',
            f'orr{s}{c} {d}, {a}', f'bic{s}{c} {d}, {a}', f'adc{s}{c} {d}, {a}', f'sbc{s}{c} {d}, {a}',
            f'ror{s}{c} {d}, {a}', f'lsl{s}{c} {d}, {a}', f'lsr{s}{c} {d}, {a}', f'asr{s}{c} {d}, {a}',
            f'mvn{s}{c} {d}, {a}', f'mul{s}{c} {d}, {a}, {d}', f'rsb{s}{c} {d}, {a}, #0',
            f'cmp{c} {a}, #{r.randrange(256)}', f'cmp{c} {a}, {b}', f'cmn{c} {a}, {b}', f'tst{c} {a}, {b}',
            f'mov{c} {self.reg()}, {self.reg()}', f'add{c} {self.reg()}, {self.reg()}', f'cmp{c} {self.reg()}, {self.reg()}'])]

    def g_dp32(self, c=''):
        r = self.r
        d, a, b = self.reg(), self.reg(), self.reg()
        s = r.choice(['', 's'])
        op = r.choice(['and', 'bic', 'orr', 'orn', 'eor', 'add', 'adc', 'sbc', 'sub', 'rsb'])
        cmp = r.choice(['tst', 'teq', 'cmp', 'cmn'])
        if r.random() < 0.5:
            o2 = f'#{self.mod_imm():#x}'
        else:
            o2 = f'{b}{self.shift()}'
        w = '' if o2.startswith('#') else '.w'
        return [r.choice([f'{op}{s}{c}{w} {d}, {a}, {o2}', f'{cmp}{c}{w} {a}, {o2}', f'mov{s}{c}{w} {d}, {o2}',
                          f'mvn{s}{c}{w} {d}, {o2}', f'{op}{s}{c}{w} {d}, {a}, {o2}'])]

    def g_shreg(self, c=''):
        r = self.r
        return [f"{r.choice(['lsl', 'lsr', 'asr', 'ror'])}{r.choice(['', 's'])}{c}.w {self.reg()}, {self.reg()}, {self.reg()}"]

    def g_imm(self, c=''):
        r = self.r
        d, a = self.reg(), self.reg()
        lsb = r.randrange(32)
        w = r.randint(1, 32 - lsb)
        return [r.choice([
            f'addw{c} {d}, {a}, #{r.randrange(4096)}', f'subw{c} {d}, {a}, #{r.randrange(4096)}',
            f'movw{c} {d}, #{r.randrange(65536)}', f'movt{c} {d}, #{r.randrange(65536)}',
            f'ssat{c} {d}, #{r.randint(1, 32)}, {a}{r.choice(["", f", lsl #{r.randint(1, 31)}", f", asr #{r.randint(1, 31)}"])}',
            f'usat{c} {d}, #{r.randint(0, 31)}, {a}{r.choice(["", f", lsl #{r.randint(1, 31)}", f", asr #{r.randint(1, 31)}"])}',
            f'ssat16{c} {d}, #{r.randint(1, 16)}, {a}', f'usat16{c} {d}, #{r.randint(0, 15)}, {a}',
            f'sbfx{c} {d}, {a}, #{lsb}, #{w}', f'ubfx{c} {d}, {a}, #{lsb}, #{w}', f'bfi{c} {d}, {a}, #{lsb}, #{w}',
            f'bfc{c} {d}, #{lsb}, #{w}'])]

    def g_bit(self, c=''):
        r = self.r
        d, a, b, e = self.reg(), self.reg(), self.reg(), self.reg()
        rot = r.choice(['', ', ror #8', ', ror #16', ', ror #24'])
        par = r.choice(['s', 'q', 'sh', 'u', 'uq', 'uh']) + r.choice(['add16', 'asx', 'sax', 'sub16', 'add8', 'sub8'])
        return [r.choice([
            f'clz{c} {d}, {a}', f'rbit{c} {d}, {a}', f'rev{c}.w {d}, {a}', f'rev16{c}.w {d}, {a}', f'revsh{c}.w {d}, {a}',
            f'{r.choice(["sxtb", "sxth", "uxtb", "uxth"])}{c}.w {d}, {a}{rot}',
            f'{r.choice(["sxtab", "sxtah", "uxtab", "uxtah", "sxtab16", "uxtab16"])}{c} {d}, {a}, {b}{rot}',
            f'{r.choice(["sxtb16", "uxtb16"])}{c} {d}, {a}{rot}', f'sel{c} {d}, {a}, {b}', f'{par}{c} {d}, {a}, {b}',
            f'{par}{c} {d}, {a}, {b}', f'{r.choice(["qadd", "qsub", "qdadd", "qdsub"])}{c} {d}, {a}, {b}',
            f'usad8{c} {d}, {a}, {b}', f'usada8{c} {d}, {a}, {b}, {e}',
            f'pkhbt{c} {d}, {a}, {b}{r.choice(["", f", lsl #{r.randint(1, 31)}"])}',
            f'pkhtb{c} {d}, {a}, {b}{r.choice(["", f", asr #{r.randint(1, 32)}"])}'])]

    def g_mul(self, c=''):
        r = self.r
        d, a, b, e = self.reg(), self.reg(), self.reg(), self.reg()
        lo = self.reg()
        hi = self.reg(excl=(lo,))
        xy = r.choice(['bb', 'bt', 'tb', 'tt'])
        return [r.choice([
            f'mul{c} {d}, {a}, {b}', f'mla{c} {d}, {a}, {b}, {e}', f'mls{c} {d}, {a}, {b}, {e}',
            f'{r.choice(["umull", "smull", "umlal", "smlal", "umaal"])}{c} {lo}, {hi}, {a}, {b}',
            f'smul{xy}{c} {d}, {a}, {b}', f'smla{xy}{c} {d}, {a}, {b}, {e}', f'smlal{xy}{c} {lo}, {hi}, {a}, {b}',
            f'smulw{xy[0]}{c} {d}, {a}, {b}', f'smlaw{xy[0]}{c} {d}, {a}, {b}, {e}',
            f'{r.choice(["smuad", "smuadx", "smusd", "smusdx"])}{c} {d}, {a}, {b}',
            f'{r.choice(["smlad", "smladx", "smlsd", "smlsdx"])}{c} {d}, {a}, {b}, {e}',
            f'{r.choice(["smlald", "smlaldx", "smlsld", "smlsldx"])}{c} {lo}, {hi}, {a}, {b}',
            f'{r.choice(["smmul", "smmulr"])}{c} {d}, {a}, {b}',
            f'{r.choice(["smmla", "smmlar", "smmls", "smmlsr"])}{c} {d}, {a}, {b}, {e}',
            f'{r.choice(["sdiv", "udiv"])}{c} {d}, {a}, {b}', f'{r.choice(["sdiv", "udiv"])}{c} {d}, {a}, {b}'])]

    def g_mem(self, c='', nostack=False):
        r = self.r
        t = self.reg()
        k = r.randrange(9)
        if c:
            k = r.choice([0, 1])
        if nostack and k == 5:
            k = 0
        if k == 0:       # immediate offset, any alignment
            op = r.choice(['ldr', 'ldrb', 'ldrh', 'ldrsb', 'ldrsh', 'str', 'strb', 'strh'])
            off = r.choice([r.randrange(-255, 0), r.randrange(0, 0x800)])
            return [f'{op}{c}{".w" if off >= 0 else ""} {t}, [r9, #{off}]']
        if k == 1:       # register offset
            op = r.choice(['ldr', 'ldrb', 'ldrh', 'ldrsb', 'ldrsh', 'str', 'strb', 'strh'])
            return ([r.choice([f'and r10, {self.reg()}, #0x3FC', f'ubfx r10, {self.reg()}, #0, #10',
                               f'and r10, {self.reg()}, #0xFF'])] if not c else []) + \
                   [f'{op}{c}.w {t}, [r9, r10{r.choice(["", ", lsl #1", ", lsl #2"])}]']
        if k == 2:       # pre / post indexed with writeback, word-aligned steps
            op = r.choice(['ldr', 'ldrb', 'ldrh', 'ldrsb', 'ldrsh', 'str', 'strb', 'strh'])
            off = 4 * r.randint(-30, 30)
            return [r.choice([f'{op} {t}, [r9, #{off}]!', f'{op} {t}, [r9], #{off}'])]
        if k == 3:       # dual
            t2 = self.reg(excl=(t,))
            off = 4 * r.randint(-60, 60)
            op = r.choice(['ldrd', 'strd'])
            return [r.choice([f'{op} {t}, {t2}, [r9, #{off}]', f'{op} {t}, {t2}, [r9, #{off}]!', f'{op} {t}, {t2}, [r9], #{off}'])]
        if k == 4:       # multiple
            regs = sorted(r.sample(D, r.randint(2, 6)), key=lambda x: int(x[1:]))
            lst = ', '.join(regs)
            return [r.choice([f'stmia r9, {{{lst}}}', f'ldmia r9, {{{lst}}}', f'stmdb r9, {{{lst}}}', f'ldmdb r9, {{{lst}}}',
                              f'stmdb r9!, {{{lst}}}', f'ldmia r9!, {{{lst}}}', f'stmia r9!, {{{lst}}}', f'ldmdb r9!, {{{lst}}}'])]
        if k == 5:       # push / pop
            regs = sorted(r.sample(D + ['lr'], r.randint(1, 5)), key=lambda x: (x == 'lr', int(x[1:]) if x != 'lr' else 14))
            if self.depth >= len(regs) and r.random() < 0.5:
                self.depth -= len(regs)
                return [f'pop {{{", ".join(regs)}}}']
            if self.depth < 200:
                self.depth += len(regs)
                return [f'push {{{", ".join(regs)}}}']
            return []
        if k == 6:       # exclusive
            t2 = self.reg(excl=(t,))
            sz = r.choice(['', 'b', 'h'])
            off = '' if sz else f', #{4 * r.randrange(4)}'
            return [f'ldrex{sz} {t}, [r9{off}]', f'strex{sz} {t2}, {self.reg(excl=(t2,))}, [r9{off}]']
        if k == 7:       # FP load / store
            s, dd = r.randrange(32), r.randrange(16)
            off = 4 * r.randint(-60, 60)
            n = r.randint(1, 8)
            s0 = r.randrange(32 - n + 1)
            return [r.choice([f'vldr s{s}, [r9, #{off}]', f'vstr s{s}, [r9, #{off}]', f'vldr d{dd}, [r9, #{off}]',
                              f'vstr d{dd}, [r9, #{off}]', f'vstmia r9, {{s{s0}-s{s0 + n - 1}}}',
                              f'vldmia r9, {{s{s0}-s{s0 + n - 1}}}', f'vstmdb r9!, {{s{s0}-s{s0 + n - 1}}}',
                              f'vldmia r9!, {{s{s0}-s{s0 + n - 1}}}'])]
        # re-centre the data pointer
        return [f'movw r9, #{DATA & 0xFFFF}', f'movt r9, #{DATA >> 16}']

    def g_fp(self, c=''):
        r = self.r
        d, n, m = (f's{r.randrange(32)}' for _ in range(3))
        op = r.choice(['vadd', 'vsub', 'vmul', 'vnmul', 'vdiv', 'vmla', 'vmls', 'vnmla', 'vnmls', 'vfma', 'vfms',
                       'vfnma', 'vfnms'])
        fb = r.randint(1, 16)
        return [r.choice([
            f'{op}{c}.f32 {d}, {n}, {m}', f'{op}{c}.f32 {d}, {n}, {m}', f'vsqrt{c}.f32 {d}, {m}', f'vabs{c}.f32 {d}, {m}',
            f'vneg{c}.f32 {d}, {m}', f'vmov{c}.f32 {d}, {m}', f'vcmp{c}.f32 {d}, {m}', f'vcmpe{c}.f32 {d}, #0',
            f'vmrs{c} APSR_nzcv, fpscr', f'vmrs{c} {self.reg()}, fpscr',
            f'{r.choice(["vcvt", "vcvtr"])}{c}.{r.choice(["s32", "u32"])}.f32 {d}, {m}',
            f'vcvt{c}.f32.{r.choice(["s32", "u32"])} {d}, {m}',
            f'vcvt{c}.{r.choice(["s16", "u16", "s32", "u32"])}.f32 {d}, {d}, #{fb}',
            f'vcvt{c}.f32.{r.choice(["s16", "u16", "s32", "u32"])} {d}, {d}, #{fb}',
            f'vcvt{r.choice(["b", "t"])}{c}.f16.f32 {d}, {m}', f'vcvt{r.choice(["b", "t"])}{c}.f32.f16 {d}, {m}',
            f'vmov{c} {d}, {self.reg()}', f'vmov{c} {self.reg()}, {d}',
            f'vmov{c}.f32 {d}, #{r.choice(["1.0", "-2.5", "0.125", "31.0", "-0.1875"])}'])]

    def g_misc(self, c=''):
        r = self.r
        return [r.choice([f'mrs{c} {self.reg()}, apsr', f'msr{c} APSR_nzcvq, {self.reg()}', f'msr{c} APSR_g, {self.reg()}',
                          f'msr{c} APSR_nzcvqg, {self.reg()}', f'nop{c}', f'dmb', f'dsb', f'isb', f'clrex'])]

    def g_branch(self):
        r = self.r
        self.lab += 1
        lab = f'L{self.lab}'
        body = []
        for _ in range(r.randint(0, 3)):
            body += self.pick(noflow=True, nostack=True)
        k = r.randrange(4)
        if k == 0:
            head = [f'b{r.choice(CONDS)}{r.choice(["", ".w"])} {lab}']
        elif k == 1:
            head = [f'{r.choice(["cbz", "cbnz"])} {self.reg(L)}, {lab}']
        elif k == 2:
            head = [f'b {lab}']
        else:
            self.lab += 1
            sub = f'S{self.lab}'
            sbody = []
            for _ in range(r.randint(1, 4)):
                sbody += self.pick(noflow=True, nomem=True)
            self.subs.append([f'{sub}:'] + sbody + ['bx lr'])
            return [f'bl {sub}']
        return head + body + [f'{lab}:']

    def g_it(self):
        r = self.r
        cond = r.choice(CONDS)
        n = r.randint(1, 4)
        pat = ''.join(r.choice('te') for _ in range(n - 1))
        out = [f'it{pat} {cond}']
        conds = [cond] + [cond if p == 't' else INV[cond] for p in pat]
        for c in conds:
            g = r.choice([self.g_dp16, self.g_dp32, self.g_shreg, self.g_bit, self.g_mul, self.g_fp, self.g_mem, self.g_imm])
            ins = g(c)
            out += ins[-1:]
        return out

    def pick(self, noflow=False, nomem=False, nostack=False):
        r = self.r
        groups = [(self.g_dp16, 14), (self.g_dp32, 14), (self.g_shreg, 4), (self.g_imm, 6), (self.g_bit, 10),
                  (self.g_mul, 8), (self.g_fp, 12), (self.g_misc, 3)]
        if not nomem:
            groups.append(((lambda: self.g_mem(nostack=True)) if nostack else self.g_mem, 16))
        if not noflow:
            groups += [(self.g_branch, 6), (self.g_it, 6)]
        tot = sum(w for _, w in groups)
        x = r.uniform(0, tot)
        for g, w in groups:
            x -= w
            if x <= 0:
                return g()
        return groups[0][0]()

    def program(self, n):
        r = self.r
        out = [f'movw r9, #{DATA & 0xFFFF}', f'movt r9, #{DATA >> 16}', 'mov r10, #0']
        for x in D + ['lr']:
            out.append(f'ldr {x}, ={r.getrandbits(32):#x}')
        pool = []
        for i in range(16):
            pool.append(r.choice([r.getrandbits(32), 0x3F800000, 0x80000000, 0x7F800000, 0x7FC00001, 0x00012345,
                                  (r.randrange(100, 160) << 23) | r.getrandbits(23)]))
        out.append('adr r10, fpool')
        out.append('vldmia r10, {s0-s15}')
        out.append('vldmia r10, {s16-s31}')
        out.append(f'ldr r10, ={(r.randrange(4) << 22) | (r.randrange(2) << 24) | (r.randrange(2) << 25) | (r.randrange(2) << 26):#x}')
        out.append('vmsr fpscr, r10')
        out.append(f'ldr r10, ={r.getrandbits(5) << 27 | r.getrandbits(4) << 16:#x}')
        out.append('msr APSR_nzcvqg, r10')
        out.append('mov r10, #0')
        while len(out) < n:
            out += self.pick()
        # balance the stacks
        while self.depth > 0:
            k = min(self.depth, 4)
            out.append(f'add sp, #{4 * k}')
            self.depth -= k
        out.append('bkpt #0')
        for s in self.subs:
            out += s
        out.append('.ltorg')
        out.append('.align 2')
        out.append('fpool:')
        out += [f'.word {v:#x}' for v in pool]
        return '\n'.join('    ' + l if not l.endswith(':') else l for l in out)


@cocotb.test()
async def random_streams(dut):
    seed = int(os.environ.get('SEED', '1'))
    nprog = int(os.environ.get('RANDOM_PROGRAMS', '40'))
    length = int(os.environ.get('RANDOM_LEN', '300'))
    bench = Bench(dut)
    fails = 0
    total = 0
    for p in range(nprog):
        rng = random.Random(seed * 1000 + p)
        src = Gen(rng).program(length)
        try:
            img, syms, lst = build_asm(src)
        except RuntimeError as e:
            dut._log.error(f'program {p}: {str(e)[:600]}')
            fails += 1
            continue
        stall = rng.choice([0, 0, 60, 140])
        errs, n, cyc = await run_lockstep(dut, bench, img, lst, mem_range=(0x27000, 0x29800), stall=stall, seed=p + 1)
        total += n
        if errs:
            fails += 1
            for e in errs[:3]:
                dut._log.error(f'program {p} (stall {stall}): {e}')
            if os.environ.get('SAVE_FAIL'):
                open(f'fail_{seed}_{p}.s', 'w').write(src)
        else:
            dut._log.info(f'program {p:3d} ok: {n} instructions, {cyc} clocks, stall {stall}')
    dut._log.info(f'{nprog - fails}/{nprog} programs ok, {total} instructions checked')
    assert fails == 0
