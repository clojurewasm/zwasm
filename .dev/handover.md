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
- **Last commit**: `251c493` — §9.6 / 6.1 chunk b: end-to-end
  `test-realworld-run` runner; 39 PASS / 1 SKIP-WASI / 10
  SKIP-VALIDATOR / 0 FAIL across the 50-fixture corpus on three
  hosts.
- **Next task**: §9.6 / 6.2 — differential gate (30+ realworld
  samples match `wasmtime run` byte-for-byte stdout).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.2 (differential gate vs wasmtime stdout)

Per ROADMAP §9.6 exit criterion: 30+ realworld samples match
`wasmtime run` byte-for-byte stdout (the ADR-0006 target,
retargeted from §9.4 / 4.10).

Plan:

1. Detect `wasmtime` in PATH (skip cleanly when absent — keeps
   the gate non-fatal for hosts that lack it; gate is real only
   on hosts where wasmtime is installed).
2. For each realworld fixture: `wasmtime run <fixture> >ref` and
   `runWasmCaptured` → compare stdout byte-by-byte. SKIP fixtures
   that produce no stdout (silent guests). The 30+ target counts
   matched-non-empty-stdout pairs.
3. Build step `test-realworld-diff` (or extend
   `realworld_run_runner.zig` with a `--diff <ref-dir>` mode).
   Wire into `test-all` only when `wasmtime` is detected at build
   configure time; else skip.
4. Three-host check: hosts without wasmtime print "0 diff'd /
   skipped"; hosts with wasmtime must hit ≥30 matches.

Phase-6 follow-ups in order: 6.3 ClojureWasm guest end-to-end /
6.4 bench baseline / 6.5 A13 merge gate / 6.6 verifier CI hook /
6.7 boundary audit / 6.8 phase tracker.

Carry-overs from §9.5 still queued (no consumer yet):
- `no_hidden_allocations` zlinter re-evaluation (ADR-0009).
- Per-feature handler split for validator.zig (with §9.1 / 1.7).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc).
- Const-prop per-block analysis (Phase-15 hoisting).
- `src/frontend/sections.zig` (1073 lines) soft-cap split.

Carry-overs from Phase 6 so far:
- `br-table-fuzzbug` v1 regression — multi-param `loop` block
  validator gap (re-add to `regen_v1_carry_over.sh` NAMES when
  the gap closes; surfaced by §9.6 / 6.0).
- 10 realworld validator-gap fixtures (mostly Go + cpp_unique_ptr;
  surfaced by §9.6 / 6.1 chunk b SKIP-VALIDATOR bucket). Each
  is a per-function typing rule v2 hasn't taught yet — Phase-6
  refinement opportunity, not a §9.6 exit-criterion blocker.

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
