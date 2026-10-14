#!/bin/sh
# Fetch CoreMark (github.com/eembc/coremark, not redistributed here) and build
# it for riscv-tt with the port in ./port. Output: ../build/coremark.elf
# Usage: sw/coremark/get_and_build.sh [ITERATIONS]      (SPIKE=1 for the Spike cross-check build)
set -e
here=$(cd "$(dirname "$0")" && pwd)
iters=${1:-1}
[ -d "$here/src" ] || git clone --depth 1 https://github.com/eembc/coremark.git "$here/src"
P=${PREFIX:-riscv64-unknown-elf-}
out="$here/../build"; lds="$here/../common/link.ld"; extra=""
if [ "$SPIKE" = 1 ]; then          # cross-check variant (see sw/Makefile)
  make -s -C "$here/.." build-link-spike.ld
  out="$here/../build-spike"; lds="$here/../build-link-spike.ld"; extra="-DSPIKE"
fi
mkdir -p "$out"
${P}gcc -march=rv32eac_zicsr_zifencei -mabi=ilp32e -O2 -g -ffreestanding -fno-builtin -nostdlib -nostartfiles \
  -I"$here/port" -I"$here/src" -I"$here/../common" -DITERATIONS=$iters -DPERFORMANCE_RUN=1 $extra \
  -T "$lds" -o "$out/coremark.elf" \
  "$here/../common/crt0.S" "$here/../common/rt.c" "$here/port/core_portme.c" \
  "$here/src/core_list_join.c" "$here/src/core_main.c" "$here/src/core_matrix.c" \
  "$here/src/core_state.c" "$here/src/core_util.c" -lgcc
${P}objdump -d "$out/coremark.elf" > "$out/coremark.dis"
echo "built $out/coremark.elf (ITERATIONS=$iters)"
