"""rv_decoder.

1. Field vectors: every supported mnemonic with random operands, encoded by
   GNU as. Expected fields come from the instruction's definition.
2. Legality: 20,000 random words per XLEN; GNU objdump (with the exact ISA
   string) decides what is a legal instruction. Two documented differences:
   * privileged instructions this core does not implement (sret, sfence.vma,
     ...) are legal to objdump but illegal here (M-mode only core);
   * FENCE / FENCE.I with nonzero reserved fields are legal here, because the
     spec says implementations must ignore those fields;
   * RV32 shift-immediates with shamt[5] = 1 are reserved by the spec, but
     objdump 2.42 still disassembles them as slli/srli/srai.
The TT build is RV32E: any instruction that names x16-x31 must be illegal.
"""
import json
import re

import cocotb
import pytest
from cocotb.triggers import Timer

from sim import PKG, TEST, params, rtl, run, u

ENUM = {m.group(1): int(m.group(2)) for m in re.finditer(r"\b([A-Z][A-Z0-9_]+)\s*=\s*\d+'d(\d+)", PKG.read_text())}
NOT_IMPLEMENTED = ("sret", "uret", "dret", "mnret", "sfence.", "hfence.", "hinval.", "sinval.", "wrs.")
FIELDS = ("illegal", "fu", "op", "f3", "rd", "rd_we", "rs1", "rs1_en", "rs2", "rs2_en", "imm",
          "use_imm", "use_pc", "word_op", "br_type", "sys")


def xlen():
    return 64 if params().get("RV_CFG_FULL") else 32


def rve():
    return not params().get("RV_CFG_FULL")


def has_m():
    return bool(params().get("RV_CFG_FULL"))          # TT build: no M extension (frontend_pkg::HAS_M = 0)


def is_m(word):
    return (word & 0x7F) in (0x33, 0x3B) and (word >> 25) == 1


def uses_high_reg(exp):
    return ((exp.get("rd_we") and exp["rd"] >= 16) or (exp.get("rs1_en") and exp["rs1"] >= 16)
            or (exp.get("rs2_en") and exp["rs2"] >= 16))


ILLEGAL_FIELDS = dict(illegal=1, fu="FU_NONE", rd_we=0, rs1_en=0, rs2_en=0, br_type="BR_NONE", sys="SYS_NONE")
HIGH_REG = re.compile(r"\bx(1[6-9]|2[0-9]|3[01])\b")


async def decode(dut, word):
    dut.raw32.value = word
    await Timer(1, "ns")


@cocotb.test()
async def field_vectors(dut):
    X = xlen()
    vecs = json.loads((TEST / "vectors" / f"dec_rv{X}.json").read_text())
    if rve():
        vecs += json.loads((TEST / "vectors" / "dec_rv32e.json").read_text())
    e_illegal = 0
    for word, exp, asm in vecs:
        await decode(dut, word)
        if rve() and uses_high_reg(exp):
            exp = ILLEGAL_FIELDS
            e_illegal += 1
        elif not has_m() and is_m(word):
            exp = ILLEGAL_FIELDS
        for k, v in exp.items():
            want = ENUM[v] if isinstance(v, str) else v
            if k == "imm":
                want &= (1 << X) - 1
            got = u(getattr(dut, k))
            assert got == want, f"{asm} ({word:#010x}): {k} = {got:#x}, want {want:#x}"
    dut._log.info("RV%d%s: %d field vectors pass (%d illegal because they name x16-x31)",
                  X, "E" if rve() else "", len(vecs), e_illegal)


@cocotb.test()
async def legality_vs_objdump(dut):
    X = xlen()
    vecs = json.loads((TEST / "vectors" / f"legal_rv{X}.json").read_text())
    agree = priv = fence = shamt5 = high = 0
    for word, mnem, ops in vecs:
        await decode(dut, word)
        ours_legal = not u(dut.illegal)
        if mnem and not has_m() and is_m(word):
            assert not ours_legal, f"{word:#010x} ({mnem}): M is not implemented in this build"
            priv += 1
        elif mnem and rve() and HIGH_REG.search(ops):
            assert not ours_legal, f"{word:#010x} ({mnem} {ops}) names x16-x31 on RV32E"
            high += 1
        elif mnem and mnem.startswith(NOT_IMPLEMENTED):
            assert not ours_legal, f"{word:#010x} ({mnem}) should be illegal on an M-mode-only core"
            priv += 1
        elif X == 32 and (word & 0x7F) == 0x13 and ((word >> 12) & 3) == 1 and (word >> 25) & 1:
            assert not ours_legal, f"{word:#010x}: RV32 shamt[5]=1 is reserved"
            shamt5 += mnem is not None
            agree += mnem is None
        elif (word & 0x7F) == 0x0F and ((word >> 12) & 7) in (0, 1):
            assert ours_legal, f"{word:#010x}: FENCE/FENCE.I must ignore reserved fields"
            fence += mnem is None
            agree += mnem is not None
        else:
            assert ours_legal == (mnem is not None), \
                f"{word:#010x}: ours legal={ours_legal}, objdump says {mnem or '.insn'}"
            agree += 1
        if not ours_legal:
            assert u(dut.rd_we) == 0 and u(dut.rs1_en) == 0 and u(dut.rs2_en) == 0 and u(dut.fu) == 0
    dut._log.info("RV%d: %d agree with objdump, %d unimplemented privileged, %d fences with reserved "
                  "fields, %d RV32 shamt[5] shifts, %d RV32E high registers", X, agree, priv, fence, shamt5, high)


@pytest.mark.parametrize("cfg", ["TT", "FULL"])
def test_rv_decoder(cfg):
    defines = {"RV_CFG_FULL": 1} if cfg == "FULL" else {}
    run("tb_decoder", rtl("rv_decoder", "rv_imm_gen"), "test_rv_decoder", defines=defines,
        extra_sources=[TEST / "tb" / "tb_decoder.sv"])
