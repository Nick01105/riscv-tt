"""rv_muldiv: all eight M operations (and the RV64 *W forms) against the
ISS's model, with division by zero, signed overflow and edge operands;
random start/ack timing and kills in the middle of an operation."""
import sys

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

from sim import ROOT, params, rng, rtl, run, u

sys.path.insert(0, str(ROOT / "model"))
import rv_iss  # noqa: E402


def model(f3, word, a, b, X):
    h = rv_iss.Hart(xlen=X)
    M = (1 << X) - 1
    if word:
        r = h._muldiv(f3, rv_iss.sext(a, 32) & 0xFFFFFFFF, rv_iss.sext(b, 32) & 0xFFFFFFFF, 32)
        return rv_iss.sext(r, 32) & M
    return h._muldiv(f3, a, b, X)


@cocotb.test()
async def ops(dut):
    X = params()["XLEN"]
    r = rng()
    M = (1 << X) - 1
    edge = [0, 1, 2, 3, M, M - 1, M >> 1, 1 << (X - 1), 0x80000000, 0xFFFFFFFF, 0x7FFFFFFF, 0xFFFFFFFF80000000 & M]
    Clock(dut.clk, 10, "ns").start()
    dut.rst_n.value = 0
    dut.kill_i.value = dut.start_i.value = dut.ack_i.value = 0
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    n = 0
    while n < 700:
        f3 = r.randrange(8)
        word = int(X == 64 and f3 in (0, 4, 5, 6, 7) and r.random() < 0.4)
        a = r.choice(edge) if r.random() < 0.35 else r.getrandbits(X)
        b = r.choice(edge) if r.random() < 0.35 else r.getrandbits(r.choice([X, 8, 3]))
        await FallingEdge(dut.clk)
        dut.start_i.value, dut.f3_i.value, dut.word_i.value, dut.a_i.value, dut.b_i.value = 1, f3, word, a, b
        await FallingEdge(dut.clk)
        dut.start_i.value = 0
        dut.a_i.value = r.getrandbits(X)              # operands are captured at start
        dut.b_i.value = r.getrandbits(X)
        kill_at = r.randrange(1, X) if r.random() < 0.1 else None
        cyc = 0
        while not u(dut.done_o):
            cyc += 1
            assert cyc <= X + 2, "too slow"
            if kill_at == cyc:
                dut.kill_i.value = 1
                await FallingEdge(dut.clk)
                dut.kill_i.value = 0
                assert not u(dut.busy_o) and not u(dut.done_o)
                break
            await FallingEdge(dut.clk)
        else:
            for _ in range(r.randrange(3)):                # result holds until ack
                await FallingEdge(dut.clk)
            exp = model(f3, word, a, b, X)
            assert u(dut.y_o) == exp, f"f3={f3} w{word} a={a:#x} b={b:#x}: {u(dut.y_o):#x} != {exp:#x}"
            dut.ack_i.value = 1
            await FallingEdge(dut.clk)
            dut.ack_i.value = 0
            n += 1


@pytest.mark.parametrize("XLEN", [32, 64])
def test_rv_muldiv(XLEN):
    run("rv_muldiv", rtl("rv_muldiv"), "test_rv_muldiv", {"XLEN": XLEN})
