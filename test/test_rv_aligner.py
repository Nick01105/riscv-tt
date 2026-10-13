"""rv_aligner against an instruction-level model.

A random program (GNU-as compressed instructions mixed with 32-bit words) is
laid out in memory. The model knows where every instruction starts, so it
predicts which instructions each fetch block must deliver, independent of how
the RTL finds boundaries. Traffic includes sequential fetch, predicted-taken
redirects into the middle of blocks, 32-bit instructions split across
blocks, fetch faults, backend flushes and output stalls.
"""
import json

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import PKG, TEST, params, rng, rtl, run, u

FAULT_ACCESS = 1


def cfg():
    full = bool(params().get("RV_CFG_FULL"))
    return dict(FB=16 if full else 4, PW=64 if full else 32, FTQW=4 if full else 2, XLEN=64 if full else 32)


def make_program(r, xlen, n=3000, base=0x1000):
    rvc = json.loads((TEST / "vectors" / f"rvc_rv{xlen}.json").read_text())
    prog, addr = [], base
    for _ in range(n):
        if r.random() < 0.5:
            c16, e32, _ = r.choice(rvc)
            prog.append(dict(addr=addr, size=2, bytes=c16.to_bytes(2, "little"), raw=e32, rvc=1))
            addr += 2
        else:
            w = r.getrandbits(32) | 3
            prog.append(dict(addr=addr, size=4, bytes=w.to_bytes(4, "little"), raw=w, rvc=0))
            addr += 4
    mem = bytearray(r.getrandbits(8) for _ in range(addr + 64))
    for i in prog:
        mem[i["addr"]:i["addr"] + i["size"]] = i["bytes"]
    return prog, mem


@cocotb.test()
async def random_fetch_stream(dut):
    c = cfg()
    FB, NP, PW, FTQW = c["FB"], c["FB"] // 2, c["PW"], c["FTQW"]
    r = rng()
    prog, mem = make_program(r, c["XLEN"])
    last_safe = len(prog) - 40
    Clock(dut.clk, 10, "ns").start()
    for s in ("flush_i", "in_valid_i", "in_pc_i", "in_data_i", "in_taken_i", "in_fault_i", "in_ftq_i"):
        getattr(dut, s).value = 0
    dut.out_ready_i.value = 1
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    async def flush():
        await FallingEdge(dut.clk)
        dut.in_valid_i.value, dut.flush_i.value = 0, 1
        await FallingEdge(dut.clk)
        dut.flush_i.value = 0

    idx = 0
    pc = prog[0]["addr"]
    stats = dict(blocks=0, slots=0, split=0, taken=0, faults=0, flushes=0, stalls=0)
    for step in range(4000):
        bb = pc & ~(FB - 1)
        be = bb + FB
        # instructions this block must deliver (on-path, ending inside the block)
        deliver = []
        j = idx
        while j < len(prog) and prog[j]["addr"] + prog[j]["size"] <= be:
            deliver.append(j)
            j += 1
        fault = r.random() < 0.02
        taken_j = None
        if deliver and not fault and r.random() < 0.15:
            taken_j = r.choice(deliver)
            deliver = deliver[:deliver.index(taken_j) + 1]
        if fault:
            deliver = [idx]                        # only the first instruction, flagged
        tmask = 0
        refetch_j = None
        if taken_j is not None:
            ins_t = prog[taken_j]
            end_parcel = (ins_t["addr"] + ins_t["size"] - 2 - bb) // 2
            if ins_t["size"] == 4 and ins_t["addr"] >= bb and r.random() < 0.3:
                end_parcel -= 1                           # stale BTB entry: mark on the first half
            tmask = 1 << end_parcel
        elif not fault and r.random() < 0.05:
            # stale BTB entry marking the start of a 32-bit instruction that spills
            j = deliver[-1] + 1 if deliver else idx
            if j < len(prog) and prog[j]["size"] == 4 and prog[j]["addr"] == be - 2 and prog[j]["addr"] >= pc:
                refetch_j = j
                tmask = 1 << (NP - 1)
        ftq = r.getrandbits(FTQW)

        await FallingEdge(dut.clk)
        dut.in_valid_i.value = 1
        dut.in_pc_i.value = pc
        dut.in_data_i.value = int.from_bytes(mem[bb:be], "little")
        dut.in_taken_i.value = tmask
        dut.in_fault_i.value = FAULT_ACCESS if fault else 0
        dut.in_ftq_i.value = ftq
        while r.random() < 0.15:                  # stall: outputs must not be consumed
            dut.out_ready_i.value = 0
            stats["stalls"] += 1
            await FallingEdge(dut.clk)
        dut.out_ready_i.value = 1
        await Timer(1, "ns")
        assert u(dut.in_ready_o) == 1

        exp = {}
        if refetch_j is not None:
            exp[NP - 1] = dict(prog[refetch_j], refetch=True)
        for j in deliver:
            ins = prog[j]
            slot = 0 if ins["addr"] < bb else (ins["addr"] - bb) // 2
            if ins["addr"] < bb:
                stats["split"] += 1
            exp[slot] = ins
        valid = u(dut.o_valid)
        assert valid == sum(1 << s for s in exp), \
            f"step {step} pc={pc:#x}: valid={valid:0{NP}b} want {sum(1 << s for s in exp):0{NP}b}"
        for slot, ins in exp.items():
            pc_o = (u(dut.o_pc) >> (slot * PW)) & ((1 << PW) - 1)
            raw_o = (u(dut.o_raw) >> (slot * 32)) & 0xFFFFFFFF
            flt_o = (u(dut.o_fault) >> (slot * 2)) & 3
            assert pc_o == ins["addr"], f"step {step} slot {slot}: pc {pc_o:#x} want {ins['addr']:#x}"
            assert ((u(dut.o_ftq) >> (slot * FTQW)) & ((1 << FTQW) - 1)) == ftq
            if ins.get("refetch"):
                assert flt_o == 3 and raw_o == 0 and (u(dut.o_taken) >> slot) & 1, f"step {step}: refetch marker"
                stats["refetch"] = stats.get("refetch", 0) + 1
            elif fault:
                assert flt_o == FAULT_ACCESS and raw_o == 0
            else:
                assert flt_o == 0
                assert raw_o == ins["raw"], f"step {step} slot {slot}: raw {raw_o:#010x} want {ins['raw']:#010x}"
                assert (u(dut.o_rvc) >> slot) & 1 == ins["rvc"]
                want_taken = int(prog.index(ins) == taken_j) if taken_j is not None else 0
                assert (u(dut.o_taken) >> slot) & 1 == want_taken
        stats["blocks"] += 1
        stats["slots"] += len(exp)

        # next fetch
        if fault or r.random() < 0.02:
            stats["faults" if fault else "flushes"] += 1
            await flush()
            idx = r.randrange(last_safe)
            pc = prog[idx]["addr"]
        elif refetch_j is not None:
            await flush()                               # backend redirects back to the instruction
            idx = refetch_j
            pc = prog[idx]["addr"]
        elif taken_j is not None:
            stats["taken"] += 1
            idx = r.randrange(last_safe)            # predicted target, often mid-block
            pc = prog[idx]["addr"]
        else:
            idx = deliver[-1] + 1 if deliver else idx
            pc = be
            if idx >= last_safe:
                await flush()
                idx = r.randrange(last_safe // 2)
                pc = prog[idx]["addr"]
    dut._log.info("FB=%d: %s", FB, stats)
    assert stats["split"] > 20 and stats["taken"] > 100 and stats["faults"] > 10 and stats.get("refetch", 0) > 5


@pytest.mark.parametrize("cfg_name", ["TT", "FULL"])
def test_rv_aligner(cfg_name):
    defines = {"RV_CFG_FULL": 1} if cfg_name == "FULL" else {}
    run("tb_aligner", rtl("rv_aligner", "rv_ilen_detect", "rv_rvc_expand"), "test_rv_aligner",
        defines=defines, extra_sources=[TEST / "tb" / "tb_aligner.sv"])
