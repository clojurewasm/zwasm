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

## Current state — Phase 9 / §9.6/9.6-e [x] (FP compares, 12 ops); **§9.6/9.6-f NEXT**

§9.6/9.6-e adds 4 NEON FP-compare encoders (FCMEQ/FCMGE × 4S/2D)
+ 12 op_simd handlers reusing 9.6-d helpers (`emitV128Binop`,
`emitV128Ne`, `emitV128BinopSwapped`). FCMGT was already added
in 9.6-c-ii. Net chunk is essentially encoder additions + thin
dispatch wiring.

Per LOOP.md chunk granularity, §9.6 sub-row state:
- 9.6-a/b/c-i/c-ii/d/e [x]: FP binary + FP unary + min/max +
  pmin/pmax + int compares + FP compares.
- 9.6-f NEXT: shuffle (i8x16.shuffle via TBL) + swizzle
  (i8x16.swizzle via TBL with the source register holding lane
  indices).
- 9.6-g: conversion (trunc_sat / convert / narrow / extend).

Mac gates: zone ✓, file_size ✓, spill ✓, lint ✓; spec
212/0/20, wast 1158/0/0.

**§9.6/9.6-f NEXT** — i8x16.shuffle + i8x16.swizzle.
- `i8x16.shuffle` takes 2 v128 sources + 16-byte immediate (the
  shuffle indices, each in 0..31). Lowers to NEON `TBL Vd.16B,
  { Vn.16B, Vn+1.16B }, Vm.16B` (table lookup with 2 source
  registers — pair must be consecutive). Indices ≥ 32 are
  Wasm-spec UB, but typically map to 0 in NEON's TBL semantics
  for indices ≥ table-size. To pass the 16-byte immediate, the
  index vector must be loaded from constant memory (literal
  pool) into a v128 vreg first.
- `i8x16.swizzle` takes 2 v128 sources (operand + index vector).
  Lowers to NEON `TBL Vd.16B, { Vn.16B }, Vm.16B` (single
  source).

Both need TBL encoder + handler; shuffle additionally needs
const-pool plumbing for the 16-byte index immediate. Estimated
~120 src + ~80 tests; may split into 9.6-f-i (swizzle, simpler)
and 9.6-f-ii (shuffle, with const-pool).

After 8b.4: 8b.5 (boundary audit_scaffolding) + 8b.6 (open
§9.9 inline + flip Phase Status).

## Closed §9.8b artefacts (for Phase 12 + Phase 15 reference)

- ADRs: 0035 (coalescer design) / 0036 (8b.1 scope down) /
  0037 (regalloc upgrade + Rev 2 discovery) / 0038 (class-
  aware deferral) / 0039 (.cwasm format + Rev 2 numeric
  correction) / 0040 (aggregate target revision)
- Lessons: `2026-05-09-greedy-local-already-does-reuse.md`
- Code: `src/ir/coalesce/pass.zig`, `src/engine/codegen/
  shared/regalloc.zig` LIFO free-pool, `src/engine/codegen/
  aot/{format, serialise, produce}.zig`, `src/cli/compile.zig`
- Surveys (gitignored): `private/notes/p8-8b{1,2,3}-*-
  survey.md`

After 8b.3: 8b.4 (≥10% aggregate; concentrated on 8b.3
contribution per ADR-0038), 8b.5 (Phase 8 boundary audit),
8b.6 (open §9.9).

## Closed §9.8b artefacts (for Phase 15 reference)

- ADR-0035 (post-regalloc slot-aliasing coalescer design)
- ADR-0036 (8b.1 scope downgrade)
- ADR-0037 (regalloc upgrade design + Revision 2 discovery)
- ADR-0038 (class-aware allocation deferral)
- `src/ir/coalesce/pass.zig` (8b.1 scaffolding)
- `src/engine/codegen/shared/regalloc.zig` (8b.2-c LIFO
  free-pool refactor)
- Lessons: `2026-05-09-greedy-local-already-does-reuse.md`

After 8b.2: 8b.3 (AOT skeleton), 8b.4 (≥10% aggregate
exit; absorbs 8b.1 + 8b.2 + 8b.3 contributions), 8b.5
(Phase 8 boundary audit), 8b.6 (open §9.9).

## Coalescer scaffolding (8b.1 [x] artefacts — for Phase 15 reference)

Surface preserved for Phase 15 detection lift:

- `src/ir/coalesce/pass.zig` — pass module + `run` shape +
  `isCoalesceCandidate` (MVP catalogue: `local.tee` /
  `local.get` / `local.set` / `select`) + `deinitArtifacts`.
- `src/ir/zir.zig` — `CoalesceRecord` + `func.coalesced_movs`
  slot.
- `src/engine/codegen/shared/compile.zig` — pipeline
  placement between regalloc and emit.
- `private/notes/p8-8b1-coalescer-survey.md` — Step 0
  survey across cranelift / wasmtime / regalloc2 / wasm3 /
  v1 zwasm (gitignored).
- ADR-0035 (post-regalloc slot-aliasing design) + ADR-0036
  (scope downgrade rationale).

## Open structural debt (pointers — current; full list in `.dev/debt.md`)

- **D-054** (`blocked-by: separate investigation`) — OrbStack-
  only; independent of D-053. Likely Rosetta JIT-emulation
  interaction or Linux-x86_64-only path.
- **D-055** (`blocked-by: D-052 + emit_test_*.zig migration`) —
  x86_64 prologue inject deferred (sentinel ARM64-only).
- 9 `blocked-by:` rows — D-007 / D-010 / D-016 / D-018 / D-020
  / D-021 / D-022 / D-026 / D-028 / D-052; barriers all hold.

D-053 closed at `2e0022c` (was promoted to ROADMAP row §9.8a /
8a.5).

**Phase**: Phase 8 (JIT optimisation foundation 🔒、ADR-0019)。
**Branch**: `zwasm-from-scratch`。
