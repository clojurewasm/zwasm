# 0189 — WASI-0.3 ζ2: canon-async-builtin dispatch (task.return first, stream/future after)

- **Status**: Accepted 2026-06-16
- **Author**: claude (autonomous, WASI-0.3 campaign D-335 Unit D-ζ2; survey of `component_wasi_p2.zig` synthDef/ResourceBuiltinCtx + `async.zig` SharedStream + `CanonicalABI.md` canon_stream_new/canon_task_return + the verified `.wat` canon-import plumbing).
- **Composes with**: ADR-0188 (P3 runner shape), ADR-0187 (async data model). Within ROADMAP §9.0 Front D. Records the load-bearing decision of WHERE the per-task async state lives + the ends↔shared ownership fork — both change behaviour across `component_wasi_p2.zig` + `async.zig`.

## Context

The P3 runner (ADR-0188) runs an async export end-to-end, but the guest's canon
async builtins (`stream.*`/`future.*`/`task.return`) are still rejected at
`component_wasi_p2.zig` `synthDef` with `error.UnsupportedWasiImport`. ζ2 wires
them to real host trampolines. Two design questions surfaced in survey:

1. **Where does per-task async state live?** The trampolines reach host state via
   `Caller.data(T)` — the same mechanism the guest-resource builtins use
   (`ResourceBuiltinCtx{ctx: *WasiP2Ctx, ...}`). `WasiP2Ctx` is heap-stable for
   the build's lifetime (`BuiltComponent.ctx`).
2. **How do a stream's two ends find their shared rendezvous?** `async.zig`'s
   `StreamFutureEnd` (in the `StreamFutureTable`) does NOT hold a pointer to its
   `SharedStream`; the rendezvous methods take `shared` as a parameter. But
   `canon stream.new` mints a readable + a writable end that MUST share one
   `SharedStream` (spec: `ri|(wi<<32)`). So a stream end needs a link to its
   shared, and the shared needs an owner/lifetime (freed when both ends drop).

## Decision

**Per-task async state lives in `WasiP2Ctx`** (created in `buildWasiP2Component`,
reached by trampolines via `Caller.data`):
- `streams: async.StreamFutureTable`, `sets: async.WaitableSetTable` move from
  the P3 runner's locals INTO `WasiP2Ctx`; `runWasiP3Main` uses `built.ctx.*`.
- `synthDef` returns new `Def` variants (`.async_builtin{op, type_index}` and
  `.task_return_builtin{...}`); `defineSynth` binds trampolines keyed by an
  `AsyncBuiltinCtx{ctx: *WasiP2Ctx, ...}` (template: the resource-builtin path).

**Sequencing — task.return FIRST, then stream/future** (task.return needs no
`SharedStream`, so it lands the ctx-wiring + dispatch plumbing on the simplest
builtin):
- **Slice 1 — `task.return`**: add `task_return: ?u32` to `WasiP2Ctx` (minimal
  single-`i32`-result case; multi-value/typed result later). Trampoline
  `p2TaskReturn(caller, val: i32)` stores it; `runWasiP3Main` surfaces it (return
  value / out-param). Fixture: a `(result u32)` async export whose core entry
  calls `task.return(42)` then returns EXIT; the test asserts 42. WAT plumbing
  (verified vs `wasi_p2_cli_env.wat`): `(core func $tr (canon task.return
  (result u32)))` → `(core instance $deps (export "task-return" (func $tr)))` →
  `(with ...)`; the core module `(import ... (func $tr (param i32)))`.
- **Slice 2 — `stream.new`/`future.new` + the ends↔shared link**: `StreamFutureEnd`
  gains a `shared: u32` handle into a NEW ctx-owned `shared_streams`/`shared_futures`
  arena (a 3rd table; refcount = 2 ends, freed on the second drop). `stream.new`
  trampoline (`() -> i64`): create the shared, mint readable+writable ends linked
  to it, return `ri|(wi<<32)`. Then read/write/drop wire onto the existing
  rendezvous methods.
- **Slice 3+ — read/write/cancel/drop + a WAIT-path e2e fixture** (a stream that
  delivers a real event, exercising `driveCallbackLoop`'s WAIT branch through the
  runner's `waitOn`).

## Alternatives rejected

- **Async state as P3-runner locals** (current) — rejected: trampolines bound at
  instantiation (inside `buildWasiP2Component`) cannot reach the runner's later
  stack frame. Ctx is the only heap-stable seam.
- **`StreamFutureEnd` embeds `SharedStream` by value** — rejected: two ends must
  share ONE mutable rendezvous; by-value gives each its own. A handle into a
  ctx-owned shared arena keeps single-ownership + a clear drop/free point.
- **Wire stream.new first** — rejected: it forces the shared-ownership design
  immediately; task.return proves the ctx+dispatch plumbing on a shared-free
  builtin first (smaller blast radius, faster green).

## Consequences

- `WasiP2Ctx` grows async fields shared by the P2 build path + the P3 runner —
  acceptable (P2 never mints async builtins, so the fields stay empty there).
- task.return's minimal single-i32 form is a deliberate first step; typed/
  multi-value results are a later slice (tracked in D-335).
- The shared-arena refcount is the one piece of genuinely new lifetime logic;
  Slice 2 lands it with adversarial drop-order tests.

## Revision (2026-06-16) — Slice 3 read/write COMPLETION gates on Unit E

Investigation (lesson `2026-06-16-stackless-stream-completion-needs-host-peer`)
established that zwasm's **stackless single-task** P3 runner (ADR-0187, no fibers)
**cannot reach a guest-to-guest stream/future read/write COMPLETION** (count > 0):
a blocked read/write returns to the callback loop with no held continuation, so
the peer can never act within the same task. The original Slice 3 exit — "a
WAIT-path e2e (guest blocks on read → a write delivers STREAM_READ)" — therefore
**gates on a HOST stream peer (Unit E) or a multi-task scheduler**, NOT pure ζ2.

Re-scope (ADR-0132 carve-out — autonomous, references genuinely-later-phase work):
- **ζ2 Slice 3 (now)** wires stream/future `read`/`write`/`cancel`/`drop` returning
  the single-task-testable outcomes: **BLOCKED** (no peer), **DROPPED** (peer
  dropped first), zero-length write. Element marshalling (Unit-C store/load) runs
  only on COMPLETION, so it **defers with COMPLETION**.
- The **WAIT-path e2e + read/write COMPLETION + element marshalling** move to
  **Unit E** (host stream peer) — the natural driver that supplies the peer.
- The Zone-1 rendezvous (`SharedStream`) is correct + peer-agnostic; only the
  driver is missing. No async.zig change needed.
