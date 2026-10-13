# Tiny Tapeout CI test for tt_um_rvcore (RTL, and gate level with GATES=yes).
# Only the pins are used: the firmware (fw/tt_ci.elf, from sw/tests/tt_ci.c)
# is served from an SPI flash model on the QSPI Pmod pins, PSRAM models hold
# its data, and the test checks the UART output and the GPIO pattern.
# The full test suite (lockstep against the ISS) is test_soc.py / test_rv_core.py.
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "model"))
import rv_iss  # noqa: E402
from spi_mem import SpiBus, SpiDevice  # noqa: E402
from test_soc import Pins, _Miso  # noqa: E402


def u(sig):
    return int(sig.value)


async def uart_rx(dut, out, bit):
    while True:
        await RisingEdge(dut.clk)
        if (u(dut.uo_out) >> 4) & 1:
            continue
        await ClockCycles(dut.clk, bit // 2)
        b = 0
        for i in range(8):
            await ClockCycles(dut.clk, bit)
            b |= ((u(dut.uo_out) >> 4) & 1) << i
        await ClockCycles(dut.clk, bit)
        out.append(b)


@cocotb.test()
async def test_project(dut):
    img = rv_iss.Hart(xlen=32)
    rv_iss.load_elf(img, str(HERE / "fw" / "tt_ci.elf"))
    devs = [SpiDevice("flash", 1 << 20, False, bytearray(img.flash[:1 << 20])),
            SpiDevice("psram_a", 1 << 20, True), SpiDevice("psram_b", 1 << 20, True)]
    pins = Pins(dut)
    bus = SpiBus(dut, dut.clk, devs, sck=pins.sck, mosi=pins.mosi, miso=_Miso(dut), cs_n=pins.cs_n)

    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0b0000_1001          # UART RX idle, debug halt
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)
    assert u(dut.uio_oe) == 0, "SPI pins must be released while halted"
    dut.ui_in.value = 0b0000_1000          # run
    await ClockCycles(dut.clk, 4)
    cocotb.start_soon(bus.run())

    # boot at the reset baud rate (434 cycles per bit), then the firmware sets 4
    uart = []
    cocotb.start_soon(uart_rx(dut, uart, 4))
    seen55 = False
    for _ in range(200_000):
        await RisingEdge(dut.clk)
        g = u(dut.uo_out)
        gpio = ((g >> 5) << 4) | (g & 0xF)
        seen55 |= gpio == 0x55
        if bytes(uart).endswith(b"tt ok\n") and gpio == 0x2A:
            break
    dut._log.info("UART: %r", bytes(uart))
    assert u(dut.uio_oe) == 0b1111_1011
    assert seen55, "GPIO never showed 0x55"
    assert bytes(uart).endswith(b"tt ok\n"), f"UART output {bytes(uart)!r}"
    assert not bus.errors, bus.errors[:3]
