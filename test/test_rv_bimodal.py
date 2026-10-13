"""rv_bimodal: init walk (reads weak-not-taken, writes dropped), then random
reads and writes against a model; read-first on collisions."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u


@cocotb.test()
async def init_then_random(dut):
    E, C = params()["ENTRIES"], params()["CTR_W"]
    WN = (1 << (C - 1)) - 1
    r = rng()
    Clock(dut.clk, 10, "ns").start()
    for s in ("rd_valid_i", "rd_idx_i", "wr_valid_i", "wr_idx_i", "wr_ctr_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    table = [WN] * E
    pending = None
    done_seen = False
    for cyc in range(E + 4000):
        await FallingEdge(dut.clk)
        if pending is not None:
            assert u(dut.rd_ctr_o) == pending, f"cycle {cyc}"
        await Timer(1, "ns")
        done = u(dut.init_done_o)
        done_seen |= bool(done)
        rd, ri = r.random() < 0.7, r.randrange(E)
        wr, wi, wv = r.random() < 0.5, (ri if r.random() < 0.3 else r.randrange(E)), r.getrandbits(C)
        dut.rd_valid_i.value, dut.rd_idx_i.value = int(rd), ri
        dut.wr_valid_i.value, dut.wr_idx_i.value, dut.wr_ctr_i.value = int(wr), wi, wv
        pending = (table[ri] if done else WN) if rd else pending
        if wr and done:
            table[wi] = wv
    assert done_seen


@pytest.mark.parametrize("ENTRIES,CTR_W,LATCH", [(64, 2, 0), (64, 2, 1), (16, 3, 0), (2048, 2, 0)])
def test_rv_bimodal(ENTRIES, CTR_W, LATCH):
    run("rv_bimodal", rtl("rv_bimodal", "rv_sram_1r1w", "rv_clock_gate"), "test_rv_bimodal",
        {"ENTRIES": ENTRIES, "CTR_W": CTR_W, "LATCH": LATCH})
