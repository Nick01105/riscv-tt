"""Shared helpers for the cocotb unit tests.

Each test_<module>.py holds the cocotb coroutines for one RTL module plus a
pytest function that builds and runs it (once per parameter set).
Run everything with:  make test      (or: cd test && python -m pytest -q)
Pick a simulator with SIM=icarus (default) or SIM=verilator.
"""
import json
import os
import random
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
TEST = ROOT / "test"
PKG = SRC / "pkg" / "frontend_pkg.sv"


def rtl(*modules):
    """Paths of the RTL files for the given module names (searched under src/)."""
    out = []
    for m in modules:
        hits = list(SRC.rglob(f"{m}.sv"))
        assert len(hits) == 1, f"expected one file for {m}, found {hits}"
        out.append(hits[0])
    return out


def run(toplevel, sources, test_module, params=None, defines=None, extra_sources=(), extra_env_params=None):
    """Build `toplevel` with `params`, run the cocotb tests in `test_module`."""
    sim = os.getenv("SIM", "icarus")
    params = dict(params or {})
    defines = dict(defines or {})
    tag = "_".join(f"{k}{v}" for k, v in sorted({**params, **defines}.items())) or "default"
    tag = "".join(ch if ch.isalnum() or ch in "_-" else "_" for ch in tag)[:150]
    build_dir = TEST / "sim_build" / sim / f"{toplevel}_{tag}"

    runner = get_runner(sim)
    build_args = ["-Wno-fatal"] if sim == "verilator" else []
    runner.build(
        sources=[PKG, *sources, *extra_sources],
        hdl_toplevel=toplevel,
        parameters=params,
        defines=defines,
        build_dir=build_dir,
        build_args=build_args,
        always=True,
        timescale=("1ns", "1ps"),
    )
    xml = runner.test(
        hdl_toplevel=toplevel,
        test_module=test_module,
        test_dir=TEST,
        build_dir=build_dir,
        extra_env={"DUT_PARAMS": json.dumps({**params, **defines, **(extra_env_params or {})})},
        seed=int(os.getenv("SEED", "12345")),
    )
    num_tests, num_failed = get_results(xml)
    assert num_tests > 0, f"no cocotb tests ran for {toplevel}"
    assert num_failed == 0, f"{num_failed} of {num_tests} cocotb tests failed for {toplevel} {tag}"


# ---- helpers used inside cocotb coroutines ---------------------------------

def params():
    """Parameters the current DUT was built with (set by run())."""
    return json.loads(os.environ.get("DUT_PARAMS", "{}"))


def u(sig):
    """Read a signal as an unsigned int."""
    v = sig.value
    return v.to_unsigned() if hasattr(v, "to_unsigned") else int(v)


def ubits(sig, lo, width):
    """Unsigned value of sig[lo +: width], ignoring X/Z in other bits."""
    bits = str(sig.value)                      # MSB first
    n = len(bits)
    seg = bits[n - lo - width:n - lo]
    return int(seg, 2)


def rng():
    return random.Random(int(os.getenv("SEED", "12345")))
