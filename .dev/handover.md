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

## Current state — Phase 9 / §9.9 in-flight; **9.9-f-6 NEXT — scale to next fixture set (simd_f64x2_arith / simd_i32x4_arith / simd_i16x8_arith) — established pattern, mostly already wired**

9.9-f-5 (`47cf7d0f`): two structural fixes — (1) validator
split of 224..255 sub-opcodes into per-op unop / binop arms
(`opSimdUnop` for 224/225/227/236/237/239); (2) lower-side
wiring of 22 sub-opcodes for f32x4 / f64x2 arith (224..235 +
236..247). ARM64 + x86_64 emit handlers already existed from
§9.6 / §9.7; this chunk closes the dispatch gap.

**Mac aarch64 simd_assert_runner totals after 9.9-f-5**:
**1628 PASS** (was 443, +1185) / **4 FAIL** (was 7, -3) /
908 SKIP. Tests: 1552/1564 Mac, 1536/1564 OrbStack.

Residual 4 fails:
- 2 simd_const call_indirect Traps (D-063)
- simd_const.388 BadValType
- simd_const.389 NotImplemented

**Next — 9.9-f-6**: add `simd_f64x2_arith`, `simd_i32x4_arith`,
`simd_i16x8_arith`, `simd_i8x16_arith` to NAMES — likely most
ZirOps + emit handlers already wired (since FP / int arith
landed in §9.6 / §9.7 across both arches). The validator's
35..76 binop range (cmp ops) already accepts these via
`opSimdBinop`. Lower-side opcodes for int arith (sub-opcodes
~98..174) also need wiring per the same pattern as 9.9-f-5.
Expect +many-thousand PASS per fixture added.

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
§9.9 in-flight (9.9-a..c + 9.9-d-1..7 + 9.9-e-1..2 + 9.9-f-1..5
landed; 9.9-f-6 NEXT — scale to f64x2/i32x4/i16x8/i8x16 arith).
**Branch**: `zwasm-from-scratch`。
