#!/usr/bin/env python3
"""Branch-predictor accuracy study (docs/bp_report.md).

Runs each program on the reference ISS, extracts conditional branches, and
replays them through bit-exact models of the predictors (model/tage_model.py;
the TT TAGE model is checked against the RTL by test/test_rv_tage.py).
History is perfect (updated with real outcomes), as in trace-driven studies.
Needs sw/build/*.elf (cd sw && make; sw/coremark/get_and_build.sh)."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
from tage_model import Bimodal, Tage  # noqa: E402
from traces import branch_trace       # noqa: E402

PREDICTORS = [
    ("Bimodal 64 x 2b (TT base alone)", lambda: Bimodal(64), 12, 128),
    ("TAGE, TT build: 64 base + 2 x 16 tagged (hist 4, 12)", lambda: Tage(), 12, 128 + 2 * 16 * (6 + 3 + 2)),
    ("Bimodal 2048 x 2b", lambda: Bimodal(2048), 12, 4096),
    ("TAGE, FULL build: 2048 base + 4 x 512 tagged (hist 5, 15, 44, 130)",
     lambda: Tage(pc_w=23, ghr_len=130, base_entries=2048, nt=4, entries=512, tag_w=10,
                  hlens=(5, 15, 44, 130), reset_log=18), 130, 4096 + 4 * 512 * 15),
]
PROGS = ["coremark", "branchy", "sort", "crc", "arith"]


def replay(pred, trace, glen):
    ghr, miss, mask = 0, 0, (1 << glen) - 1
    for pc, t in trace:
        p, meta = pred.predict(pc, ghr)
        miss += p != t
        pred.update(pc, ghr, t, meta)
        ghr = ((ghr << 1) | t) & mask
    return miss


def main():
    traces = {}
    for prog in PROGS:
        elf = ROOT / "sw" / "build" / f"{prog}.elf"
        if elf.exists():
            traces[prog] = branch_trace(str(elf), max_steps=20_000_000)
    lines = ["# Branch prediction study", "",
             "Conditional-branch mispredictions per 1,000 instructions (MPKI), lower is better.",
             "Programs run on the reference ISS (RV32EMAC, `-O2`); 4-byte fetch blocks; history",
             "updated with real outcomes. Regenerate with `python3 scripts/bp_study.py`.", "",
             "| Predictor | Storage (bits) | " + " | ".join(traces) + " |",
             "|---|---|" + "---|" * len(traces)]
    acc = ["| (instructions / conditional branches) | | " +
           " | ".join(f"{n:,} / {len(t):,}" for t, n in traces.values()) + " |"]
    for name, mk, glen, bits in PREDICTORS:
        cells = []
        for prog, (tr, n) in traces.items():
            miss = replay(mk(), tr, glen)
            cells.append(f"{miss / n * 1000:.1f}")
        lines.append(f"| {name} | {bits:,} | " + " | ".join(cells) + " |")
        print(name, cells)
    lines += acc
    (ROOT / "docs" / "bp_report.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
