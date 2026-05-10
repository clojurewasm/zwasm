# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.9 row — Phase 9 active.
3. `.dev/debt.md` — D-063 / D-066 / D-068 + D-065 + 11 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd ops, ARM64 NEON, ADR-0041 §5).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline).

## Current state — Phase 9 / §9.9 in-flight; **9.9-g-4 NEXT — wire 5 missing v128 splat emit handlers (i8x16 / i16x8 / i64x2 / f32x4 / f64x2; only i32x4.splat is currently dispatched). Will flip simd_lane.138 + likely many more in remaining shapes.**

9.9-g-3 (`<pending-sha>`): added 5 v128 reduction emit
handlers (any_true + all_true) + 4 NEON UMAXV/UMINV
encoders + validator/lower wiring. Substrate work; PASS
count unchanged at 10385 because simd_lane.138 still blocks
on splat-handlers gap (D-068).

**Mac aarch64 simd_assert_runner totals after 9.9-g-3**:
**10385 PASS** / **5 FAIL** / 1925 SKIP (over 18 manifests).
OrbStack test-all green; windowsmini gate not yet exercised
this round (heuristic-deferred per `should_gate_windows.sh`).

Residual 5 fails:
- 2× simd_const call_indirect Trap (D-063, spike-pending).
- simd_const.388 BadValType (parse-side gap).
- simd_lane f64x2_extract_lane mismatch (D-066).
- simd_lane.138 UnsupportedOp (D-068 — splat handlers).

**Next — 9.9-g-4** (D-068 splat handlers, ~5 ops + ~4 encoders):
- emitI8x16Splat (DUP V.16B, W) — sub-op 15.
- emitI16x8Splat (DUP V.8H, W) — sub-op 16.
- emitI64x2Splat (DUP V.2D, X — `encDupGen2D` exists) —
  sub-op 18.
- emitF32x4Splat (DUP V.4S, V.S[0] — element form,
  bit[10]=0) — sub-op 19.
- emitF64x2Splat (DUP V.2D, V.D[0] — element form) —
  sub-op 20.
- New encoders: `encDup16B`, `encDup8H`,
  `encDup4SFromS0`, `encDup2DFromD0`. (encDup4S +
  encDupGen2D pre-exist.)
- Lower-side already wires 15..20 (per `lower.zig:562-567`).
- Likely flips simd_lane.138 to PASS, plus +many simd_lane
  asserts that are gated on each shape's splat path.

After D-068 close: continue with D-066 (single-fixture
extract_lane bug) → D-063 spike → corpus expansion →
§9.10 (smoke benches) → §9.11 (audit + SHA backfill) →
§9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-063** (simd_const call_indirect v128 Trap) — `now`;
  static analysis done, runtime spike pending.
- **D-066** (simd_lane f64x2_extract_lane mismatch) — `now`.
- **D-068** (5 v128 splat handlers missing — only i32x4 wired) — `now`.
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
9.9-f-1..8 + 9.9-g-1..3 landed; 9.9-g-4 NEXT).
**Branch**: `zwasm-from-scratch`。
