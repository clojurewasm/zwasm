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

- **Phase**: **Phase 6 IN-PROGRESS** (v1 conformance baseline per
  ADR-0008 🔒).
- **Last commit**: `0825794` — §9.6 / 6.5 land: A13 merge-gate
  documentation; `gate_merge.sh` + CLAUDE.md cross-reference
  ROADMAP §A13. `test-all` (Mac + OrbStack + windowsmini) is the
  enforcement point; it already aggregates every A13 layer v2
  has stood up. ClojureWasm joins when §9.6 / 6.3 lands.
- **Next task**: §9.6 / 6.7 — Phase-6 boundary `audit_scaffolding`
  pass. Done early as a sanity check before deciding how to
  approach the §9.6 / 6.2 + 6.3 + 6.4 execution-coverage blocker.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.7 (Phase-6 boundary audit, early)

Run `audit_scaffolding` even though 6.2 + 6.3 + 6.4 are still
`[ ]`. Rationale: the audit might surface false-positive triggers
or stale doc that's misleading the loop's next-task choice; it
costs nothing and may find scaffolding fixes. After the audit:

1. Local `block` findings → fix and commit inline.
2. Non-local `block` findings → file ADR via §18, queue.
3. The §9.6 / 6.8 phase tracker stays gated on 6.2-4 closing
   (or being explicitly deferred via ADR-0008-style replan).

Phase-6 outstanding (blocked on v2 execution coverage):

| #   | Description                                            | Blocker            |
|-----|--------------------------------------------------------|--------------------|
| 6.2 | wasmtime stdout differential (30+ matches)             | v2 trap mid-exec   |
| 6.3 | ClojureWasm guest end-to-end                           | same as 6.2        |
| 6.4 | `bench/baseline_v1_regression.yaml` interp wall-clock  | needs cleanly-running fixtures |
| 6.7 | Phase-6 boundary audit                                 | unblocked (NEXT)   |
| 6.8 | Open §9.7 inline; flip phase tracker                   | depends on 6.2-4   |

Carry-overs from §9.5:
- `no_hidden_allocations` zlinter re-evaluation (ADR-0009).
- Per-feature handler split for validator.zig (with §9.1 / 1.7).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc).
- Const-prop per-block analysis (Phase-15 hoisting).
- `src/frontend/sections.zig` (1073 lines) soft-cap split.

Carry-overs from Phase 6:
- `br-table-fuzzbug` v1 regression — multi-param `loop` block
  validator gap.
- 10 realworld SKIP-VALIDATOR fixtures (Go + cpp_unique_ptr).
- 39 realworld trap-mid-execution fixtures — root cause TBD.

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
