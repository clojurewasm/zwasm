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

## Current state — Phase 9 / §9.9 in-flight; **9.9-f-5 NEXT — split validator/lower 224..255 FP unop arms (f32x4.{abs,neg,sqrt}, f64x2.{abs,neg,sqrt}, ceil, floor, …) + wire f32x4/f64x2 binop lower opcodes (228..231 + 240..243); unblocks ~1700+ simd_f32x4_arith assertions**

9.9-f-4 (`5c955a5e`): two parts:
1. Scaled corpus: `simd_f32x4_arith` (1819 assertions) added.
   New `(v128) → v128` entry helper + runner dispatch +
   SUPPORTED dict expansion.
2. Filed **D-063** for the `simd_const.386` call_indirect
   v128 Trap (deferred from 9.9-f-3; investigation depth
   exceeds chunk budget; broader scaling has higher leverage).

**Mac aarch64 simd_assert_runner totals after 9.9-f-4**:
**443 PASS** (was 412, +31) / **7 FAIL** (was 4, +3) /
2093 SKIP. Tests: 1552/1564 Mac, 1536/1564 OrbStack.

Residual 7 fails:
- simd_f32x4_arith.0 NotImplemented (lower-side missing
  f32x4.add / .sub / .mul / .div opcodes 228..231)
- simd_f32x4_arith.1 StackUnderflow (validator approximates
  224..255 as binop; f32x4.{abs,neg,sqrt} are unops)
- simd_f32x4_arith.18 NotImplemented (similar lower gap)
- simd_const: 2 call_indirect Traps (D-063)
- simd_const.388 BadValType, .389 NotImplemented

**Next — 9.9-f-5**: extend validator dispatch (`validator.zig:
dispatchPrefixFD`) for sub-opcodes 224..255 — split out unop
arms (224 f32x4.abs, 225 f32x4.neg, 227 f32x4.sqrt, 236
f64x2.abs, 237 f64x2.neg, 239 f64x2.sqrt + ceil/floor/trunc/
nearest variants) using existing `opSimdUnop`. Wire the
matching `lower.zig` arms (mirror the 78..82 pattern from
9.9-f-1). Emit handlers for f32x4 / f64x2 arith already exist
in op_simd.zig (see emitF32x4Add etc.); just need to ensure
dispatch routes correctly. Likely +1500-1700 PASS in one
chunk if the emit handlers are byte-equal.

After §9.9: §9.10 (smoke benches + gap analysis), §9.11
(audit + SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-063** (simd_const.386 call_indirect v128 Trap) — `now`;
  deferred from 9.9-f-3.
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
§9.9 in-flight (9.9-a..c + 9.9-d-1..7 + 9.9-e-1..2 + 9.9-f-1..4
landed; 9.9-f-5 NEXT — validator/lower 224..255 FP unop split).
**Branch**: `zwasm-from-scratch`。
