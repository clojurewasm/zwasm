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
  ADR-0008 🔒). Phase 5 closed; Phases 0–5 `DONE` with all §9.<N>
  SHAs backfilled.
- **Last commit**: `15e2c82` — §9.5 / 5.7 [x] + handover retarget
  at 5.8 (phase-5 close). 5.8 itself lands in this iteration's
  ROADMAP-edit commit (Phase Status widget advance + §9.5 SHA
  backfill + §9.6 task table opened inline).
- **Next task**: §9.6 / 6.0 — vendor v1 regression tests into
  `test/v1_carry_over/` + add `zig build test-v1-carry-over`.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.0 (vendor v1 carry-over regression tests)

Per ROADMAP §9.6 exit criterion #1: stand up the carry-over
regression suite that the v1 codebase passes but isn't covered
by the upstream spec testsuite, so v2 inherits every regression
v1 fixed.

Plan:

1. Survey v1's regression tests: `~/Documents/MyProducts/zwasm/`
   tree (read-only reference clone). Likely under `test/` or
   `tests/`. Identify which tests duplicate spec coverage (skip)
   vs add unique coverage (vendor).
2. Vendor unique tests into `test/v1_carry_over/<name>.wast` (or
   `.wasm` + expected stdout per `wasmtime run`).
3. Add `zig build test-v1-carry-over` step in `build.zig`,
   modelled on `test-spec`. Three-host gate.
4. Add to `test-all` aggregate.
5. Three-host `zig build test-all` per usual.

Phase-6 follow-up tasks (already enumerated in §9.6 task table):
6.1 realworld coverage / 6.2 differential gate / 6.3 ClojureWasm
/ 6.4 bench baseline / 6.5 A13 merge gate / 6.6 verifier CI hook
/ 6.7 boundary audit / 6.8 phase tracker.

Carry-overs from §9.5 (queued for Phase-6+ as consumer pressure
builds):
- `no_hidden_allocations` zlinter re-evaluation (ADR-0009 follow-
  up; per-zone exclusion clean post-split).
- Per-feature handler split for validator.zig (paired with
  §9.1 / 1.7 dispatch-table migration per §A12).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc).
- Const-prop per-block analysis past first non-foldable op
  (Phase-15 hoisting).
- `src/frontend/sections.zig` (1073 lines) soft-cap split.

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
