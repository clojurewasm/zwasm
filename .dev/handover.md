# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.9 row — Phase 9 active.
3. `.dev/debt.md` — D-063 / D-066 / D-067 + D-065 + 11 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd ops, ARM64 NEON, ADR-0041 §5).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline).

## Current state — Phase 9 / §9.9 in-flight; **9.9-g-3 NEXT — scale corpus further (simd_boolean / simd_load* / simd_int_to_int_extend / simd_bit_shift) AND/OR start D-067 spike (v128 reduction handlers, ~7 ops bundle)**

9.9-g-2 (`<pending-sha>`): wired 50 SIMD cmp sub-opcodes in
lower.zig + i64x2 cmp validator binop arm + manifest read
limit bump + 7 new corpus manifests. Mac aarch64
simd_assert: **3549 → 10385 PASS** (+6836).

**Mac aarch64 simd_assert_runner totals after 9.9-g-2**:
**10385 PASS** (was 3549, +6836 / ×2.93) / **5 FAIL** (was 3,
+2 from new simd_lane gaps) / 1925 SKIP. OrbStack test-all
green; windowsmini gate deferred (heuristic).

Residual 5 fails:
- 2× simd_const call_indirect Trap (D-063, spike-pending).
- simd_const.388 BadValType (parse-side gap).
- simd_lane f64x2_extract_lane mismatch (D-066).
- simd_lane.138 UnsupportedOp — v128.any_true + i*x*.all_true
  emit handlers missing (D-067).

**Next 9.9-g-3 candidates** (default = D-067 since it's bounded
and unblocks simd_lane.138 + simd_boolean):
- **D-067 discharge** (~7 reduction ops: v128.any_true +
  i{8x16,16x8,32x4,64x2}.all_true + bitmask family): NEON
  UMAXV/UMINV synthesis, single chunk; unblocks ~ several
  hundred more spec assertions in simd_boolean / simd_lane.
- **Corpus expansion**: simd_boolean, simd_load*, simd_bit_shift
  — likely to surface more dispatch gaps. After D-067 closes,
  these expansions yield more PASS per-chunk than they cost.
- **D-066 spike** (f64x2_extract_lane mismatch — single
  fixture, but bug-fix path; bounded).
- **D-063 spike** (call_indirect v128 trap) — runtime lldb
  spike; appropriate for a session with focused budget.

After §9.9: §9.10 (smoke benches + gap analysis), §9.11 (audit
+ SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-063** (simd_const call_indirect v128 Trap) — `now`;
  static analysis done, runtime spike pending.
- **D-066** (simd_lane f64x2_extract_lane mismatch) — `now`.
- **D-067** (v128 reduction handlers missing) — `now`.
- **D-065** (arm64/inst_neon.zig 2029 LOC > 2000) —
  blocked-by ADR for source-split.
- **D-055** (x86_64 prologue inject) — blocked-by D-052.
- **D-057** (x86_64 op_simd.zig 4442 LOC hard-cap) —
  blocked-by ADR for source-split landing.
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
§9.9 in-flight (9.9-a..c + 9.9-d-1..7 + 9.9-e-1..2 +
9.9-f-1..8 + 9.9-g-1..2 landed; 9.9-g-3 NEXT).
**Branch**: `zwasm-from-scratch`。
