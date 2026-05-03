# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` — read the **Phase Status** widget at the top
   of §9 to find the IN-PROGRESS phase, then its expanded `§9.<N>`
   task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing deviations in flight.

## Current state

- **Phase**: **Phase 5 IN-PROGRESS.** Phases 0–4 are `DONE` (all
  SHAs backfilled in §9.<N> task tables; `git log --grep="§9.<N>
  / N.M"` is the canonical lookup).
- **Last commit**: `d22bd63` — §9.5 / 5.5 land: `src/ir/verifier.zig`
  invariant pass over `loop_info` / `liveness` / `branch_targets`.
- **Next task**: §9.5 / 5.6 — `src/ir/const_prop.zig` (limited
  const folding).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.6 (limited const propagation)

Adds `src/ir/const_prop.zig` — a const-folding pass over straight-
line MVP arithmetic. Populates the `ConstantPool` slot reserved
on `ZirFunc` since day-1 (per ROADMAP §4.2 / P13).

Phase-5 scope:

- Identify peephole foldable patterns: `i32.const A; i32.const B;
  i32.<binop>` → `i32.const C` (where C is the constant-evaluated
  result). Same for i64/f32/f64.
- Skip ops with side effects (div_s/div_u/rem_s/rem_u — divide-
  by-zero traps; min/max/copysign on floats with NaN); fold only
  trap-free arithmetic (add/sub/mul/and/or/xor/shl/shr/rotl/rotr).
- Surface a `[]ConstantFold` describing each foldable site:
  `{def_pc_a, def_pc_b, op_pc, result}`. The actual rewrite of
  `instrs` is the consumer's job (Phase-15 hoisting / Phase-7
  regalloc). 5.6 is the analysis only.

Plan:

1. Add `ConstantPool` fields + `compute(allocator, *const ZirFunc)`
   in `src/ir/const_prop.zig` + tests.
2. Three-host `zig build test-all`.

Remaining §9.5 rows after 5.6: 5.7 phase-boundary audit, 5.8
phase tracker.

Queued for §9.5 / 5.7 (Phase-5 audit):
- Re-evaluate `no_hidden_allocations` zlinter rule for the now-
  split c_api + mvp + frontend modules (deferred per ADR-0009).
- Per-feature handler split for validator.zig (deferred from
  5.2; lands alongside §9.1 / 1.7 dispatch-table migration per
  ROADMAP §A12).
- Liveness control-flow + memory-op coverage (deferred from 5.4;
  Phase-7 regalloc consumer drives the refinement).
- Verifier CI hook in `test/spec/runner.zig` (deferred from 5.5
  to keep the runner-shape change out of analysis-pass commits).

## Outstanding spec gaps (queued for Phase 6 — v1 conformance)

These were surfaced during Phases 2–4 and deferred from their own
phase. Phase 6 (ADR-0008) absorbs them as part of the v1
conformance baseline; do NOT re-pick during Phase 5.

- **multivalue blocks (multi-param)**: `BlockType` needs to carry
  both params + results; `pushFrame` must consume params (Phase 2
  chunk 3b carry-over).
- **element-section forms 2 / 4-7**: explicit-tableidx and
  expression-list variants (Phase 2 chunk 5d-3).
- **ref.func declaration-scope**: §5.4.1.4 strict declaration-
  scope check (Phase 2 chunk 5e).
- **Wasm-2.0 corpus expansion**: 47 of 97 upstream `.wast` files
  deferred (block / loop / if 1-5, global 24, data 20, ref_*,
  return_call*) — each surfaces a specific validator gap.

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required.)
