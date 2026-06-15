# 0188 — WASI-0.3 P3 runner shape: a Zone-3 callback-loop ctx over async.zig

- **Status**: Accepted 2026-06-16
- **Author**: claude (autonomous, WASI-0.3 campaign D-335 Unit D-ηB; informed by the η/ζ surveys + the wasmtime async test fixtures + `CanonicalABI.md` canon_lift stackless path)
- **Composes with**: ADR-0187 (stackless callback ABI on a synchronous engine — the Zone-1 data model + `driveCallbackLoop`), ADR-0186 (Front D / D-335), ADR-0175 (the general engine `buildWasiP2Component`). Within ROADMAP §9.0 Front D — records the load-bearing layout (§5) of the new Zone-3 file; not a §1/§2 deviation.

## Context

`async.zig` (Zone-1, pure data) now holds the full CM-async model: handle/stream/future
tables, `WaitableSet` + `WaitableSetTable`, `Subtask`, the `CallbackCode`/`ReturnCode`
encodings, and `driveCallbackLoop(ctx, initial)` — the spec `canon_lift` stackless loop body
written as a generic over two **engine seams** (`invokeCallback`, `waitOn`). What is missing is
the Zone-3 wiring that turns those seams into real guest execution: instantiate an async
component, invoke its async-lifted export once, then drive the callback loop.

Creating a new Zone-3 file is a §5 layout decision → ADR-first (deviation watch). D-335 unit E
already names the file (`component_wasi_p3.zig`, coexists with P2, does not replace it).

## Decision

**The P3 runner is a thin Zone-3 orchestrator + a concrete ctx struct that installs the two
`driveCallbackLoop` seams against a live `Instance` + the async.zig tables.** No new engine
capability — the synchronous engine already suffices (ADR-0187).

1. **New file `src/api/component_wasi_p3.zig`** (Zone-3, sibling of `component_wasi_p2.zig`).
   It **reuses** `buildWasiP2Component` (`component_wasi_p2.zig:1687`) for decode/validate/
   instantiate — async lift is a property of the *export*, not the instantiation, so the
   general engine builds the instances unchanged.

2. **`P3CallbackCtx`** — the concrete ctx `driveCallbackLoop` is generic over. Holds:
   - `inst: *Instance` (the core instance exporting the task entry + the `callback` func),
   - `callback_name: []const u8` (resolved from `CanonOpts.callback` core:funcidx → its export name),
   - `*StreamFutureTable` + `*WaitableSetTable` (per-task, owned by the runner).
   Methods:
   - `invokeCallback(event_code, p1, p2) Error!u32` → packs `[3]Value{.i32}`, calls
     `inst.invoke(callback_name, &args, &results)` (`src/zwasm/instance.zig:219`), returns
     `results[0].i32` reinterpreted as the packed `u32`.
   - `waitOn(set_index) Error!EventTuple` → `(try sets.get(set_index)).poll(streams)`; a
     null poll (nothing ready) in a single-task host is a guest deadlock → trap
     (`error.AsyncDeadlock`), NOT a silent NONE. Cross-task progress is Unit E/ζ2.

3. **Async export detection**: an export is async-lifted iff its `Canon.lift.opts.is_async`
   (or `FuncType.is_async`). The runner calls the core task-entry func once via `inst.invoke`,
   `unpackCallbackResult`s the returned i32, then `driveCallbackLoop(&ctx, initial)`.

4. **`task.return` delivery**: the async export's result is delivered when the guest calls the
   `task.return` core import (decoded ηB.2) — wired as a host builtin in ζ2; until then the
   first end-to-end fixture is a **result-less** async export that returns EXIT immediately
   (no `task.return` needed), exercising the instantiate→invoke→loop→EXIT path.

## Fixture approach (self-provisioned, Mac-host)

Hand-authored `.wat` assembled with `wasm-tools 1.251.0` (`nix develop .#gen`), committed as
`.wasm` (runs on the test hosts via the edge-runner, per `toolchain_provisioning.md`). The
async-lift WAT spelling (verbatim, wasmtime `tests/misc_testsuite/component-model/async/lift.wast`):

```wat
(component
  (core module $m
    (func (export "callback") (param i32 i32 i32) (result i32) i32.const 0)
    (func (export "run") (result i32) i32.const 0))     ;; returns EXIT (0) immediately
  (core instance $i (instantiate $m))
  (func (export "run") async
    (canon lift (core func $i "run") async (callback (func $i "callback")))))
```

`async` is a bare canonopt keyword (0x06); `(callback (func $i "callback"))` is 0x07. Corpus
under `test/component/` (broader async corpus = unit G).

## Alternatives rejected

- **Fold P3 into `component_wasi_p2.zig`** — rejected: P2 is already large; async is a distinct
  ABI with its own loop; coexistence (not replacement) is the D-335 plan.
- **A stackful/fiber runner** — rejected by ADR-0187 (no fibers; stackless callback ABI).
- **`waitOn` returns NONE on empty poll** — rejected: masks a real single-task deadlock as
  progress (a `no_workaround.md` silent-fallback). Trap instead until real concurrency (ζ2/E).

## Consequences

- The runner is small (orchestration + a 2-method ctx); the hard logic already lives + is
  tested in `async.zig`.
- First green increment = the immediate-EXIT fixture through the full path; streams/futures/
  task.return delivery layer on in ζ2 + E.
- `error.AsyncDeadlock` is a new component-runner trap (not a silent fallback).
