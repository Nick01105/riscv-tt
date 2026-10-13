"""rv_axi_rd_slice: both channels under random valid/ready, with an
AXI-compliant source (payload held until accepted). Checks order, integrity,
output stability while stalled, and full throughput with no stalls."""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import TEST, rng, rtl, run, u


async def channel(dut, r, src_v, src_rdy, src_d, dst_v, dst_rdy, dst_d, cycles, p_valid, p_ready):
    W = len(src_d)
    sent, got = [], []
    cur = None
    held = None
    for cyc in range(cycles):
        await FallingEdge(dut.clk)
        if cur is None and r.random() < p_valid:
            cur = r.getrandbits(W)
        src_v.value = int(cur is not None)
        src_d.value = cur if cur is not None else 0
        rdy = int(r.random() < p_ready)
        dst_rdy.value = rdy
        await Timer(1, "ns")
        v = u(dst_v)
        if held is not None:
            assert v == 1 and u(dst_d) == held, "output changed while stalled"
        held = u(dst_d) if (v and not rdy) else None
        if v and rdy:
            got.append(u(dst_d))
        if cur is not None and u(src_rdy):
            sent.append(cur)
            cur = None
    assert got == sent[:len(got)] and len(sent) - len(got) <= 2
    return len(got)


@cocotb.test()
async def both_channels(dut):
    r1, r2 = rng(), rng()
    r2.seed(99)
    Clock(dut.clk, 10, "ns").start()
    for s in ("s_ar_valid_i", "s_ar_i", "m_ar_ready_i", "m_r_valid_i", "m_r_i", "s_r_ready_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    ar = cocotb.start_soon(channel(dut, r1, dut.s_ar_valid_i, dut.s_ar_ready_o, dut.s_ar_i,
                                   dut.m_ar_valid_o, dut.m_ar_ready_i, dut.m_ar_o, 6000, 0.6, 0.5))
    rr = cocotb.start_soon(channel(dut, r2, dut.m_r_valid_i, dut.m_r_ready_o, dut.m_r_i,
                                   dut.s_r_valid_o, dut.s_r_ready_i, dut.s_r_o, 6000, 0.8, 0.7))
    n_ar, n_r = await ar, await rr
    assert n_ar > 1500 and n_r > 2500
    # drain what is still inside before the next phase
    await FallingEdge(dut.clk)
    dut.s_ar_valid_i.value = dut.m_r_valid_i.value = 0
    dut.m_ar_ready_i.value = dut.s_r_ready_i.value = 1
    for _ in range(4):
        await FallingEdge(dut.clk)
    # full rate: 1000 beats in about 1000 cycles
    n = await channel(dut, r1, dut.m_r_valid_i, dut.m_r_ready_o, dut.m_r_i,
                      dut.s_r_valid_o, dut.s_r_ready_i, dut.s_r_o, 1000, 1.0, 1.0)
    assert n >= 998


@pytest.mark.parametrize("cfg", ["TT", "FULL"])
def test_rv_axi_rd_slice(cfg):
    defines = {"RV_CFG_FULL": 1} if cfg == "FULL" else {}
    run("tb_axi_rd_slice", rtl("rv_axi_rd_slice", "rv_skid_buffer"), "test_rv_axi_rd_slice", defines=defines,
        extra_sources=[TEST / "tb" / "tb_axi_rd_slice.sv"])
