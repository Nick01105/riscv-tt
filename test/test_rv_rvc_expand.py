"""rv_rvc_expand.

1. GNU-as vectors: every Zca instruction class, random operands; the expected
   32-bit encoding comes from the assembler, not from this code.
2. Reserved encodings and HINTs listed by hand from the C-extension spec.
3. Full sweep of all 65,536 parcels: illegal output format and that every
   legal expansion is a 32-bit instruction. Prints the legal/illegal count.
4. 32-bit instructions pass through untouched.
"""
import json

import cocotb
import pytest
from cocotb.triggers import Timer

from sim import TEST, params, rng, rtl, run, u


async def expand(dut, word):
    dut.instr_i.value = word
    await Timer(1, "ns")
    return u(dut.instr_o), u(dut.is_rvc_o), u(dut.illegal_o)


@cocotb.test()
async def gas_vectors(dut):
    xlen = params()["XLEN"]
    vecs = json.loads((TEST / "vectors" / f"rvc_rv{xlen}.json").read_text())
    seen = set()
    for c16, e32, cls in vecs:
        out, rvc, ill = await expand(dut, c16)
        assert (rvc, ill) == (1, 0), f"{cls} {c16:#06x} flagged illegal"
        assert out == e32, f"{cls} {c16:#06x}: got {out:#010x}, gas says {e32:#010x}"
        seen.add(cls)
    dut._log.info("RV%d: %d gas vectors over %d classes pass", xlen, len(vecs), len(seen))


# (parcel, legal on RV32, legal on RV64, expected expansion if legal or None)
def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


SPECIAL = [
    (0x0000, False, False, None, "all-zero parcel"),
    (0x0004, False, False, None, "c.addi4spn with zero immediate"),
    (0x2000, False, False, None, "c.fld (no D)"),
    (0x8000, False, False, None, "quadrant 0 funct3=100 reserved (Zcb not supported)"),
    (0xA000, False, False, None, "c.fsd (no D)"),
    (0x6000, False, True, i_type(0, 8, 3, 8, 0x03), "c.flw on RV32 / c.ld x8,0(x8) on RV64"),
    (0xE000, False, True, (8 << 20) | (8 << 15) | (3 << 12) | 0x23, "c.fsw on RV32 / c.sd on RV64"),
    (0x2001, True, False, 0x0000_00EF, "c.jal +0 on RV32 / c.addiw x0 reserved on RV64"),
    (0x6101, False, False, None, "c.addi16sp with zero immediate"),
    (0x6281, False, False, None, "c.lui with zero immediate"),
    (0x6005, True, True, (1 << 12) | 0x37, "c.lui x0 HINT"),
    (0x9005, False, True, i_type(33, 8, 5, 8, 0x13), "c.srli shamt[5]=1"),
    (0x8001, True, True, i_type(0, 8, 5, 8, 0x13), "c.srli shamt=0 HINT"),
    (0x9C05, False, True, r_type(0x20, 9, 8, 0, 8, 0x3B), "c.subw"),
    (0x9C41, False, False, None, "reserved CA encoding"),
    (0x9C61, False, False, None, "reserved CA encoding"),
    (0x0006, True, True, i_type(1, 0, 1, 0, 0x13), "c.slli x0 HINT"),
    (0x1282, False, True, i_type(32, 5, 1, 5, 0x13), "c.slli shamt[5]=1"),
    (0x2002, False, False, None, "c.fldsp (no D)"),
    (0x4002, False, False, None, "c.lwsp rd=x0 reserved"),
    (0x6002, False, False, None, "c.flwsp on RV32 / c.ldsp rd=x0 reserved on RV64"),
    (0x8002, False, False, None, "c.jr x0 reserved"),
    (0x8016, True, True, r_type(0, 5, 0, 0, 0, 0x33), "c.mv x0 HINT"),
    (0x9002, True, True, 0x0010_0073, "c.ebreak"),
    (0x9016, True, True, r_type(0, 5, 0, 0, 0, 0x33), "c.add x0 HINT"),
    (0xA002, False, False, None, "c.fsdsp (no D)"),
    (0xE002, False, True, (0 << 20) | (2 << 15) | (3 << 12) | 0x23, "c.fswsp on RV32 / c.sdsp x0,0(sp) on RV64"),
    (0x4005, True, True, i_type(1, 0, 0, 0, 0x13), "c.li x0 HINT"),
    (0x0281, True, True, i_type(0, 5, 0, 5, 0x13), "c.addi imm=0 HINT"),
]


@cocotb.test()
async def reserved_and_hints(dut):
    rv64 = params()["XLEN"] == 64
    for c16, ok32, ok64, exp, what in SPECIAL:
        legal = ok64 if rv64 else ok32
        out, rvc, ill = await expand(dut, c16)
        assert rvc == 1
        assert ill == int(not legal), f"{what} ({c16:#06x}): illegal={ill}"
        if legal:
            assert out == exp, f"{what}: got {out:#010x} want {exp:#010x}"
        else:
            assert out == c16, f"{what}: illegal output should be the raw parcel"


@cocotb.test()
async def full_sweep(dut):
    legal = 0
    for c16 in range(1 << 16):
        if c16 & 3 == 3:
            continue
        out, rvc, ill = await expand(dut, (0xA5A5 << 16) | c16)   # upper half must be ignored
        assert rvc == 1
        if ill:
            assert out == c16
        else:
            legal += 1
            assert out & 3 == 3, f"{c16:#06x} expanded to a non-32-bit word"
    dut._log.info("RV%d: %d legal / %d illegal compressed encodings", params()["XLEN"], legal, 49152 - legal)


@cocotb.test()
async def passthrough(dut):
    r = rng()
    for _ in range(3000):
        w = r.getrandbits(32) | 3
        out, rvc, ill = await expand(dut, w)
        assert (out, rvc, ill) == (w, 0, 0)


@pytest.mark.parametrize("XLEN", [32, 64])
def test_rv_rvc_expand(XLEN):
    run("rv_rvc_expand", rtl("rv_rvc_expand"), "test_rv_rvc_expand", {"XLEN": XLEN})
