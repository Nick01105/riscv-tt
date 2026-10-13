"""rv_frontend system test (the project document's definition of done).

Real programs are fetched over AXI from the memory model. A Python backend
model runs the reference ISS in lockstep: every correct-path uop must have
the ISS's pc, length and (for 32-bit instructions) encoding. The model
resolves branches and predicted-taken uops one cycle after taking them,
redirects on mispredicts and exceptions with real pipeline timing, drops
wrong-path uops, and retires FTQ entries. Reports IPC and MPKI."""
import os
import random
import sys

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from axi_mem import ArLayout, AxiReadSlave
from sim import ROOT, TEST, params, rtl, run, u, ubits

sys.path.insert(0, str(ROOT / "model"))
import rv_iss  # noqa: E402

BR_NONE, BR_COND = 0, 1
RDR_MISPREDICT, RDR_EXCEPTION, RDR_FENCE_I = 0, 1, 2
SYS_FENCE_I = 6
FAULT_NONE, FAULT_ACCESS, FAULT_REFETCH = 0, 1, 3


@cocotb.test()
async def run_program(dut):
    p = params()
    full = bool(p.get("RV_CFG_FULL"))
    X, PW, FW = (64, 64, 4) if full else (32, 32, 2)
    DW = 4 if full else 1
    r = random.Random(int(os.getenv("SEED", "12345")))
    elf = str(ROOT / "sw" / ("build64" if full else "build") / f"{p['PROG']}.elf")
    hart = rv_iss.Hart(xlen=X, rve=not full)
    hart.pc = rv_iss.load_elf(hart, elf)

    def mem_read(a, n):
        reg, base = hart._region(a, n)
        return int.from_bytes(reg[a - base:a - base + n], "little") if reg is not None else 0

    layout = ArLayout(2, PW, 64 if full else 32)
    slave = AxiReadSlave(dut, dut.clk, mem_read, layout, seed=3, p_ar_ready=0.7, p_beat=0.8, max_delay=3,
                         line_bytes=64 if full else 16)
    Clock(dut.clk, 10, "ns").start()
    ins = ("u_ready", "rd_valid", "rd_target", "rd_ftq", "rd_cause", "rs_valid", "rs_pc", "rs_rvc", "rs_taken",
           "rs_target", "rs_br", "rs_mispredict", "rs_ftq", "rt_valid", "rt_ftq", "tgt_idx")
    for s in ins:
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    cocotb.start_soon(slave.run())

    pending = None          # (resolve dict or None, redirect dict or None, retire idx) for next cycle
    stats = dict(insns=0, cycles=0, mispredicts=0, exceptions=0, refetch=0, wrong_path=0, ic_miss=0, preds=0)
    idle = 0
    done = False
    cyc = 0
    while not done:
        cyc += 1
        await FallingEdge(dut.clk)
        # ---- drive last cycle's results (registered backend) ----
        res, rdr, ret = pending if pending else (None, None, None)
        dut.rs_valid.value = int(res is not None)
        if res:
            for k, v in res.items():
                getattr(dut, "rs_" + k).value = v
        dut.rd_valid.value = int(rdr is not None)
        if rdr:
            dut.rd_target.value, dut.rd_ftq.value, dut.rd_cause.value = rdr["target"], rdr["ftq"], rdr["cause"]
        dut.rt_valid.value = int(ret is not None)
        if ret is not None:
            dut.rt_ftq.value = ret
        ready = (1 << r.randint(0, DW)) - 1 if r.random() < 0.85 else 0
        dut.u_ready.value = ready
        await Timer(1, "ns")
        assert not u(dut.overflow), "IQ credit overflow"
        stats["ic_miss"] += u(dut.ev_ic_miss)
        stats["preds"] += u(dut.ev_pred)
        squashing = rdr is not None              # uops seen in a redirect cycle are wrong path
        pending = None
        n_res = None
        n_rdr = None
        n_ret = None
        valid = u(dut.u_valid)
        took = 0
        for k in range(DW):
            if not ((valid >> k) & 1 and (ready >> k) & 1):
                break
            took += 1
            if squashing or n_rdr is not None:
                stats["wrong_path"] += 1
                continue
            pc = ubits(dut.u_pc, k * PW, PW)
            raw = ubits(dut.u_raw, 32 * k, 32)
            rvc = (u(dut.u_rvc) >> k) & 1
            ptaken = (u(dut.u_taken) >> k) & 1
            fault = ubits(dut.u_fault, 2 * k, 2)
            br = ubits(dut.u_br, 3 * k, 3)
            ftq = ubits(dut.u_ftq, FW * k, FW)
            sysop = ubits(dut.u_sys, 3 * k, 3)
            assert pc == hart.pc, f"cycle {cyc}: uop pc {pc:#x}, ISS at {hart.pc:#x}"
            n_ret = ftq
            if fault == FAULT_REFETCH:
                stats["refetch"] += 1
                n_res = dict(pc=pc, rvc=0, taken=0, target=0, br=BR_NONE, mispredict=1, ftq=ftq)
                n_rdr = dict(target=pc, ftq=ftq, cause=RDR_MISPREDICT)
                continue
            assert fault == FAULT_NONE, f"cycle {cyc}: unexpected fetch fault at {pc:#x}"
            lo = mem_read(pc, 2)
            size = 2 if lo & 3 != 3 else 4
            assert rvc == int(size == 2), f"cycle {cyc}: length at {pc:#x}"
            if size == 4:
                assert raw == mem_read(pc, 4), f"cycle {cyc}: encoding at {pc:#x}: {raw:#010x}"
            dut.tgt_idx.value = ftq
            await Timer(1, "ps")
            pred_next = ubits(dut.tgt, 0, PW) if ptaken else pc + size
            rec = hart.step()
            stats["insns"] += 1
            actual = hart.pc
            if rec.trap is not None:
                stats["exceptions"] += 1
                n_rdr = dict(target=actual, ftq=ftq, cause=RDR_EXCEPTION)
                continue
            if sysop == SYS_FENCE_I:                     # serialize: flush the I-cache, refetch
                stats["fence_i"] = stats.get("fence_i", 0) + 1
                n_rdr = dict(target=actual, ftq=ftq, cause=RDR_FENCE_I)
                continue
            mis = actual != pred_next
            if br != BR_NONE or ptaken:
                tk = int(actual != pc + size) if br == BR_COND else int(br != BR_NONE)
                n_res = dict(pc=pc, rvc=rvc, taken=tk, target=actual, br=br, mispredict=int(mis), ftq=ftq)
            if mis:
                stats["mispredicts"] += 1
                n_rdr = dict(target=actual, ftq=ftq, cause=RDR_MISPREDICT)
            if hart.tohost is not None:
                done = True
                break
        pending = (n_res, n_rdr, n_ret)
        idle = 0 if took else idle + 1
        assert idle < 2000, f"no progress for 2000 cycles at ISS pc {hart.pc:#x}"
        await RisingEdge(dut.clk)
    assert hart.tohost == 1, f"program failed: tohost={hart.tohost}"
    assert not slave.errors, slave.errors[:3]
    n = stats["insns"]
    dut._log.info("%s: %d instructions in %d cycles, IPC %.2f, mispredict MPKI %.1f, %d I-cache misses, "
                  "%d exceptions, %d refetches, %d fence.i, %d wrong-path uops dropped",
                  p["PROG"], n, cyc, n / cyc, stats["mispredicts"] * 1000 / n, stats["ic_miss"],
                  stats["exceptions"], stats["refetch"], stats.get("fence_i", 0), stats["wrong_path"])


PROGS_TT = ["hello", "traps", "selfmod", "crc", "branchy", "atomics", "arith", "sort"]
PROGS_FULL = ["hello", "traps", "crc", "branchy", "atomics", "arith", "sort"]


@pytest.mark.parametrize("prog", PROGS_TT)
def test_frontend_tt(prog):
    run("tb_frontend", list((ROOT / "src").rglob("rv_*.sv")), "test_rv_frontend",
        extra_sources=[TEST / "tb" / "tb_frontend.sv"], extra_env_params={"PROG": prog})


@pytest.mark.parametrize("prog", PROGS_FULL)
def test_frontend_full(prog):
    run("tb_frontend", list((ROOT / "src").rglob("rv_*.sv")), "test_rv_frontend", defines={"RV_CFG_FULL": 1},
        extra_sources=[TEST / "tb" / "tb_frontend.sv"], extra_env_params={"PROG": prog})
