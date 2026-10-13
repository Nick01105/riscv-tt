"""rv_sat_counter: exhaustive over every counter value, update and direction."""
import cocotb
import pytest
from cocotb.triggers import Timer

from sim import params, rtl, run, u


@cocotb.test()
async def exhaustive(dut):
    W = params()["W"]
    MAX = (1 << W) - 1
    WT, WN = 1 << (W - 1), (1 << (W - 1)) - 1
    for cnt in range(1 << W):
        for upd in (0, 1):
            for taken in (0, 1):
                dut.cnt_i.value, dut.upd_i.value, dut.taken_i.value = cnt, upd, taken
                await Timer(1, "ns")
                if not upd:
                    exp = cnt
                elif taken:
                    exp = min(cnt + 1, MAX)
                else:
                    exp = max(cnt - 1, 0)
                assert u(dut.cnt_o) == exp, f"cnt={cnt} upd={upd} taken={taken}"
                assert u(dut.pred_o) == cnt >> (W - 1)
                assert u(dut.weak_o) == int(cnt in (WT, WN))
                assert u(dut.sat_o) == int(cnt in (0, MAX))


@pytest.mark.parametrize("W", [2, 3, 4])
def test_rv_sat_counter(W):
    run("rv_sat_counter", rtl("rv_sat_counter"), "test_rv_sat_counter", {"W": W})
