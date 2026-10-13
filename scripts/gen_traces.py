#!/usr/bin/env python3
"""Branch traces from the sw/ programs (run on the reference ISS), checked in
as test/vectors/bp_<prog>.json so the predictor tests need no toolchain.
Each file: {"insns": N, "trace": [[block, taken], ...]}."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
from traces import branch_trace  # noqa: E402

for prog in ("crc", "branchy", "sort", "arith"):
    tr, n = branch_trace(str(ROOT / "sw" / "build" / f"{prog}.elf"))
    (ROOT / "test" / "vectors" / f"bp_{prog}.json").write_text(json.dumps({"insns": n, "trace": tr}))
    print(f"{prog}: {n} instructions, {len(tr)} conditional branches")
