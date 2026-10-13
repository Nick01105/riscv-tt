# Makefile for the Tiny Tapeout test (test.py), RTL or gate level (GATES=yes).
# The project's own test suite is run with pytest instead: see ../README.md.
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = pkg/frontend_pkg.sv \
                  backend/rv_alu.sv \
                  backend/rv_backend.sv \
                  backend/rv_csr.sv \
                  backend/rv_lsu.sv \
                  backend/rv_muldiv.sv \
                  backend/rv_regfile.sv \
                  bpu/rv_bimodal.sv \
                  bpu/rv_bpu.sv \
                  bpu/rv_btb.sv \
                  bpu/rv_fold_step.sv \
                  bpu/rv_ftq.sv \
                  bpu/rv_ghr.sv \
                  bpu/rv_hist_fold.sv \
                  bpu/rv_ras.sv \
                  bpu/rv_sat_counter.sv \
                  bpu/rv_tage.sv \
                  bpu/rv_tage_hash.sv \
                  bpu/rv_tage_table.sv \
                  common/rv_axi_rd_slice.sv \
                  common/rv_clock_gate.sv \
                  common/rv_fifo.sv \
                  common/rv_rr_arbiter.sv \
                  common/rv_skid_buffer.sv \
                  common/rv_sram_1r1w.sv \
                  decode/rv_decode_group.sv \
                  decode/rv_decoder.sv \
                  decode/rv_imm_gen.sv \
                  decode/rv_rvc_expand.sv \
                  ifu/rv_aligner.sv \
                  ifu/rv_axi_rd_master.sv \
                  ifu/rv_icache.sv \
                  ifu/rv_icache_arrays.sv \
                  ifu/rv_ifu.sv \
                  ifu/rv_ilen_detect.sv \
                  ifu/rv_iq.sv \
                  ifu/rv_mshr_file.sv \
                  ifu/rv_plru.sv \
                  ifu/rv_tag_cmp.sv \
                  soc/rv_clint.sv \
                  soc/rv_soc.sv \
                  soc/rv_spi_mem.sv \
                  soc/rv_uart.sv \
                  top/rv_core.sv \
                  top/rv_frontend.sv \
                  top/tt_um_rvcore.sv

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
COMPILE_ARGS    += -g2012

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
