"""rv_regfile: two read ports against a model; x0 reads zero; a read in the
same cycle as a write to that register returns the old value; read data
holds while re_i is low. Flop and latch rows must behave the same."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

from sim import params, rng, rtl, run, u


@cocotb.test()
async def random_access(dut):
    p = params()
    W, N = p["W"], p["NREGS"]
    r = rng()
    Clock(dut.clk, 10, "ns").start()
    dut.re_i.value = dut.we_i.value = 0
    regs = [0] * N
    for a in range(1, N):
        await FallingEdge(dut.clk)
        dut.we_i.value, dut.waddr_i.value, dut.wdata_i.value = 1, a, 0
    await FallingEdge(dut.clk)
    dut.we_i.value = 0
    exp = None
    for _ in range(4000):
        await FallingEdge(dut.clk)
        if exp is not None:
            assert (u(dut.rdata1_o), u(dut.rdata2_o)) == exp
        re, we = int(r.random() < 0.7), r.getrandbits(1)
        a1, a2 = r.randrange(N), r.randrange(N)
        wa = a1 if r.random() < 0.3 else r.randrange(1, N)
        wd = r.getrandbits(W)
        dut.re_i.value, dut.raddr1_i.value, dut.raddr2_i.value = re, a1, a2
        dut.we_i.value, dut.waddr_i.value, dut.wdata_i.value = we, wa, wd
        if re:
            exp = (regs[a1], regs[a2])
        if we and wa:
            regs[wa] = wd


@pytest.mark.parametrize("LATCH", [0, 1])
@pytest.mark.parametrize("W,NREGS", [(32, 16), (64, 32)])
def test_rv_regfile(W, NREGS, LATCH):
    run("rv_regfile", rtl("rv_regfile", "rv_clock_gate"), "test_rv_regfile", {"W": W, "NREGS": NREGS, "LATCH": LATCH})
