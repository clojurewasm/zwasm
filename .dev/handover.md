# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.8 task table — Phase 8 active.
3. `.dev/debt.md` — D-054 + D-055 + 9 other rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: hoist-branch-targets-as-pc, regalloc, coalescer).
5. `.dev/decisions/0031_zir_hoist_pass.md` (D-053 root-cause amend per 8a.6).
6. `.dev/optimisation_log.md` (F/R/O ledger; 8b adoption discipline).

## Current state — Phase 9 / §9.7 in-flight (9.7-a + 9.7-b [x]); **9.7-c NEXT**

9.7-b landed at 1e798581: bundled packed integer add/sub family
(8 ops). Refactored 9.7-a's `emitI32x4Add` body into shared
`emitV128IntBinop(encoder)` helper; 7 new encoders (encPaddB/W/Q
+ encPsubB/W/D/Q) + 7 new handler wrappers + 7 new dispatch
arms. ARM64 mirror per ROADMAP P7. v128 spill remains
UnsupportedOp pending 9.7-c MOVDQU helpers.

Three-host gate at 1e798581: Mac unit 1344/0/12 + zone/file_size/
spill/lint ✓; OrbStack at known D-054 baseline (211/1/20
spec_assert + every other runner green); windowsmini full green
(212/0/20 spec_assert + every other runner green).

**9.7-c NEXT** — SIMD integer multiply family. i16x8.mul (PMULLW
SSE2) + i32x4.mul (PMULLD SSE4.1, the first SSE4.1-exclusive op
in this phase) bundle naturally. i64x2.mul has no native form
(neither SSE2 nor SSE4.1 has packed 64×64→64); synthesis via
3-mul + 2-shift + 2-add per cranelift idiom — ADR-grade design,
likely separate sub-chunk. Step 0 survey will scope.

Alternative ordering: lane access (splat / extract_lane /
replace_lane via PSHUFD + PINSRB/W/D + PEXTRB/W/D) could land
first if needed by an end-to-end integration fixture. Decided
during 9.7-c's Plan step.

Subsequent chunks: 9.7-d (compare family), 9.7-e (FP arith),
9.7-f (FP compare), 9.7-g (conversion + shuffle). Sub-row plan
refines as each chunk's Step 0 survey lands.

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-054** (OrbStack-only as-loop-broke) — Rosetta JIT-emulation
  artefact; baseline 211/1/20 carried as known.
- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract.
- 9 `blocked-by:` rows: D-007/D-010/D-016/D-018/D-020/D-021/D-022/
  D-026/D-028/D-052 — barriers all hold.

Closed Phase 8b artefacts (preserved for Phase 12 + Phase 15
reference) live in git: ADRs 0035-0040, lessons indexed in
`.dev/lessons/INDEX.md`, code in `src/ir/coalesce/`,
`src/engine/codegen/shared/regalloc.zig` (LIFO free-pool),
`src/engine/codegen/aot/`. No need to duplicate pointers here —
`git log` is the authoritative lookup.

**Phase**: Phase 9 (SIMD-128, ADR-0041). §9.5 [x] (ARM64 NEON pt 1),
§9.6 [x] (ARM64 NEON pt 2), §9.7 NEXT (x86_64 SSE4.1).
**Branch**: `zwasm-from-scratch`。
