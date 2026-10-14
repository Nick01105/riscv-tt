#!/usr/bin/env python3
"""Cross-check the reference ISS (model/rv_iss.py) against Spike, instruction
by instruction: pc, encoding and register write-back of every retired
instruction must match.

Needs Spike (SPIKE env var or /opt/spike/bin/spike) and the cross-check
builds: cd sw && make SPIKE=1 && SPIKE=1 coremark/get_and_build.sh
Usage: scripts/iss_vs_spike.py [elf ...]   (default: sw/build-spike/*.elf)
       XLEN=64 scripts/iss_vs_spike.py      (RV64 builds: make -C sw FULL=1 SPIKE=1)"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
import rv_iss  # noqa: E402

SPIKE = os.environ.get("SPIKE_BIN", "/opt/spike/bin/spike")
COMMIT = re.compile(r"core\s+0: 3 0x([0-9a-f]+) \(0x([0-9a-f]+)\)(.*)")
XREG = re.compile(r"\bx(\d+)\s+0x([0-9a-f]+)")


XLEN = int(os.environ.get("XLEN", "32"))
ISA = "rv32eac_zicsr_zifencei" if XLEN == 32 else "rv64imac_zicsr_zifencei"


def spike_trace(elf):
    out = subprocess.run([SPIKE, f"--isa={ISA}", "--priv=m", "-m0x20000000:0x1000000,0x1000000:0x1000000",
                          "-l", "--log-commits", elf], capture_output=True, text=True, timeout=1800)
    recs = []
    for line in out.stderr.splitlines():
        m = COMMIT.match(line)
        if not m:
            continue
        pc = int(m.group(1), 16)
        if 0x1000 <= pc < 0x2000:
            continue                                   # Spike's boot ROM
        w = XREG.search(m.group(3))
        recs.append((pc, int(m.group(2), 16), int(w.group(1)) if w else 0, int(w.group(2), 16) if w else 0))
    return recs, out.stdout


def is_volatile_read(insn):
    """csrr of a counter neither model can predict (cycle, time, hpm)."""
    return insn & 3 == 3 and insn & 0x7F == 0x73 and (insn >> 12) & 7 in (1, 2, 3, 5, 6, 7) \
        and (insn >> 20) in rv_iss.VOLATILE_CSRS


def lockstep(elf, spike):
    """Step the ISS beside Spike's trace. Volatile CSR reads take Spike's value."""
    h = rv_iss.Hart(xlen=XLEN, rve=XLEN == 32, flash_base=0x20000000, tohost_addr=0x01FFF000)
    h.pc = rv_iss.load_elf(h, elf)
    k, steps = 0, 0
    while h.tohost is None and steps < 20_000_000:
        steps += 1
        nxt = spike[k] if k < len(spike) else None
        h.volatile_csr = nxt[3] if (nxt and is_volatile_read(nxt[1])) else None
        r = h.step()
        if r.trap is not None:
            continue
        mine = (r.pc, r.insn, r.rd, r.rd_val)
        if nxt != mine:
            return k, mine, h
        k += 1
    # Spike keeps running the final `j .` until it polls tohost: allow that tail
    tail_ok = all(rec[0] == h.pc and rec[1] in (0xA001, 0x0000006F) for rec in spike[k:])
    return (None if (k == len(spike) or tail_ok) else k), None, h


ASYNC = {"irq"}          # programs whose instruction stream depends on interrupt timing
SKIP = {"io"}            # needs UART/GPIO input from the chip-level test bench


def main():
    d = "build-spike" if XLEN == 32 else "build64-spike"
    elfs = sys.argv[1:] or sorted(str(p) for p in (ROOT / "sw" / d).glob("*.elf") if p.stem not in SKIP)
    bad = 0
    for elf in elfs:
        s, s_out = spike_trace(elf)
        if Path(elf).stem in ASYNC:
            # interrupt timing differs between the models: compare outcomes only
            h = rv_iss.Hart(xlen=XLEN, rve=XLEN == 32, flash_base=0x20000000, tohost_addr=0x01FFF000)
            h.pc = rv_iss.load_elf(h, elf)
            rv_iss.run(h)
            i_out = h.uart_out.decode(errors="replace")
            ok = h.tohost == 1 and s_out == i_out
            bad += not ok
            print(f"{Path(elf).name:14s} {h.instret:8,} instructions  {'SAME RESULT' if ok else 'MISMATCH'} (interrupts: outcome only)")
            continue
        diff, mine, h = lockstep(elf, s)
        i_out = h.uart_out.decode(errors="replace")
        ok = diff is None and h.tohost == 1 and s_out == i_out
        bad += not ok
        print(f"{Path(elf).name:14s} {h.instret:8,} instructions  {'MATCH' if ok else 'MISMATCH'}")
        if diff is not None:
            exp = s[diff] if diff < len(s) else None
            print(f"   first difference at #{diff}: spike {exp and tuple(hex(v) for v in exp)}  "
                  f"iss {mine and tuple(hex(v) for v in mine)}")
        elif s_out != i_out:
            print(f"   UART output differs: spike {s_out!r} iss {i_out!r}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
