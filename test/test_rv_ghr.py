"""rv_ghr: random speculative pushes and checkpoint restores against a model."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u


@cocotb.test()
async def random_push_restore(dut):
    L = params()["LEN"]
    mask = (1 << L) - 1
    r = rng()
    Clock(dut.clk, 10, "ns").start()
    for s in ("spec_push_i", "spec_bit_i", "restore_i", "restore_val_i", "restore_push_i", "restore_bit_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    hist = 0
    checkpoints = [0]                  # values hist_o had before past pushes
    for cyc in range(4000):
        await FallingEdge(dut.clk)
        assert u(dut.hist_o) == hist, f"cycle {cyc}"
        assert u(dut.out_bit_o) == (hist >> (L - 1)) & 1
        push, bit = r.random() < 0.6, r.getrandbits(1)
        restore = r.random() < 0.1
        rval = r.choice(checkpoints[-8:])
        rpush, rbit = r.getrandbits(1), r.getrandbits(1)
        dut.spec_push_i.value, dut.spec_bit_i.value = int(push), bit
        dut.restore_i.value, dut.restore_val_i.value = int(restore), rval
        dut.restore_push_i.value, dut.restore_bit_i.value = rpush, rbit
        if push and not restore:
            checkpoints.append(hist)
        if restore:
            hist = ((rval << 1) | rbit) & mask if rpush else rval
        elif push:
            hist = ((hist << 1) | bit) & mask
    await FallingEdge(dut.clk)
    assert u(dut.hist_o) == hist


@pytest.mark.parametrize("LEN", [2, 12, 130])
def test_rv_ghr(LEN):
    run("rv_ghr", rtl("rv_ghr"), "test_rv_ghr", {"LEN": LEN})
