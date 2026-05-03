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
- **Last commit**: `9d029ef` — §9.6 / 6.6 land: verifier CI hook
  in `c_api/instance.zig:instantiateRuntime`; every lowered
  function now runs `loop_info` + `verifier.verify` before
  reaching dispatch. All three hosts green.
- **Next task**: §9.6 / 6.5 — A13 (v1 regression suite stays
  green) merge gate. Doable today since 6.0 + 6.1 + 6.6 are all
  in test-all and gating; need to add the merge-gate doc /
  scripting layer.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.6 / 6.5 (A13 merge gate)

ROADMAP §A13 says the v1 regression suite stays green at every
merge. v2's equivalent of the v1 suite is what currently rides
in `test-all`:

- `test` — unit tests (1700+ tests across src/)
- `test-spec` — Wasm 1.0 curated corpus
- `test-spec-wasm-2.0` — Wasm 2.0 manifest-driven corpus
- `test-realworld` — 50-fixture parse-smoke
- `test-realworld-run` — 50-fixture instantiate + invoke
- `test-v1-carry-over` — vendored v1 regression bundle
- `test-c-api` — c-host integration
- `test-wasi-p1` — WASI fixtures

A13's meta-gate is: every PR merge to `zwasm-from-scratch` must
pass `zig build test-all` on Mac aarch64 + OrbStack Ubuntu
x86_64 + windowsmini SSH. The `continue` skill's per-task TDD
loop already enforces this for autonomous commits; documenting
it as the policy formalises it.

Plan:

1. Document the A13 gate in ROADMAP §A13 (verify it's already
   there — it is; was authored Phase 0).
2. Add a `MERGE_GATE.md` (or extend `CLAUDE.md`) noting that
   any merge to `zwasm-from-scratch` must run `test-all` on
   three hosts, with the "Mandatory pre-commit checks" section
   in CLAUDE.md being the per-commit equivalent.
3. Three-host `test-all` confirms.

Phase-6 outstanding (blocked on v2 execution coverage):

| #   | Description                                            | Blocker            |
|-----|--------------------------------------------------------|--------------------|
| 6.2 | wasmtime stdout differential (30+ matches)             | v2 trap mid-exec   |
| 6.3 | ClojureWasm guest end-to-end                           | same as 6.2        |
| 6.4 | `bench/baseline_v1_regression.yaml` interp wall-clock  | needs cleanly-running fixtures |
| 6.7 | Phase-6 boundary audit                                 | unblocked          |
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
