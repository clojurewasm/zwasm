# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.9 row — Phase 9 active.
3. `.dev/debt.md` — D-063 + D-070 (`now` / blocked) + D-065 + 11 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain.
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline).
6. **`.dev/decisions/0049_defer_windowsmini_to_phase_close_batch.md`**
   — gate policy: per-chunk gate is Mac + OrbStack only;
   windowsmini reconciles at Phase boundaries. Effective
   from 2026-05-11.

## Current state — Phase 9 / §9.9 in-flight; **9.9-g-10 NEXT — corpus expansion (simd_boolean / simd_i*x*_arith2) OR D-063 spike OR bitmask family**

9.9-g-9 (`<pending-sha>`): D-066 discharge — fixed
`emitV128ReplaceLaneFp` aliasing bug (regalloc LIFO slot-reuse
can assign `result_v == new_lane_v`; naive copy MOV clobbered
new_lane_v before INS read). Stash through V31 (popcnt scratch)
when alias condition holds. Mac aarch64 simd_assert: 10787 →
**10788 PASS** (+1) / **3 FAIL** (-1) / 2127 SKIP. Lesson
`2026-05-11-regalloc-lifo-vreg-alias-inplace-modify.md`. Same
bug shape exists in `emitV128Bitselect` + `emitV128Select`;
filed as D-070, blocked-by 3-v128-param runner dispatch
(currently SKIP'd as v128-param-pending).

**Mac aarch64 simd_assert_runner totals after 9.9-g-9**:
**10788 PASS** / **3 FAIL** / 2127 SKIP (over 21 manifests).
OrbStack green; windowsmini gate not yet run this round.

Residual 3 fails (all pre-existing):
- 2× simd_const call_indirect Trap (D-063, spike-pending).
- simd_const.388 BadValType (parse-side gap).

**Next 9.9-g-10 candidates** (in priority order):
- **Corpus expansion** (default): simd_boolean (needs bitmask;
  may surface gaps), simd_i*x*_arith2 (per-shape secondary
  arith — saturated arith, abs, neg, etc.). Cheap PASS gains
  if mostly wired; surfaces dispatch gaps if not. Default.
- **D-063 spike** (simd_const call_indirect v128 Trap) —
  bounded; needs runtime lldb body dump compare against
  passing direct-call func; hypotheses recorded in D-063 body.
- **Bitmask family** (D-067 follow-up; sub-ops 100/132/164/196
  bitmask) — multi-instr synthesis (SSHR + AND-mask + ADDV).
- **D-070 spike** (defensively fix bitselect/select alias) —
  blocked-by 3-v128-param runner dispatch.

After §9.9 closes: §9.10 (smoke benches + gap analysis), §9.11
(audit + SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-063** (simd_const call_indirect v128 Trap) — `now`.
- **D-070** (bitselect/select alias risk; mirror of D-066) —
  blocked-by 3-v128-param runner dispatch + corpus assertion.
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
9.9-f-1..8 + 9.9-g-1..9 landed; 9.9-g-10 NEXT).
**Branch**: `zwasm-from-scratch`。
