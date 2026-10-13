"""rv_plru: exhaustive over every state and access against an explicit tree
model, plus the PLRU guarantee that the victim is never the last way used."""
import cocotb
import pytest
from cocotb.triggers import Timer

from sim import params, rtl, run, u


def tree_victim(state, ways):
    node = 1
    while node < ways:                         # internal nodes are 1..ways-1
        go_right = (state >> (node - 1)) & 1
        node = 2 * node + go_right
    return node - ways


def tree_access(state, way, ways):
    node = way + ways                          # leaf
    while node > 1:
        parent = node // 2
        came_from_right = node & 1
        bit = 0 if came_from_right else 1      # point away from the accessed side
        state = (state & ~(1 << (parent - 1))) | (bit << (parent - 1))
        node = parent
    return state


@cocotb.test()
async def exhaustive(dut):
    WAYS = params()["WAYS"]
    for state in range(1 << (WAYS - 1)):
        for acc in (0, 1):
            for way in range(WAYS):
                dut.state_i.value, dut.access_i.value, dut.access_way_i.value = state, acc, way
                await Timer(1, "ns")
                assert u(dut.victim_o) == tree_victim(state, WAYS)
                exp = tree_access(state, way, WAYS) if acc else state
                assert u(dut.state_o) == exp, f"state={state:b} way={way}"
                if acc:
                    assert tree_victim(exp, WAYS) != way


@pytest.mark.parametrize("WAYS", [2, 4, 8])
def test_rv_plru(WAYS):
    run("rv_plru", rtl("rv_plru"), "test_rv_plru", {"WAYS": WAYS})
