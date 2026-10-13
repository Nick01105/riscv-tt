"""rv_fold_step: a fold updated only incrementally must always equal the
from-scratch fold of the shifted history (checked over long random walks)."""
import cocotb
import pytest
from cocotb.triggers import Timer

from sim import params, rng, rtl, run, u
from test_rv_hist_fold import fold


@cocotb.test()
async def incremental_matches_definition(dut):
    p = params()
    L, W = p["LEN"], p["W"]
    mask = (1 << L) - 1
    r = rng()
    h = r.getrandbits(L)
    f = fold(h, L, W)
    for step in range(5000):
        b = r.getrandbits(1)
        dut.fold_i.value, dut.new_bit_i.value, dut.out_bit_i.value = f, b, (h >> (L - 1)) & 1
        await Timer(1, "ns")
        h = ((h << 1) | b) & mask
        f = u(dut.fold_o)                 # feed the DUT's own result back in
        assert f == fold(h, L, W), f"step {step}"


@pytest.mark.parametrize("LEN,W", [(12, 4), (12, 5), (15, 5), (130, 10), (130, 9), (44, 8), (5, 9)])
def test_rv_fold_step(LEN, W):
    run("rv_fold_step", rtl("rv_fold_step"), "test_rv_fold_step", {"LEN": LEN, "W": W})
