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
- **Last commit**: `64447ce` — §9.5 / 5.2 land: validator + lowerer
  test blocks carved to `*_tests.zig` siblings; both source files
  drop out of §A2 soft-cap warn list (1426→939 / 1062→576).
- **Next task**: §9.5 / 5.3 — `src/ir/loop_info.zig` (branch_targets,
  loop_headers, loop_end computed for every fn).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.5 / 5.3 (loop_info IR analysis)

`src/ir/loop_info.zig` adds the first IR-level analysis pass per
ROADMAP §9.5. For every `ZirFunc` it computes:

- `branch_targets: []u32` — each `br` / `br_if` / `br_table`
  resolved to the absolute pc of its target instr (replacing the
  current depth-walk in the dispatch loop).
- `loop_headers: []u32` — instr indices of every `loop` open.
- `loop_end: []u32` — instr index of each loop's `end` close.

`ZirFunc` already carries a `branch_targets` slice (used by
`br_table`); the §9.5 / 5.3 analysis fills it for the simple
`br` / `br_if` cases too and surfaces the loop metadata for §9.5 /
5.4 (liveness) consumption.

Plan:

1. Survey existing branch-target handling in `interp/mvp.zig`
   `doBranch` + `frame.popLabel` to identify the depth-walk that
   the new analysis will short-circuit.
2. Add the analysis fn (`computeLoopInfo`) under `src/ir/`; tests
   alongside.
3. Wire it into the lowerer / instantiation path so populated
   `branch_targets` reaches `dispatch.run`.
4. Three-host `zig build test-all` per usual.

Remaining §9.5 rows after 5.3: 5.4 `liveness`, 5.5 `verifier`,
5.6 `const_prop`, 5.7 phase-boundary audit, 5.8 phase tracker.

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
