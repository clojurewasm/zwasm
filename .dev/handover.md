# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0011_phase6_reopen.md` — the ADR that defines
   the current Phase 6 reopen state and the next-step structure.
3. `.dev/ROADMAP.md` — read the **Phase Status** widget at the
   top of §9 (Phase 6 IN-PROGRESS again per ADR-0011), then the
   §9.6 task table to see which rows reopened.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (v1 conformance baseline,
  reopened per ADR-0011).
- **Last commit**: TBD — the semantic revert commit landing
  ADR-0011 + ADR-0010 supersession + Phase 7 code revert
  (`src/jit/` + `src/jit_arm64/` deletions, `src/ir/zir.zig`
  RegClass restoration to 3-variant, `src/main.zig` import
  removals) + ROADMAP §9.6 / 6.4 + 6.8 unflip + §9.7 / 7.0/7.1/7.2
  unflip + Phase Status widget revert.
- **Branch**: `zwasm-from-scratch`, pushed to
  `origin/zwasm-from-scratch`. `main` is forbidden; `--force` is
  forbidden.
- **`/continue` autonomous loop**: explicitly halted. Does not
  re-arm until the v1-asset triage decision (separate ADR) lands
  and provides a clear next-task pointer for Phase 6 reopen.

## Active task — v1-asset triage decision (separate ADR)

Per ADR-0011 Decision §6: Phase 6 reopens with its original
ADR-0008 charter intact (the §9.6 Goal "bring all v1-passing
artefacts to green before any JIT or local-optimisation
complexity is introduced" stands as written). The specific
work breakdown (which v1 assets to ingest, in what order, with
what runner shape, with what classification scheme) is
established by a separate decision after this revert lands.

Pending that decision, the working assumption per ADR-0011 §3:

- §9.6 / 6.2 (wasmtime stdout differential 30+) must close on
  the completion bucket, not the trap bucket.
- §9.6 / 6.3 (ClojureWasm guest end-to-end) must close honestly.
- §9.6 / 6.4 (bench baseline) must close on completion-time
  numbers (current `bench/baseline_v1_regression.yaml` retained
  in tree per ADR-0011 §3 staged plan; regenerated and replaced
  at honest-close).
- §9.6 / 6.8 (Phase close + §9.7 reopen flip) lands last,
  exactly as before.
- New rows attach as §9.6 / 6.X with X assigned by the
  forthcoming v1-asset triage ADR.

Bench baseline staged disposition (ADR-0011 §3):

1. Immediately after revert: re-run `bash
   scripts/record_baseline_v1_regression.sh`, confirm current
   interp produces the same trap-time numbers as a regression-
   detection sanity check.
2. During Phase 6 reopen: as interp behaviour bugs are fixed,
   the 5 baseline fixtures transition from trap-time to
   completion-time numbers.
3. At Phase 6 honest-close: regenerate baseline against
   completion-bucket fixtures, delete or overwrite the trap-
   time yaml, then mark §9.6 / 6.4 `[x]` again.

## Outstanding spec gaps (queued for Phase 6 — v1 conformance)

These were surfaced during Phases 2–4 and deferred from their
own phase. Phase 6 (ADR-0008 charter, ADR-0011 reopen) absorbs
them as part of the v1 conformance baseline.

- **multivalue blocks (multi-param)**: `BlockType` needs to
  carry both params + results; `pushFrame` must consume params
  (Phase 2 chunk 3b carry-over).
- **element-section forms 2 / 4-7**: explicit-tableidx and
  expression-list variants (Phase 2 chunk 5d-3).
- **ref.func declaration-scope**: §5.4.1.4 strict declaration-
  scope check (Phase 2 chunk 5e).
- **Wasm-2.0 corpus expansion**: 47 of 97 upstream `.wast` files
  deferred (block / loop / if 1-5, global 24, data 20, ref_*,
  return_call*) — each surfaces a specific validator gap.
- **39 trap-mid-execution realworld fixtures**: root cause is
  interp behaviour drift vs wasmtime (ADR-0010 analysis
  preserved as historical record). The v1-asset triage ADR
  defines the runner shape that makes these tractable.
- **10 SKIP-VALIDATOR realworld fixtures**: per-function
  validator typing-rule gaps. Same context as above.

## Open questions / blockers

- **Blocker for `/continue` re-arm**: the v1-asset triage ADR
  (the "ADR after ADR-0011" referenced in 0011 §6 + 0011 §4) is
  not yet drafted. `/continue` does not re-arm until that ADR
  lands. User session required to draft it.
