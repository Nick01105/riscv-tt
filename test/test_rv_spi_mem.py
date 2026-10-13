"""rv_spi_mem against SPI flash/PSRAM models: random AXI fetch bursts (WRAP
from any word, INCR, unmapped addresses) and data reads/writes of every size
to all three devices, with R back-pressure. Checks data, AXI beat order and
last/resp, error responses without SPI traffic, and the SPI protocol."""
import random

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from sim import TEST, params, rng, rtl, run, u
from spi_mem import SpiBus, SpiDevice

ID_W, AW, DW = 2, 32, 32
FLASH, PSA, PSB = 0x0000_0000, 0x0100_0000, 0x0180_0000
SIZE = 1 << 16                     # model only the low 64 KB of each device (addresses wrap)


def pack_ar(id_, addr, length, burst):
    v = id_
    v = (v << AW) | addr
    v = (v << 8) | length
    v = (v << 3) | 2               # size: 4 bytes
    v = (v << 2) | burst
    v = (v << 1) | 0
    v = (v << 4) | 0
    v = (v << 3) | 0
    return v


def unpack_r(v):
    last, v = v & 1, v >> 1
    resp, v = v & 3, v >> 2
    data, v = v & 0xFFFFFFFF, v >> DW
    return v, data, resp, last


@cocotb.test()
async def random_traffic(dut):
    r = rng()
    devs = [SpiDevice("flash", SIZE, False, bytearray(r.getrandbits(8) for _ in range(SIZE))),
            SpiDevice("psram_a", SIZE, True, bytearray(r.getrandbits(8) for _ in range(SIZE))),
            SpiDevice("psram_b", SIZE, True, bytearray(r.getrandbits(8) for _ in range(SIZE)))]
    ref = [bytearray(d.mem) for d in devs]
    bus = SpiBus(dut, dut.clk, devs)
    Clock(dut.clk, 10, "ns").start()
    for s in ("ar_valid", "ar", "r_ready", "d_valid", "d_addr", "d_we", "d_be", "d_wdata"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    cocotb.start_soon(bus.run())

    def where(a):
        if a >> 24 == 0:
            return 0, a & 0xFFFFFF
        if a >> 24 == 1:
            return (2 if (a >> 23) & 1 else 1), a & 0x7FFFFF
        return None, None

    def ref_read(a, n):
        d, off = where(a)
        return int.from_bytes(bytes(ref[d][(off + i) % SIZE] for i in range(n)), "little")

    def rand_addr():
        k = r.random()
        base = FLASH if k < 0.4 else PSA if k < 0.7 else PSB if k < 0.95 else r.choice([0x0200_0000, 0x1000_0000, 0xFFFF_FFF0])
        return (base + r.randrange(SIZE)) & 0xFFFFFFFF

    for n in range(300):
        await FallingEdge(dut.clk)
        if r.random() < 0.5:
            # ---- fetch burst ----
            length = r.choice([3, 3, 3, 1, 7, 0])
            burst = 2 if (length in (1, 3, 7) and r.random() < 0.8) else 1
            a = rand_addr() & ~3
            if burst == 1:
                a &= ~(4 * (length + 1) - 1)        # INCR bursts stay inside the window
            id_ = r.randrange(4)
            dut.ar.value = pack_ar(id_, a, length, burst)
            dut.ar_valid.value = 1
            while True:
                await RisingEdge(dut.clk)
                if u(dut.ar_ready):
                    break
            await FallingEdge(dut.clk)
            dut.ar_valid.value = 0
            total = 4 * (length + 1)
            base = a - a % total
            exp = [(base + (a - base + 4 * i) % total) if burst == 2 else a + 4 * i for i in range(length + 1)]
            for i, ea in enumerate(exp):
                while True:
                    rdy = int(r.random() < 0.7)
                    dut.r_ready.value = rdy
                    await RisingEdge(dut.clk)
                    if u(dut.r_valid) and rdy:
                        break
                    await FallingEdge(dut.clk)
                rid, data, resp, last = unpack_r(u(dut.r))
                assert rid == id_ and last == int(i == length)
                if where(ea)[0] is None:
                    assert resp == 2
                else:
                    assert resp == 0 and data == ref_read(ea, 4), f"fetch {a:#x} beat {i} at {ea:#x}: {data:#x} {bus.errors[:3]} {bus.transactions[-3:]}"
                await FallingEdge(dut.clk)
                dut.r_ready.value = 0
        else:
            # ---- data access ----
            size = r.choice([1, 2, 4])
            a = rand_addr() & ~(size - 1)
            we = int(r.random() < 0.5)
            off = a & 3
            be = ((1 << size) - 1) << off
            wd = r.getrandbits(32)
            dut.d_valid.value, dut.d_addr.value, dut.d_we.value, dut.d_be.value = 1, a, we, be
            dut.d_wdata.value = wd
            while True:
                await RisingEdge(dut.clk)
                if u(dut.d_ready):
                    break
            await FallingEdge(dut.clk)
            dut.d_valid.value = 0
            cyc = 0
            while True:
                await RisingEdge(dut.clk)
                cyc += 1
                assert cyc < 2000
                if u(dut.d_rsp_valid):
                    break
            d, offd = where(a)
            bad = d is None or (we and d == 0)
            assert u(dut.d_err) == int(bad), f"err for {a:#x} we={we}"
            if not bad:
                if we:
                    for i in range(size):
                        ref[d][(offd + i) % SIZE] = (wd >> (8 * (off + i))) & 0xFF
                else:
                    assert u(dut.d_rdata) == ref_read(a & ~3, 4), f"read {a:#x}"
    for _ in range(10):
        await RisingEdge(dut.clk)
    assert not bus.errors, bus.errors[:5]
    for d, rf in zip(devs, ref):
        assert d.mem == rf, f"{d.name} contents differ"
    cmds = {t[1] for t in bus.transactions}
    assert cmds <= {2, 3} and 2 in cmds


@pytest.mark.parametrize("DIV", [1, 3])
def test_rv_spi_mem(DIV):
    run("tb_spi_mem", rtl("rv_spi_mem"), "test_rv_spi_mem", {"DIV": DIV}, extra_sources=[TEST / "tb" / "tb_spi_mem.sv"])
