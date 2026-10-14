# Build the riscv-tt test programs (RV32EAC bare metal; the TT silicon has no M).
#   make            all programs in tests/
#   make FULL=1     RV64IMAC versions for the FULL frontend tests
#   make SPIKE=1    variants for cross-checking against Spike (flash at 0x2000_0000)
PREFIX ?= riscv64-unknown-elf-
CC := $(PREFIX)gcc
OBJDUMP := $(PREFIX)objdump
ifeq ($(SPIKE),1)
EXTRA := -DSPIKE
endif
ifeq ($(FULL),1)
ARCH := -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany
OUT := build64
else
ARCH := -march=rv32eac_zicsr_zifencei -mabi=ilp32e
OUT := build
endif
ifeq ($(SPIKE),1)
OUT := $(OUT)-spike
LINK := build-link-spike.ld
else
LINK := common/link.ld
endif
CFLAGS := $(EXTRA) $(ARCH) -O2 -g -ffreestanding -fno-builtin -nostdlib -nostartfiles -Icommon -Wall -Wextra
SRCS := $(wildcard tests/*.c)
ELFS := $(patsubst tests/%.c,$(OUT)/%.elf,$(SRCS))

all: $(ELFS)

$(OUT)/%.elf: tests/%.c common/crt0.S common/rt.c common/rt.h $(LINK)
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -T $(LINK) -o $@ common/crt0.S common/rt.c $< -lgcc
	$(OBJDUMP) -d $@ > $(@:.elf=.dis)

# Spike reserves [0, 0x1000) for its debug module, so cross-check builds put
# flash at 0x2000_0000 (make SPIKE=1).
build-link-spike.ld: common/link.ld
	sed -e 's/FLASH (rx)  : ORIGIN = 0x00000000/FLASH (rx)  : ORIGIN = 0x20000000/' \
	    -e 's/tohost = 0x10000300;/tohost = 0x01FFF000;/' -e 's/fromhost = 0x10000308;/fromhost = 0x01FFF008;/' \
	    -e 's/LENGTH(PSRAM) - 16;/LENGTH(PSRAM) - 0x2000;/' $< > $@

clean:
	rm -rf build build64 build-spike build64-spike build-link-spike.ld
.PHONY: all clean
