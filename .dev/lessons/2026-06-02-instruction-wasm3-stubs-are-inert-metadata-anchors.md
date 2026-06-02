# `instruction/wasm_3_0/<op>.zig` stubs returning `NotMigrated` are INERT metadata anchors, not the live dispatch

2026-06-02. While surveying for the `array.init_data`/`array.init_elem` JIT-emit
chunk, an Explore subagent read `src/instruction/wasm_3_0/array_init_data.zig`,
saw `validate`/`lower`/`interp` all `return error.NotMigrated`, and concluded
"the interpreter is unimplemented" — which would have contradicted the whole
bundle premise (a module can't JIT-compile if validate/lower fail first).

## The trap

`array.fill` — fully working on JIT, corpus-green — has an IDENTICAL `NotMigrated`
stub in `instruction/wasm_3_0/array_fill.zig`. There are **126** such stubs in
`wasm_3_0/`. They are NOT the live dispatch path: they exist only to export
`op_tag` / `wasm_level` / `wasi_level` (the per-arch codegen emit file imports
the stub as `meta` for those three consts, per ADR-0074).

## Where the real handlers live

- **validate**: `src/validate/validator.zig` (a switch over sub-opcodes).
- **lower**: `src/ir/lower.zig` (decode → ZirOp).
- **interp**: the `*_ops.zig` aggregator that `register()`s into the dispatch
  table (e.g. `array_ops.zig:59 table.interp[op(.@"array.init_data")] = …`).
- **JIT emit**: `engine/codegen/<arch>/ops/wasm_3_0/<op>.zig` + trampoline.

## Rule

Don't infer "unimplemented" from a `NotMigrated` per-op stub. Grep the op name
across `validator.zig` / `lower.zig` / `*_ops.zig` (the live sites), and compare
against a known-working sibling's stub (it looks identical). Measure the actual
corpus/test behaviour — don't trust the stub's surface (same family as
`spec-jit-corpus-fails-are-gaps-not-stale-state`).
