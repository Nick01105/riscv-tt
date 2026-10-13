"""rv_sram_1r1w: random reads and writes; read-first on collisions; rdata
holds when re_i is low. The flop and latch implementations must behave the same."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u


@cocotb.test()
async def random_access(dut):
    p = params()
    W, D = p["W"], p["DEPTH"]
    r = rng()
    Clock(dut.clk, 10, "ns").start()
    dut.re_i.value = dut.we_i.value = 0
    mem = {}
    # initialise every address so reads are defined
    for a in range(D):
        await FallingEdge(dut.clk)
        mem[a] = r.getrandbits(W)
        dut.we_i.value, dut.waddr_i.value, dut.wdata_i.value = 1, a, mem[a]
    await FallingEdge(dut.clk)
    dut.we_i.value = 0
    last = None
    for _ in range(4000):
        await FallingEdge(dut.clk)
        if last is not None:
            assert u(dut.rdata_o) == last
        re, we = r.getrandbits(1), r.getrandbits(1)
        ra = r.randrange(D)
        wa = ra if r.random() < 0.25 else r.randrange(D)    # frequent collisions
        wd = r.getrandbits(W)
        dut.re_i.value, dut.raddr_i.value = re, ra
        dut.we_i.value, dut.waddr_i.value, dut.wdata_i.value = we, wa, wd
        if re:
            last = mem[ra]                 # old value even when wa == ra
        if we:
            mem[wa] = wd


@pytest.mark.parametrize("LATCH", [0, 1])
@pytest.mark.parametrize("W,DEPTH", [(8, 16), (32, 5), (1, 2), (70, 64)])
def test_rv_sram_1r1w(W, DEPTH, LATCH):
    run("rv_sram_1r1w", rtl("rv_sram_1r1w", "rv_clock_gate"), "test_rv_sram_1r1w",
        {"W": W, "DEPTH": DEPTH, "LATCH": LATCH})
