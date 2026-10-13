"""rv_skid_buffer: order and integrity under random back-pressure, stable
output while stalled, and one transfer per cycle with no stalls."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u


async def reset(dut):
    Clock(dut.clk, 10, "ns").start()
    dut.rst_n.value = 0
    dut.flush_i.value = dut.in_valid_i.value = dut.out_ready_i.value = dut.in_data_i.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1


@cocotb.test()
async def random_backpressure(dut):
    W = params()["W"]
    r = rng()
    await reset(dut)
    sent, got = [], []
    pending = r.getrandbits(W)
    prev_stall = None                     # (data) seen while valid && !ready
    for cyc in range(8000):
        await FallingEdge(dut.clk)
        iv = int(r.random() < 0.7)
        orr = int(r.random() < 0.6)
        dut.in_valid_i.value, dut.in_data_i.value, dut.out_ready_i.value = iv, pending, orr
        await Timer(1, "ns")
        ov = u(dut.out_valid_o)
        od = u(dut.out_data_o) if ov else None
        if prev_stall is not None:
            assert ov == 1 and od == prev_stall, f"output changed while stalled at {cyc}"
        prev_stall = od if (ov and not orr) else None
        if ov and orr:
            got.append(od)
        if iv and u(dut.in_ready_o):
            sent.append(pending)
            pending = r.getrandbits(W)    # an item changes only after it was accepted
    assert got == sent[:len(got)], "data lost, duplicated or reordered"
    assert len(sent) - len(got) <= 2      # at most two items held inside
    assert len(got) > 3000


@cocotb.test()
async def full_throughput(dut):
    W = params()["W"]
    m = (1 << W) - 1
    await reset(dut)
    dut.out_ready_i.value = 1
    got = []
    for i in range(200):
        await FallingEdge(dut.clk)
        dut.in_valid_i.value, dut.in_data_i.value = 1, i & m
        await Timer(1, "ns")
        assert u(dut.in_ready_o) == 1
        if u(dut.out_valid_o):
            got.append(u(dut.out_data_o))
    assert got == [i & m for i in range(len(got))] and len(got) == 199   # latency of one cycle


@cocotb.test()
async def flush_empties(dut):
    await reset(dut)
    dut.out_ready_i.value = 0
    for i in range(3):
        await FallingEdge(dut.clk)
        dut.in_valid_i.value, dut.in_data_i.value = 1, i & 1
    await FallingEdge(dut.clk)
    dut.in_valid_i.value, dut.flush_i.value = 0, 1
    await FallingEdge(dut.clk)
    dut.flush_i.value = 0
    await Timer(1, "ns")
    assert u(dut.out_valid_o) == 0 and u(dut.in_ready_o) == 1


@pytest.mark.parametrize("W", [1, 8, 64])
def test_rv_skid_buffer(W):
    run("rv_skid_buffer", rtl("rv_skid_buffer"), "test_rv_skid_buffer", {"W": W})
