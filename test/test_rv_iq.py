"""rv_iq: sparse blocks in, in-order packed slots out, random back-pressure
and flushes, against a deque model."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u, ubits


@cocotb.test()
async def random_traffic(dut):
    p = params()
    NP, OW, D, SW = p["NP"], p["OUT_W"], p["DEPTH"], p["SW"]
    r = rng()
    Clock(dut.clk, 10, "ns").start()
    for s in ("flush_i", "in_valid_i", "in_mask_i", "in_slots_i", "out_ready_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    q, seq, moved = [], 0, 0
    for cyc in range(6000):
        await FallingEdge(dut.clk)
        iv = r.random() < 0.7
        mask = r.getrandbits(NP)
        slots = [r.getrandbits(SW - 16) << 16 | (seq + k) & 0xFFFF for k in range(NP)]
        rdy = (1 << r.randint(0, OW)) - 1            # prefix of ready slots
        fl = r.random() < 0.01
        dut.in_valid_i.value, dut.in_mask_i.value = int(iv), mask
        dut.in_slots_i.value = sum(v << (SW * k) for k, v in enumerate(slots))
        dut.out_ready_i.value, dut.flush_i.value = rdy, int(fl)
        await Timer(1, "ns")
        assert u(dut.count_o) == len(q)
        assert u(dut.in_ready_o) == int(len(q) + NP <= D)
        ov = u(dut.out_valid_o)
        for k in range(OW):
            assert (ov >> k) & 1 == int(k < len(q))
            if k < len(q):
                assert ubits(dut.out_slots_o, SW * k, SW) == q[k], f"cycle {cyc} slot {k}"
        taken = 0
        for k in range(OW):
            if (rdy >> k) & 1 and k < len(q) and taken == k:
                taken += 1
        if fl:
            q = []
        else:
            q = q[taken:]
            moved += taken
            if iv and len(q) + taken + NP <= D + taken and (len(q) + taken) + NP <= D:
                q += [slots[k] for k in range(NP) if (mask >> k) & 1]
        seq += NP
    assert moved > 2000


@pytest.mark.parametrize("NP,OUT_W,DEPTH", [(2, 1, 4), (2, 1, 8), (8, 4, 16), (4, 2, 8)])
def test_rv_iq(NP, OUT_W, DEPTH):
    run("rv_iq", rtl("rv_iq"), "test_rv_iq", {"NP": NP, "OUT_W": OUT_W, "DEPTH": DEPTH, "SW": 40})
