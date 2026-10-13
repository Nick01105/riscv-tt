"""rv_tage_hash: index/tag hash against the formula in the module header."""
import cocotb
import pytest
from cocotb.triggers import Timer

from sim import params, rng, rtl, run, u
from test_rv_hist_fold import fold


@cocotb.test()
async def hash_values(dut):
    p = params()
    PC_W, H, I, T = p["PC_W"], p["HLEN"], p["IDX_W"], p["TAG_W"]
    r = rng()
    for _ in range(3000):
        pc, h = r.getrandbits(PC_W), r.getrandbits(H)
        dut.pc_i.value, dut.hist_i.value = pc, h
        await Timer(1, "ns")
        im = (1 << I) - 1
        tm = (1 << T) - 1
        idx = (pc & im) ^ ((pc >> I) & im) ^ fold(h, H, I)
        tag = (pc & tm) ^ fold(h, H, T) ^ ((fold(h, H, T - 1) << 1) & tm)
        assert u(dut.idx_o) == idx
        assert u(dut.tag_o) == tag


@pytest.mark.parametrize("PC_W,HLEN,IDX_W,TAG_W", [(31, 4, 4, 6), (31, 12, 4, 6), (63, 130, 9, 10), (63, 5, 9, 10)])
def test_rv_tage_hash(PC_W, HLEN, IDX_W, TAG_W):
    run("rv_tage_hash", rtl("rv_tage_hash", "rv_hist_fold"), "test_rv_tage_hash",
        {"PC_W": PC_W, "HLEN": HLEN, "IDX_W": IDX_W, "TAG_W": TAG_W})
