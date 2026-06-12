# `resource_counter.wasm` — wit-bindgen GUEST-DEFINED resource fixture (D-322)

A real wit-bindgen (0.36) Rust component exporting a RESOURCE:
`counter-api.counter` with `constructor(start)`, `increment()`, `get()`.
The decode side works since D-322 narrowed (deftype 0x3f + rule 12);
this fixture pins the RUNTIME residual.

## Measured gap (Phase I evidence, 2026-06-13)

`buildWasiP2Component` fails with **UnknownImport**: the core module
imports the SYNTHESIZED canon builtins for its own exported resource —

```wat
(import "[export]zwasm:restest/counter-api" "[resource-new]counter" (func ...))
(import "[export]zwasm:restest/counter-api" "[resource-drop]counter" (func ...))
```

— i.e. the component's `(canon resource.new/drop ...)` definitions must
be wired by the graph builder to per-component resource-table-backed
core funcs (`core_funcs` `.resource_new/.resource_drop/.resource_rep`
entries exist in the decode model; the instantiation layer doesn't
provide them yet). After that, the typed API needs own-handle arms in
`ComponentValue` to drive `[constructor]counter` -> own<counter> ->
`[method]counter.increment`.

## Reproduce (Mac gen shell)

Same recipe as README_typed_payload.md with
`resource_counter.{wit,rs}`; `cargo build --target wasm32-wasip2
--release`, `wasm-tools strip`.
