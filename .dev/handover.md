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
  ADR-0008 🔒). 6 of 9 §9.6 rows closed; remaining 3 = 6.2 + 6.3
  (execution-coverage blocked) + 6.8 (depends on 6.2-3).
- **Last commit**: `4f73288` — §9.6 / 6.4 land:
  `bench/baseline_v1_regression.yaml` (5 fixtures, 8.83-14.75 ms
  mean, stddev 0.56-2.07 ms) + `record_baseline_v1_regression.sh`
  regen script.
- **Next task**: §9.6 / 6.2 + 6.3 are blocked on the same root
  cause (v2 traps mid-execution before stdout). The §9.6 / 6.8
  phase tracker close needs either both gaps closed OR an
  ADR-0008-style replan documenting deferral. Investigate the
  trap root cause to see if a single fix unblocks both gates.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.2 root-cause investigation

Goal: identify which interp op v2 is trapping on for the 39
realworld fixtures (vs the 10 SKIP-VALIDATOR which fail at the
typing layer). If a single missing op or single small bug is
the cause, fixing it unblocks both 6.2 and 6.3 and lets the
phase close cleanly.

Plan:

1. Pick the smallest failing fixture (c_integer_overflow at
   ~104 KB).
2. Add temporary instrumentation to `interp/dispatch.zig:step`
   to log the unbound-op id when `Trap.Unreachable` originates
   from the dispatch table lookup (vs the wasm `unreachable`
   opcode itself). Run the fixture; capture the trap site.
3. If the cause is a missing op handler: register it in the
   appropriate `interp/mvp_*.zig` or `ext_2_0/*.zig` module;
   re-run; iterate until c_integer_overflow exits cleanly with
   wasmtime-matching stdout.
4. Re-run `test-realworld-diff` to see how many fixtures
   newly match.
5. If cause is something else (lowering bug, validator gap that
   slipped through, etc.): document the finding, file ADR if
   load-bearing, queue.
6. Three-host `test-all` per usual.

If the investigation determines the gap is more than a single-
fix problem (likely — production wasms use a long tail of ops),
then file an ADR-0008-style replan that deferrs 6.2 + 6.3 to
Phase 7 (when JIT brings the same coverage pressure naturally)
and closes Phase 6 with the gates that exist (6.0, 6.1, 6.4,
6.5, 6.6, 6.7).

Phase-6 outstanding:

| #   | Description                                  | Blocker          |
|-----|----------------------------------------------|------------------|
| 6.2 | wasmtime stdout differential (30+ matches)   | v2 trap mid-exec |
| 6.3 | ClojureWasm guest end-to-end                 | same root cause  |
| 6.8 | Open §9.7 inline; flip phase tracker         | depends on 6.2-3 OR ADR-style replan |

Carry-overs from §9.5:
- `no_hidden_allocations` zlinter re-evaluation (ADR-0009).
- Per-feature handler split for validator.zig (with §9.1 / 1.7).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc).
- Const-prop per-block analysis (Phase-15 hoisting).
- `src/frontend/sections.zig` (1073 lines) soft-cap split.

Carry-overs from Phase 6:
- `br-table-fuzzbug` v1 regression — multi-param `loop` block.
- 10 realworld SKIP-VALIDATOR fixtures.
- 39 realworld trap-mid-execution fixtures — investigation in
  6.2 chunk b above.

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
