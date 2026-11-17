"""Replays a saved random program (FAIL_FILE) printing the data-bus transactions and retirements."""
import os
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly
from harness import Bench, build_asm, Lockstep

@cocotb.test()
async def debug(dut):
    b = Bench(dut)
    import random
    from test_random import Gen
    from harness import run_lockstep
    pre = os.environ.get('PRE')          # "seed:prog" of a program to run first
    if pre:
        sd, pg = map(int, pre.split(':'))
        rng = random.Random(sd * 1000 + pg)
        src0 = Gen(rng).program(300)
        img0, _, lst0 = build_asm(src0)
        st0 = rng.choice([0, 0, 60, 140])
        errs, n, cyc = await run_lockstep(dut, b, img0, lst0, stall=st0, seed=pg + 1)
        dut._log.info(f'pre-program: {errs[:2]} {n} {cyc} stall {st0}')
    src = open(os.environ['FAIL_FILE']).read()
    img, syms, lst = build_asm(src)
    await b.start(stall=int(os.environ.get('STALL', '0')))
    b.load(img, words=max(len(img) // 4 + 1, 0x800))
    ls = Lockstep(b, img, lst)
    await b.release()
    c = dut.u_cpu.u_core
    log = []
    g = lambda x: int(x.value)
    for cyc in range(20000):
        await RisingEdge(dut.clk)
        await ReadOnly()
        ls.cycle(cyc)
        line = []
        if g(dut.u_cpu.trc_valid):
            line.append(f'RET {ls.insn_text(g(dut.u_cpu.trc_pc))[:60]}')
        if g(dut.d_awvalid) and g(dut.d_awready):
            line.append(f'W [{g(dut.d_awaddr):05x}]={g(dut.d_wdata):08x}/{g(dut.d_wstrb):x}')
        if g(dut.d_arvalid) and g(dut.d_arready):
            line.append(f'AR [{g(dut.d_araddr):05x}]')
        if g(dut.d_rvalid):
            line.append(f'R {g(dut.d_rdata):08x}')
        if g(c.rf_we):
            line.append(f'rf[{g(c.rf_wa)}]={g(c.rf_wd):08x}')
        if line:
            log.append(f'{cyc:5d} ' + '  '.join(line))
        if ls.errors or g(c.halted):
            break
    for l in log[-int(os.environ.get('TAIL', '40')):]:
        dut._log.info(l)
    for e in ls.errors:
        dut._log.error(e)
