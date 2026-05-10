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

## Current state — Phase 9 / §9.9 in-flight (9.9-a..c landed); **9.9-d iterate to fail=skip=0 NEXT**

9.9-c: populate manifest + JIT execution wiring (this commit).
`scripts/regen_spec_simd_assert.sh` now drives wast2json on the
lightweight starter set (simd_address, simd_align, simd_const,
simd_select). Python distillation packs v128 lanes as little-
endian `lane_size`-byte ints, concats to 16 bytes, emits as
32-char lower-hex (lane-0-byte-0 first). `simd_assert_runner.zig`
gains manifest parsing + JIT execution for `() → {i32, i64,
f32, f64, v128, ()}` and `(i32) → {i32, v128}` shapes. Two new
entry helpers in `src/engine/codegen/shared/entry.zig`:
`callV128NoArgs` and `callV128_i32`, both returning `[16]u8` via
`@Vector(16, u8)` (lowers to V0 on AAPCS64 / XMM0 on SysV).
Bad-module flag suppresses cascade FAIL on assert_returns under
a module that failed compile.

**Initial baseline (Mac aarch64)**: 74 passed, 301 failed,
478 skipped over 4 manifests. Failure breakdown:
- 158 `compile: UnsupportedOp` — codegen gaps (v128.load8x8_u
  family, alignment-hint variants).
- 143 `compile: BadValType` — validator gaps (likely v128 valtype
  acceptance in some surface; needs Diagnostic surfacing in 9.9-d).
- 478 skipped: `v128-param-pending` (deferred to 9.9-e),
  `directive-assert_malformed-text`, assert_invalid surfacing as
  `SKIP-VALIDATOR-GAP`, and asserts cascaded under bad modules.

**Next — 9.9-d**: iterate to fail=skip=0 on lightweight set.
- Discharge `compile: BadValType` cluster — surface valtype name
  in Diagnostic (extend ADR-0016 / 0028 thread-local) so each
  rejection is actionable; expected to be one or two validator
  rules accepting v128 in `(global v128 ...)` / `(func (result
  v128))` / multi-result shapes.
- Discharge `compile: UnsupportedOp` cluster — populate op_simd
  + dispatch_table with v128.load8x8_{s,u}, load16x4_{s,u},
  load32x2_{s,u}, load{8,16,32,64}_lane, load{8,16,32,64}_zero
  variants per ADR-0041 §5; ARM64 LD1.* / LD1R.* + x86_64 PMOVSX
  / MOVDQU + insert/extract.
- Re-check tracking under bad-module: if root cause clusters
  expose a structural gap, lift to ADR per `lessons_vs_adr.md`.
- Add `assert_trap` v128-result path (currently `skip
  assert_trap-v128-pending`).

Subsequent §9.9 chunks per ADR-0045:
- 9.9-e: v128 PARAM marshal per ADR-0046 (unblocks multi-arg
  spec assertions like simd_select).
- 9.9-f: scale to FP arith + compares (heavy 9k+ files).
- 9.9-g: aggregate `test-spec-simd` into `test-all`; flip §9.9 [x].

After §9.9: §9.10 (smoke benches + gap analysis), §9.11
(audit + SHA backfill), §9.12 (open Phase 10).

Subsequent: §9.9 (simd.wast wired in, fail=skip=0), §9.10
(smoke benches + gap analysis), §9.11 (audit + SHA backfill),
§9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract.
- **D-057** (op_simd.zig hard-cap, now ~4070 LOC) — blocked-by
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
§9.9 in-flight (9.9-a..b landed; ADR-0045 + ADR-0046; 9.9-c
NEXT populate manifest + JIT execution wiring).
**Branch**: `zwasm-from-scratch`。
