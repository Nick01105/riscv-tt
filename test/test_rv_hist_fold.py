"""rv_hist_fold: XOR folding against the definition fold[i mod W] ^= h[i]."""
import cocotb
import pytest
from cocotb.triggers import Timer

from sim import params, rng, rtl, run, u


def fold(h, L, W):
    f = 0
    for i in range(L):
        f ^= ((h >> i) & 1) << (i % W)
    return f


@cocotb.test()
async def fold_values(dut):
    p = params()
    L, W = p["LEN"], p["W"]
    r = rng()
    values = range(1 << L) if L <= 12 else [r.getrandbits(L) for _ in range(3000)]
    for h in values:
        dut.hist_i.value = h
        await Timer(1, "ns")
        assert u(dut.fold_o) == fold(h, L, W), hex(h)


@pytest.mark.parametrize("LEN,W", [(12, 4), (12, 5), (7, 3), (130, 10), (130, 9), (44, 8)])
def test_rv_hist_fold(LEN, W):
    run("rv_hist_fold", rtl("rv_hist_fold"), "test_rv_hist_fold", {"LEN": LEN, "W": W})
