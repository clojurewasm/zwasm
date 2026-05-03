# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   the ADR that defines the Phase 6 reopen scope (work items
   6.A〜6.J, DAG dependencies, deferred items).
3. `.dev/decisions/0011_phase6_reopen.md` — the structural ADR
   that reopened Phase 6 and defined the bench staged disposition.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (v1 conformance baseline,
  reopened per ADR-0011, scope defined per ADR-0012).
- **Last commit**: TBD — landing ADR-0012 (first-principles
  test/bench redesign methodology) into `.dev/decisions/`.
  Prior commit `a4e7405` landed ADR-0011 + Phase 7 semantic
  revert.
- **Branch**: `zwasm-from-scratch`, pushed to
  `origin/zwasm-from-scratch`. `main` is forbidden; `--force` is
  forbidden.
- **`/continue` autonomous loop**: explicitly halted. Re-arms
  after 6.A becomes well-bounded (i.e. after ADR-0013 is
  Accepted).

## Active task — 6.A: runtime-asserting WAST runner

Per ADR-0012 §6 work item 6.A. **Blocking prerequisite: ADR-0013
must be drafted and Accepted before 6.A implementation starts**
(per ADR-0012 Consequences / Neutral / follow-ups).

### 6.A scope (from ADR-0012 §6 row 6.A)

Add `test/runners/wast_runtime_runner.zig`. v1's
`e2e_runner.zig` (844 LOC) is the textbook reference; the v2
runner is re-derived for v2's Zone shape per
`.claude/rules/no_copy_from_v1.md`.

Capability scope:
- assert_return / assert_trap / assert_invalid /
  assert_malformed / assert_unlinkable / assert_uninstantiable /
  assert_exhaustion
- register / action / module
- cross-module Store sharing
- per-instr execution trace (consumed by 6.E)

Deferred to relevant feature phases:
- thread block
- assert_return_canonical_nan / assert_return_arithmetic_nan

### Sub-tasks

1. ~~Draft ADR-0013~~ — **DONE** (Accepted).
2. **Implement runner** per ADR-0013 design — **NEXT**.
   Extend `src/interp/{mod,dispatch}.zig` with TraceEvent +
   trace_cb, add `test/runners/wast_runtime_runner.zig` with
   manifest parser + 9 directive handlers + value/trap parsing.
3. **Wire into `build.zig`** as `test-runtime-runner-smoke`
   step pointing at `test/runners/fixtures/`. The full
   `test-wasmtime-misc` step lands populated in 6.D.
4. **Three-host `zig build test` + `test-runtime-runner-smoke`
   green**.

## Phase 6 reopen DAG (from ADR-0012 §6)

```
6.A (runtime-asserting runner + per-instr trace)        ← active
 │
 ├─→ 6.B (test/ restructure + 4 fixtures migration)
 │    └─→ 6.C (vendor wasmtime_misc BATCH1-3 ≈ 55 fixtures)
 │         └─→ 6.D (wire 6.C into test-all via 6.A runner)
 │              └─→ 6.E (interp behaviour bug fixes)
 │                   ├─→ 6.F (test-realworld-diff 30+ matches)
 │                   ├─→ 6.G (ClojureWasm guest e2e)
 │                   └─→ 6.H (bench honest baseline)
 │                        └─→ 6.J (Phase 6 close gate)
 │
 └─→ 6.I (bench/ restructure + sightglass)  ─→ 6.J
       (parallel to 6.E〜6.H)
```

## Outstanding spec gaps (Phase 6 absorbs as v1 conformance)

- multivalue blocks (multi-param) — Phase 2 chunk 3b carry-over
- element-section forms 2 / 4-7 — Phase 2 chunk 5d-3
- ref.func declaration-scope — Phase 2 chunk 5e
- Wasm-2.0 corpus expansion (47 of 97 .wast files) — validator
  gaps surface per .wast file
- 39 trap-mid-execution realworld fixtures — 6.E target
- 10 SKIP-VALIDATOR realworld fixtures — per-function validator
  typing-rule gaps

## Open questions / blockers

- **Blocker for `/continue` re-arm**: ADR-0013 is not yet
  drafted. The next session draft + accept ADR-0013, then 6.A
  implementation lands, then `/continue` re-arms with 6.B as
  the active task. User session needed for ADR-0013 draft +
  review.
