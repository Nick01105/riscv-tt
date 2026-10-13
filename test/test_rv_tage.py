"""rv_tage against the bit-exact model in model/tage_model.py, replaying real
branch traces (sw/ programs on the reference ISS). Every prediction and every
meta bit must match; the run also reports MPKI."""
import json
import sys

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import ROOT, TEST, params, rtl, run, u

sys.path.insert(0, str(ROOT / "model"))
from tage_model import Tage  # noqa: E402


@cocotb.test()
async def replay_traces(dut):
    p = params()
    hl = [(p["HLENS"] >> (8 * t)) & 0xFF for t in range(p["NT"])]
    Clock(dut.clk, 10, "ns").start()
    for s in ("pd_valid_i", "pd_pc_i", "pd_hist_i", "up_valid_i", "up_pc_i", "up_hist_i", "up_taken_i", "up_meta_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(max(p["BASE_ENTRIES"], p["ENTRIES"]) + 4):     # init walkers
        await RisingEdge(dut.clk)
    m = Tage(pc_w=p["PC_W"], ghr_len=p["GHR_LEN"], base_entries=p["BASE_ENTRIES"], nt=p["NT"],
             entries=p["ENTRIES"], tag_w=p["TAG_W"], hlens=hl, reset_log=p["RESET_LOG"])
    gmask = (1 << p["GHR_LEN"]) - 1
    pmask = (1 << p["PC_W"]) - 1
    report = []
    for prog in p["PROGS"].split(","):
        data = json.loads((TEST / "vectors" / f"bp_{prog}.json").read_text())
        ghr, miss = 0, 0
        for k, (pc, taken) in enumerate(data["trace"]):
            pc &= pmask
            await FallingEdge(dut.clk)
            dut.up_valid_i.value = 0
            dut.pd_valid_i.value, dut.pd_pc_i.value, dut.pd_hist_i.value = 1, pc, ghr
            await FallingEdge(dut.clk)
            dut.pd_valid_i.value = 0
            await Timer(1, "ns")
            exp_t, meta = m.predict(pc, ghr)
            got_t, got_meta = u(dut.pd_taken_o), u(dut.pd_meta_o)
            assert got_meta == m.pack(meta), f"{prog} branch {k}: meta {got_meta:#x} want {m.pack(meta):#x}"
            assert got_t == exp_t, f"{prog} branch {k}: prediction"
            miss += got_t != taken
            dut.up_valid_i.value, dut.up_pc_i.value, dut.up_hist_i.value = 1, pc, ghr
            dut.up_taken_i.value, dut.up_meta_i.value = taken, got_meta
            m.update(pc, ghr, taken, meta)
            ghr = ((ghr << 1) | taken) & gmask
        await FallingEdge(dut.clk)
        dut.up_valid_i.value = 0
        report.append(f"{prog}: {len(data['trace'])} branches, MPKI {miss / data['insns'] * 1000:.1f}")
    dut._log.info("bit-exact with model; %s", "; ".join(report))


CONFIGS = {
    "TT": dict(PC_W=23, GHR_LEN=12, BASE_ENTRIES=64, NT=2, ENTRIES=16, TAG_W=6, HLENS=(12 << 8) | 4,
               RESET_LOG=9, LATCH=1, PROGS="crc,branchy,sort"),
    "4T": dict(PC_W=30, GHR_LEN=64, BASE_ENTRIES=256, NT=4, ENTRIES=64, TAG_W=9,
               HLENS=(64 << 24) | (24 << 16) | (9 << 8) | 3, RESET_LOG=10, LATCH=0, PROGS="branchy,crc"),
}


@pytest.mark.parametrize("cfg", list(CONFIGS))
def test_rv_tage(cfg):
    c = CONFIGS[cfg]
    hw = {k: v for k, v in c.items() if k != "PROGS"}
    hw["HLENS"] = f"{8 * c['NT']}'h{c['HLENS']:0{2 * c['NT']}x}"
    run("rv_tage", rtl("rv_tage", "rv_bimodal", "rv_tage_table", "rv_tage_hash", "rv_hist_fold",
                       "rv_sram_1r1w", "rv_clock_gate"), "test_rv_tage", hw,
        extra_env_params={"HLENS": c["HLENS"], "PROGS": c["PROGS"]})
