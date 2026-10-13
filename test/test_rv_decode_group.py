"""rv_decode_group: intra-group dependencies (youngest older producer per
source) on random groups of real instructions; the flat-uop field offsets the
module uses are checked against the uop_t struct."""
import json

import cocotb
import pytest
from cocotb.triggers import Timer

from sim import TEST, params, rng, rtl, run, u


@cocotb.test()
async def random_groups(dut):
    W = params()["W"]
    full = bool(params().get("RV_CFG_FULL"))
    r = rng()
    vecs = json.loads((TEST / "vectors" / ("dec_rv64.json" if full else "dec_rv32e.json")).read_text())
    words = [w for w, f, _ in vecs if not f.get("illegal")]
    deps = 0
    for _ in range(4000):
        grp = [r.choice(words) for _ in range(W)]
        # force some register collisions
        for k in range(1, W):
            if r.random() < 0.5:
                src = r.randrange(k)
                rdv = (grp[src] >> 7) & 31
                grp[k] = (grp[k] & ~(31 << 15)) | (rdv << 15) if r.random() < 0.5 else (grp[k] & ~(31 << 20)) | (rdv << 20)
        valid = r.getrandbits(W) | 1
        dut.raw.value = sum(w << (32 * k) for k, w in enumerate(grp))
        dut.valid.value = valid
        await Timer(1, "ns")
        f = lambda sig, k, b=1: (u(sig) >> (k * b)) & ((1 << b) - 1)
        IW = max(1, (W - 1).bit_length())
        for j in range(W):
            e1 = e2 = None
            for i in range(j):
                if not (valid >> i) & 1 or not f(dut.rd_we, i):
                    continue
                if f(dut.rs1_en, j) and f(dut.rd, i, 5) == f(dut.rs1, j, 5):
                    e1 = i
                if f(dut.rs2_en, j) and f(dut.rd, i, 5) == f(dut.rs2, j, 5):
                    e2 = i
            assert f(dut.dep1_v, j) == (e1 is not None), f"slot {j} rs1 dep"
            assert f(dut.dep2_v, j) == (e2 is not None), f"slot {j} rs2 dep"
            if e1 is not None:
                assert f(dut.dep1_i, j, IW) == e1
                deps += 1
            if e2 is not None:
                assert f(dut.dep2_i, j, IW) == e2
    if W > 1:
        assert deps > 500


@pytest.mark.parametrize("cfg,W", [("TT", 1), ("FULL", 4)])
def test_rv_decode_group(cfg, W):
    defines = {"RV_CFG_FULL": 1} if cfg == "FULL" else {}
    run("tb_decode_group", rtl("rv_decode_group", "rv_decoder", "rv_imm_gen"), "test_rv_decode_group",
        {"W": W}, defines=defines, extra_sources=[TEST / "tb" / "tb_decode_group.sv"])
