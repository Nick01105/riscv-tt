# riscv-tt — frozen spec (v0.2, 13 Oct 2026)

This file is the single source of truth for parameters and interfaces. The
RTL reads every number from `src/pkg/frontend_pkg.sv`, which must match the
tables below. Change a value here first, then in the package, in the same commit.

## 1. Target and scope

| Item | Decision |
|---|---|
| Tapeout target | Tiny Tapeout SKY26d (SkyWater 130 nm), up to 16 tiles; GF26c as fallback |
| Top module | `tt_um_rvcore` |
| Clock | 50 MHz target (TT maximum). QSPI SCK = clk/2 |
| Reset | `rst_n`, active low, synchronous |
| Doc milestone | Frontend RTL verified by 26 Oct (from `RISC-V_Project_Document`) |
| Submission | Before the shuttle closes, target 25 Nov |

## 2. ISA

| Build | ISA | Privilege | Addressing |
|---|---|---|---|
| `TT` (default) | RV32EAC + Zicsr + Zifencei (M removed 14 Oct, see section 6) | M-mode only | physical, no iTLB |
| `FULL` (`+define+RV_CFG_FULL`) | RV64IMAC + Zicsr + Zifencei | M-mode only | physical, no iTLB |

The project document asks for RV64IMAC. RV64 doubles the register file
(31 × 64 bits ≈ 2,000 storage cells) and every datapath, which the 16-tile
budget in section 6 cannot absorb. So both builds exist: `FULL` meets the
document's milestone in simulation, `TT` is what gets hardened. Every Level 0
block that depends on XLEN (RVC expander, immediate generator) supports both.

The TT build is RV32**E** (16 registers, decision of 13 Oct, section 6).
Instructions that name x16–x31 raise an illegal-instruction exception.
Software is built with `-march=rv32eac_zicsr_zifencei -mabi=ilp32e`: multiply and divide
are libgcc calls. `HAS_M = 1` in the package brings the M unit back (FULL keeps it).

Compressed (C) is Zca only: no Zcb/Zcmp, and no compressed float/double
encodings (there is no F or D). Those encodings decode as illegal. HINT
encodings (for example `c.addi x0, n`, `c.li x0, n`) are legal and execute as
their base instruction, which writes x0 and has no effect. Reserved encodings
are illegal.

## 3. Parameters

| Parameter | Package name | TT | FULL (doc) |
|---|---|---|---|
| XLEN | `XLEN` | 32 | 64 |
| Physical address bits | `PADDR_W` | 32 | 64 |
| Fetch block | `FETCH_BYTES` | 4 B | 16 B |
| Decode width | `DECODE_W` | 1 | 4 |
| I-cache size | `IC_BYTES` | 64 B | 32 KB |
| I-cache ways | `IC_WAYS` | 1 (direct mapped) | 4 |
| I-cache line | `IC_LINE_BYTES` | 16 B | 64 B |
| MSHRs | `IC_MSHRS` | 1 | 4 |
| AXI data width | `AXI_DATA_W` | 32 | 64 |
| Refill burst | (derived) | 4 beats, WRAP | 8 beats, WRAP |
| AXI ID width | `AXI_ID_W` | 2 | 2 |
| BTB entries | `BTB_ENTRIES` | 4 | 1024 |
| BTB tag bits | `BTB_TAG_W` | 6 | 10 |
| Cache-tag / BTB-target address bits | `CACHE_PA_W` | 25 | 64 |
| Registers | `NREGS` (`RVE`) | 16 | 32 |
| RAS entries | `RAS_DEPTH` | 2 | 16 |
| RAS top in FTQ checkpoint | `RAS_CKPT_TOP` | no | yes |
| FTQ entries | `FTQ_DEPTH` | 4 | 16 |
| TAGE base (bimodal) entries | `TAGE_BASE_ENTRIES` | 64 | 2048 |
| TAGE tagged tables | `TAGE_NTABLES` | 0 (bimodal only) | 4 |
| Tagged-table entries | `TAGE_ENTRIES` | 16 | 512 |
| History lengths (geometric) | `TAGE_HIST_LEN` | (4, 12 if re-enabled) | 5, 15, 44, 130 |
| Tag width | `TAGE_TAG_W` | 6 | 10 |
| Global history length | `GHR_LEN` | 2 (unused) | 130 |
| Instruction queue | `IQ_DEPTH` | 2 parcels | 16 parcels |
| FTQ entries (minimum 3, see the package) | `FTQ_DEPTH` | 4 | 16 |
| Event counters | `HPM_N` × `HPM_W` | 2 × 32 bits | 4 × 64 bits |
| TAGE counter / useful bits | | 3 / 2 | 3 / 2 |

The refill burst is one cache line: `IC_LINE_BYTES / (AXI_DATA_W/8)` beats.
WRAP bursts start at the missing word, so the critical word returns first.

The TT values reflect the area decision in section 6. If the hardened design
is still over budget, the next knobs are, in order: TAGE tagged tables 2 → 1,
bimodal 64 → 32 entries, RAS 4 → 2.

## 4. Interfaces (`frontend_pkg.sv`)

The document's five interfaces, unchanged except for one note on item 4.

1. **BPU → fetch** `fetch_req_t`: `valid, pc, taken_mask, block_end, ftq_idx`.
   `taken_mask` has one bit per 16-bit parcel and marks the parcel where the
   predicted-taken instruction **ends** (at most one bit set). A 32-bit branch
   that straddles two fetch blocks therefore belongs to the second block, so
   the second half is always fetched before the redirect. The BTB is indexed
   the same way.
2. **Fetch → decode** `fetch_slot_t`: `valid, pc, raw32, is_rvc, pred_taken, fault, ftq_idx`.
   `raw32` is already expanded when `is_rvc` is set. `ftq_idx` was added so the
   backend can report branch outcomes against the right FTQ entry.
   An instruction that straddles two blocks takes the `ftq_idx` of the block
   where it ends (where its prediction lives) and the `pc` where it starts.
3. **Decode → backend** `uop_t`: see the package for fields.
4. **Backend → frontend** `redirect_t` (redirect and flush) and `br_resolve_t`
   (resolved branch: `pc, taken, target, br_type, mispredict, ftq_idx`).
   *Change from the document:* the history checkpoint is not carried by the
   backend. The FTQ already stores it per entry, so the frontend looks it up
   by `ftq_idx`. This avoids moving a 130-bit history through the backend
   pipeline. The predictor's training port `bp_train_t` carries the checkpoint.
5. **Cache → AXI** `refill_req_t` (`addr` of the missing word, `mshr`) and
   `refill_beat_t` (`data, last, err, mshr`).

AXI4 read channels use `axi_ar_t` and `axi_r_t`. Write channels are a
stretch goal for the load/store unit.

### Backend (`rv_backend`, `rv_core`)

* Scalar in-order pipeline: ID (register read) → EX (ALU, branch unit,
  iterative mul/div, address) → MEM (commit point: loads/stores/atomics,
  CSRs, traps) → WB (register-file write). Only slot 0 of a decode group is
  used, so the FULL build runs one uop per cycle in the backend.
* Forwarding from MEM and from the previous cycle's write; loads and CSR
  reads stall a dependent uop until the cycle after they complete. The
  register file is re-read every cycle for a stalled uop.
* Branches resolve in EX (mispredict redirect the same cycle). Traps, mret
  and fence.i redirect from MEM. Interrupts are sampled as a uop enters MEM.
* FTQ entries are freed by commit (MEM), not by resolve, so a MEM redirect
  always finds its entry.
* Data bus (`dreq_*`/`drsp_*`): one request at a time, held until ready; the
  response arrives in a later cycle with the aligned XLEN-bit word, or `err`
  (access fault). Byte enables and lane-aligned write data. Every access
  waits for its response (precise faults, no posted writes). AMOs are a read
  then a write; atomics outside PSRAM raise an access fault.
* CSRs: mstatus, misa, mie, mip, mtvec (direct/vectored), mscratch, mepc,
  mcause, mtval, mcountinhibit, mcycle, minstret (64-bit), mhpmcounter3-4
  (TT; 3-6 in FULL: mispredicts, I-cache misses, frontend-starved cycles,
  data-memory stall cycles), user aliases, ID registers (zero).
* The register file has no reset, so `crt0.S` zeroes every register.
* Known deviation: for a compressed instruction that is illegal only
  because it names x16-x31 (RV32E), mtval holds the expanded 32-bit form.

## 5. Tiny Tapeout pins and memory map

Check the pin numbers below against the current TT pinout page before
hardening. The QSPI assignment follows the TT QSPI Pmod.

| Pin | Use |
|---|---|
| `uio[0]` | QSPI CS0 (flash) |
| `uio[1]` | QSPI SD0 / MOSI |
| `uio[2]` | QSPI SD1 / MISO |
| `uio[3]` | QSPI SCK |
| `uio[4]` | QSPI SD2 |
| `uio[5]` | QSPI SD3 |
| `uio[6]` | QSPI CS1 (PSRAM A) |
| `uio[7]` | QSPI CS2 (PSRAM B) |
| `ui_in[3]` | UART RX (from the demoboard RP2040) |
| `uo_out[4]` | UART TX |
| `ui_in[0]` | Debug halt: hold the core stopped after reset |
| `ui_in[2:1]`, `ui_in[7:4]` | GPIO in |
| `uo_out[3:0]`, `uo_out[7:5]` | GPIO out |

| Address range | Region | Cacheable | Notes |
|---|---|---|---|
| `0x0000_0000`–`0x00FF_FFFF` | QSPI flash, 16 MB | yes (I) | execute in place, read-only; reset PC = `0x0000_0000` |
| `0x0100_0000`–`0x017F_FFFF` | PSRAM A, 8 MB | yes (I) | code and data |
| `0x0180_0000`–`0x01FF_FFFF` | PSRAM B, 8 MB | yes (I) | data |
| `0x0200_0000` | CLINT `msip` | no | SiFive CLINT layout |
| `0x0200_4000` | CLINT `mtimecmp` | no | |
| `0x0200_BFF8` | CLINT `mtime` | no | |
| `0x1000_0000` | UART | no | data, status, baud divisor |
| `0x1000_0100` | GPIO | no | |
| `0x1000_0300` | TOHOST | no | write: test result (simulation; harmless on silicon) |

Data accesses are uncached in the TT build. A D-cache is added only if the
area budget has room left after the I-cache.

The memories use plain single-bit SPI (`rv_spi_mem`): command 0x03 (read)
for flash and PSRAM, 0x02 (write) for PSRAM, SCK = clk/2. A 16-byte line
refill costs about 330 cycles, so the measured chip-level IPC is 0.01-0.15
(test_soc); quad mode is the obvious upgrade. SD2/SD3 are driven high
(WP#/HOLD#). While `ui_in[0]` (debug halt) is high the core is held in reset
and every `uio` pin is an input, so the RP2040 can program the flash.

UART: 8N1, one bit = divisor + 1 cycles, reset divisor 433 (115200 baud at
50 MHz). GPIO in is `{ui_in[7:4], ui_in[2:1]}`; GPIO out bits 3:0 go to
`uo_out[3:0]` and bits 6:4 to `uo_out[7:5]`.

## 6. Tile budget (TT build, estimates)

A SKY130 tile is about 161 × 111 µm ≈ 18,000 µm². At a placement density of
about 65 %, a tile holds about 11,700 µm² of cells, and 16 tiles about
187,000 µm². The table is a pre-synthesis estimate. `scripts/area_est.py`
replaces each row with a measured number as the blocks are built.

| Block | Estimate (µm²) |
|---|---|
| Register file, 31 × 32 latches, 2 read / 1 write | 35,000 |
| Backend datapath (ALU, shifter, branch unit, forwarding, pipeline registers) | 25,000 |
| Iterative multiplier/divider | 8,000 |
| CSRs + counters | 12,000 |
| I-cache 256 B, 2-way, tags, PLRU | 50,000 |
| BPU: BTB, TAGE, RAS, FTQ | 30,000 |
| Fetch, aligner, RVC expander, decoder | 12,000 |
| AXI master, AXI-to-QSPI bridge, UART | 10,000 |
| **Total** | **182,000 ≈ 15.6 tiles** |

This is right at the 16-tile limit, so the cut order in section 3 matters.

### Measured so far (`scripts/area_est.py`, Yosys + ABC on SKY130 cells, no buffering)

| Array | Bits | Flop array | Latch array (`LATCH=1`) |
|---|---|---|---|
| 64 B (32 × 16) | 512 | 22,559 µm² (1.93 tiles) | 15,706 µm² (1.35 tiles) |
| 124 B (32 × 31, register-file size, 1 read port) | 992 | ~44,000 µm² | 27,479 µm² (2.35 tiles) |
| 256 B (32 × 64, I-cache data) | 2,048 | 88,226 µm² (7.56 tiles) | 57,461 µm² (4.92 tiles) |

The latch array costs about 28 µm² per bit: 15 for the latch and about 11 for
the read multiplexer, which now dominates. The real flow will do somewhat
better (mux4 cells, which the estimator does not use), but not by much.

Consequences for the TT build:

* The register file needs two read ports, so expect about 38,000 µm² (3.3 tiles).
* A 256 B I-cache data array plus the register file is about 8.2 tiles,
  half the budget, before any logic. **Recommendation: drop the I-cache to
  128 B (about 2.5 tiles)** as soon as the BTB and TAGE tables are measured.
* Level 0 logic blocks are small: everything except the memory totals under
  13,000 µm² (about 1.1 tiles).

### Level 1 measured at TT sizes (13 Oct)

| Block | Size | µm² | Tiles |
|---|---|---|---|
| I-cache arrays | 256 B, 2-way, 32-bit tags | 72,379 | 6.20 |
| I-cache arrays | 128 B, 2-way, tags for a 25-bit cacheable space | 38,787 | 3.32 |
| I-cache arrays | 64 B, direct mapped, 25-bit space | 19,130 | 1.64 |
| BTB | 16 entries, 8-bit tag | 21,422 | 1.84 |
| BTB | 8 entries, 6-bit tag | 11,362 | 0.97 |
| RAS | 4 × 31 bits | 5,594 | 0.48 |
| Bimodal base | 64 × 2 bits | 5,849 | 0.50 |
| TAGE tagged table (each, 2 needed) | 16 entries | 6,701 | 0.57 |
| Aligner | 4-byte fetch | 5,986 | 0.51 |
| Decoder | RV32IMAC | 1,558 | 0.13 |
| MSHR file | 1 entry | 1,817 | 0.16 |
| AXI read slice | | 6,955 | 0.60 |
| Register file, 1 read port (proxy) | 31 × 32 / 15 × 32 | 27,479 / 13,769 | 2.35 / 1.18 |

The cacheable regions (flash and PSRAM) span 32 MB, so cache tags and BTB
targets only need 25 address bits; this is free and should be adopted.
The AXI slice can be left out of the TT build (QSPI is far slower than the
core, so the timing it protects is not critical).

**Budget with the lean frontend** (128 B I-cache, 8-entry BTB, TAGE kept,
no AXI slice): frontend 7.2 tiles measured, backend about 9.0 estimated
(register file 3.3, datapath 2.1, M unit 0.7, CSRs 1.0, memory interface
and UART 1.0, FTQ and control 0.9). Total about 16.2 tiles: over the limit,
before the real flow adds buffers and clock tree (estimates here are a lower
bound, typically 20–40 % under).

| Option | Saves | Total | Cost |
|---|---|---|---|
| A. RV32E (16 registers) | 1.6 | 14.6 | non-standard ABI (`ilp32e`), still GCC-supported |
| B. No TAGE in silicon (bimodal only; TAGE stays in FULL) | 1.2 | 15.1 | loses the measured-on-silicon predictor comparison |
| C. 64 B direct-mapped I-cache | 1.7 | 14.5 | more misses on slow QSPI |
| A + C | 3.3 | 12.9 | leaves margin for the real flow |

**Decision (13 Oct): A + C.** RV32E and a 64 B direct-mapped I-cache, plus
the free 25-bit tags and targets. Measured Level 1 total at these sizes:
62,416 µm² (5.35 tiles), down from 134,963 µm² (11.56).

### Core measured (14 Oct) and second area decision

With the backend built, `rv_core` measured 196,258 µm² (16.8 tiles) before
the SoC, so A + C was not enough. Cuts, all TT-only parameters (FULL keeps
everything, and each can be reverted in `frontend_pkg.sv` if the hardened
design has room):

| Change | Tiles saved |
|---|---|
| FTQ entries in latch rows with a write bypass (no behaviour change) | 0.5 |
| TAGE out of silicon: bimodal 64 × 2 only (`TAGE_NTABLES = 0`) | 1.4 |
| Instruction queue 4 → 2 parcels | 0.7 |
| RAS 4 → 2, no RAS top in the FTQ checkpoint | 0.4 |
| 2 event counters instead of 4 | 0.2 |
| BTB 8 → 4 entries | 0.45 |
| Backend: re-read the register file instead of operand hold registers; one forwarding stage fewer; address shares the result register | 0.6 |
| **Frontend + backend after the cuts** | **147,353 µm² (12.6 tiles)** |

Cost in simulation: TT IPC drops by about 15 % (for example sort 0.31 → 0.28),
and crc's branch MPKI rises from 1.4 to 15.8 without TAGE. On silicon, QSPI
refills dominate, so the effect is small. The TT GitHub Action hardening run
gives the real number. FTQ 4 → 2 was tried and deadlocks (see the package
comment), so it stays at 4.

**Whole chip** (`make area`, `tt_um_rvcore` with SPI controller, CLINT, UART):

| Part | µm² | Tiles |
|---|---|---|
| Frontend | 65,967 | 5.65 |
| Backend | 81,386 | 6.97 |
| SPI memory controller | 8,476 | 0.73 |
| CLINT | 7,345 | 0.63 |
| UART | 3,986 | 0.34 |
| **tt_um_rvcore** | **166,158** | **14.24 of 16** |

This estimator has no complex cells (it overestimates logic) and no buffers or
clock tree (it underestimates the flow), so treat 14.2 as ±15 %. If the TT
hardening run does not fit 8×2 tiles, the next cuts in order are: event
counters 2 → 0 (`HPM_N`), the RV32 `mtval` as read-only zero for illegal
instructions, and the CLINT `mtimecmp` comparison done serially.

## 7. Verification plan (from the document)

* Unit tests per block in cocotb (Verilator lacks full UVM).
* Branch predictor: trace-driven accuracy and MPKI on CBP traces or Spike runs of CoreMark/Embench.
* Decoders: checked against Spike.
* AXI4: protocol assertions on every channel and a slave memory model.
* System: the frontend fetches a real binary from the AXI memory model and the μop stream matches Spike.

Cut order if late (document): AXI write channels → MSHRs down to 1 → fewer TAGE tables.

## 8. Coding rules

* SystemVerilog subset that Icarus 12, Verilator 5 and Yosys 0.33 all accept:
  `logic`, `always_ff`, `always_comb`, packages, packed structs and enums.
  No interfaces, no unpacked struct ports, no `unique`/`priority` keywords.
* One module per file, file name = module name, prefix `rv_`.
* `verilator --lint-only -Wall` must be clean. Waivers go inline with a reason.
* Yosys 0.33 limits: no `return` in functions (assign to the function name),
  no `import pkg::*` in the module header (write `frontend_pkg::type_t`),
  derived widths used by ports go in the parameter list marked "do not override".
* No packed arrays of structs (Yosys 0.33 turns `a[i].field` into an undriven
  implicit wire with only a warning). Pass bundles as flat vectors of
  `SLOT_W`-bit chunks and cast each chunk to the struct.
* No casts to package types (`frontend_pkg::fault_e'(x)`): Yosys 0.33 rejects
  them, and Icarus requires them when a ternary is assigned to an enum. Use a
  plain `logic [N:0]` for such intermediate signals.
* Memories go through `rv_sram_1r1w`, so the TT build can swap in a latch array.
* No `int'(x)` casts (Yosys 0.33 syntax error); use a sized cast such as `2'(x)`.
