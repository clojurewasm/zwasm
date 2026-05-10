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

## Current state — Phase 9 / §9.9 in-flight; **9.9-d-5 NEXT — bundle ARM64 select_v128 + v128.load_lane / v128.store_lane (9 ops) + investigate residual 21 value-mismatches**

9.9-d-4 (`3aaed99f`): fix arm64 function-level `end` handler's
v128 return marshal (was missed in 9.9-b). The `.return` op
handler had the correct `.v128 →` arm but the function-level
`.end` handler classified v128 as `is_fp = false` and routed
through the GPR path. Spike via debug prints in the runner +
disassembling the JIT body confirmed `MOV X0, Xn` was being
emitted instead of `MOV V0.16B, Vn.16B`. Lesson:
[`fn-end-vs-return-parallel-handlers`](lessons/2026-05-10-fn-end-vs-return-parallel-handlers.md).

**Mac aarch64 simd_assert_runner totals after 9.9-d-4**:
62 → **226 PASS** / 200 → **36 FAIL** / 296 SKIP. PASS +164,
FAIL -164.

Residual 36 fails:
- 3 compile UnsupportedOp — select_v128 + load_lane / store_lane.
- 21 value-mismatch (`got v128`) — small enough to inspect
  case-by-case after 9.9-d-5 lands the missing emit handlers
  (some may be unblocked by select_v128 wiring; others likely
  FP NaN canonicalization).
- 3 small validator surfaces (BadBlockType / BadValType /
  NotImplemented).
- The remaining 9 likely cluster around assert_invalid /
  assert_trap shapes the runner partially supports.

**Next — 9.9-d-5**: bundle the 9 missing emit handlers per
chunk-granularity rule (same shape — all ARM64 v128
mem-or-select ops; small, sharing v128MemPrologue or a
similar scaffold for store_lane / load_lane).

Subsequent §9.9 chunks per ADR-0045:
- 9.9-e: v128 PARAM marshal per ADR-0046 (unblocks multi-arg
  spec assertions like simd_select).
- 9.9-f: scale to FP arith + compares (heavy 9k+ files).
- 9.9-g: aggregate `test-spec-simd` into `test-all`; flip §9.9 [x].

After §9.9: §9.10 (smoke benches + gap analysis), §9.11
(audit + SHA backfill), §9.12 (open Phase 10).

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
§9.9 in-flight (9.9-a..c + 9.9-d-1..4 landed; 9.9-d-5 NEXT —
ARM64 select_v128 + load_lane / store_lane bundle).
**Branch**: `zwasm-from-scratch`。
