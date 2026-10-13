"""Chip-level test of tt_um_rvcore, the Tiny Tapeout top.

The program sits in an SPI flash model on the QSPI Pmod pins; two SPI PSRAM
models hold data (crt0 copies .data there). Everything the core does goes
through the real rv_spi_mem, CLINT, UART and GPIO. Each commit is checked
against the reference ISS (as in test_rv_core); UART output is decoded from
the TX pin and must equal the ISS's. Also checks the debug-halt pin: while
ui_in[0] is high the core stays in reset and the SPI pins are released.
"""
import sys

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from sim import ROOT, params, run, u
from spi_mem import SpiBus, SpiDevice

sys.path.insert(0, str(ROOT / "model"))
import rv_iss  # noqa: E402

UART_DIV = 3
VOLATILE = set(rv_iss.VOLATILE_CSRS) | {rv_iss.CSR["mip"]}


def volatile_load(addr):
    return (rv_iss.CLINT_BASE <= addr < rv_iss.CLINT_BASE + 0x10000) or \
           (rv_iss.UART_BASE <= addr < rv_iss.UART_BASE + 12) or addr == rv_iss.GPIO_BASE + 4


class Pins:
    """Splits the TT pin bundles into the signals the SPI models expect."""

    def __init__(self, dut):
        self.dut = dut

    @property
    def sck(self):
        return _Bit(self.dut.uio_out, 3)

    @property
    def mosi(self):
        return _Bit(self.dut.uio_out, 1)

    @property
    def cs_n(self):
        return _CsBits(self.dut.uio_out)


class _Bit:
    def __init__(self, sig, i):
        self.sig, self.i = sig, i

    @property
    def value(self):
        return (u(self.sig) >> self.i) & 1


class _CsBits:
    def __init__(self, sig):
        self.sig = sig

    @property
    def value(self):
        v = u(self.sig)
        return (v & 1) | (((v >> 6) & 1) << 1) | (((v >> 7) & 1) << 2)


class _Miso:
    def __init__(self, dut):
        self.dut = dut
        self._v = 0

    @property
    def value(self):
        return self._v

    @value.setter
    def value(self, v):
        self._v = int(v)
        self.dut.uio_in.value = self._v << 2


async def uart_rx(dut, out):
    """Decode 8N1 frames on uo_out[4]; one bit = UART_DIV + 1 cycles."""
    bit = UART_DIV + 1
    while True:
        await RisingEdge(dut.clk)
        if (u(dut.uo_out) >> 4) & 1:
            continue
        for _ in range(bit // 2):                      # middle of the start bit
            await RisingEdge(dut.clk)
        b = 0
        for i in range(8):
            for _ in range(bit):
                await RisingEdge(dut.clk)
            b |= ((u(dut.uo_out) >> 4) & 1) << i
        for _ in range(bit):
            await RisingEdge(dut.clk)
        assert (u(dut.uo_out) >> 4) & 1, "UART stop bit missing"
        out.append(b)


GPIO_UI = 0b1011_0010          # GPIO in = {ui[7:4], ui[2:1]} = 0b101101 (io.c expects it)


async def uart_tx(dut, text, echoed):
    """Send each byte on ui_in[3] after the previous one was echoed."""
    bit = UART_DIV + 1
    base = GPIO_UI

    def drive(level):
        dut.ui_in.value = base | (level << 3)
    for _ in range(3000):
        await RisingEdge(dut.clk)
    for i, ch in enumerate(text.encode()):
        while len(echoed) < i:
            await RisingEdge(dut.clk)
        for level in [0] + [(ch >> k) & 1 for k in range(8)] + [1]:
            drive(level)
            for _ in range(bit):
                await RisingEdge(dut.clk)


@cocotb.test()
async def run_program(dut):
    p = params()
    elf = str(ROOT / "sw" / "build" / f"{p['PROG']}.elf")
    img = rv_iss.Hart(xlen=32)
    rv_iss.load_elf(img, elf)
    ref = rv_iss.Hart(xlen=32)
    ref.pc = rv_iss.load_elf(ref, elf)
    ref.uart_div = UART_DIV

    devs = [SpiDevice("flash", rv_iss.FLASH_SIZE, False, bytearray(img.flash)),
            SpiDevice("psram_a", 8 << 20, True), SpiDevice("psram_b", 8 << 20, True)]
    pins = Pins(dut)
    bus = SpiBus(dut, dut.clk, devs, sck=pins.sck, mosi=pins.mosi, miso=_Miso(dut), cs_n=pins.cs_n)

    Clock(dut.clk, 20, "ns").start()                   # 50 MHz
    dut.ena.value = 1
    dut.uio_in.value = 0
    dut.ui_in.value = 0b0000_1001                      # UART RX idle high, debug halt on
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(20):                                # halted: nothing moves, SPI pins released
        await RisingEdge(dut.clk)
        assert u(dut.uio_oe) == 0
    io = p["PROG"] == "io"
    dut.ui_in.value = (GPIO_UI if io else 0) | 0b0000_1000
    cocotb.start_soon(bus.run())
    uart = []
    cocotb.start_soon(uart_rx(dut, uart))
    if io:
        cocotb.start_soon(uart_tx(dut, "riscv\n", uart))

    core = dut.u_soc.u_core
    soc = dut.u_soc
    n = idle = cyc = 0
    irqs = 0
    while True:
        await FallingEdge(dut.clk)
        cyc += 1
        if u(core.trc_valid_o):
            idle = 0
            pc, trap = u(core.trc_pc_o), u(core.trc_trap_o)
            rd = u(core.trc_rd_o)
            cause = u(core.trc_cause_o) if trap else 0
            rd_val = u(core.trc_rd_val_o) if rd else 0
            insn = u(core.trc_insn_o)
            assert pc == ref.pc, f"commit #{n}: core pc {pc:#x}, ISS pc {ref.pc:#x}"
            if trap and cause >> 31:
                irqs += 1
                ref.pc = ref.take_trap(cause & 0xF, 0, ref.pc, interrupt=True)
                ref._tick()
            else:
                vcsr = (insn & 0x7F) == 0x73 and ((insn >> 12) & 7) not in (0, 4) and (insn >> 20) in VOLATILE
                ref.volatile_csr = rd_val if vcsr else None
                rec = ref.step(irq_ok=False)
                n += 1
                where = f"commit #{n} pc {pc:#x} insn {insn:#010x}"
                if rec.trap is not None or trap:
                    assert trap and rec.trap == cause, f"{where}: core trap {trap} cause {cause:#x}, ISS {rec.trap}"
                else:
                    if rec.rd and (vcsr or (rec.mem and not rec.mem[3] and volatile_load(rec.mem[0]))):
                        ref.x[rec.rd] = rec.rd_val = rd_val
                    assert rd == rec.rd, f"{where}: core writes x{rd}, ISS x{rec.rd}"
                    if rd:
                        assert rd_val == rec.rd_val, f"{where}: x{rd} = {rd_val:#x}, ISS {rec.rd_val:#x}"
            if ref.tohost is not None:
                break
        else:
            idle += 1
            if idle >= 20000:
                m, be = soc.u_mem, core.u_be
                state = {k: u(getattr(m, k)) for k in ("st_q", "beats_q", "restart_q", "fetch_q")}
                state.update(d_valid=u(soc.dreq_valid), d_ready=u(soc.dreq_ready), ar_valid=u(soc.ar_valid),
                             r_valid=u(soc.r_valid), r_ready=u(soc.r_ready), lsu_st=u(be.u_lsu.st_q),
                             mem_v=u(be.mem_v_q), ex_v=u(be.ex_v_q), addr=hex(u(soc.dreq_addr)))
                assert False, f"no commit for 20000 cycles, ISS pc {ref.pc:#x}: {state}"
    for _ in range(12 * (UART_DIV + 1) * 2):           # let the last UART frame finish
        await RisingEdge(dut.clk)
    assert ref.tohost == 1, f"program failed: tohost={ref.tohost}"
    assert u(soc.tohost_valid_o) and u(soc.tohost_o) == 1
    assert not bus.errors, bus.errors[:5]
    assert bytes(uart) == bytes(ref.uart_out), f"UART {bytes(uart)!r} != {bytes(ref.uart_out)!r}"
    if io:
        g = u(dut.uo_out)
        assert ((g >> 5) << 4 | (g & 0xF)) == 0x2D ^ 0x7F, f"GPIO out {g:#x}"
        assert bytes(uart) == b"RISCV\n"
    assert devs[1].mem == ref.psram[:8 << 20] and devs[2].mem == ref.psram[8 << 20:], "PSRAM differs from the ISS"
    rd_lines = sum(1 for t in bus.transactions if t[0] == "flash")
    dut._log.info("%s: %d instructions in %d cycles (IPC %.3f), %d interrupts, %d flash reads, "
                  "%d PSRAM transactions; uart %r", p["PROG"], n, cyc, n / cyc, irqs, rd_lines,
                  len(bus.transactions) - rd_lines, bytes(uart)[:60])


PROGS = ["hello", "traps", "irq", "atomics", "selfmod", "pipe", "crc", "io"]


@pytest.mark.parametrize("prog", PROGS)
def test_soc(prog):
    src = list((ROOT / "src").rglob("rv_*.sv")) + [ROOT / "src" / "top" / "tt_um_rvcore.sv"]
    run("tt_um_rvcore", src, "test_soc", {"UART_DIV": UART_DIV}, extra_env_params={"PROG": prog})
