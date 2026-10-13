# Branch prediction study

> **Note (14 Oct):** to fit 16 tiles, the TT silicon uses the bimodal
> 64 × 2b predictor alone (first row; `TAGE_NTABLES = 0`, docs/spec.md
> section 6). The TT-sized TAGE stays in the RTL and can be switched back on
> in `frontend_pkg.sv` if the hardened design has room; the FULL build keeps
> the large TAGE.

Conditional-branch mispredictions per 1,000 instructions (MPKI), lower is better.
Programs run on the reference ISS (RV32EMAC, `-O2`); 4-byte fetch blocks; history
updated with real outcomes. Regenerate with `python3 scripts/bp_study.py`.

| Predictor | Storage (bits) | coremark | branchy | sort | crc | arith |
|---|---|---|---|---|---|---|
| Bimodal 64 x 2b (TT base alone) | 128 | 16.8 | 50.5 | 15.6 | 15.5 | 17.9 |
| TAGE, TT build: 64 base + 2 x 16 tagged (hist 4, 12) | 480 | 12.7 | 39.1 | 15.6 | 0.9 | 19.1 |
| Bimodal 2048 x 2b | 4,096 | 14.8 | 48.0 | 15.5 | 15.5 | 17.9 |
| TAGE, FULL build: 2048 base + 4 x 512 tagged (hist 5, 15, 44, 130) | 34,816 | 3.6 | 24.1 | 16.2 | 0.9 | 6.0 |
| (instructions / conditional branches) | | 341,958 / 62,139 | 27,087 / 5,238 | 85,511 / 25,307 | 20,055 / 3,009 | 47,120 / 13,189 |

## What it shows

* On CoreMark the TT-sized TAGE (480 bits) mispredicts less than a bimodal
  table with 8.5x the storage (12.7 vs 14.8 MPKI), and 25 % less than its own
  base table alone (16.8).
* `crc` has a loop whose exit depends on the last few outcomes; even the
  4- and 12-bit histories learn it (15.5 -> 0.9).
* With only 16 entries per tagged table, `arith` thrashes and TAGE is
  slightly worse than bimodal (19.1 vs 17.9); the FULL-size TAGE fixes this
  (6.0).
* `sort` is data-dependent (comparisons on random keys); no predictor helps.

The TT TAGE RTL is bit-exact with the model on these traces
(`test/test_rv_tage.py`), so the TT rows are what the silicon will do, given
the same branch stream. On silicon the history is speculative and repaired on
mispredicts (section in the frontend tests), so measured numbers will differ
slightly; the perf counters (mhpmcounter3) report them.
