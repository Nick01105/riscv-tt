"""rv_icache + rv_axi_rd_master against an AXI4 memory model.

Fetch traffic mixes sequential blocks, jumps, redirects (kill) while misses
are outstanding, fence.i with code changes, uncached addresses and lines
whose refill returns a bus error. Every answer is checked against memory;
killed requests must never answer; refills must not repeat a line that is
already being filled; the AXI master must follow the protocol."""
import random

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from axi_mem import ArLayout, AxiReadSlave
from sim import TEST, params, rng, rtl, run, u


@cocotb.test()
async def random_fetch(dut):
    p = params()
    FB, LINE, BEAT, C_W, PA_W = p["FETCH_BYTES"], p["LINE_BYTES"], p["BEAT_BYTES"], p["C_W"], p["PA_W"]
    full = bool(p.get("RV_CFG_FULL"))
    r = rng()
    nlines = 3 * p["SETS"] * p["WAYS"] // 2               # working set: 1.5x the cache
    base = 0x40000 & ((1 << C_W) - 1)
    mem = {}

    def mem_read(a, n):
        return int.from_bytes(bytes(mem.get(a + i, (a + i) * 7 & 0xFF) for i in range(n)), "little")

    def block(a):
        return mem_read(a - a % FB, FB)

    err_lines = {(base // LINE) + nlines - 2}
    layout = ArLayout(2, 64 if full else 32, 8 * BEAT)
    # line -> live refills; id -> lines in order. A refill allocated before a
    # fence.i may still sit in the master's AR register; it does not count.
    live, by_id, dup = {}, {}, []
    pre_flush = [False]
    done_at, redundant, cyc_now = {}, [], [0]     # line -> cycle its last refill validated it
    set_ar = {}                                     # set -> cycle of the last refill into it
    set_of = lambda line: line % p["SETS"]

    def on_ar(ar):
        line = ar["addr"] // LINE
        if (line in done_at and cyc_now[0] - done_at[line] <= 3 and line not in err_lines
                and set_ar.get(set_of(line), -1) <= done_at[line]):
            redundant.append(hex(ar["addr"]))     # refetching a line that was just validated
        set_ar[set_of(line)] = cyc_now[0]
        if pre_flush[0]:
            pre_flush[0] = False
            by_id.setdefault(ar["id"], []).append([None, False])
            return
        if live.get(line):
            dup.append(hex(ar["addr"]))
        live[line] = live.get(line, 0) + 1
        by_id.setdefault(ar["id"], []).append([line, True])

    def on_last(rid):
        line, fills = by_id[rid].pop(0)
        if line is not None and live.get(line):
            live[line] -= 1
        if line is not None and fills:
            done_at[line] = cyc_now[0]

    slave = AxiReadSlave(dut, dut.clk, mem_read, layout, seed=7, err_lines=err_lines, line_bytes=LINE,
                         on_ar=on_ar, on_last=on_last)
    Clock(dut.clk, 10, "ns").start()
    for s in ("req_valid_i", "req_addr_i", "kill_i", "flush_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    cocotb.start_soon(slave.run())

    out = None                  # (addr, issue cycle) of the outstanding request
    nxt = base
    stats = dict(answers=0, hits=0, misses=0, kills=0, flushes=0, faults=0, uncached=0)
    for cyc in range(30000):
        await FallingEdge(dut.clk)
        cyc_now[0] = cyc
        quiet = (cyc // 2000) % 2 == 1                    # every other 2000 cycles: no redirects
        kill = out is not None and not quiet and r.random() < p.get("KILL_P", 0.01)
        flush = False
        if kill and r.random() < 0.2:
            flush = True                                  # fence.i: change some code, then flush
            for _ in range(4):
                a = base + r.randrange(nlines * LINE)
                mem[a] = r.getrandbits(8)
        req = out is None or kill or r.random() < 0.5
        if req:
            if r.random() < 0.06 or not (base <= nxt < base + nlines * LINE):
                nxt = base + r.randrange(nlines * LINE) // FB * FB
            if r.random() < 0.003 and PA_W > C_W:
                nxt = (1 << C_W) + r.randrange(1 << 10) * FB                     # uncached
        dut.kill_i.value, dut.flush_i.value = int(kill), int(flush)
        dut.req_valid_i.value, dut.req_addr_i.value = int(req), nxt
        await Timer(1, "ns")
        if u(dut.resp_valid_o):
            assert out is not None and not kill, f"cycle {cyc}: answer without a live request"
            a = out[0]
            stats["answers"] += 1
            if a >= (1 << C_W):
                assert u(dut.resp_fault_o) == 1
                stats["uncached"] += 1
            elif (a // LINE) in err_lines:
                assert u(dut.resp_fault_o) == 1, f"cycle {cyc}: expected a bus-error fault at {a:#x}"
                stats["faults"] += 1
            else:
                assert u(dut.resp_fault_o) == 0, f"cycle {cyc}: unexpected fault at {a:#x}"
                assert u(dut.resp_data_o) == block(a), f"cycle {cyc}: data at {a:#x}"
            out = None
        stats["hits"] += u(dut.ev_hit_o)
        stats["misses"] += u(dut.ev_miss_o)
        if kill:
            out = None
            stats["kills"] += 1
            stats["flushes"] += flush
            if flush:
                live.clear()                  # after fence.i a line may be fetched again
                done_at.clear()
                for q in by_id.values():      # refills in flight will not validate their line
                    for e in q:
                        e[1] = False
                pre_flush[0] = bool(u(dut.ar_valid))
        accepted = req and u(dut.req_ready_o)
        await RisingEdge(dut.clk)
        if accepted:
            assert out is None, "accepted a second request while one is outstanding"
            out = (nxt, cyc)
            nxt += FB
        if out is not None:
            limit = 400 if quiet and (cyc % 2000) > 400 else 3000
            assert cyc - out[1] < limit, f"request {out[0]:#x} not answered after {cyc - out[1]} cycles"
    assert not slave.errors, slave.errors[:3]
    assert not dup, f"line refilled while a refill for it was outstanding: {dup[:5]}"
    assert not redundant, f"line refilled right after it was validated: {redundant[:5]}"
    # a line is never refilled twice while a refill for it is outstanding
    dut._log.info("%s, AR bursts %d, beats %d", stats, len(slave.ar_log), slave.beats)
    if p["KILL_P"] < 0.1:
        assert stats["hits"] > stats["answers"] // 3 and stats["misses"] > 100 and stats["faults"] > 3 \
            and stats["kills"] > 100 and stats["flushes"] > 20


SHAPES = {
    "tt": dict(WAYS=1, SETS=4, LINE_BYTES=16, BEAT_BYTES=4, FETCH_BYTES=4, MSHRS=1, PA_W=32, C_W=25, LATCH=1),
    "2w2m": dict(WAYS=2, SETS=8, LINE_BYTES=16, BEAT_BYTES=4, FETCH_BYTES=4, MSHRS=2, PA_W=32, C_W=25, LATCH=0),
    "full": dict(WAYS=4, SETS=16, LINE_BYTES=64, BEAT_BYTES=8, FETCH_BYTES=16, MSHRS=4, PA_W=64, C_W=40, LATCH=0),
    # redirects in almost every cycle: exercises kill-and-accept racing with beats and fills
    "tt_kills": dict(WAYS=1, SETS=4, LINE_BYTES=16, BEAT_BYTES=4, FETCH_BYTES=4, MSHRS=1, PA_W=32, C_W=25, LATCH=0),
    "2w_kills": dict(WAYS=2, SETS=8, LINE_BYTES=16, BEAT_BYTES=4, FETCH_BYTES=4, MSHRS=2, PA_W=32, C_W=25, LATCH=0),
}
KILL_P = {"tt_kills": 0.3, "2w_kills": 0.3}


@pytest.mark.parametrize("shape", list(SHAPES))
def test_rv_icache(shape):
    c = SHAPES[shape]
    defines = {"RV_CFG_FULL": 1} if shape == "full" else {}
    run("tb_icache", rtl("rv_icache", "rv_icache_arrays", "rv_mshr_file", "rv_axi_rd_master", "rv_sram_1r1w",
                         "rv_clock_gate", "rv_tag_cmp", "rv_plru"), "test_rv_icache", c, defines=defines,
        extra_sources=[TEST / "tb" / "tb_icache.sv"], extra_env_params={"KILL_P": KILL_P.get(shape, 0.01)})
