# D-489 step 4: jit.callcount profiler pins the divergence to json.Marshal's encoder dispatch

**Date**: 2026-06-21
**Tool**: new `ZWASM_DEBUG=jit.callcount` per-function-entry profiler
(`src/support/call_profile.zig`; interp bumps at call/call_indirect, x86_64-jit
bumps via an absolute-address `INC` in the prologue). Diff interp vs x86_64-jit
profiles on `min.wasm`.

## Result

interp executes **161** distinct funcs; x86_64-jit only **63**. The JIT skips the
**entire** json encoder:

| func | interp | jit |
|---|---|---|
| `encoding/json.typeEncoder` | 4 | **0** |
| `encoding/json.newTypeEncoder` | 3 | **0** |
| `encoding/json.structEncoder` | 1 | **0** |
| `(*encodeState).…` (reflectValue) | 1 | **0** |
| `reflect.toType` | 25 | **1** |
| `runtime.alloc` | 181 | 24 |

The JIT *does* reach `reflect.TypeOf` / `interfaceTypeAssert` / `reflect.toType`
(once), then **never dispatches to any encoder** → `json.Marshal` returns empty.
So it is NOT a deep-in-the-encoder bug: Marshal gets the type but **bails before
the encoder lookup**.

## Next (step 5)

The divergence is in the Marshal→encoder-dispatch path. `reflect.toType` (idx=243,
25→1) is the prime suspect — a reflect type-resolution that returns wrong/early on
x86_64, so the encoder-lookup (`typeEncoder`/`valueEncoder`) is skipped. Disassemble
`reflect.toType` (+ its caller) arm64-vs-x86_64 via jit.dump, OR trace its args/return
(it's called once in jit — a tiny window). The miscompiled scalar is in there.

## Reusable

The `jit.callcount` profiler is a permanent primitive: for ANY interp-vs-jit
divergence, diff the per-function call profiles to localize to a function in
log-few steps (vs reading a 1MB binary's asm blind).
