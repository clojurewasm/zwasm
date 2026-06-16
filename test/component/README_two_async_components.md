# p17 Component Model fixture: two_async_components (cross-component async graph)

A hand-written component WAT exercising **guest↔guest cross-component
async routing** (ADR-0195 c-2b): component A async-imports component B's
async `tick` export and async-calls it from A's own async `run` export.
Drives the two-component async graph end-to-end through the stackless
callback scheduler (`feature/component/async.zig:driveScheduler` over a
shared `TaskTable`).

## Why hand-written component WAT (not a compose tool)

Same rationale as `README_adder_graph.md`: `wasm-tools` has no WIT-level
`compose`/`wac` on PATH, and `component link` is shared-everything
dynamic linking, not composition. The component-model **text format**
natively expresses nested `(component ...)` + `(instance (instantiate
...) (with ...))`, and `wasm-tools parse` assembles it in one step.

## Spelling requirements (the parse/validate-passing shape)

- Child **B** exports `tick: async func()`; its core `tick` returns
  `i32.const 0` (= EXIT immediately) and provides a `callback` core func.
- Child **A** declares the import as `(func $tick async)` and lowers it
  with `(canon lower (func $tick) async (memory $mem "mem"))` — the async
  lowering needs a core **memory** (subtask storage), so A instantiates a
  tiny `(memory (export "mem") 1)` module. The lowered core func returns
  an i32 status (the async-call result code).
- A's core `run` calls the async-lowered `tick`, `drop`s the status, and
  returns `i32.const 0` (EXIT); A's `run: async func()` lift carries a
  `callback`.
- Outer: `(instance $b (instantiate $B))`, then `(instance $a
  (instantiate $A (with "tick" (func $b "tick"))))`, then `(export "run"
  (func $a "run"))`.

Full spelling notes:
`.dev/lessons/2026-06-17-cross-component-async-wat-spelling.md`.

## Reproduce

```sh
wasm-tools parse two_async_components.wat -o two_async_components.wasm
wasm-tools validate --features all two_async_components.wasm
```

## Behaviour

`driveAsyncMain("run")` seeds task 0 = A's `run`; the async boundary
trampoline mints B's `tick` subtask into the SAME scheduler `TaskTable`;
`driveScheduler` drives BOTH tasks to `done` (both EXIT immediately) with
no `AsyncDeadlock`. This is real cross-component async routing — not A
running in isolation.

## Files

- `two_async_components.wat`   — source (single-file component WAT)
- `two_async_components.wasm`  — the fixture (632 B)
