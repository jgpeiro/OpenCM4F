#!/usr/bin/env python3
"""Runs the OpenCM4F cocotb testbenches.

usage: run.py [--sim icarus|verilator] [--waves] test [test ...]
tests: fpu mul div isa random programs all   (debug, debug2, debug3: development aids)
Environment: SEED, FPU_VECTORS, RANDOM_PROGRAMS, ... (see each test_*.py)
SPDX-License-Identifier: MIT"""
import argparse
import os
import sys

from cocotb_tools.runner import get_runner, get_results

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CORE = os.path.join(ROOT, 'rtl', 'core')
TB = os.path.join(ROOT, 'tb')

CORE_SRC = [os.path.join(CORE, f) for f in (
    'opencm4f.v', 'ocm4_core.v', 'ocm4_fetch.v', 'ocm4_decode.v', 'ocm4_regfile.v', 'ocm4_alu.v',
    'ocm4_bitops.v', 'ocm4_mul.v', 'ocm4_div.v', 'ocm4_lsu.v', 'ocm4_scs.v', 'ocm4_fpu.v')]

# name -> (toplevel, sources, test module)
CORE_TB = CORE_SRC + [os.path.join(TB, 'tb_core.v'), os.path.join(TB, 'axil_mem.v')]
BENCHES = {
    'fpu':      ('ocm4_fpu', [os.path.join(CORE, 'ocm4_fpu.v')], 'test_fpu'),
    'mul':      ('ocm4_mul', [os.path.join(CORE, 'ocm4_mul.v')], 'test_units'),
    'div':      ('ocm4_div', [os.path.join(CORE, 'ocm4_div.v')], 'test_units'),
    'isa':      ('tb_core', CORE_TB, 'test_isa'),
    'random':   ('tb_core', CORE_TB, 'test_random'),
    'programs': ('tb_core', CORE_TB, 'test_programs'),
}
# development aids (not in "all"): replay one failing random program / dump a trace
DEBUG = {
    'debug':  ('tb_core', CORE_TB, 'test_debug'),
    'debug2': ('tb_core', CORE_TB, 'test_debug2'),
    'debug3': ('tb_core', CORE_TB, 'test_debug3'),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sim', default=os.environ.get('SIM', 'verilator'))
    ap.add_argument('--waves', action='store_true', help='dump waves (FST for Verilator, FST for Icarus)')
    ap.add_argument('tests', nargs='+')
    args = ap.parse_args()
    names = list(BENCHES) if args.tests == ['all'] else args.tests
    ok = True
    for name in names:
        top, srcs, module = BENCHES[name] if name in BENCHES else DEBUG[name]
        build = os.path.join(ROOT, 'build', f'cocotb_{name}_{args.sim}')
        runner = get_runner(args.sim)
        build_args = []
        if args.sim == 'verilator':
            build_args = ['-Wno-fatal', '-Wno-WIDTH', '-Wno-lint', '-Wno-style', '--x-assign', '0', '--x-initial', '0',
                          '-O3']
            if args.waves:
                build_args += ['--trace-fst', '--trace-structs']
        runner.build(sources=srcs, hdl_toplevel=top, build_dir=build, includes=[CORE, TB],
                     build_args=build_args, timescale=('1ns', '1ps'), waves=args.waves, always=False)
        res = runner.test(hdl_toplevel=top, test_module=module, build_dir=build, test_dir=HERE,
                          waves=args.waves, extra_env={'PYTHONPATH': HERE})
        dump = os.path.join(HERE, 'dump.fst')
        if args.waves and os.path.exists(dump):          # next to the build, where tb/gtkw/*.gtkw look
            os.replace(dump, os.path.join(build, 'dump.fst'))
            print(f'{name}: waves in {os.path.join(build, "dump.fst")}')
        tests, failed = get_results(res)
        print(f'{name}: {tests - failed} / {tests} passed ({res})')
        ok = ok and failed == 0 and tests > 0
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
