#!/usr/bin/env python3
"""Estimate SKY130 area of RTL modules with Yosys + ABC.

Maps to a small subset of sky130_fd_sc_hd cells (areas taken from the PDK's
tt_025C_1v80 liberty data). No timing, no buffering, no placement density
effects, so treat results as a lower bound: the TT flow typically needs
20-40 % more once buffers and clock tree are added.

Usage:
  scripts/area_est.py                       # every Level 0 block at TT sizes
  scripts/area_est.py --level1              # Level 1 blocks at TT sizes
  scripts/area_est.py --chip                # TT top and its parts (the last line is the total)
  scripts/area_est.py rv_fifo W=32 DEPTH=8  # one module with parameters
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
TILE_UM2 = 161.0 * 111.52          # one SKY130 TT tile
DENSITY = 0.65                     # usable fraction after placement and routing

# name: (area um^2, liberty body)
CELLS = {
    "inv_1":   (3.7536,  'pin(A){direction:input;} pin(Y){direction:output;function:"!A";}'),
    "buf_1":   (3.7536,  'pin(A){direction:input;} pin(X){direction:output;function:"A";}'),
    "nand2_1": (3.7536,  'pin(A){direction:input;} pin(B){direction:input;} pin(Y){direction:output;function:"!(A&B)";}'),
    "nor2_1":  (3.7536,  'pin(A){direction:input;} pin(B){direction:input;} pin(Y){direction:output;function:"!(A|B)";}'),
    "and2_1":  (6.256,   'pin(A){direction:input;} pin(B){direction:input;} pin(X){direction:output;function:"(A&B)";}'),
    "or2_1":   (6.256,   'pin(A){direction:input;} pin(B){direction:input;} pin(X){direction:output;function:"(A|B)";}'),
    "xor2_1":  (8.7584,  'pin(A){direction:input;} pin(B){direction:input;} pin(X){direction:output;function:"(A^B)";}'),
    "xnor2_1": (8.7584,  'pin(A){direction:input;} pin(B){direction:input;} pin(Y){direction:output;function:"!(A^B)";}'),
    "nand3_1": (5.0048,  'pin(A){direction:input;} pin(B){direction:input;} pin(C){direction:input;} pin(Y){direction:output;function:"!(A&B&C)";}'),
    "nor3_1":  (5.0048,  'pin(A){direction:input;} pin(B){direction:input;} pin(C){direction:input;} pin(Y){direction:output;function:"!(A|B|C)";}'),
    "a21oi_1": (5.0048,  'pin(A1){direction:input;} pin(A2){direction:input;} pin(B1){direction:input;} pin(Y){direction:output;function:"!((A1&A2)|B1)";}'),
    "o21ai_0": (5.0048,  'pin(A1){direction:input;} pin(A2){direction:input;} pin(B1){direction:input;} pin(Y){direction:output;function:"!((A1|A2)&B1)";}'),
    "mux2_1":  (11.2608, 'pin(A0){direction:input;} pin(A1){direction:input;} pin(S){direction:input;} pin(X){direction:output;function:"((A0&!S)|(A1&S))";}'),
    "dfxtp_1": (20.0192, 'ff(IQ,IQN){clocked_on:"CLK";next_state:"D";} pin(CLK){direction:input;clock:true;} pin(D){direction:input;} pin(Q){direction:output;function:"IQ";}'),
    "dfrtp_1": (25.024, 'ff(IQ,IQN){clocked_on:"CLK";next_state:"D";clear:"!RESET_B";} pin(CLK){direction:input;clock:true;} pin(D){direction:input;} pin(RESET_B){direction:input;} pin(Q){direction:output;function:"IQ";}'),
    "dlxtp_1": (15.0144, 'latch(IQ,IQN){enable:"GATE";data_in:"D";} pin(GATE){direction:input;} pin(D){direction:input;} pin(Q){direction:output;function:"IQ";}'),
    "dlxtn_1": (15.0144, 'latch(IQ,IQN){enable:"!GATE_N";data_in:"D";} pin(GATE_N){direction:input;} pin(D){direction:input;} pin(Q){direction:output;function:"IQ";}'),
}

# Yosys 0.33's dfflibmap does not map latches, so map them explicitly.
LATCH_MAP = """
module \\$_DLATCH_P_ (input E, input D, output Q);
  sky130_fd_sc_hd__dlxtp_1 _TECHMAP_REPLACE_ (.GATE(E), .D(D), .Q(Q));
endmodule
module \\$_DLATCH_N_ (input E, input D, output Q);
  sky130_fd_sc_hd__dlxtn_1 _TECHMAP_REPLACE_ (.GATE_N(E), .D(D), .Q(Q));
endmodule
"""

# Level 0 blocks at TT-config sizes (docs/spec.md section 3)
DEFAULT_JOBS = [
    ("rv_sat_counter", {"W": 3}),
    ("rv_ghr", {"LEN": 12}),
    ("rv_hist_fold", {"LEN": 12, "W": 4}),
    ("rv_fold_step", {"LEN": 12, "W": 4}),
    ("rv_tage_hash", {"PC_W": 31, "HLEN": 12, "IDX_W": 4, "TAG_W": 6}),
    ("rv_plru", {"WAYS": 2}),
    ("rv_tag_cmp", {"WAYS": 2, "TAG_W": 25}),
    ("rv_ilen_detect", {"NP": 2}),
    ("rv_fifo", {"W": 32, "DEPTH": 4}),
    ("rv_skid_buffer", {"W": 32}),
    ("rv_sram_1r1w", {"W": 32, "DEPTH": 16}),
    ("rv_rr_arbiter", {"N": 2}),
    ("rv_rvc_expand", {"XLEN": 32}),
    ("rv_imm_gen", {"XLEN": 32}),
]

# The whole TT build and its main parts (scripts/area_est.py --chip)
CHIP_JOBS = [
    ("rv_frontend", {}),
    ("rv_backend", {}),
    ("rv_spi_mem", {}),
    ("rv_clint", {}),
    ("rv_uart", {}),
    ("tt_um_rvcore", {}),
]

# Level 1 blocks at TT sizes, latch arrays (docs/spec.md section 3)
LEVEL1_JOBS = [
    ("rv_decoder", {}),
    ("rv_aligner", {}),
    ("rv_btb", {"ENTRIES": 8, "TAG_W": 6, "LATCH": 1, "TGT_W": 25}),
    ("rv_ras", {"DEPTH": 4, "W": 24}),
    ("rv_bimodal", {"ENTRIES": 64, "CTR_W": 2, "LATCH": 1}),
    ("rv_tage_table", {"ENTRIES": 16, "TAG_W": 6, "CTR_W": 3, "U_W": 2, "LATCH": 1}),
    ("rv_tage_table", {"ENTRIES": 16, "TAG_W": 6, "CTR_W": 3, "U_W": 2, "LATCH": 1}),
    ("rv_icache_arrays", {"WAYS": 1, "SETS": 4, "LINE_BYTES": 16, "BEAT_BYTES": 4, "FETCH_BYTES": 4, "PW": 25, "LATCH": 1}),
    ("rv_mshr_file", {"N": 1, "PW": 25, "LINE_BYTES": 16, "BEAT_BYTES": 4, "WAYS": 1}),
]


def liberty():
    body = "\n".join(f"  cell(sky130_fd_sc_hd__{n}) {{ area : {a}; {b} }}" for n, (a, b) in CELLS.items())
    return "library(sky130_min) {\n" + body + "\n}\n"


def sources():
    return ([str(SRC / "pkg" / "frontend_pkg.sv")] + sorted(str(p) for p in SRC.rglob("rv_*.sv"))
            + [str(SRC / "top" / "tt_um_rvcore.sv")])


def estimate(top, params, lib):
    latch_map = Path(lib).with_name("latch_map.v")
    latch_map.write_text(LATCH_MAP)
    chparam = " ".join(f"-set {k} {v}" for k, v in params.items())
    script = (f"read_verilog -sv {' '.join(sources())}; "
              f"{'chparam ' + chparam + ' ' + top + ';' if params else ''} "
              f"hierarchy -top {top}; synth -flatten -top {top}; "
              f"dfflegalize -cell $_DFF_P_ 01 -cell $_DFF_PN0_ 01 -cell $_DLATCH_P_ 01; "
              f"dfflibmap -liberty {lib}; techmap -map {latch_map}; abc -liberty {lib}; opt_clean; "
              f"stat -liberty {lib}")
    res = subprocess.run(["yosys", "-p", script], capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(res.stderr[-2000:] or res.stdout[-2000:])
    m = re.findall(r"Chip area for (?:module|top module) '.*?': ([0-9.]+)", res.stdout)
    cells = re.findall(r"Number of cells:\s+(\d+)", res.stdout)
    flops = re.findall(r"sky130_fd_sc_hd__dfxtp_1\s+(\d+)", res.stdout)
    latches = re.findall(r"sky130_fd_sc_hd__dlxt[pn]_1\s+(\d+)", res.stdout)
    if "is unknown" in res.stdout:
        raise RuntimeError(f"{top}: unmapped cells in area report")
    return float(m[-1]), int(cells[-1]), int(flops[-1]) if flops else 0, int(latches[-1]) if latches else 0


def main():
    args = sys.argv[1:]
    if not args:
        jobs = DEFAULT_JOBS
    elif args[0] == "--level1":
        jobs = LEVEL1_JOBS
    elif args[0] == "--chip":
        jobs = CHIP_JOBS
    else:
        jobs = [(args[0], dict(a.split("=") for a in args[1:]))]
    with tempfile.TemporaryDirectory() as d:
        lib = Path(d) / "sky130_min.lib"
        lib.write_text(liberty())
        total = 0.0
        print(f"{'module':<16} {'params':<34} {'cells':>6} {'ff+lat':>6} {'area um2':>10} {'tiles':>6}")
        for top, params in jobs:
            area, cells, flops, latches = estimate(top, params, lib)
            total += area
            p = ",".join(f"{k}={v}" for k, v in params.items())
            print(f"{top:<16} {p:<34} {cells:>6} {flops + latches:>6} {area:>10.0f} {area / (TILE_UM2 * DENSITY):>6.2f}")
        if len(jobs) > 1 and jobs is not CHIP_JOBS:
            print(f"{'total':<16} {'':<34} {'':>6} {'':>6} {total:>10.0f} {total / (TILE_UM2 * DENSITY):>6.2f}")
        print(f"(tile = {TILE_UM2:.0f} um2 at {DENSITY:.0%} density = {TILE_UM2 * DENSITY:.0f} um2 of cells)")


if __name__ == "__main__":
    main()
