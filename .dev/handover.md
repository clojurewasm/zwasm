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

## Current state — Phase 9 / §9.7 + §9.8 closed; **§9.9 simd.wast spec test wiring NEXT**

9.7-bb: 6 ops (commit `401f2e1f`) — v128.load{8x8,16x4,32x2}_{s,u}
extending loads. MOVSD + PMOVSX/ZX{BW,WD,DQ}. Closes the §9.7
v128 op surface — all 237 SIMD ZirOps in zir.zig:184-288 have
x86_64 emit handlers (verified by grep). 3-host green.

**§9.8 closed per ADR-0044** — its nominal scope (SSE4.1 SIMD
comparison + shuffle + FP arith + conversion) was absorbed by
§9.7's progressive expansion (9.7-k..n compares; 9.7-o FP
compares; 9.7-p..q FP arith; 9.7-ab..ae conversions; 9.7-ar
shuffle; 9.7-aj..aq pairwise extadd). No additional emit work;
ADR-0044 documents the scope-merge.

**Next — §9.9**: `simd.wast` spec test wired in; fail=skip=0
across both backends (3-host gate). Likely sub-chunks:
- Locate WebAssembly testsuite simd.wast bundle:
  `~/Documents/OSS/WebAssembly/testsuite/proposals/simd/*.wast`
  (~50 files, ~7000 assertions per the §9.1 survey).
- Wire into test-all via `test/spec/wast_runner.zig` extension
  (similar to existing wasm-1.0 + Wasm 2.0 multi-value runners).
- Initial run will produce a fail+skip baseline; iterate
  until 0 of each. Likely surfaces:
  - validator gaps for SIMD edge cases not yet exercised
  - emit-side off-by-one or sign-handling subtleties
  - shape_tag / regalloc bugs only triggered by specific spec
    fixtures
- Edge-case fixtures (per ADR-0020) for any newly-found bugs.

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
§9.8 [x] (scope absorbed per ADR-0044), §9.9 NEXT (simd.wast
spec test wiring).
**Branch**: `zwasm-from-scratch`。
