"""rv_core system test: real programs, every commit checked against the ISS.

Instructions come over AXI from the memory model (AxiReadSlave); loads,
stores and atomics go over the data bus to a second Hart used only as the
memory map (flash, PSRAM, CLINT, UART, GPIO, TOHOST), with random request
back-pressure and response latency. mtime advances one tick per cycle and
drives mtip/msip.

Lockstep: each commit (or trap) the core reports is replayed on a reference
ISS; pc, trap cause and the written register must match. Interrupts are
asynchronous, so when the core takes one the ISS is made to take the same
one at the same instruction. Values that depend on timing (mcycle, mtime,
mip, hpm counters, CLINT loads) are copied from the core into the ISS.
"""
import os
import random
import sys

import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from axi_mem import ArLayout, AxiReadSlave
from sim import ROOT, TEST, params, run, u, ubits

sys.path.insert(0, str(ROOT / "model"))
import rv_iss  # noqa: E402

VOLATILE = set(rv_iss.VOLATILE_CSRS) | {rv_iss.CSR["mip"]}


def volatile_load(addr):
    return (rv_iss.CLINT_BASE <= addr < rv_iss.CLINT_BASE + 0x10000) or \
           (rv_iss.UART_BASE <= addr < rv_iss.UART_BASE + 12)


@cocotb.test()
async def run_program(dut):
    p = params()
    full = bool(p.get("RV_CFG_FULL"))
    X = 64 if full else 32
    XB = X // 8
    seed = int(os.getenv("SEED", "12345")) + int(p.get("VAR", 0))
    rnd = random.Random(seed)
    fast = bool(p.get("FAST"))                    # always-ready bus, short latency
    elf = str(ROOT / "sw" / ("build64" if full else "build") / f"{p['PROG']}.elf")

    mem = rv_iss.Hart(xlen=X, rve=not full)       # the memory map the core talks to
    entry = rv_iss.load_elf(mem, elf)
    ref = rv_iss.Hart(xlen=X, rve=not full)       # reference
    ref.pc = rv_iss.load_elf(ref, elf)
    assert entry == 0, "the core resets to 0"

    def fetch_read(a, n):
        reg, base = mem._region(a, n)
        return int.from_bytes(reg[a - base:a - base + n], "little") if reg is not None else 0

    layout = ArLayout(2, X, 64 if full else 32)
    slave = AxiReadSlave(dut, dut.clk, fetch_read, layout, seed=seed + 1,
                         p_ar_ready=1.0 if fast else 0.7, p_beat=1.0 if fast else 0.8,
                         max_delay=0 if fast else 3, line_bytes=64 if full else 16)

    Clock(dut.clk, 10, "ns").start()
    for s in ("dreq_ready", "drsp_valid", "drsp_rdata", "drsp_err", "mtip", "msip", "mtime"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    cocotb.start_soon(slave.run())

    rsp = None                 # [cycles left, rdata, err]
    stats = dict(insns=0, traps=0, irqs=0, mispredicts=0, loads=0, stores=0)
    idle = 0
    cyc = 0
    limit = int(p.get("MAX_CYCLES", 3_000_000))
    while cyc < limit:
        await FallingEdge(dut.clk)
        cyc += 1
        # ---- CLINT --------------------------------------------------------------
        mem.mtime += 1
        dut.mtime.value = mem.mtime & ((1 << 64) - 1)
        dut.mtip.value = int(mem.mtime >= mem.mtimecmp)
        dut.msip.value = mem.msip
        # ---- data bus ----------------------------------------------------------------
        ready = 1 if fast else int(rnd.random() < 0.6)
        dut.dreq_ready.value = ready
        if rsp is not None and rsp[0] == 0:
            dut.drsp_valid.value = 1
            dut.drsp_rdata.value = rsp[1]
            dut.drsp_err.value = rsp[2]
        else:
            dut.drsp_valid.value = 0
        await Timer(1, "ns")
        if rsp is not None:
            if rsp[0] == 0:
                rsp = None
            else:
                rsp[0] -= 1
        if u(dut.dreq_valid) and ready:
            assert rsp is None, "second data request before the response"
            addr, we, size = u(dut.dreq_addr), u(dut.dreq_we), 1 << u(dut.dreq_size)
            off = addr % XB
            err, rdata = 0, 0
            try:
                if we:
                    be = u(dut.dreq_be)
                    assert be == ((1 << size) - 1) << off, f"bad byte enables {be:#x} for {addr:#x}/{size}"
                    val = ubits(dut.dreq_wdata, 8 * off, 8 * size)
                    mem.write(addr, size, val)
                    stats["stores"] += 1
                else:
                    rdata = mem.read(addr, size) << (8 * off)
                    stats["loads"] += 1
            except rv_iss.Trap:
                err = 1
            rsp = [0 if fast else rnd.randint(0, 3), rdata, err]
        # ---- commit trace ---------------------------------------------------------------
        if u(dut.trc_valid):
            idle = 0
            pc, trap = u(dut.trc_pc), u(dut.trc_trap)
            rd = u(dut.trc_rd)
            cause = u(dut.trc_cause) if trap else 0
            rd_val = u(dut.trc_rd_val) if rd else 0
            insn = u(dut.trc_insn)
            stats["mispredicts"] += u(dut.trc_mispredict)
            assert pc == ref.pc, f"commit #{stats['insns']}: core pc {pc:#x}, ISS pc {ref.pc:#x}"
            if trap and cause >> (X - 1):
                stats["irqs"] += 1
                ref.pc = ref.take_trap(cause & 0xF, 0, ref.pc, interrupt=True)
                ref._tick()
            else:
                ref.volatile_csr = None
                vcsr = (insn & 0x7F) == 0x73 and ((insn >> 12) & 7) not in (0, 4) and (insn >> 20) in VOLATILE
                if vcsr:
                    ref.volatile_csr = rd_val
                rec = ref.step(irq_ok=False)
                if vcsr and rec.rd and rec.trap is None:       # mip is timing-dependent too
                    ref.x[rec.rd] = rec.rd_val = rd_val
                stats["insns"] += 1
                where = f"commit #{stats['insns']} pc {pc:#x} insn {insn:#010x}"
                if rec.trap is not None or trap:
                    assert trap and rec.trap == cause, f"{where}: core trap {trap} cause {cause:#x}, ISS {rec.trap}"
                    stats["traps"] += 1
                else:
                    if rec.rd and rec.mem and not rec.mem[3] and volatile_load(rec.mem[0]):
                        ref.x[rec.rd] = rd_val
                        rec.rd_val = rd_val
                    assert rd == rec.rd, f"{where}: core writes x{rd}, ISS x{rec.rd}"
                    if rd:
                        assert rd_val == rec.rd_val, f"{where}: x{rd} = {rd_val:#x}, ISS {rec.rd_val:#x}"
            if ref.tohost is not None:
                break
        else:
            idle += 1
            assert idle < 5000, f"no commit for 5000 cycles, ISS pc {ref.pc:#x}"
        assert not u(dut.overflow), "frontend credit overflow"
    assert ref.tohost == 1, f"program failed: tohost={ref.tohost} (cycle {cyc})"
    # the core's own writes reached the memory map too
    assert mem.tohost == 1 and bytes(mem.uart_out) == bytes(ref.uart_out)
    assert not slave.errors, slave.errors[:3]
    n = stats["insns"]
    dut._log.info("%s: %d instructions in %d cycles, IPC %.3f, %d mispredicts (MPKI %.1f), %d traps, "
                  "%d interrupts, %d loads, %d stores; uart %r", p["PROG"], n, cyc, n / cyc, stats["mispredicts"],
                  stats["mispredicts"] * 1000 / n, stats["traps"], stats["irqs"], stats["loads"], stats["stores"],
                  bytes(mem.uart_out)[:60])


PROGS = ["hello", "arith", "traps", "irq", "atomics", "selfmod", "pipe", "crc", "branchy", "sort"]
SRC = list((ROOT / "src").rglob("rv_*.sv"))


@pytest.mark.parametrize("prog", PROGS)
def test_core_tt(prog):
    run("tb_core", SRC, "test_rv_core", extra_sources=[TEST / "tb" / "tb_core.sv"], extra_env_params={"PROG": prog})


@pytest.mark.parametrize("prog", [x for x in PROGS if x != "selfmod"])
def test_core_full(prog):
    run("tb_core", SRC, "test_rv_core", defines={"RV_CFG_FULL": 1},
        extra_sources=[TEST / "tb" / "tb_core.sv"], extra_env_params={"PROG": prog})


@pytest.mark.parametrize("prog", ["arith", "irq", "pipe", "sort"])
def test_core_tt_fast(prog):
    """Zero-latency memory: back-to-back requests and same-cycle hazards."""
    run("tb_core", SRC, "test_rv_core", extra_sources=[TEST / "tb" / "tb_core.sv"],
        extra_env_params={"PROG": prog, "FAST": 1})


def test_core_tt_coremark():
    """CoreMark (1 iteration, about 340k instructions) in lockstep. Needs sw/coremark/get_and_build.sh."""
    if not (ROOT / "sw" / "build" / "coremark.elf").exists():
        pytest.skip("coremark.elf not built")
    run("tb_core", SRC, "test_rv_core", extra_sources=[TEST / "tb" / "tb_core.sv"],
        extra_env_params={"PROG": "coremark", "MAX_CYCLES": 6_000_000})
