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

## Current state — Phase 9 / §9.7 in-flight (9.7-a [x]); **9.7-b NEXT**

9.7-a landed at 228286d3: `i32x4.add` via PADDD foundation chunk
(encPaddD encoder + op_simd.emitI32x4Add handler + emit dispatch +
zwasm.zig discovery). Shape-tag pipeline reuses
`shared/regalloc.populateShapeTags` (no x86_64-side wiring per
ADR-0041 §"Decision" / 2). Spilled v128 vregs surface UnsupportedOp
until 9.7-c lifts in 16-byte MOVDQU helpers.

Mac gates at 228286d3: zone ✓, file_size ✓, spill ✓, lint ✓;
unit 1339/0/12. OrbStack at known D-054 baseline (211/1/20).
windowsmini green at prior origin (212/0/20); re-validation
against pushed 228286d3 follows commit.

**9.7-b NEXT** — bundled SIMD integer arithmetic family. Bundle
guidance per LOOP.md: same encoder family + same handler shape
(only opcode byte differs). Candidate set: i8x16/i16x8/i32x4/i64x2
add+sub via PADDB/W/D/Q + PSUBB/W/D/Q (8 ops, 1 chunk). Multiplies
(i16x8.mul = PMULLW; i32x4.mul = PMULLD SSE4.1; i64x2.mul = synth)
go in 9.7-c (separate chunk because i64x2.mul needs synthesis;
ADR-grade design).

After 9.7-b: 9.7-c (lane access — splat / extract_lane /
replace_lane via MOVD + PSHUFD + PINSRD/PEXTRD), 9.7-d (compare
family), 9.7-e (FP arith), 9.7-f (FP compare), 9.7-g (conversion +
shuffle). Sub-row plan refines as each chunk's Step 0 survey lands.

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
