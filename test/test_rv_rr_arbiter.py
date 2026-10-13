"""rv_rr_arbiter: grant order against a round-robin model, and no requester
waits more than N accepted grants."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u


@cocotb.test()
async def round_robin(dut):
    N = params()["N"]
    r = rng()
    Clock(dut.clk, 10, "ns").start()
    dut.rst_n.value, dut.req_i.value, dut.accept_i.value = 0, 0, 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    last = -1
    waited = [0] * N
    for cyc in range(5000):
        await FallingEdge(dut.clk)
        req = r.getrandbits(N) if r.random() < 0.8 else (1 << N) - 1
        acc = int(r.random() < 0.7)
        dut.req_i.value, dut.accept_i.value = req, acc
        await Timer(1, "ns")
        order = [(last + 1 + k) % N for k in range(N)]
        winner = next((i for i in order if (req >> i) & 1), None)
        assert u(dut.any_o) == int(req != 0)
        if winner is None:
            assert u(dut.grant_o) == 0
            continue
        assert u(dut.grant_o) == 1 << winner, f"cycle {cyc} req={req:b} last={last}"
        assert u(dut.grant_idx_o) == winner
        if acc:
            last = winner
            for i in range(N):
                if (req >> i) & 1 and i != winner:
                    waited[i] += 1
                    assert waited[i] < N, "starvation"
            waited[winner] = 0
        for i in range(N):
            if not (req >> i) & 1:
                waited[i] = 0


@pytest.mark.parametrize("N", [1, 2, 3, 4, 8])
def test_rv_rr_arbiter(N):
    run("rv_rr_arbiter", rtl("rv_rr_arbiter"), "test_rv_rr_arbiter", {"N": N})
