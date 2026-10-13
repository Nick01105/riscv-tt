"""rv_ilen_detect: instruction boundaries against a sequential parcel walk.
Exhaustive over parcel types for small blocks, random for large ones."""
import itertools

import cocotb
import pytest
from cocotb.triggers import Timer

from sim import params, rng, rtl, run, u


def walk(lows, start, carry):
    NP = len(lows)
    cont = carry and start == 0
    starts = rvc = 0
    for p in range(start, NP):
        if cont:
            cont = False
        else:
            starts |= 1 << p
            if lows[p] != 3:
                rvc |= 1 << p
            else:
                cont = True
    return starts, rvc, int(cont)


@cocotb.test()
async def boundaries(dut):
    NP = params()["NP"]
    r = rng()
    if NP <= 4:
        cases = [(list(l), s, c) for l in itertools.product(range(4), repeat=NP)
                 for s in range(NP) for c in (0, 1)]
    else:
        cases = [([r.choice([0, 1, 2, 3, 3]) for _ in range(NP)], r.randrange(NP), r.getrandbits(1))
                 for _ in range(6000)]
    for lows, start, carry in cases:
        parcels = sum(((r.getrandbits(14) << 2) | lo) << (16 * p) for p, lo in enumerate(lows))
        dut.parcels_i.value, dut.start_i.value, dut.carry_i.value = parcels, start, carry
        await Timer(1, "ns")
        s, c, co = walk(lows, start, carry)
        assert (u(dut.start_mask_o), u(dut.rvc_mask_o), u(dut.carry_o)) == (s, c, co), \
            f"lows={lows} start={start} carry={carry}"


@pytest.mark.parametrize("NP", [2, 4, 8])
def test_rv_ilen_detect(NP):
    run("rv_ilen_detect", rtl("rv_ilen_detect"), "test_rv_ilen_detect", {"NP": NP})
