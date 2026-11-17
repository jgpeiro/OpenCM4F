import os
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly
from harness import Bench, build_asm
from test_isa import T

@cocotb.test()
async def debug(dut):
    b = Bench(dut)
    img, syms, lst = build_asm(T[os.environ.get('ISA_ONLY', 'alu16')])
    await b.start(stall=int(os.environ.get('STALL', '0')))
    b.load(img, words=0x800)
    await b.release()
    f = dut.u_cpu.u_core.u_fetch
    for cyc in range(int(os.environ.get('CYC', '40'))):
        await RisingEdge(dut.clk)
        await ReadOnly()
        g = lambda x: int(x.value)
        dut._log.info(f"{cyc:3d} redir={g(f.redir)} arv={g(f.arvalid)} arr={g(f.arready)} ara={g(f.araddr):05x} rv={g(f.rvalid)} pend={g(f.ar_pend)} infl={g(f.infl)} disc={g(f.disc)} q={g(f.qcnt)} fa={g(f.fa):05x} en={g(f.enable)} pc0={g(f.pc0):05x} skip={g(f.skip)}")
