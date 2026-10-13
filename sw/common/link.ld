/* riscv-tt memory map (docs/spec.md section 5).
   Code and read-only data execute in place from QSPI flash; .data and .bss
   live in PSRAM, with .data's initial values copied from flash by crt0. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 16M
  PSRAM (rwx) : ORIGIN = 0x01000000, LENGTH = 16M
  MMIO  (rw)  : ORIGIN = 0x10000000, LENGTH = 4K
}

SECTIONS {
  .text : {
    KEEP(*(.text.init))
    *(.text .text.*)
    *(.rodata .rodata.* .srodata .srodata.*)
    . = ALIGN(4);
  } > FLASH

  .data : {
    __data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  } > PSRAM AT > FLASH
  __data_load = LOADADDR(.data);

  .bss (NOLOAD) : {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > PSRAM

  __stack_top = ORIGIN(PSRAM) + LENGTH(PSRAM) - 16;
  __global_pointer$ = __data_start + 0x800;

  /* simulation exit register; Spike's HTIF also finds it by this name */
  tohost = 0x10000300;
  fromhost = 0x10000308;
}
