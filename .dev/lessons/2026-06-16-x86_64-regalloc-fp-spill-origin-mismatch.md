# x86_64 v128 spill OOB = arm64-tuned regalloc + x86_64 "faked" thresholds + spill_offsets origin mismatch

**Date**: 2026-06-16
**Context**: D-461 — `index out of bounds: index 5, len 5` at `regalloc.zig:222`
(`offsets[spill_idx]`) when x86_64 JIT-compiles ≥7 live FP/v128 vregs (the
12-live-v128 force-spill fixture). arm64 is unaffected.

## Ground truth (instrumented `slot()` dump under x86_64-macos Rosetta)

```
class=.fpr id=9 gpr=4 fp=6 n_slots=13 len=5 spill_idx=5   → offsets[5] len 5 → OOB
```

## Mechanism (two compounding facts)

1. **Sizing vs resolve origin mismatch.** `computeSpillOffsets`
   (`regalloc_compute.zig:354`) sizes the v128 `spill_offsets` array as
   `n_slots - max_reg_slots_gpr_default` (origin **8**, hardcoded). But
   `Allocation.slot()` (`regalloc.zig:221`) indexes it `id - self.max_reg_slots_gpr`
   — and the x86_64 emit path sets `max_reg_slots_gpr = 4` (its real GPR pool,
   via the `gpr.zig` wrapper). Index origin 4 ≠ sizing origin 8 → every FP spill
   index is +4 too high → OOB.
2. **arm64-tuned deterministic regalloc.** The single-pass regalloc mints
   register slots assuming **8 GPR + 13 FP** slots and spills at force-threshold
   **8** (arm64 reg counts). x86_64 has **4 GPR + 6 XMM**, so it lowers the
   `slot()` thresholds to treat the over-count register ids (gpr 4..7, fp 6..7)
   as spills — but those "faked" spills have **no `spill_offsets` entries** (the
   array only covers minted-spill ids ≥ 8). So even fixing (1)'s origin is not
   enough: the array genuinely lacks slots for x86_64's extra spills.

## Why it stayed hidden

v128/FP spills only occur under >6 live FP vregs — never exercised in production
until the v128-in-GC-aggregate work (D-460) created high-v128-pressure programs.
Scalar GPR spills use the fallback `(id - max_reg_slots_gpr)*16` formula (no
array bound), so they tolerated the origin slop.

## Fix direction (multi-cycle rework, NOT a one-liner)

The regalloc must model **per-arch GPR/FP register counts** (one shared
force-threshold cannot express GPR≠FP pool sizes). Either parameterize
`computeWith` per-arch (mint spills at the true per-class boundary + size
`spill_offsets` from the same origin `slot()` resolves with), or store the
spill-region origin in `Allocation` so sizing and indexing always agree. Pin
current behaviour with characterization tests first (ADR-0153 rework Phase II).

## Repro

Un-gate `runner_gc_test.zig` "12 live v128 force-spill … (D-461 SIMD spill)"
(remove the `builtin.cpu.arch != .aarch64` skip) → `zig build test
-Dtarget=x86_64-macos` (Rosetta) reproduces deterministically.
