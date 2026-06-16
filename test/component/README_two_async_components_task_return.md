# `two_async_components_task_return.wasm`

ADR-0195 step (d-a) — the smallest guest↔guest async DATA transfer.

Two nested child components:

- **B** exports `tick: async func() -> u32`. Its core `tick` calls
  `task.return(42)` (imported from a synthetic `(core instance $deps)`
  exporting the `canon task.return (result u32)` core func) to deliver its
  result, then returns `0` (EXIT). Its `callback` is a no-op that returns EXIT.
- **A** async-imports `tick` and exports `run: async func()`. A's `run`
  async-calls `tick` (the lowered import's core signature is
  `(param retptr i32) -> (result i32)` — a result-bearing async lower carries a
  retptr param), drops the status, then EXITs.

The outer component instantiates B, instantiates A with `tick` bound to B's
lifted export, and re-exports A's `run`.

## What it exercises

Drives the graph runner's cross-component async path AND the graph-level
`task.return` wiring: when `driveAsyncMain("run")` runs, A's `run` enqueues B's
subtask; B's `tick` callee calls `task.return(42)`; the graph host func captures
`42` into B's `TaskDescriptor.result` (the per-task result slot — NOT the single
`WasiP2Ctx.task_return` slot the single-component P3 runner uses, which would
collide across multiple graph tasks). After the loop, both tasks are `.done` and
B's subtask `result == 42`.

## Regenerate

```sh
nix develop .#gen -c wasm-tools parse \
  test/component/two_async_components_task_return.wat \
  -o test/component/two_async_components_task_return.wasm
nix develop .#gen -c wasm-tools validate --features all \
  test/component/two_async_components_task_return.wasm
```
