# ADR-0195 — Multi-task async scheduler for guest↔guest stream/future completion (D-335 remainder)

- Status: **Implemented — FUNCTIONALLY COMPLETE 2026-06-17 (@a82b4f84)**. Steps (a)–(d) landed end-to-end
  (multi-task scheduler → cross-component routing → `task.return` capture + result round-trip → future +
  synchronous + BLOCKING multi-element stream rendezvous + pollSet/waitable-set delivery + AsyncDeadlock guard).
  This closed the D-335 last functional gap. Step (e) adversarial corpus is **partially done** (the AsyncDeadlock
  guard landed; the cross-component DROPPED / CANCELLED variants + graph cancel-op/waitable wait-poll-drop
  builtins remain as **D-464**, consumer-gated). See **Phase V retrospective (2026-06-17)** below. The (a)–(e)
  plan stands as the historical record; the campaign ran as bundle `wasi-p3-multitask-scheduler`.
- Date: 2026-06-17

## Phase V retrospective (2026-06-17) — campaign close

The campaign ran as bundle `wasi-p3-multitask-scheduler` (not a formal five-phase rework — it was new
functionality on a green base, not a redesign of a measured deficiency, so the ADR-0153 II-before-IV gate did
not apply; the (a) correctness-corpus-first ordering served the same role). Pipeline as landed:

| Step | Delivered | Key SHA(s) |
|------|-----------|-----------|
| II(a) | single-task driver characterization net pinned | `529cfcba` |
| (b) | `TaskTable` / `seedTask` / `foldResult` (Zone-1) | `b90cbecb`, `61c4a20d` |
| (c-1) | `driveScheduler` (round-robin + `pollSet` seam + all-waiting→`AsyncDeadlock`) | `822d30d5` |
| (c-2a) | P3 runner unified on `driveScheduler`; retired `driveCallbackLoop` | `54a9b0bc`, `c7710cda` |
| (c-2b) | cross-component ROUTING (`ComponentGraph.driveAsyncMain` + `installAsyncBoundary`) | `a0e2d4c7` |
| (d-a) | `task.return` capture into `TaskDescriptor.result` | `cc63edd9` |
| (d-b-1) | A consumes result via `retptr` | `7cf62e3a` |
| (d-b-2) | future rendezvous (shared `GraphAsync` tables) | `4a344503` |
| (d-c-1) | synchronous multi-element stream rendezvous | `9eabb709` |
| (d-c-2) | BLOCKING stream rendezvous + pollSet/waitable-set delivery + AsyncDeadlock guard | `a82b4f84` |

**Hit the 完成形?** Functional dimension yes — guest↔guest async works end-to-end (future / stream / blocking /
deadlock fixtures in `test/component/two_async_components_*.wat`, each asserting `taskResult == 42`); the D-335
last functional gap is closed. 3-host verified (ubuntu OK @4f95129a; windows BATCHED). P3/P6 single-pass
invariants untouched (interp/host driver only, no JIT/codegen surface).

**New debt.** Step (e) is intentionally incomplete — the cross-component DROPPED / CANCELLED adversarial
variants, the graph cancel-op + waitable-set wait/poll/drop builtins (currently loud `UnsupportedBoundaryType`
in `pourSyntheticExport`), and the deferred async boundary shapes (param-alongside-retptr, aggregate async
params, >`SharedStream.buf[64]` payloads) are tracked as **D-464** and land when a consumer/fixture demands
them — not grindable speculatively. **D-463** (shared `StreamFutureTable` across the graph vs per-component
handle isolation) is the structural-simplification residual — correct for a trusted composed graph, a
spec-fidelity refinement for untrusted composition.

**Superseded-simplification note.** The d-b-2 graph-shared `StreamFutureTable` ("the handle crosses verbatim …
no rebind is needed") was a deliberate trusted-graph simplification — it gave all children one shared handle
index space, so a child could reach a peer's un-granted stream/future end. **Superseded 2026-06-18 by ADR-0197**
(cross-component async handle isolation via an ownership ledger; D-463): handles are now owner-tagged and
transfer-on-lower, so an un-granted end traps. The shared rendezvous (`SharedTable`) stays graph-shared (reached
only through an owned end) — that part of d-b-2 stands.

## Revision 2026-06-17 (PM) — UNBLOCKED (the D-305 blocker landed)

A read-only feasibility investigation (after the D-305 sync linker reached common-shape completion: string/list
params + string result + `(string)->string` + boundary error-trap, @2b9b14ee) re-checked the parking reason
below and found it **obsolete**:

- The parking precondition was "D-305 must route async-import→guest-callee FIRST." D-305 now routes SYNC
  cross-component calls through `component_graph.zig`'s two-level instantiation + boundary trampolines
  (`installBoundaryTrampoline` / `buildChild`). That IS the routing substrate the scheduler needed.
- The **async** routing trampoline is now a clear **~100 LOC mirror** of the sync `boundaryTrampoline`: detect
  `is_async` on the imported func's canonopts → instead of `invoke()→return-flat`, create a `Subtask`
  (`async.zig:397`, the built-but-unwired ζ1 machinery) + return its handle, re-entering via the driver loop.
  This folds into step (c) below; it is NOT a separate D-305 deliverable.
- The **true** remaining bottleneck is now scheduler-internal: step (b) `TaskTable` + the 1-entry-table refactor
  of `driveCallbackLoop` (generalise "drive THE task" → "drive the task TABLE"), ~200 LOC Zone-1/3. In-process
  testable: a 2-component fixture (A async-imports B's async export) asserts Subtask creation→resolution +
  waitable-set delivery, no OS scheduler. ROI ~300–350 LOC total, MEDIUM risk (regression surface = the
  single-task path, kept byte-identical by the (a)+(e) corpus hard gate).

CAMPAIGN REVIVED. Next-cycle entry = Phase II(a) correctness corpus FIRST (pin the single-task driver before
the TaskTable generalisation), then (b). Lesson `2026-06-17-guest-guest-async-is-downstream-of-component-linker`
gets a closing note: the downstream dependency is satisfied; the scheduler is now the frontier.

## Revision 2026-06-17 — implementation PARKED (blocked-by D-305)

A Phase-II design verification (before any scheduler code) found the campaign's exit-condition (a guest↔guest
`stream<u8>` rendezvous e2e) is **not in-process achievable today**, blocked one layer deeper than Phase I
assumed:

- **Async-lowered imports resolve to HOST functions ONLY.** Cross-component import resolution is name-match
  (`component.zig:~488`); there is no path routing a `canon lower`-with-`async` import call to a *guest*
  async callee in another instance.
- **`Subtask` (async.zig:397) is built but entirely UNWIRED** — zero production callers of `.resolve()` /
  subtask creation (only the `async.zig:~865` unit test). It was scaffolding for exactly this step.
- **CM-async spawns a subtask ONLY via an async-lowered import targeting an async callee in ANOTHER
  component instance** = cross-component composition. There is NO intra-component multi-task path (one async
  export per instance; no `spawn` builtin; cyclic self-import disallowed).
- Therefore guest↔guest needs **D-305 (the fully-general component linker)** to route async-import→guest-callee
  FIRST; the ADR-0195 scheduler (`TaskTable` + per-task dispatch) is the layer ABOVE that. Building it now =
  speculative infra with no real consumer (spike §2). PARKED until D-305.

What was retained as genuine value: **Phase II(a)** pinned single-task `AsyncDeadlock` (the behavior the
scheduler would generalise) — a permanent regression guard. The design (TaskTable + cooperative round-robin)
is recorded here intact; revive this ADR's Decision when D-305 lands. Lesson:
`2026-06-17-guest-guest-async-is-downstream-of-component-linker`.
- Relates: ADR-0187 (stackless callback ABI), ADR-0189 (ζ2 wiring / WasiP2Ctx async state), ADR-0190/0191
  (host-peer Unit E + WAIT path), lesson `2026-06-16-stackless-stream-completion-needs-host-peer`. Builds on
  the committed ζ1 `Subtask` machinery (1e3e814b).

## Context

zwasm's CM-async is **stackless** (ADR-0187): a guest's async export is driven by `driveCallbackLoop`
(`async.zig:124`), re-entering the guest `callback(event, p1, p2)` until it returns `EXIT`. Host-backed
streams complete because a host sink/source acts as the synchronous 2nd actor (Unit E; E1 stdout / E3 stdin).

**The gap (not a bug — an acknowledged design boundary):** a *guest↔guest* `stream.read` that blocks returns
to the callback loop with no continuation, and there is **no second guest task** to write the peer end →
`waitOn` polls an empty set → `AsyncDeadlock`. The single-task runner is architecturally complete for ONE
task; it cannot rendezvous two guest tasks.

Investigation (Phase I, 2026-06-17) confirmed the **Zone-1 machinery is already complete**: `Subtask`
state machine + lenders + resolve→SUBTASK event (`async.zig:397`), `SharedStream`/`SharedFuture` rendezvous
with peer-handle notify (`:482`, `StreamFutureEnd.copy` `:209`), `WaitableSet`/`WaitableSetTable` event
delivery (`:290`). What is missing is purely the **driver**: `driveCallbackLoop` drives one task; a second
task (an async-lowered import's guest func) is never re-entered.

## Decision

Add a **cooperative round-robin multi-task scheduler** as a clean, additive extension of the callback ABI:

1. **`TaskDescriptor` + `TaskTable` (Zone-1, `async.zig`)** — per-component table (mirrors `StreamFutureTable`
   shape): `{ task_id, callback_funcidx, set_index, state: {ready, waiting_on_set, done} }`. Pure data.
2. **Scheduler loop (Zone-3, the P3 runner)** — generalise the single-task `driveCallbackLoop` consumer into a
   loop over the `TaskTable`: drive each `ready` task's callback; for a `waiting_on_set` task, poll its set and
   deliver a pending event if present; mark `done` on `EXIT`. Terminate when all tasks `done`, or trap
   `AsyncDeadlock` when *all* tasks are `waiting_on_set` AND no set has a pending event (generalises the
   current single-task deadlock check).
3. **Async-lowered import → new task** — when a guest calls a `canon lower`-with-`async` import, mint a
   `Subtask` (exists) AND enqueue a `TaskDescriptor` for the callee so the scheduler drives it. Cross-task
   events already route correctly: a `SharedStream.write` on task A's end deposits the rendezvous result in
   task B's end `pending_event` (`copy()` `:209`), which B's next poll delivers — the rendezvous code is
   peer-agnostic and unchanged.

The main export seeds task 0 in the `TaskTable`; a pure single-task component is just a 1-entry table (zero
behaviour change — the regression guard).

## Alternatives rejected

- **Fibers / stackful coroutines** — rejected by ADR-0187 (and re-rejected here): the callback ABI already
  encodes continuations as guest-visible state; fibers would duplicate that + add per-task native stacks.
- **Preemptive scheduler** — unnecessary; CM-async is cooperative (tasks yield at canon calls / blocked I/O).
  Round-robin over the ready set is sufficient and deterministic (testability).
- **Amend ADR-0187** — not needed; multi-task concurrency is at the *application* level (guest calls async
  imports), not a new engine concurrency primitive. ADR-0187's "stackless, no fibers" is fully intact.

## Incremental plan (bundle `wasi-p3-multitask-scheduler`, correctness-first)

- **(a) Correctness gate FIRST** — confirm/strengthen the characterization net for the 8+ single-task async
  e2e fixtures (`component_wasi_p3.zig`) so the `driveCallbackLoop` generalisation cannot silently regress
  EXIT / YIELD / WAIT / host-peer COMPLETION / single-task `AsyncDeadlock`.
- **(b)** `TaskDescriptor` + `TaskTable` (Zone-1) + the 1-entry-table refactor of the driver (single-task
  behaviour byte-identical; full async corpus green).
- **(c)** async-lowered-import → enqueue-task wiring + the scheduler dispatch loop.
- **(d)** the smallest guest↔guest e2e: `async_two_tasks_stream_rendezvous.wat` (main mints a `stream<u8>`,
  spawns a subtask, writes; subtask reads → both COMPLETE + return). Exit-condition of the bundle.
- **(e)** adversarial corpus: both-tasks-read → `AsyncDeadlock`; drop-mid-rendezvous → `DROPPED`; subtask
  cancel-before-start → `CANCELLED`.

Each step keeps the full test net green (P3/P6 single-pass invariants untouched — this is the interp/host
driver, no JIT/codegen surface).

## Consequences

- Closes the last D-335 functional gap; enables (later, user-only) the `-Dwasi` `.p2→.p3` default flip.
- `driveCallbackLoop`'s contract generalises from "drive THE task" to "drive the task TABLE"; the single-task
  path is the 1-entry special case.
- New adversarial surface (race/join/cancel timing) — paid down by the (a)+(e) correctness corpus, which is a
  hard gate, not optional.
