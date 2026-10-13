#!/bin/sh
# Cross-check rv_rvc_expand against Ibex's compressed decoder.
# Usage: IBEX_DIR=/path/to/ibex test/xcheck/ibex/run.sh
# Get Ibex with: git clone --depth 1 https://github.com/lowRISC/ibex.git
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
: "${IBEX_DIR:?set IBEX_DIR to an Ibex checkout}"
obj="$here/obj_dir"
verilator --cc --exe --build -O2 -Wno-fatal -Wno-lint -Wno-style \
  --top-module tb_xcheck -Mdir "$obj" -I"$here" \
  "$IBEX_DIR/rtl/ibex_pkg.sv" "$IBEX_DIR/rtl/ibex_compressed_decoder.sv" \
  "$root/src/decode/rv_rvc_expand.sv" "$here/tb_xcheck.sv" "$here/main.cpp" >/dev/null
cd "$here" && "$obj/Vtb_xcheck"
