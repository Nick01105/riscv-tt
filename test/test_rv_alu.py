"""rv_alu: every op against a Python model, random and edge operands,
RV32 and RV64 (including the *W forms)."""
import cocotb
import pytest
from cocotb.triggers import Timer

from sim import params, rng, rtl, run, u

ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND, PASSB = range(11)


def sext(v, b):
    v &= (1 << b) - 1
    return v - (1 << b) if v >> (b - 1) else v


def model(op, word, a, b, X):
    M = (1 << X) - 1
    if word:
        a32, sh = a & 0xFFFFFFFF, b & 31
        r = {ADD: a32 + b, SUB: a32 - b, SLL: a32 << sh, SRL: a32 >> sh, SRA: sext(a32, 32) >> sh}[op]
        return sext(r, 32) & M
    sh = b & (X - 1)
    return {ADD: a + b, SUB: a - b, SLL: a << sh, SLT: int(sext(a, X) < sext(b, X)), SLTU: int(a < b),
            XOR: a ^ b, SRL: a >> sh, SRA: sext(a, X) >> sh, OR: a | b, AND: a & b, PASSB: b}[op] & M


@cocotb.test()
async def ops(dut):
    X = params()["XLEN"]
    r = rng()
    M = (1 << X) - 1
    edge = [0, 1, 2, M, M >> 1, 1 << (X - 1), 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 31, 32, 63]
    ops_ = list(range(11))
    for i in range(6000):
        op = r.choice(ops_)
        word = int(X == 64 and op in (ADD, SUB, SLL, SRL, SRA) and r.random() < 0.4)
        a = r.choice(edge) & M if r.random() < 0.3 else r.getrandbits(X)
        b = r.choice(edge) & M if r.random() < 0.3 else r.getrandbits(X)
        if op in (SLL, SRL, SRA) and r.random() < 0.5:
            b = r.randrange(X)
        dut.op_i.value, dut.word_i.value, dut.a_i.value, dut.b_i.value = op, word, a, b
        await Timer(1, "ns")
        assert u(dut.y_o) == model(op, word, a, b, X), f"op {op} w{word} a={a:#x} b={b:#x}"


@pytest.mark.parametrize("XLEN", [32, 64])
def test_rv_alu(XLEN):
    run("rv_alu", rtl("rv_alu"), "test_rv_alu", {"XLEN": XLEN})
