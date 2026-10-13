"""rv_btb: random lookups and updates against a model with the same partial
tag; includes aliasing, mid-block entry points, invalidation, read-first."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import params, rng, rtl, run, u


@cocotb.test()
async def random_traffic(dut):
    p = params()
    full = bool(p.get("RV_CFG_FULL"))
    FB, PW = (16, 64) if full else (4, 32)
    NP, OFF = FB // 2, (FB - 1).bit_length()
    E, T = p["ENTRIES"], p["TAG_W"]
    TGT = p.get("TGT_W", PW)
    IDX = (E - 1).bit_length()
    r = rng()
    idx = lambda pc: (pc >> OFF) & (E - 1)
    tag = lambda pc: (pc >> (OFF + IDX)) & ((1 << T) - 1)
    # block pool: a few tags per index plus aliases that differ only above the tag
    blocks = [r.getrandbits(PW - OFF) << OFF for _ in range(3 * E)]
    blocks += [b ^ (1 << (OFF + IDX + T)) for b in blocks[:E]]

    Clock(dut.clk, 10, "ns").start()
    for s in ("lk_valid_i", "lk_pc_i", "up_valid_i", "up_inval_i", "up_pc_i", "up_end_mask_i", "up_type_i", "up_target_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    table = {}
    pending = None
    hits = 0
    for cyc in range(6000):
        await FallingEdge(dut.clk)
        if pending is not None:
            exp = pending
            assert u(dut.lk_hit_o) == int(exp is not False), f"cycle {cyc}: hit"
            if exp:
                hits += 1
                end, typ, tgt = exp
                assert u(dut.lk_end_mask_o) == 1 << end
                assert u(dut.lk_type_o) == typ
                assert u(dut.lk_target_o) == tgt & ((1 << TGT) - 1)
        lk = r.random() < 0.8
        pc = r.choice(blocks) | (2 * r.randrange(NP))
        up = r.random() < 0.4
        upc = r.choice(blocks) | (2 * r.randrange(NP))
        inval = r.random() < 0.1
        end = r.randrange(NP)
        typ = r.randrange(1, 6)
        tgt = r.getrandbits(PW) & ~1
        dut.lk_valid_i.value, dut.lk_pc_i.value = int(lk), pc
        dut.up_valid_i.value, dut.up_inval_i.value, dut.up_pc_i.value = int(up), int(inval), upc
        dut.up_end_mask_i.value, dut.up_type_i.value, dut.up_target_i.value = 1 << end, typ, tgt
        # model: lookup sees the table before this cycle's update
        if lk:
            e = table.get(idx(pc))
            start = (pc >> 1) & (NP - 1)
            pending = (e[1:] if e and e[0] == tag(pc) and e[1] >= start else False)
        else:
            pending = None
        if up:
            if inval:
                table.pop(idx(upc), None)
            else:
                table[idx(upc)] = (tag(upc), end, typ, tgt)
    assert hits > 500


@pytest.mark.parametrize("cfg,ENTRIES,TAG_W,LATCH,TGT_W", [("TT", 8, 6, 1, 25), ("TT", 16, 8, 0, 32),
                                                           ("TT", 8, 4, 0, 25), ("FULL", 64, 10, 0, 64)])
def test_rv_btb(cfg, ENTRIES, TAG_W, LATCH, TGT_W):
    defines = {"RV_CFG_FULL": 1} if cfg == "FULL" else {}
    run("rv_btb", rtl("rv_btb", "rv_sram_1r1w", "rv_clock_gate"), "test_rv_btb",
        {"ENTRIES": ENTRIES, "TAG_W": TAG_W, "LATCH": LATCH, "TGT_W": TGT_W}, defines=defines)
