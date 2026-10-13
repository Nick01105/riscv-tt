"""rv_imm_gen: immediates of GNU-as-assembled instructions, every format."""
import json

import cocotb
import pytest
from cocotb.triggers import Timer

from sim import TEST, params, rng, rtl, run, u


@cocotb.test()
async def gas_vectors(dut):
    xlen = params()["XLEN"]
    mask = (1 << xlen) - 1
    vecs = json.loads((TEST / "vectors" / f"imm_rv{xlen}.json").read_text())
    for word, imm, fmt in vecs:
        dut.instr_i.value = word
        await Timer(1, "ns")
        assert u(dut.fmt_o) == fmt, f"{word:#010x} format"
        assert u(dut.imm_o) == imm & mask, f"{word:#010x}: got {u(dut.imm_o):#x} want {imm & mask:#x}"


@cocotb.test()
async def unknown_opcodes(dut):
    known = {0x03, 0x0F, 0x13, 0x17, 0x1B, 0x23, 0x37, 0x63, 0x67, 0x6F, 0x73}
    r = rng()
    for op in range(128):
        if op in known:
            continue
        dut.instr_i.value = (r.getrandbits(25) << 7) | op
        await Timer(1, "ns")
        assert (u(dut.fmt_o), u(dut.imm_o)) == (0, 0)


@pytest.mark.parametrize("XLEN", [32, 64])
def test_rv_imm_gen(XLEN):
    run("rv_imm_gen", rtl("rv_imm_gen"), "test_rv_imm_gen", {"XLEN": XLEN})
