"""rv_tage_table: init walk, tag hits, counter and useful-bit writes,
bit-plane clears, read-first; against a model."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u


@cocotb.test()
async def random_traffic(dut):
    p = params()
    E, T, C, U = p["ENTRIES"], p["TAG_W"], p["CTR_W"], p["U_W"]
    WN = (1 << (C - 1)) - 1
    r = rng()
    Clock(dut.clk, 10, "ns").start()
    for s in ("rd_valid_i", "rd_idx_i", "rd_tag_i", "wr_valid_i", "wr_idx_i", "wr_tag_i", "wr_ctr_i",
              "u_wr_valid_i", "u_wr_idx_i", "u_wr_i", "u_clear_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    tags, ctrs, us = [0] * E, [WN] * E, [0] * E
    pending = None
    hits = 0
    for cyc in range(E + 5000):
        await FallingEdge(dut.clk)
        if pending is not None:
            h, c, uu = pending
            assert u(dut.rd_hit_o) == h, f"cycle {cyc}: hit"
            assert u(dut.rd_ctr_o) == c, f"cycle {cyc}: ctr"
            assert u(dut.rd_u_o) == uu, f"cycle {cyc}: u"
            hits += h
        await Timer(1, "ns")
        done = u(dut.init_done_o)
        ri = r.randrange(E)
        rt = tags[ri] if r.random() < 0.6 else r.getrandbits(T)
        rd = r.random() < 0.7
        wr, wi = r.random() < 0.4, (ri if r.random() < 0.3 else r.randrange(E))
        wt, wc = r.getrandbits(T), r.getrandbits(C)
        uw, ui, uv = r.random() < 0.4, r.randrange(E), r.getrandbits(U)
        clr = r.getrandbits(U) if r.random() < 0.03 else 0
        for s, v in (("rd_valid_i", int(rd)), ("rd_idx_i", ri), ("rd_tag_i", rt), ("wr_valid_i", int(wr)),
                     ("wr_idx_i", wi), ("wr_tag_i", wt), ("wr_ctr_i", wc), ("u_wr_valid_i", int(uw)),
                     ("u_wr_idx_i", ui), ("u_wr_i", uv), ("u_clear_i", clr)):
            getattr(dut, s).value = v
        if rd:
            pending = (int(done and tags[ri] == rt), ctrs[ri] if done else WN, us[ri])
        if done and wr:
            tags[wi], ctrs[wi] = wt, wc
        for i in range(E):
            if uw and done and i == ui:
                us[i] = uv & ~clr
            else:
                us[i] &= ~clr
    assert hits > 500


@pytest.mark.parametrize("ENTRIES,TAG_W,LATCH", [(16, 6, 0), (16, 6, 1), (512, 10, 0)])
def test_rv_tage_table(ENTRIES, TAG_W, LATCH):
    run("rv_tage_table", rtl("rv_tage_table", "rv_sram_1r1w", "rv_clock_gate"), "test_rv_tage_table",
        {"ENTRIES": ENTRIES, "TAG_W": TAG_W, "CTR_W": 3, "U_W": 2, "LATCH": LATCH})
