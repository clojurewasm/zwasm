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
- **Last commit**: `5215b87` — §9.5 / 5.6 land: `src/ir/const_prop.zig`
  peephole folding analysis; `ConstantPool` slot filled
  (`folds: []const ConstantFold`).
- **Next task**: §9.5 / 5.7 — Phase-5 boundary `audit_scaffolding`
  pass (adaptive cadence; absorbs the queued items below).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.7 (Phase-5 boundary audit)

Run `audit_scaffolding` adaptively at the Phase-5 boundary; fix
local `block` findings inline, file ADRs for non-local ones.
Mirror the §9.4-end pattern.

Plan:

1. Invoke `audit_scaffolding`; review the produced report at
   `private/audit-YYYY-MM-DD.md`.
2. Local `block` findings → fix and commit.
3. Non-local `block` findings → file `.dev/decisions/NNNN_*.md`
   per §18, queue follow-ups in handover.
4. Optionally run `simplify` over `git diff <phase-start>..HEAD
   -- src/` — apply behaviour-preserving suggestions.
5. Three-host `zig build test-all` after any source change.

Remaining §9.5 rows after 5.7: 5.8 phase tracker (open §9.6 +
flip Phase Status widget; backfill §9.5 SHAs in one commit per
the boundary protocol).

Carry-overs queued from earlier 5.* tasks (the audit may surface
related findings or re-prioritise these):
- Re-evaluate `no_hidden_allocations` zlinter rule for the now-
  split c_api + mvp + frontend modules (deferred per ADR-0009).
- Per-feature handler split for validator.zig (deferred from
  5.2; lands alongside §9.1 / 1.7 dispatch-table migration per
  ROADMAP §A12).
- Liveness control-flow + memory-op coverage (deferred from 5.4;
  Phase-7 regalloc consumer drives the refinement).
- Verifier CI hook in `test/spec/runner.zig` (deferred from 5.5
  to keep the runner-shape change out of analysis-pass commits).
- Const-prop per-block analysis covering past first non-foldable
  op (deferred from 5.6 — current pass stops at the cutoff;
  Phase-15 hoisting consumer drives the refinement).

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
