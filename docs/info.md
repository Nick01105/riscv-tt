<!---
This file is used to generate the project datasheet.
-->

## How it works

riscv-tt is a pipelined RISC-V processor (RV32EAC + Zicsr + Zifencei,
machine mode) with a decoupled, predicting frontend:

- **Branch prediction**: a 2-stage predictor with a BTB (2 entries), a
  bimodal direction predictor (64 × 2-bit), a return address stack and a
  fetch target queue (FTQ) that holds every predicted block until it
  commits, with history and RAS checkpoints for repair. The same RTL builds
  a TAGE predictor (enabled in the larger simulation-only configuration).
- **Instruction fetch**: a 32-byte direct-mapped instruction cache with a
  non-blocking miss handler and an AXI4 read master (critical word first),
  an aligner for compressed instructions (including ones that cross a fetch
  block), and a decoder.
- **Backend**: ID → EX → MEM → WB with forwarding, branch resolution in EX,
  precise exceptions and interrupts taken at the commit point (MEM), LR/SC
  and AMOs, and the machine CSRs (mcycle, minstret). Multiply and divide run
  in software (the RTL's iterative M unit is left out of this build to fit).
- **SoC**: a plain-SPI controller for the QSPI Pmod (flash for code, two
  PSRAMs for data), a SiFive-style CLINT (timer and software interrupts), a
  UART and GPIO.

Memory map: flash `0x0000_0000` (16 MB, execute in place, reset vector 0),
PSRAM A `0x0100_0000`, PSRAM B `0x0180_0000`, CLINT `0x0200_0000`,
UART `0x1000_0000` (+0 data, +4 status: bit 0 TX ready, bit 1 RX valid,
+8 divisor; one bit = divisor + 1 clocks, reset value 216 = 115200 baud at
25 MHz), GPIO `0x1000_0100` (+0 out, 7 bits; +4 in, 6 bits).

## How to test

1. Build a program (`sw/` in the repository: `make -C sw`, needs
   `riscv64-unknown-elf-gcc`), convert it with
   `riscv64-unknown-elf-objcopy -O binary prog.elf prog.bin`, and write
   `prog.bin` to the flash on the QSPI Pmod at offset 0.
2. Hold `ui_in[0]` (HALT) high while programming: the core is held in reset
   and every Pmod pin is an input, so the RP2040 can drive the flash.
3. Release HALT. The core boots from flash; `crt0` copies initialised data to
   PSRAM. Output appears on the UART (`uo_out[4]`, 115200 8N1 at 25 MHz).
   The test programs print "... ok" and write the result to TOHOST.

GPIO out bits 3:0 appear on `uo_out[3:0]` and bits 6:4 on `uo_out[7:5]`;
GPIO in is `{ui_in[7:4], ui_in[2:1]}`.

## External hardware

- QSPI Pmod (flash on CS0, PSRAM on CS1 and CS2), used in single-bit SPI mode.
- UART: the demo board's RP2040 (`ui_in[3]` RX, `uo_out[4]` TX) or any
  3.3 V USB-UART adapter.
