"""rv_icache_arrays: random reads, beat/tag writes, invalidates and flushes
against a model; checks hit, way, data (across banks), victim choice and the
PLRU update timing (read-first, update the cycle after a hit)."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from sim import params, rng, rtl, run, u
from test_rv_plru import tree_access, tree_victim


@cocotb.test()
async def random_traffic(dut):
    p = params()
    WAYS, SETS, LINE, BEAT, FETCH, PW = (p[k] for k in ("WAYS", "SETS", "LINE_BYTES", "BEAT_BYTES", "FETCH_BYTES", "PW"))
    BEATS, NBANK = LINE // BEAT, FETCH // BEAT
    OFF = (LINE - 1).bit_length()
    SB = (SETS - 1).bit_length()
    r = rng()
    set_of = lambda a: (a >> OFF) & (SETS - 1)
    tag_of = lambda a: a >> (OFF + SB)
    lines = [r.getrandbits(PW - OFF) << OFF for _ in range(3 * SETS)]

    Clock(dut.clk, 10, "ns").start()
    ins = ("rd_valid_i", "rd_addr_i", "wd_valid_i", "wd_way_i", "wd_addr_i", "wd_data_i", "wt_valid_i",
           "wt_way_i", "wt_addr_i", "inv_valid_i", "inv_way_i", "inv_addr_i", "flush_i")
    for s in ins:
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    tags = [[None] * WAYS for _ in range(SETS)]
    valid = [[0] * WAYS for _ in range(SETS)]
    data = {}
    plru = [0] * SETS

    # fill every beat and tag once so reads are defined, then flush
    for s in range(SETS):
        for w in range(WAYS):
            base = lines[s] & ~((SETS - 1) << OFF) | (s << OFF)
            for b in range(BEATS):
                await FallingEdge(dut.clk)
                d = r.getrandbits(8 * BEAT)
                dut.wd_valid_i.value, dut.wd_way_i.value, dut.wd_addr_i.value, dut.wd_data_i.value = 1, w, base + b * BEAT, d
                data[(s, w, b)] = d
            dut.wt_valid_i.value, dut.wt_way_i.value, dut.wt_addr_i.value = 1, w, base
            tags[s][w] = tag_of(base)
    await FallingEdge(dut.clk)
    dut.wd_valid_i.value = dut.wt_valid_i.value = 0
    dut.flush_i.value = 1
    await FallingEdge(dut.clk)
    dut.flush_i.value = 0

    pending = None          # expected read result
    plru_upd = None         # (set, new state) applied at the end of the next cycle
    hits = misses = 0
    for cyc in range(5000):
        await FallingEdge(dut.clk)
        if pending is not None:
            hit, way, dat, victim, multi = pending
            assert u(dut.rd_hit_o) == hit, f"cycle {cyc}: hit"
            if WAYS > 1:
                assert u(dut.rd_victim_o) == victim, f"cycle {cyc}: victim"
            assert u(dut.rd_multi_o) == multi
            if hit:
                hits += 1
                assert u(dut.rd_way_o) == way
                assert u(dut.rd_data_o) == dat, f"cycle {cyc}: data"
            else:
                misses += 1
        # drive this cycle
        rd = r.random() < 0.7
        ra = r.choice(lines) | (r.randrange(LINE // FETCH) * FETCH)
        wd, wdw, wda, wdd = r.random() < 0.4, r.randrange(WAYS), r.choice(lines) | (r.randrange(BEATS) * BEAT), r.getrandbits(8 * BEAT)
        wt, wtw, wta = r.random() < 0.15, r.randrange(WAYS), r.choice(lines)
        iv, ivw, iva = r.random() < 0.1, r.randrange(WAYS), r.choice(lines)
        if wt and iv and set_of(wta) == set_of(iva) and wtw == ivw:
            iv = False
        fl = r.random() < 0.005
        for s, v in zip(ins, (rd, ra, wd, wdw, wda, wdd, wt, wtw, wta, iv, ivw, iva, fl)):
            getattr(dut, s).value = int(v)
        # expected result of this read, from state before this cycle's updates
        if rd:
            s = set_of(ra)
            hv = [valid[s][w] and tags[s][w] == tag_of(ra) and not fl for w in range(WAYS)]
            hit = int(any(hv))
            way = hv.index(True) if hit else 0
            fb = (ra % LINE) // FETCH
            dat = sum(data[(s, way, fb * NBANK + b)] << (8 * BEAT * b) for b in range(NBANK)) if hit else None
            inval = [w for w in range(WAYS) if not valid[s][w] or fl]
            victim = inval[0] if inval else (tree_victim(plru[s], WAYS) if WAYS > 1 else 0)
            new_upd = (s, tree_access(plru[s], way, WAYS)) if (hit and WAYS > 1) else None
            pending = (hit, way, dat, victim, int(sum(hv) > 1))
        else:
            pending, new_upd = None, None
        # apply this cycle's updates
        if wd:
            data[(set_of(wda), wdw, (wda % LINE) // BEAT)] = wdd
        if fl:
            valid = [[0] * WAYS for _ in range(SETS)]
        else:
            if iv:
                valid[set_of(iva)][ivw] = 0
            if wt:
                valid[set_of(wta)][wtw] = 1
        if wt:
            tags[set_of(wta)][wtw] = tag_of(wta)
        if plru_upd:
            plru[plru_upd[0]] = plru_upd[1]
        plru_upd = new_upd
    assert hits > 300 and misses > 300, (hits, misses)


SHAPES = [
    dict(WAYS=1, SETS=4, LINE_BYTES=16, BEAT_BYTES=4, FETCH_BYTES=4, PW=25, LATCH=1),    # TT build (64 B)
    dict(WAYS=2, SETS=8, LINE_BYTES=16, BEAT_BYTES=4, FETCH_BYTES=4, PW=32, LATCH=0),    # TT
    dict(WAYS=2, SETS=8, LINE_BYTES=16, BEAT_BYTES=4, FETCH_BYTES=4, PW=32, LATCH=1),    # TT, latch
    dict(WAYS=4, SETS=16, LINE_BYTES=64, BEAT_BYTES=8, FETCH_BYTES=16, PW=64, LATCH=0),  # FULL shape, fewer sets
    dict(WAYS=1, SETS=4, LINE_BYTES=16, BEAT_BYTES=4, FETCH_BYTES=8, PW=32, LATCH=0),    # direct mapped, 2 banks
]


@pytest.mark.parametrize("shape", SHAPES, ids=lambda s: f"{s['WAYS']}w{s['SETS']}s{s['FETCH_BYTES']}f{s['LATCH']}l")
def test_rv_icache_arrays(shape):
    run("rv_icache_arrays", rtl("rv_icache_arrays", "rv_sram_1r1w", "rv_clock_gate", "rv_tag_cmp", "rv_plru"),
        "test_rv_icache_arrays", shape)
