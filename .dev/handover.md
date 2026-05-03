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
- **Last commit**: `581bae0` — §9.6 / 6.2 chunk a: `diff_runner`
  + `test-realworld-diff` step landed; **gate not yet achievable**
  (0 matched / 39 mismatched today — v2 traps mid-execution
  before fd_write). Not wired into `test-all` to keep build
  green; run explicitly when working on closing the gap.
- **Next task**: §9.6 / 6.6 — verifier CI hook (deferred from
  5.5; independent of the execution-coverage blocker holding
  6.2–6.5).
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.6 (verifier CI hook)

Wires `src/ir/verifier.verify` into the spec-runner so every
function lowered during a `zig build test-spec` / `test-spec-
wasm-2.0` / `test-realworld-run` invocation is checked against
the §9.5 / 5.5 invariants (loop_info / liveness / branch_targets).
Catches W54-class regressions in any analysis pass populated on
ZirFunc.

Plan:

1. Locate the per-function lowering site in
   `test/spec/runner.zig` and `test/spec/wast_runner.zig` (and
   the realworld run runner via cli_run path).
2. After lowering, populate `loop_info` (cheap; analysis already
   exists) AND call `verifier.verify(&func)`. On error, print
   the failed invariant + fixture name; exit non-zero.
3. Liveness + const_prop are NOT populated by default (their
   analyses can fail on control-flow modules per their
   "out-of-scope" note); only `loop_info` is universally safe to
   populate so the verifier has something to check.
4. Three-host `zig build test-all` per usual.

Phase-6 outstanding (blocked on v2 execution coverage — none of
these can honestly close until v2 runs realworld fixtures
cleanly enough for stdout to match wasmtime):

| #   | Description                                              | Blocker            |
|-----|----------------------------------------------------------|--------------------|
| 6.2 | wasmtime stdout differential (30+ matches)               | v2 trap mid-exec   |
| 6.3 | ClojureWasm guest end-to-end                             | same as 6.2        |
| 6.4 | `bench/baseline_v1_regression.yaml` interp wall-clock    | needs cleanly-running fixtures |
| 6.5 | A13 (v1 regression suite stays green) merge gate         | meta-gate over 6.0 + 6.1 (both done) — possibly closeable |

Per the carry-over queue in handover, the validator + dispatch
gaps surfaced by 6.1 chunk b (10 SKIP-VALIDATOR fixtures, plus
the trap-mid-exec on the other 39) are real Phase-6 refinement
work but no single fix unblocks the gate. The §9.6 / 6.7 boundary
audit will reassess once 6.6 lands.

Carry-overs from §9.5:
- `no_hidden_allocations` zlinter re-evaluation (ADR-0009).
- Per-feature handler split for validator.zig (with §9.1 / 1.7).
- Liveness control-flow + memory-op coverage (Phase-7 regalloc).
- Const-prop per-block analysis (Phase-15 hoisting).
- `src/frontend/sections.zig` (1073 lines) soft-cap split.

Carry-overs from Phase 6:
- `br-table-fuzzbug` v1 regression — multi-param `loop` block
  validator gap (re-add to NAMES when gap closes).
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
