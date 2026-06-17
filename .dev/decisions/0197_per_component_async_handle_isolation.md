# ADR-0197 — Cross-component async handle isolation via an ownership ledger (D-463)

- Status: **Implemented 2026-06-18 (@633189454)**. Phase II adversarial fixture
  `two_async_components_stream_isolation` (RED→GREEN, "found void"→trap) + Phase IV ownership-ledger landed:
  `GraphAsync.owners` + `GraphFutureCtx.child_idx` + `GraphChild.idx`; owner-set on stream/future mint;
  owner-check in stream/future write/read/drop + waitable.join; owner-transfer in the boundary trampoline. All
  6 trusted `two_async_components_*` fixtures + the isolation fixture green; D-463 discharged. Phase V retro below.
- Date: 2026-06-18
- Refines: ADR-0195 d-b-2 (the graph-shared `StreamFutureTable`/`SharedTable` was the least-change path that
  made cross-component future/stream rendezvous work; this ADR closes its deliberate handle-isolation
  simplification, tracked as **D-463**).

## Context

`GraphAsync` (`src/api/component_graph.zig`) gives ALL child components ONE shared `StreamFutureTable`
(`streams`) + ONE `WaitableSetTable` (`sets`) + ONE `SharedTable` (`shared`). Every `graphStream*`/
`graphFuture*`/`graphWaitable*` builtin resolves `ctx.as.streams.get(handle)` against that one table
regardless of which child is calling (`GraphFutureCtx = { as: *GraphAsync, elem_size }` — no child identity).

So a future/stream handle minted in child A is a bare i32 that is **directly valid in child B's lookup** at the
same index. This is functionally correct for a TRUSTED composed graph (the `two_async_components_*` fixtures
pass, mutation-proven) but **violates Component-Model handle isolation**: each component instance owns its own
index space; a handle crossing a boundary TRANSFERS (ownership moves) rather than being globally index-visible.
Concretely, child B can reach child A's *un-granted* handles by guessing indices — the same
cross-component-security family as the D-305 boundary error-trap.

## Decision

Make the async handle tables **per-component**, with **call-time end-transfer** at the async boundary:

> **Revision 2026-06-18 (during Phase IV scoping)** — the original Decision below (relocate `streams`/`sets`
> to per-`GraphChild` + boundary end-transfer + `pending_graph_reads` re-key) was supplanted by the
> **ownership-ledger** design after Phase-I deepening showed the relocation forces the *generic* scheduler
> (`async.zig driveScheduler`/`GraphAsyncCtx.pollSet`) to thread per-child table identity for every WAITING
> task — a Zone-1 change with no guest-observable benefit. Component-Model handle values are **opaque to
> conformant guests** (a component never observes another's index space), so a single graph-shared table with a
> **graph-layer handle→owner ledger**, enforced at the guest-facing builtins, is equally spec-conformant and
> isolates B from A's handles with a fraction of the blast radius (the scheduler stays untouched). The relocation
> wording is retained below struck-through as the rejected path.

1. **Ownership ledger in the graph layer.** `GraphAsync` keeps ONE shared `streams`/`sets`/`shared`, and gains
   `owners: AutoHashMapUnmanaged(u32 handle → u32 child_idx)`. `GraphFutureCtx` gains `child_idx`. Every
   guest-facing builtin that operates on an existing end (`graphStream{Write,Read}`, `graphFuture{Write,Read}`,
   `graphStreamDrop`, `graphWaitableJoin`) asserts `owners.get(handle) == ctx.child_idx` → else the canonical
   guest trap (`error.Unreachable`). `graphStream/FutureNew` records `owners.put(both_ends, ctx.child_idx)` on
   mint. The shared backing channel (`SharedTable`) is reached only THROUGH an owned end, so it needs no ledger.

2. **Ownership transfer at the boundary.** `asyncBoundaryParamTrampoline(caller, handle)` retags
   `owners.put(handle, callee.idx)` IFF the handle is a tracked end (`owners.contains` — scalars/resource handles
   are untracked and untouched). Ownership MOVES per Component-Model lower-of-an-owned-handle semantics; the
   caller can no longer access it afterward. `GraphChild` gains a stable `idx` (its position in `graph.children`).

3. **No scheduler / no Zone-1 / no re-key change.** `driveScheduler` + `pollSet` keep using the graph-shared
   tables internally (host-side, guest-invisible); `pending_graph_reads` stays keyed by the (graph-unique) end
   handle. The ledger is consulted ONLY at the guest builtins — the isolation boundary the guest actually sees.

~~Original: relocate `streams`/`sets` to per-`GraphChild`; `GraphFutureCtx` gains `*StreamFutureTable`/
`*WaitableSetTable`; `SharedTable` stays graph-shared; boundary end-transfer removes-from-caller + mints-callee-local;
`pending_graph_reads` re-keys raw-handle → shared-slot id.~~ (rejected — scheduler/Zone-1 cost; see Revision.)

## Alternatives rejected

- **Status quo (no isolation).** The D-463 simplification — functionally correct for trusted graphs but a
  spec-fidelity + sandboxing miss; the project bar is 100% spec + sandboxing-triad-everywhere.
- **Relocate to per-component `StreamFutureTable`/`WaitableSetTable` (the original Decision).** Spec-canonical
  "separate index spaces," but forces the generic stackless scheduler (`driveScheduler`/`pollSet`, Zone-1) to
  resolve each WAITING task's set/stream against its owning child's table → child-identity threading through a
  layer that today is component-agnostic, plus a `pending_graph_reads` re-key. Since handle values are
  guest-opaque, the only delta over the ledger is independent per-child exhaustion caps (negligible: `MAX_LENGTH`
  is huge). Not worth the Zone-1 blast radius for a lightweight runtime → rejected in favour of the ledger.

## Correctness-first plan (II before IV — hard self-gate)

- **Phase II (correctness-assurance FIRST).** (a) Characterization: the 6 `two_async_components_*` fixtures stay
  green at every commit (they are the trusted-graph regression net). (b) **Adversarial isolation fixture**
  `two_async_components_stream_isolation.wat`: child A mints TWO streams (granted w1 + private w2), async-calls
  B passing ONLY w1; B's `tick` attempts `stream.write` on the index of A's PRIVATE end. Today this SUCCEEDS
  (global table — the leak); the test asserts it TRAPS (B's per-component table has no such index). Authored as
  a RED test (`expectError`) pinning the post-fix guarantee. This is the 正しさ担保 gate; no Phase IV code lands
  before it is red-then-driving.
- **Phase IV (implementation).** `GraphAsync.owners` ledger + `GraphFutureCtx.child_idx` + `GraphChild.idx` →
  owner-set on mint → owner-check in the guest-facing builtins → owner-transfer in the boundary trampoline. Full
  async test net green at EVERY commit.
- **Phase V retro.** Mark D-463 discharged; add a Revision note to ADR-0195 d-b-2 (its no-isolation simplification
  is now superseded by this ledger pass).

## Consequences

- Closes D-463; cross-component async handles are isolated (B cannot read/write/drop/join an end it was not
  granted) — untrusted composition safe, spec-conformant (handle opacity).
- `GraphAsync` keeps its graph-shared tables (scheduler untouched) + one small `owners` ledger; the isolation
  boundary lives entirely in the Zone-3 graph builtins. `async.zig` (Zone-1) is unchanged.
- No public API change; no WIT/fixture-semantics change for the 6 trusted fixtures (their passed end transfers
  ownership; the holder keeps its own end). New adversarial fixture `two_async_components_stream_isolation`.
- P3/P6 single-pass invariants untouched (interp/host driver only; no JIT/codegen surface).

## Phase V retrospective (2026-06-18)

- **Hit the 完成形?** Yes for the isolation dimension: a child can no longer read/write/drop/join a
  stream/future end it was not granted (the `two_async_components_stream_isolation` fixture goes from a silent
  cross-component data-injection — A read 42 from a stream only B should have touched — to a hard trap). 100%
  spec (handle opacity) + sandboxing-triad extended to graph async handles.
- **Design pivot during the campaign** (logged in the Revision above): the per-component-table plan was dropped
  for the ownership ledger when Phase-IV scoping exposed the scheduler/Zone-1 threading cost for zero
  guest-observable benefit. The ADR process worked — the cheaper, equally-conformant design surfaced before code.
- **New debt:** none from this pass. Untouched residuals remain **D-464** (graph cancel-op / wider boundary
  shapes — a handle crossing via a result or aggregate param is not yet transfer-tagged because those shapes are
  themselves deferred; when they land, mirror the `asyncBoundaryParamTrampoline` retag).
- **Superseded simplification:** ADR-0195 d-b-2's graph-shared-table "no rebind needed" note — annotated there.
