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

## Current state — Phase 9 / §9.9 in-flight (9.9-a foundation landed); **9.9-b populate manifest NEXT**

9.9-a: foundation chunk per ADR-0045 (commit `d8ffe36b`).
- ADR-0045 — parallel `simd_assert_runner` + v128-aware text
  manifest format (`v128:<32 hex>` token shape) decision.
- New `scripts/regen_spec_simd_assert.sh` skeleton — wast2json-
  driven; NAMES list empty.
- New `test/spec/simd_assert_runner.zig` skeleton — corpus walk
  reports manifest count, exits 0 when 0 manifests.
- `build.zig` `test-spec-simd` step (NOT yet aggregated into
  test-all).
- 3-host green; smoke output: `simd_assert_runner: 0 passed,
  0 failed, 0 skipped (over 0 manifests; §9.9-a foundation)`.

**Next — 9.9-b**: populate the lightweight starter set in
`scripts/regen_spec_simd_assert.sh`'s NAMES list. Per the
survey (private/notes/p9-9.9-survey.md):
- simd_address (46 assertions)
- simd_align (54 assertions)
- simd_const (lightweight)
- simd_select (6 assertions)
- simd_*_splat (per-shape splat fixtures)

Implementation:
1. Extend regen script with the wast2json invocation pattern
   from `scripts/regen_spec_1_0_assert.sh` (lines 60+) — adapt
   the Python distillation step for v128 args / results.
2. Run regen → populates `test/spec/wasm-2.0-simd-assert/`.
3. Extend `simd_assert_runner.zig` with manifest parsing for
   v128 tokens + JIT execution + assert_return comparison.
4. Capture baseline fail/skip count; commit + push.

Subsequent §9.9 chunks per ADR-0045:
- 9.9-c: iterate to fail=skip=0 on lightweight set; surfaces
  validator + emit gaps.
- 9.9-d: scale to FP arithmetic + compares (heavy 9k+ assertion
  files); NaN canonicalisation likely surfaces.
- 9.9-e: aggregate `test-spec-simd` into `test-all`; flip §9.9 [x].

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
§9.9 in-flight (9.9-a foundation landed per ADR-0045; 9.9-b
NEXT populate manifest with lightweight starter set).
**Branch**: `zwasm-from-scratch`。
