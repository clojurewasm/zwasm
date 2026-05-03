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
- **Last commit**: `bd29343` — §9.5 / 5.4 land: `src/ir/liveness.zig`
  per-vreg analysis pass; `Liveness` slot filled
  (`ranges: []const LiveRange`).
- **Next task**: §9.5 / 5.5 — `src/ir/verifier.zig` runs after
  every analysis pass; CI calls it on the spec corpus.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.5 (IR verifier pass)

Adds `src/ir/verifier.zig` — a sanity checker that runs after
each Phase-5 analysis pass and on the spec corpus in CI. Per
ROADMAP §9.5 it must verify the invariants the analyses are
supposed to maintain so a regression in `loop_info` / `liveness`
/ later passes surfaces immediately rather than as a downstream
JIT bug (W54-class lesson).

Phase-5 scope (what the verifier checks today):

- `loop_info.loop_headers.len == loop_info.loop_end.len` AND
  every header / end index is < `instrs.len` AND the instr at
  each `header[i]` is `.@"loop"` AND instr at `loop_end[i]` is
  `.@"end"`.
- `liveness.ranges[v].def_pc <= last_use_pc` AND both pcs in
  range AND `def_pc` indexes an instr that pushes (cross-checks
  via the same `stackEffect` table the liveness pass uses).
- ZirFunc structural: `branch_targets` indexes are in range
  for every `br_table` instr (already validated upstream but
  cheap to assert).

Plan:

1. Add the analysis-result shape to `src/ir/verifier.zig`:
   `pub fn verify(*const ZirFunc) Error!void`.
2. Tests: each invariant has a positive (passes) + negative
   (mutated state fails with the right error) case.
3. CI hook: `test/spec/runner.zig` calls `verify` after lowering
   each function — defer to §9.5 / 5.7 if too invasive for this
   chunk; surface the deferral in handover.
4. Three-host `zig build test-all`.

Remaining §9.5 rows after 5.5: 5.6 `const_prop`, 5.7 phase-
boundary audit, 5.8 phase tracker.

Queued for §9.5 / 5.7 (Phase-5 audit): re-evaluate
`no_hidden_allocations` zlinter rule for the now-split c_api +
mvp + frontend modules (deferred per ADR-0009 — all 13 monolith-
era hits were in `wasm_c_api.zig`; per-zone exclusion is clean
post-split). Also: per-feature handler split for validator.zig
(deferred from 5.2, will land alongside §9.1 / 1.7 dispatch-
table migration per ROADMAP §A12). Also: liveness pass
control-flow + memory-op coverage (deferred from 5.4 — Phase-7
regalloc consumer drives the refinement).

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
