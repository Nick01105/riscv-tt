# riscv-tt build entry points
#   make lint      Verilator -Wall on every module, TT and FULL configs
#   make synth     Yosys synthesis of every module (synthesizability check)
#   make test      cocotb unit tests (Icarus)
#   make area      SKY130 area estimate: the TT chip and its parts
#   make vectors   regenerate decode test vectors with GNU binutils
#   make xcheck    RVC expander vs Ibex (needs IBEX_DIR)
#   make sw        build the test programs, RV32E and RV64 (needs gcc-riscv64-unknown-elf)
#   make tt-test   the Tiny Tapeout CI test (test/test.py) on the RTL
#   make iss-check reference ISS vs Spike, every retired instruction (needs Spike)
#   make bp-study  branch-predictor accuracy report -> docs/bp_report.md
#   make all       lint + synth + test

PKG     := src/pkg/frontend_pkg.sv
TOP     := src/top/tt_um_rvcore.sv
RTL     := $(sort $(wildcard src/*/rv_*.sv)) $(TOP)
MODULES := $(basename $(notdir $(RTL)))
# the SoC and the TT top exist only for the TT build (32-bit buses)
TT_ONLY := rv_spi_mem rv_soc tt_um_rvcore

.PHONY: all lint synth test area vectors xcheck sw iss-check bp-study tt-test clean

all: lint synth test

lint:
	@set -e; for cfg in "" "-DRV_CFG_FULL"; do \
	  verilator --lint-only -Wall $$cfg $(PKG) test/pkg/pkg_smoke.sv --top-module pkg_smoke; \
	  for m in $(MODULES); do \
	    if [ -n "$$cfg" ] && echo " $(TT_ONLY) " | grep -q " $$m "; then continue; fi; \
	    verilator --lint-only -Wall $$cfg $(PKG) $(RTL) --top-module $$m; \
	  done; \
	done; \
	for m in rv_rvc_expand rv_imm_gen; do \
	  verilator --lint-only -Wall -GXLEN=64 $(PKG) $(RTL) --top-module $$m; \
	done; \
	for m in rv_sram_1r1w rv_regfile; do \
	  verilator --lint-only -Wall -GLATCH=1 $(PKG) $(RTL) --top-module $$m; \
	done; \
	echo "lint: $(words $(MODULES)) modules clean (TT, FULL, XLEN=64, LATCH=1)"

synth:
	@set -e; for m in $(MODULES) pkg_smoke; do \
	  yosys -q -p "read_verilog -sv $(PKG) $(RTL) test/pkg/pkg_smoke.sv; hierarchy -top $$m; synth -top $$m" \
	    || { echo "synth FAILED: $$m"; exit 1; }; \
	done; echo "synth: $(words $(MODULES)) modules OK"

test:
	cd test && python3 -m pytest -q

tt-test:
	cd test && $(MAKE) -B && python3 -m cocotb_tools.check_results results.xml

area:
	python3 scripts/area_est.py --chip

vectors:
	python3 scripts/gen_vectors.py

xcheck:
	test/xcheck/ibex/run.sh

sw:
	$(MAKE) -C sw
	$(MAKE) -C sw FULL=1
	sw/coremark/get_and_build.sh 1

iss-check:
	$(MAKE) -C sw SPIKE=1
	SPIKE=1 sw/coremark/get_and_build.sh 1
	python3 scripts/iss_vs_spike.py

bp-study: sw
	python3 scripts/bp_study.py

clean:
	rm -rf test/sim_build test/results.xml test/*.result.xml test/__pycache__ test/.pytest_cache test/xcheck/ibex/obj_dir
