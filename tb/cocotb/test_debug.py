"""Debug helper: runs one directed test printing the core state per clock."""
import os
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly
from harness import Bench, build_asm
from test_isa import T

@cocotb.test()
async def debug(dut):
    b = Bench(dut)
    name = os.environ.get('ISA_ONLY', 'alu16')
    img, syms, lst = build_asm(T[name])
    await b.start(stall=int(os.environ.get('STALL', '0')))
    b.load(img, words=0x800)
    await b.release()
    c = dut.u_cpu.u_core
    for cyc in range(int(os.environ.get('CYC', '60'))):
        await RisingEdge(dut.clk)
        await ReadOnly()
        def g(x):
            try: return int(x.value)
            except Exception: return -1
        dut._log.info(f"{cyc:3d} xs={g(c.xs)} st={g(c.step)} xv={g(c.x_valid)} op={g(c.x_op):2d} xpc={g(c.x_pc):05x} "
                      f"lreq={g(c.lsu_req)} la={g(c.lsu_addr):08x} ack={g(c.lsu_ack)} rv={g(c.lsu_rvalid)} rd={g(c.lsu_rdata):08x} "
                      f"redir={g(c.redir)} qpc={g(c.q_pc):05x} dv={g(c.dv)} dgo={g(c.d_go)} flt={g(c.x_fault)} fn={g(c.x_fault_num)} "
                      f"done={g(c.x_done)} rfwe={g(c.rf_we)} wa={g(c.rf_wa)} wd={g(c.rf_wd):08x} tv={g(c.trc_valid)} dit={g(c.d_it):02x} xc={g(c.x_cond):x} cp={g(c.cond_pass)} f={g(c.fN)}{g(c.fZ)}{g(c.fC)}{g(c.fV)}")
        if g(c.lockup) or g(c.halted): break
