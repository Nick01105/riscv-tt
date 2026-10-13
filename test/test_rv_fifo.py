"""rv_fifo: cycle-accurate model with random valid/ready/flush traffic."""
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
async def random_traffic(dut):
    p = params()
    W, DEPTH = p["W"], p["DEPTH"]
    r = rng()
    await reset(dut)
    q = []
    pushed = popped = 0
    for phase in range(6):
        p_in, p_out = [(0.9, 0.9), (0.9, 0.2), (0.2, 0.9), (0.5, 0.5), (1.0, 1.0), (1.0, 0.0)][phase]
        for _ in range(1500):
            await FallingEdge(dut.clk)
            iv, orr, fl = int(r.random() < p_in), int(r.random() < p_out), int(r.random() < 0.01)
            d = r.getrandbits(W)
            dut.in_valid_i.value, dut.in_data_i.value = iv, d
            dut.out_ready_i.value, dut.flush_i.value = orr, fl
            await Timer(1, "ns")
            assert u(dut.count_o) == len(q)
            assert u(dut.in_ready_o) == int(len(q) < DEPTH)
            assert u(dut.out_valid_o) == int(len(q) > 0)
            if q:
                assert u(dut.out_data_o) == q[0]
            push = iv and len(q) < DEPTH
            pop = orr and len(q) > 0
            if fl:
                q = []
            else:
                if pop:
                    q.pop(0)
                    popped += 1
                if push:
                    q.append(d)
                    pushed += 1
    assert pushed > 1000 and popped > 1000


@pytest.mark.parametrize("W,DEPTH", [(8, 1), (8, 2), (16, 4), (5, 5), (32, 8)])
def test_rv_fifo(W, DEPTH):
    run("rv_fifo", rtl("rv_fifo"), "test_rv_fifo", {"W": W, "DEPTH": DEPTH})
