# riscv-tt

A pipelined RISC-V processor for Tiny Tapeout (SKY130, 8×2 tiles): a
5-stage in-order core with a decoupled, predicting frontend (BTB, direction
predictor, return address stack, fetch target queue), a non-blocking
instruction cache over AXI4, compressed instructions, and a small SoC on the
QSPI Pmod (flash + 2 PSRAMs), with a CLINT, UART and GPIO.

Two builds come from the same RTL:

| | TT (taped out) | FULL (simulation, `+define+RV_CFG_FULL`) |
|---|---|---|
| ISA | RV32EMAC + Zicsr + Zifencei, M-mode | RV64IMAC + Zicsr + Zifencei, M-mode |
| Frontend | 4-byte fetch, 1-wide decode | 16-byte fetch, 4-wide decode |
| Prediction | BTB 4, bimodal 64, RAS 2, FTQ 4 | BTB 1024, TAGE (2048 + 4 × 512), RAS 16, FTQ 16 |
| I-cache | 64 B direct mapped, 1 MSHR | 32 KB 4-way, 4 MSHRs |
| Memory | SPI flash + PSRAM (rv_spi_mem) | AXI4 / data-bus models |

The FULL build implements the `RISC-V_Project_Document` frontend (RV64IMAC,
TAGE, FTQ, non-blocking cache, N-wide decode). Every number, interface, pin
and the area decisions are in [`docs/spec.md`](docs/spec.md); the datasheet
page is [`docs/info.md`](docs/info.md).

## Status

Complete and verified in simulation; ready for the Tiny Tapeout GDS flow.

* **Frontend** (`src/bpu`, `src/ifu`, `src/decode`, `src/top/rv_frontend.sv`)
* **Backend** (`src/backend`, `src/top/rv_core.sv`): ID/EX/MEM/WB with
  forwarding, iterative mul/div, LR/SC and AMOs, CSRs, precise traps,
  timer and software interrupts, cycle/instret and event counters.
* **SoC and TT top** (`src/soc`, `src/top/tt_um_rvcore.sv`)

### Verification

| Level | What | Result |
|---|---|---|
| Unit | every block against a Python model (cocotb + Icarus), TT and FULL shapes | all pass |
| Decoder / RVC | GNU-as vectors and objdump; all 65,536 compressed parcels vs Ibex | exact match |
| Reference ISS | `model/rv_iss.py` vs Spike, every retired instruction | 11 programs incl. CoreMark match; irq: same result |
| Frontend | real programs fetched over AXI, uop stream vs the ISS | 8 TT + 7 FULL programs |
| Core | `rv_core` in lockstep with the ISS at every commit, random memory latency | 10 TT + 9 FULL programs, CoreMark, 4 with zero-latency memory |
| Chip | `tt_um_rvcore` with SPI flash/PSRAM models, UART decoded from the pin, lockstep | 8 programs |
| TT CI | `test/test.py` on the pins only (also runs on the gate-level netlist) | pass |
| Planted bugs | mutations of the RTL must fail some test | 39/39 frontend, 8/8 backend and SoC |

Test programs (`sw/tests`): hello, arith (M extension corners), traps (every
exception and CSR rule), irq (timer and software interrupts, vectored mode,
MIE masking windows, counters), atomics, selfmod (fence.i), pipe (hazards),
crc, branchy, sort, io (UART receive, GPIO), tt_ci, plus CoreMark.

### Measured (simulation)

| | TT core, fast memory | TT chip, SPI memories |
|---|---|---|
| IPC | 0.18-0.39 (crc 0.39, sort 0.28) | 0.01-0.14 (SPI line refill about 330 cycles) |
| Branch MPKI | crc 15.8, sort 21.9 (bimodal) | |

FULL core: IPC up to 0.90 (crc), mispredicts 1.3 MPKI on crc with TAGE.
Branch-predictor study (MPKI per predictor and program): [`docs/bp_report.md`](docs/bp_report.md).

### Area (`make area`, Yosys + ABC on SKY130 cells)

| Part | µm² | Tiles (at 65 % density) |
|---|---|---|
| Frontend | 65,967 | 5.65 |
| Backend | 81,386 | 6.97 |
| SPI controller + CLINT + UART | 19,807 | 1.70 |
| **tt_um_rvcore** | **166,158** | **14.2 of 16** |

The estimate has no buffers or clock tree and no complex cells, so treat it
as ±15 %. The GDS action gives the real number. `src/config.json` sets
`PL_TARGET_DENSITY_PCT` to 70. If placement fails, spec section 6 lists the
next cuts.

## Running

Tools: Icarus Verilog 12, Verilator 5, Yosys 0.33+, Python 3 with
`cocotb==2.1.*` and `pytest`, `gcc-riscv64-unknown-elf` (Ubuntu 24.04
packages). Optional: Spike for `make iss-check`.

```sh
make sw        # build the test programs (RV32E, RV64) and CoreMark
make lint      # Verilator -Wall: TT, FULL, XLEN=64, latch arrays
make synth     # Yosys synthesis of every module
make test      # all cocotb tests (unit, frontend, core, chip); about 1-2 hours
make tt-test   # the Tiny Tapeout CI test only
make area      # area estimate of the chip and its parts
make iss-check # reference ISS vs Spike (needs Spike)
make bp-study  # regenerate docs/bp_report.md
```

One test file: `cd test && python3 -m pytest -q test_rv_core.py`.
One program: `cd test && python3 -m pytest -q "test_soc.py::test_soc[hello]"`.
Another seed: `SEED=7 make test`.

## Tiny Tapeout submission

1. Fill in `author` (and `discord`) in `info.yaml`. TT asks for a top
   module name that includes your GitHub username: if you rename
   `tt_um_rvcore`, rename it in `info.yaml`, `src/top/tt_um_rvcore.sv`
   (module and file), `test/tb.v`, `test/test_soc.py`, the Makefile `TOP`
   line and `scripts/area_est.py`.
2. Push to GitHub and enable Actions and Pages. The `gds` workflow hardens the
   design, runs the precheck and the gate-level test; `docs` builds the
   datasheet; `test` runs the TT CI test; `ci` runs the full suite.
3. Submit the repository on app.tinytapeout.com for the SKY26d shuttle.

Programming the board: `riscv64-unknown-elf-objcopy -O binary prog.elf prog.bin`,
write it at offset 0 of the Pmod flash with `ui_in[0]` (HALT) high, then
release HALT. UART is 115200 8N1 at 25 MHz.

## Layout

```
docs/spec.md        frozen spec: ISA, parameters, interfaces, pins, memory map, area decisions
docs/info.md        Tiny Tapeout datasheet page
docs/bp_report.md   branch-predictor study
info.yaml           Tiny Tapeout project file
src/pkg/            frontend_pkg.sv: parameters (TT and FULL) and interface types
src/bpu/            BTB, TAGE, bimodal, RAS, GHR, FTQ, BPU
src/ifu/            I-cache, MSHRs, AXI read master, aligner, IQ, fetch unit
src/decode/         RVC expander, immediates, decoder, decode group
src/backend/        register file, ALU, mul/div, LSU, CSRs, pipeline
src/soc/            SPI memory controller, CLINT, UART, SoC
src/top/            rv_frontend, rv_core, tt_um_rvcore
src/common/         FIFO, skid buffer, SRAM wrapper (flop or latch), arbiter, clock gate
model/              reference ISS (rv_iss.py), TAGE model, trace tools
sw/                 runtime, linker script, test programs, CoreMark port
test/               cocotb tests (one per block + system), SPI/AXI models, TT CI test
scripts/            area estimate, vector generation, ISS vs Spike, predictor study
```

## Known limits

* Plain single-bit SPI: memory-bound on silicon. Quad SPI is the natural next step.
* The TT build has no TAGE (area); it can be switched back on in the package
  (`TAGE_NTABLES = 2`, `GHR_LEN = 12`) if the hardened design has room.
* For a compressed instruction that is illegal only because it names x16-x31,
  `mtval` holds the expanded 32-bit form.
* Writes to `mcountinhibit` apply to the writing instruction itself (as in the
  reference ISS; Spike ignores `mcountinhibit.IR`).
