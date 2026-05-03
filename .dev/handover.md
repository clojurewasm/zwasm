# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   Phase 6 reopen scope (work items 6.A〜6.J, DAG, deferred items).
3. `.dev/ROADMAP.md` §9.6 task table — see "§9.6 reopened scope"
   sub-table for the active row.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS**.
- **Last commit**: `5bae426` — feat(p6) §9.6 / 6.D wire
  wast_runtime_runner to wasmtime_misc corpus + dual manifest;
  test-wasmtime-misc-runtime step wired, NOT in test-all (panics
  inside interp.popOperand on ops-stack discipline bug; queued
  for 6.E).
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — 6.E: fix interp behaviour bugs (39 trap-mid-execution + runtime crash)

Per ADR-0012 §6 row 6.E. Sequenced after 6.A + 6.D.

The runtime-asserting runner against the wasmtime_misc corpus
(test-wasmtime-misc-runtime, wired in 6.D) panics inside
`interp.popOperand`'s assert. Symptom: a fixture executes through
i32.add with an empty operand stack (validator missed an
underflow, OR the runtime runner's pre-call setup mis-sized the
operand stack).

In parallel, the 39 trap-mid-execution realworld fixtures
(handover §Outstanding spec gaps) trap at runtime on
guest-emitted `unreachable` due to interp behavior drift vs
wasmtime.

Sub-tasks:
1. Identify which wasmtime_misc fixture causes the popOperand
   panic. Run `zig build test-wasmtime-misc-runtime` 2>&1 |
   tail and locate the last PASS before the panic; that fixture
   + the next assert_return is the trigger.
2. Use the per-instr trace API (Runtime.trace_cb, added in 6.A)
   to dump operand-stack state per instruction up to the
   panic; compare against wasmtime's execution trace via
   `wasmtime run --trace`.
3. Identify the root cause class:
   - Validator gap: ops-stack underflow not caught at validate
     → fix validator to require correct ops-stack discipline.
   - Runtime runner gap: pre-call setup mis-sizes operand stack
     → fix invokeExport in test/runners/wast_runtime_runner.zig.
   - Op-handler gap: handler pops more than it pushes →
     fix in src/interp/{mvp,mvp_int,mvp_float,...}.
4. Apply fix; re-run; iterate. For each fixture moved into
   completion bucket:
   - Remove its known-bad annotation from regen script comments
   - Re-run regen
   - Verify the runtime runner runs it green
5. When at least 5 wasmtime_misc fixtures fully pass under
   test-wasmtime-misc-runtime, ADD the step to test-all
   aggregate in build.zig.
6. Three-host gate.
7. Commit (chore(p6): land §9.6 / 6.E — fix N interp behavior
   bugs; M fixtures moved into completion bucket).

## Phase 6 reopen DAG (ADR-0012 §6)

```
6.A ✅  6.B ✅  6.C ✅  6.D ✅
 │
 ├─→ 6.E ← ACTIVE (interp behavior bug investigation)
 │    └─→ {6.F, 6.G, 6.H} → 6.J
 │
 └─→ 6.I (parallel)  ─→ 6.J
```

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — Phase 2 chunk 3b carry-over
- element-section forms 2 / 4-7 — Phase 2 chunk 5d-3
- ref.func declaration-scope — Phase 2 chunk 5e
- 13 wasmtime_misc BATCH1-3 fixtures queued (validator gaps;
  test/wasmtime_misc/wast/README.md "Queued for 6.E")
- 39 trap-mid-execution realworld fixtures — 6.E target
- 10 SKIP-VALIDATOR realworld fixtures — per-function validator
  typing-rule gaps
- popOperand panic in test-wasmtime-misc-runtime — 6.E first
  triage target

## Open questions / blockers

(none — autonomous loop continues 6.E. Parallel-eligible 6.I
queued for after 6.E surfaces enough investigation to merit
the parallel switch.)
