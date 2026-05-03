# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   defines Phase 6 reopen scope (work items 6.A〜6.J, DAG, deferred
   items).
3. `.dev/ROADMAP.md` §9.6 task table — see "§9.6 reopened scope"
   sub-table for the active row.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS**.
- **Last commit**: `165d506` — feat(p6) §9.6 / 6.C vendor
  wasmtime_misc BATCH1-3 (42 fixtures, 72 .wasm) + regen
  script + 2-level walk in wast_runner; three-host green.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — 6.D: wire 6.C corpus through runtime-asserting runner

Per ADR-0012 §6 row 6.D. Sequenced after 6.C (now done).

The 42 fixtures vendored under `test/wasmtime_misc/wast/` in
6.C are currently driven by `wast_runner.zig` (parse + validate
only). 6.D wires them through the new `wast_runtime_runner.zig`
(from 6.A) so that any assert_return / assert_trap / etc.
directives in the underlying .wast files actually execute.

Sub-tasks:
1. Extend `scripts/regen_wasmtime_misc.sh` to emit the runtime-
   asserting directive forms (assert_return / assert_trap /
   assert_exhaustion + invoke / register / module-with-as-name)
   into manifest.txt alongside the existing valid/invalid/
   malformed lines.
2. Verify a small representative subset (e.g. add, div-rem,
   empty) renders sane runtime-asserting manifests + the new
   runner consumes them green.
3. Add `test-wasmtime-misc-runtime` step in build.zig pointing
   the runtime-asserting runner at `test/wasmtime_misc/wast`.
4. Wire `test-wasmtime-misc-runtime` into `test-all` aggregate.
5. Likely surfaces v2 interp behaviour gaps — fixtures that
   parse + validate green may still fail at assert_return
   comparison or trap at unexpected locations. Triage:
   - If gap is small (one missing op handler) → fix inline.
   - If gap is large (operand-stack discipline / behaviour
     bug) → queue as 6.E target, exclude fixture from runtime
     manifest while keeping its parse+validate gate.
6. Three-host `zig build test-all` green.
7. Commit (chore(p6): land §9.6 / 6.D — wire wasmtime_misc
   corpus through runtime-asserting runner).

Note: the existing `wast_runtime_runner.zig` directive parser
handles `i32` end-to-end but stubs `i64`/`f32`/`f64`/refs at
parse-only. Broader value-type comparison (per ADR-0013 §6
"deferred per-directive") wires per-fixture as the corpus
demands it.

## Phase 6 reopen DAG (ADR-0012 §6)

```
6.A ✅  6.B ✅  6.C ✅
 │
 ├─→ 6.D ← ACTIVE
 │    └─→ 6.E → {6.F, 6.G, 6.H} → 6.J
 │
 └─→ 6.I (parallel)  ─→ 6.J
```

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — Phase 2 chunk 3b carry-over
- element-section forms 2 / 4-7 — Phase 2 chunk 5d-3
- ref.func declaration-scope — Phase 2 chunk 5e
- 13 wasmtime_misc BATCH1-3 fixtures queued for §9.6 / 6.E
  (validator gaps; full list in
  `test/wasmtime_misc/wast/README.md`)
- 39 trap-mid-execution realworld fixtures — 6.E target
- 10 SKIP-VALIDATOR realworld fixtures — per-function validator
  typing-rule gaps

## Open questions / blockers

(none — autonomous loop continues 6.D → 6.J per ADR-0012 DAG.)
