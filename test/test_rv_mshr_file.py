"""rv_mshr_file: random allocations, interleaved WRAP-order refill beats,
bus errors, fence.i flushes and early RLAST against a model. Checks every
combinational output each cycle."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u


@cocotb.test()
async def random_refills(dut):
    p = params()
    N, PW, LINE, BEAT, WAYS = p["N"], p["PW"], p["LINE_BYTES"], p["BEAT_BYTES"], p["WAYS"]
    BEATS = LINE // BEAT
    OFF = (LINE - 1).bit_length()
    r = rng()
    lines = [r.getrandbits(PW - OFF) for _ in range(4 * N)]
    Clock(dut.clk, 10, "ns").start()
    ins = ("flush_i", "alloc_i", "alloc_addr_i", "alloc_way_i", "lookup_addr_i",
           "beat_valid_i", "beat_mshr_i", "beat_last_i", "beat_err_i")
    for s in ins:
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    ent = {}
    stats = dict(fills=0, errs=0, flushed=0, mismatch=0)
    for cyc in range(8000):
        await FallingEdge(dut.clk)
        free = [i for i in range(N) if i not in ent]
        pending_lines = {e["line"] for e in ent.values()}
        live_lines = {e["line"] for e in ent.values() if not e["nofill"]}
        alloc = bool(free) and r.random() < 0.3
        cand = [l for l in lines if l not in pending_lines]
        aline = r.choice(cand)
        aaddr = (aline << OFF) | r.randrange(LINE)
        away = r.randrange(WAYS)
        bv = bool(ent) and r.random() < 0.6
        bm = r.choice(sorted(ent)) if ent else 0
        berr = r.random() < 0.03
        flush = r.random() < 0.01
        if bv:
            e = ent[bm]
            blast = e["cnt"] == BEATS - 1
            if not blast and r.random() < 0.005:
                blast = True                      # early RLAST: protocol error
        else:
            blast = False
        lk_line = r.choice(sorted(pending_lines)) if pending_lines and r.random() < 0.7 else r.choice(lines)
        del live_lines
        lk = (lk_line << OFF) | r.randrange(LINE)
        for s, v in zip(ins, (flush, alloc, aaddr, away, lk, bv, bm, blast, berr)):
            getattr(dut, s).value = int(v)
        await Timer(1, "ns")

        assert u(dut.free_o) == int(bool(free))
        if free:
            assert u(dut.alloc_idx_o) == free[0]
        hits = [i for i in sorted(ent) if ent[i]["line"] == (lk >> OFF) and not ent[i]["nofill"]]
        assert u(dut.lookup_hit_o) == int(bool(hits)), f"cycle {cyc}: lookup"
        if hits:
            i = hits[0]
            assert u(dut.lookup_idx_o) == i
            assert u(dut.lookup_beat_ready_o) == int(((lk % LINE) // BEAT) in ent[i]["recv"])
        assert u(dut.wd_valid_o) == int(bv)
        assert u(dut.done_o) == int(bv and blast)
        if bv:
            e = ent[bm]
            bidx = (e["start"] + e["cnt"]) % BEATS
            assert u(dut.wd_way_o) == e["way"]
            assert u(dut.wd_addr_o) == (e["line"] << OFF) | (bidx * BEAT), f"cycle {cyc}: beat address"
            assert u(dut.last_mismatch_o) == int(blast != (e["cnt"] == BEATS - 1))
            stats["mismatch"] += u(dut.last_mismatch_o)
            if blast:
                err = e["err"] or berr
                assert u(dut.done_idx_o) == bm and u(dut.done_err_o) == int(err)
                validate = not (e["nofill"] or err or flush)
                assert u(dut.wt_valid_o) == int(validate), f"cycle {cyc}: tag write"
                if validate:
                    assert u(dut.wt_way_o) == e["way"] and u(dut.wt_addr_o) == e["line"] << OFF
                    stats["fills"] += 1
                else:
                    stats["errs" if err else "flushed"] += 1
        else:
            assert u(dut.wt_valid_o) == 0
        # model update at the clock edge
        if bv:
            e = ent[bm]
            e["recv"].add((e["start"] + e["cnt"]) % BEATS)
            e["cnt"] += 1
            e["err"] |= berr
            if blast:
                del ent[bm]
        if flush:
            for e in ent.values():
                e["nofill"] = True
        if alloc:
            ent[free[0]] = dict(line=aline, way=away, start=(aaddr % LINE) // BEAT, cnt=0, recv=set(),
                                nofill=False, err=False)
    dut._log.info("%s", stats)
    assert stats["fills"] > 200 and stats["errs"] > 5 and stats["flushed"] > 5


@pytest.mark.parametrize("N,PW,LINE_BYTES,BEAT_BYTES,WAYS", [(1, 32, 16, 4, 2), (2, 32, 16, 4, 2),
                                                            (4, 64, 64, 8, 4)])
def test_rv_mshr_file(N, PW, LINE_BYTES, BEAT_BYTES, WAYS):
    run("rv_mshr_file", rtl("rv_mshr_file"), "test_rv_mshr_file",
        {"N": N, "PW": PW, "LINE_BYTES": LINE_BYTES, "BEAT_BYTES": BEAT_BYTES, "WAYS": WAYS})
