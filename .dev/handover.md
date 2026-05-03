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
  ADR-0008 🔒). 5 of 9 §9.6 rows closed; remaining 4 split into
  one unblocked + three execution-coverage-blocked.
- **Last commit**: `9c545d9` — §9.6 / 6.5 [x] + handover retarget
  at 6.7. 6.7 audit landed in this iteration —
  `private/audit-2026-05-03-phase6-mid.md` (gitignored). 0 block,
  1 soon (deliberate prioritisation, documented), 3 watch (known
  soft-cap + forward-looking ref).
- **Next task**: §9.6 / 6.4 — `bench/baseline_v1_regression.yaml`
  records interp wall-clock baseline. Doable today on the
  fixtures that DO run cleanly under v2 (the 39/50 realworld +
  whatever subset of v1 carry-over runs); produces a partial
  baseline that future Phase-6 refinement work expands.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.4 (interp wall-clock baseline)

Per §9.6 exit criterion: `bench/baseline_v1_regression.yaml`
records interp-only wall-clock numbers as the Phase-7+ comparison
floor. Spread + repeatability under noise matters; absolute speed
irrelevant. The §9.6 / 6.4 row text doesn't promise full coverage
of all 50 fixtures — it asks for "a baseline" that future
phases can compare against.

Plan:

1. Pick a small stable subset of fixtures that run cleanly via
   `runWasm` (the 39 PASS from §9.6 / 6.1 chunk b). Subset
   should be deterministic (no clock / random) and short enough
   that 5–10 iterations finish in <30s total. Candidates:
   c_integer_overflow, c_many_functions, rust_compression,
   rust_enum_match — small, exit=1 from trap reproducibly.
2. Use `hyperfine` (already in flake.nix) to measure each
   fixture's `runWasm` wall-clock. Capture mean + stddev across
   5 runs.
3. Write `bench/baseline_v1_regression.yaml` with the per-
   fixture results + a comment block documenting the subset and
   why (35+ fixtures excluded as "needs Phase-6 follow-up
   execution-coverage work").
4. Add a `scripts/record_baseline_v1_regression.sh` script that
   regens the file deterministically (similar to
   `scripts/run_bench.sh`).
5. Three-host `test-all` (no test changes, just bench artefact).

Phase-6 outstanding after 6.4:

| #   | Description                                  | Blocker          |
|-----|----------------------------------------------|------------------|
| 6.2 | wasmtime stdout differential (30+ matches)   | v2 trap mid-exec |
| 6.3 | ClojureWasm guest end-to-end                 | same as 6.2      |
| 6.8 | Open §9.7 inline; flip phase tracker         | depends on 6.2-3 |

Carry-overs from §9.5:
- `no_hidden_allocations` zlinter re-evaluation (ADR-0009).
- Per-feature handler split for validator.zig (with §9.1 / 1.7).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc).
- Const-prop per-block analysis (Phase-15 hoisting).
- `src/frontend/sections.zig` (1073 lines) soft-cap split.

Carry-overs from Phase 6:
- `br-table-fuzzbug` v1 regression — multi-param `loop` block.
- 10 realworld SKIP-VALIDATOR fixtures.
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
