# two_async_components_stream_blocking.wat — BLOCKING cross-component async stream rendezvous

ADR-0195 step (d-c-2): the guest↔guest async **stream** transfer across a
component graph in the BLOCKING (read-first → park → resume) case — the
read-first path d-c-1 deferred. This is the LAST functional gap of the
multi-task async campaign + the hardest piece (the waitable-set delivery seam).

## Shape

- **Component B** exports `tick: async func(stream<u8>)`. Its core `tick`
  receives the READABLE end handle and `stream.read(r, &buf, 2)` with **no bytes
  yet available** → the read PARKS (returns `BLOCKED`, `0xffffffff`). B then
  `waitable-set.new` + `waitable.join`s the read-end and returns `WAIT(set)` → B's
  task becomes `.waiting` (the genuine block, NOT the synchronous d-c-1 path).
- **Component A** imports `tick`, exports `run: async func() -> u32`. A's core
  `run` mints a `stream<u8>` (readable `r` + writable `w`), async-calls `tick(r)`
  (B runs synchronously during the call and PARKS), then `stream.write(w, &{20,22},
  2)` — the rendezvous resolves B's parked read: the 2 bytes are copied into B's
  memory + B's read-end gets a `STREAM_READ` `pending_event`. A `task.return`s 0
  and EXITs.
- The scheduler then polls B's `.waiting` task → `GraphAsyncCtx.pollSet` fetches
  the graph-shared set, finds the pending event, re-enters B's `callback`, which
  reads the delivered bytes (`20+22 == 42`) and `task.return(42)`, EXIT.
- The test (`component_tests.zig`, "ADR-0195 d-c-2 …") asserts **B's OWN** task
  result (task 2) == 42, proving the value crossed A→B through the BLOCKING
  park-then-deliver path + the pollSet/waitable-set delivery.

## two_async_components_stream_deadlock.wat — the adversarial guard

Identical EXCEPT A omits the `stream.write`. B's parked read is never resolved,
so B stays `.waiting` with no deliverable `pollSet` event and a whole scheduler
pass makes no progress → `driveScheduler` traps `error.AsyncDeadlock` (loud — the
(e)-adjacent correctness guard, never a hang or silent completion).

## Build

`wasm-tools` 1.251.0 (no `compose`/`wac`); hand-authored nested `(component …)`.
The `waitable-set.new`/`waitable.join` builtins need the same `async` import
namespace as the stream ops; the import func type must be declared `async` and
`canon lower … async` needs a `(memory …)` (cf. the WAT-spelling lesson).

```sh
wasm-tools parse two_async_components_stream_blocking.wat -o two_async_components_stream_blocking.wasm
wasm-tools validate --features all two_async_components_stream_blocking.wasm
wasm-tools parse two_async_components_stream_deadlock.wat  -o two_async_components_stream_deadlock.wasm
wasm-tools validate --features all two_async_components_stream_deadlock.wasm
```
