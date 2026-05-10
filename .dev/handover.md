# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.9 row — Phase 9 active.
3. `.dev/debt.md` — D-063 / D-066 + D-065 + 11 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline).

## Current state — Phase 9 / §9.9 in-flight; **9.9-g-6 NEXT — wire SIMD extend + shift family in lower.zig (sub-ops 134..137 i16x8.extend_*, 166..169 i32x4.extend_*, 199..202 i64x2.extend_*; AND 138..140 i16x8.shl/shr_s/u, 171..173 i32x4.shl/shr_s/u, 203..205 i64x2.shl/shr_s/u). Then add simd_int_to_int_extend / simd_boolean / simd_bit_shift to corpus.**

9.9-g-5 (`<pending-sha>`): added simd_load_extend to corpus.
+84 PASS (10391→10475), 4 FAIL unchanged.

**Mac aarch64 simd_assert_runner totals after 9.9-g-5**:
**10475 PASS** / **4 FAIL** / 1937 SKIP (over 19 manifests).
OrbStack test-all green; windowsmini gate not yet run this
round (heuristic-deferred).

Residual 4 fails:
- 2× simd_const call_indirect Trap (D-063, spike-pending).
- simd_const.388 BadValType (parse-side gap).
- simd_lane f64x2_extract_lane mismatch (D-066, spike-pending).

**Next 9.9-g-6 — extend + shift wiring**:
Lower.zig `emitPrefixFD` `else => NotImplemented` swallows
~12 spec-defined sub-ops. ZirOps + per-arch emit dispatch
likely pre-exist (need verification), validator already
covers them in the binop list. Wiring is mechanical —
just add `<sub-op> => self.emit(.@"i*x*.extend_*", 0, 0)`
arms. Bundle: extend (12 ops) + shift (9 ops) = 21 lower
arms in one chunk. Plus add simd_int_to_int_extend +
simd_bit_shift to NAMES; rebake corpus. Likely +many-
hundred PASS.

After D-066 / D-063 / D-067-followup land, §9.9 closes;
then §9.10 (smoke benches + gap analysis), §9.11 (audit +
SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-063** (simd_const call_indirect v128 Trap) — `now`;
  static analysis done, runtime spike pending.
- **D-066** (simd_lane f64x2_extract_lane mismatch) — `now`;
  static analysis: shape correct in isolation, runtime spike
  pending.
- **D-065** (arm64/inst_neon.zig 2050+ LOC > 2000 cap) —
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
9.9-f-1..8 + 9.9-g-1..5 landed; 9.9-g-6 NEXT).
**Branch**: `zwasm-from-scratch`。
