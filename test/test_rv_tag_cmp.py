"""rv_tag_cmp: random sets with forced hits, misses and duplicate tags."""
import cocotb
import pytest
from cocotb.triggers import Timer

from sim import params, rng, rtl, run, u


@cocotb.test()
async def random_sets(dut):
    p = params()
    WAYS, T = p["WAYS"], p["TAG_W"]
    r = rng()
    for _ in range(4000):
        look = r.getrandbits(T)
        tags = [r.choice([look, r.getrandbits(T)]) for _ in range(WAYS)]
        valid = [r.getrandbits(1) for _ in range(WAYS)]
        dut.tags_i.value = sum(t << (w * T) for w, t in enumerate(tags))
        dut.valid_i.value = sum(v << w for w, v in enumerate(valid))
        dut.tag_i.value = look
        await Timer(1, "ns")
        hits = [int(valid[w] and tags[w] == look) for w in range(WAYS)]
        assert u(dut.hit_vec_o) == sum(h << w for w, h in enumerate(hits))
        assert u(dut.hit_o) == int(any(hits))
        assert u(dut.multi_hit_o) == int(sum(hits) > 1)
        if any(hits):
            assert u(dut.hit_way_o) == hits.index(1)


@pytest.mark.parametrize("WAYS,TAG_W", [(1, 8), (2, 20), (4, 6), (8, 3)])
def test_rv_tag_cmp(WAYS, TAG_W):
    run("rv_tag_cmp", rtl("rv_tag_cmp"), "test_rv_tag_cmp", {"WAYS": WAYS, "TAG_W": TAG_W})
