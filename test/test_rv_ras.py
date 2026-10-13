"""rv_ras: random push/pop/push+pop/restore sequences against a circular model."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from sim import params, rng, rtl, run, u


@cocotb.test()
async def random_ops(dut):
    D, W = params()["DEPTH"], params()["W"]
    r = rng()
    Clock(dut.clk, 10, "ns").start()
    for s in ("push_i", "push_addr_i", "pop_i", "restore_i", "restore_ptr_i", "restore_top_i",
              "restore_push_i", "restore_pop_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    stack, ptr = [0] * D, 0
    checkpoints = []
    for cyc in range(5000):
        await FallingEdge(dut.clk)
        assert u(dut.ptr_o) == ptr, f"cycle {cyc}"
        assert u(dut.top_o) == stack[ptr], f"cycle {cyc}"
        checkpoints = (checkpoints + [(ptr, stack[ptr])])[-6:]
        push, pop = r.random() < 0.35, r.random() < 0.35
        restore = r.random() < 0.08
        addr = r.getrandbits(W)
        rp, rt = r.choice(checkpoints)
        dut.push_i.value, dut.pop_i.value, dut.push_addr_i.value = int(push), int(pop), addr
        rpush, rpop = r.random() < 0.3, r.random() < 0.3
        dut.restore_i.value, dut.restore_ptr_i.value, dut.restore_top_i.value = int(restore), rp, rt
        dut.restore_push_i.value, dut.restore_pop_i.value = int(rpush), int(rpop)
        if restore:
            ptr = rp
            stack[ptr] = rt
            if rpush:
                ptr = (ptr + 1) % D
                stack[ptr] = addr
            elif rpop:
                ptr = (ptr - 1) % D
        elif push and pop:
            stack[ptr] = addr
        elif push:
            ptr = (ptr + 1) % D
            stack[ptr] = addr
        elif pop:
            ptr = (ptr - 1) % D


@pytest.mark.parametrize("DEPTH,W", [(2, 31), (4, 31), (16, 63)])
def test_rv_ras(DEPTH, W):
    run("rv_ras", rtl("rv_ras"), "test_rv_ras", {"DEPTH": DEPTH, "W": W})
