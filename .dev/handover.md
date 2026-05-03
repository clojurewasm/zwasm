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
- **Last commit**: `ccbd91b` — §9.5 / 5.3 land: `src/ir/loop_info.zig`
  analysis pass; `LoopInfo` slot fields filled (`loop_headers` +
  `loop_end`).
- **Next task**: §9.5 / 5.4 — `src/ir/liveness.zig` per-vreg live
  ranges.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.4 (per-vreg liveness analysis)

Adds `src/ir/liveness.zig` which computes per-vreg live ranges
for every `ZirFunc`. Populates the `Liveness` slot reserved on
`ZirFunc` since day-1 (per ROADMAP §4.2 / P13 / W54 lesson —
"liveness is a `?Liveness` slot in `ZirFunc` from day 1").

Phase-5 scope is the analysis itself; consumers land later:
- Phase-7 regalloc (`src/jit/`) reads live ranges to size live
  intervals.
- Phase-15 `const_prop` cross-references liveness to prove value
  freshness.

Plan:

1. Audit how the interp's operand-stack model maps to "vreg"
   identity. The MVP interp uses a stack-machine; ZIR ops are
   stack-typed too. Liveness in this model is per stack slot
   per program point — i.e. each push starts a range, each pop
   closes it. Define the data shape on that basis.
2. Add `Liveness` fields + `compute(allocator, *const ZirFunc)`
   in `src/ir/liveness.zig` + tests.
3. Three-host `zig build test-all`.

Remaining §9.5 rows after 5.4: 5.5 `verifier`, 5.6 `const_prop`,
5.7 phase-boundary audit, 5.8 phase tracker.

Queued for §9.5 / 5.7 (Phase-5 audit): re-evaluate
`no_hidden_allocations` zlinter rule for the now-split c_api +
mvp + frontend modules (deferred per ADR-0009 — all 13 monolith-
era hits were in `wasm_c_api.zig`; per-zone exclusion is clean
post-split). Also: per-feature handler split for validator.zig
(deferred from 5.2, will land alongside §9.1 / 1.7 dispatch-
table migration per ROADMAP §A12).

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
