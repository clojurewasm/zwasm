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

- **Phase**: **Phase 5 IN-PROGRESS** (final task §9.5 / 5.8 in
  flight). Phases 0–4 are `DONE` (all SHAs backfilled).
- **Last commit**: `929cdd8` — §9.5 / 5.6 [x] + handover retarget
  at 5.7 (audit). 5.7 audit landed in the same iteration —
  `private/audit-2026-05-03.md` (gitignored). Findings: 1 block
  (expected widget drift owned by 5.8), 2 soon (deferrals already
  documented), 3 watch.
- **Next task**: §9.5 / 5.8 — open §9.6 inline, advance Phase
  Status widget, backfill §9.5 SHA pointers in one commit.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.8 (open §9.6, flip phase tracker)

Phase-5 closing protocol per `continue` skill:

1. Backfill SHA pointers for §9.5 task rows 5.0–5.7 in one
   commit (`git log --grep="§9.5 / N.M" --pretty=%h | head -1`).
2. Update the Phase Status widget at the top of §9: mark §9.5
   as `DONE`, §9.6 as `IN-PROGRESS`.
3. §9.6 (v1 conformance baseline per ADR-0008) is already
   present; expand its task table inline if missing, mirror
   §9.5's structure.
4. Replace handover with §9.6's first open task.
5. Three-host `zig build test-all` (no source change here, but
   the gates verify the ROADMAP edit didn't break parsing).

Carry-overs from §9.5 to track in §9.6 / Phase-7 follow-ups:
- `no_hidden_allocations` zlinter rule re-evaluation (ADR-0009
  follow-up; per-zone exclusion clean post-split).
- Per-feature handler split for validator.zig (paired with
  §9.1 / 1.7 dispatch-table migration per ROADMAP §A12).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc
  consumer drives the refinement).
- Verifier CI hook in `test/spec/runner.zig`.
- Const-prop per-block analysis past first non-foldable op
  (Phase-15 hoisting consumer drives the refinement).
- `src/frontend/sections.zig` (1073 lines) soft-cap split —
  surfaced by 5.7 audit; queued for §9.6 follow-up.

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
