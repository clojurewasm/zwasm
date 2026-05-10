# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.7 row — Phase 9 active.
3. `.dev/debt.md` — D-055 / D-057 + 10 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd ops, x86_64 SSE/SSE4.1/SSE4.2, ADR-0041 §5).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline post-9.7-m
   amendment).

## Current state — Phase 9 / §9.9 in-flight; **9.9-f-3 NEXT — v128 merge MOV in `arm64/op_control.zig:emitEndIntra` (unblocks simd_const.386 + scales to multi-arm-result-v128 fixtures)**

9.9-f-2 (`a968a84d`): two-line fix — extend `validator.readBlockType`
+ `lower.readBlockArity` to accept -5 (0x7B) → v128 single
valtype block result. Per Wasm spec §5.3.5 blocktype encoding;
was missing in the -1..-4 (i32/i64/f32/f64) switch.

**Mac aarch64 simd_assert_runner totals after 9.9-f-2**:
**394 PASS** (was 381, +13) / **3 FAIL** (was 4, -1) /
325 SKIP. simd_bitwise.17 unblocked. simd_const.386 moved
past validator into emit-side UnsupportedOp.

Residual 3 fails:
- simd_const.386 emit UnsupportedOp — `arm64/op_control.zig:
  emitEndIntra` merge MOV uses GPR helpers; v128 result
  needs `qLoadSpilled` / `encMovV16B`. Concrete next chunk.
- simd_const.388 BadValType — separate parse-side gap
- simd_const.389 NotImplemented — separate

**Next — 9.9-f-3**: extend `emitEndIntra`'s merge MOV to
type-aware dispatch. Track the result type per-arity slot
(via the label or pushed-vreg shape_tag); for v128 slots
emit `qLoadSpilled(else_result, stage 1)` + `qDefSpilled
(merge_vreg, stage 0)` + `encMovV16B(merge_reg, else_reg)`
+ `qStoreSpilled(merge_vreg, 0)`. The same widening must
apply to br/br_if's branch-fixup result marshal if those
also touch the merge.

After §9.9: §9.10 (smoke benches + gap analysis), §9.11
(audit + SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract.
- **D-057** (op_simd.zig hard-cap, now ~4442 LOC) — blocked-by
  ADR for source-split landing. Discharge requires ADR mirror
  of ADR-0030; deferred until §9.7 row close.
- 10 `blocked-by:` rows: D-007/D-010/D-016/D-018/D-020/D-021/
  D-022/D-026/D-028/D-052 — barriers all hold this resume.

Closed Phase 8b artefacts (preserved for Phase 12 + Phase 15)
live in git: ADRs 0035-0040, lessons in `.dev/lessons/INDEX.md`,
code in `src/ir/coalesce/`, regalloc.zig LIFO free-pool,
`src/engine/codegen/aot/`. `git log` is authoritative.

**Phase**: Phase 9 (SIMD-128, ADR-0041 — SSE4.2 baseline).
§9.5 [x] (ARM64 NEON pt 1), §9.6 [x] (ARM64 NEON pt 2),
§9.7 [x] (x86_64 SSE4.1+SSE4.2; 9.7-a..bb landed),
§9.8 [x] (scope absorbed per ADR-0044),
§9.9 in-flight (9.9-a..c + 9.9-d-1..7 + 9.9-e-1..2 + 9.9-f-1..2
landed; 9.9-f-3 NEXT — v128 merge MOV in emitEndIntra).
**Branch**: `zwasm-from-scratch`。
