# c_api v128 — spec excludes it permanently; industry-uniform pattern is "v128 internal, never c_api"

**Citing**: commits `1d8d7d15` (initial reframe + audit) + `00cb63de` (D-170 / D-079 (ii) discharge: regression-detector test confirms cross-module v128 wiring works as predicted; no `instantiateRuntime` fix needed). Audit subagent run 2026-05-24 covered wasmtime + wasmer + v1 zwasm + wasm-c-api spec.

## What we believed

Through cycles 38-56 of §9.13-V (ADR-0110 Value=16 widen) and Phase B.3 / C / D close work, several debts (D-079 (ii), D-170, D-171, D-172, D-173) carried framings that mixed two distinct concerns:

1. **Cross-module v128 global import threading** (internal: pointer-aliasing for shared 16-byte cells across instances).
2. **c_api `wasm_global_get/set` for v128** (external: read/write a v128 value through the C ABI).

The framings tended to bundle both as "v0.1.0 RC scope, deferred to D-075 native facade" — implying the c_api layer would eventually expose v128.

## What the industry says (2026-05-24 audit)

**Three reference runtimes audited**: wasmtime, wasmer, v1 zwasm. Plus the wasm-c-api upstream spec.

### Storage shape (Section A)

All three use **uniform 16-byte cells**:

- wasmtime: `VMGlobalDefinition.storage: [u8; 16]` (`crates/wasmtime/src/runtime/vm/vmcontext.rs:548-551`)
- wasmer: `RawValue` union with `u128` slot (`lib/types/src/value.rs:9-17`)
- v1 zwasm: `Global.value: u128` (`src/store.zig:150-158`)
- zwasm v2 post-Phase A.4g: `Value` extern union widened to 16 bytes per ADR-0110

### Cross-module import wiring (Section B)

All three use **pointer aliasing**:

- wasmtime: `VMGlobalImport.from: VmPtr<VMGlobalDefinition>` (`vmcontext.rs:315-330`)
- wasmer: `VMGlobal.vm_global_definition: MaybeInstanceOwned<VMGlobalDefinition>` aliases source (`lib/vm/src/global.rs:6-10`)
- v1 zwasm: `Global.shared_ref: ?*Global = null` (`src/store.zig:155-157`)
- zwasm v2: `Runtime.globals: []*Value` post-A.4g

### c_api v128 surface (Section C — the load-bearing finding)

**wasm-c-api spec `include/wasm.h`**:
- Line 180-187: `enum wasm_valkind_enum { WASM_I32, WASM_I64, WASM_F32, WASM_F64, WASM_EXTERNREF, WASM_FUNCREF }` — **no `WASM_V128`**.
- Line 329-338: `wasm_val_t.of` union contains `i32 / i64 / f32 / f64 / ref` — **no 128-bit slot**.
- Line 452-459: `wasm_global_new / wasm_global_get / wasm_global_set` all operate on `wasm_val_t` — **structurally cannot carry v128**.

**wasmtime c_api binding** (`crates/c-api/src/global.rs:35-79`): conforms to spec; v128 globals **cannot be created or queried** via c_api. Wasmtime offers `wasmtime_val_t` (extended Rust API) outside the spec for v128 access.

**wasmer c_api binding** (`lib/c-api/src/wasm_c_api/instance.rs:38-99`): same — accepts v128 imports as opaque `Extern*` but cannot get/set v128 values through `wasm_val_t`.

**Industry uniform rule**: v128 globals **work internally** (pointer aliasing across instances) but are **never exposed via wasm-c-api**. Access is only via the runtime's native (non-spec) language API.

### Test fixtures (Section D)

- wasmtime `tests/all/globals.rs`: scalar cross-module tests + v128 single-instance test; **no v128 cross-module test**.
- wasmer: scalar cross-module examples only.
- wasm-c-api `example/global.c`: scalar types only.

**Spec testsuite does not exercise cross-module v128 imports**: this is **not** a deferral signal — it reflects that v128 globals are a Wasm 2.0 SIMD proposal feature whose cross-module aspect wasn't added to the spec test corpus. Runtime correctness is verified via runtime-specific internal tests.

## Decisions for zwasm v2

### Permanently NOT in c_api

- `wasm_global_get` / `wasm_global_set` / `wasm_global_new` for v128 — **spec-prohibited**, matches wasmtime + wasmer.
- Any future `WASM_V128` valkind addition to `wasm_val_t` — **rejected** as spec divergence.
- Implication: D-171 (mutable global zombie test) covers scalar globals only; v128 is excluded from the c_api accessor surface.

### Permanently NOT zwasm-specific c_api extension either

zwasm v2 does NOT create a `zwasm_val_t` analog for v128 access. The pattern wasmtime adopts (`wasmtime_val_t`) is a v1 legacy choice; the current direction (ADR-0109 native Zig API inversion) is to use Zig-native types directly (`Value` tagged union with v128 variant) without going through a C ABI.

### Required at v0.1.0 RC (= Phase 9 / Phase 10 close)

1. **Cross-module v128 global import threading works internally** (matches wasmtime/wasmer/v1).
2. **Test fixture in our `test/edge_cases/p9/v128_cross_instance/`** (we write the fixture; upstream has none — that's expected, not a deferral signal).
3. **c_api scalar accessors** (`wasm_global_get/set` for i32/i64/f32/f64, `wasm_extern_as_global/table/memory`, etc.) — these ARE in spec, should be normal completion work for D-171/D-172/D-173.

### ADR-0109 native Zig API scope clarification

The "Zig-side v128 global access" use case lives entirely in ADR-0109's Engine + Linker + TypedFunc API surface, NOT in any c_api extension. This is the design-coherent line:

```
                                                 ┌─ Wasm code (interp / JIT) — v128 internal ✅
zwasm v2 runtime (Value=16 byte uniform cell) ───┼─ Zig native API (ADR-0109)  — v128 typed access ✅
                                                 └─ wasm-c-api (wasm_val_t)    — v128 PROHIBITED ❌ (industry-aligned)
```

## What this prevents

Future sessions re-paying the cost of:

1. Believing "v0.1.0 RC adds v128 to wasm_val_t" (we don't; spec doesn't allow it).
2. Filing debts that mix "internal v128 wiring" and "c_api v128 exposure" — those are different concerns with different lifecycles.
3. Treating "no upstream spec test for cross-module v128" as a deferral signal (it's not; we write our own test).
4. Adding `WASM_V128` to our `ValKind` enum (would break spec conformance).

## References

- ADR-0110 §"Industry comparison" (Value=16 widen rationale; pre-audit framing)
- ADR-0109 (Proposed; native Zig API as the v128-typed access path)
- ADR-0025 (c_api facade; scoped to spec-compliant surface)
- D-079 / D-170 / D-171 / D-172 / D-173 debt rows (reframed per this lesson)
- `docs/runtime_deep_comparison.md` §1-2 (prior industry comparison — Value width axis)
- Industry audit subagent run 2026-05-24 (this commit)
