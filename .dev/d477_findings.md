# D-477 — JIT host-invoke signature completeness: findings (裏取り)

> **Doc-state**: ACTIVE
> Phase I investigation for the D-477 bundle (full multi-arg typed
> host→guest JIT `--invoke`). Mandated 裏取り-first per the debt row.
> Sources cited inline; survey 2026-06-20.

## Problem

The JIT `--invoke` path only invokes **zero-arg** exports
(void / single-scalar / single-v128). Any param, ≥2 results, or a
ref/v128 result with a name → `Error.UnsupportedEntrySignature`
(`runner.zig:657`) and the CLI hard-rejects multi-arg on the JIT engine
(`main.zig:257`). The interp path already does full multi-arg/result
(`invoke_args.zig` → C-API `wasm_func_call` → interp). User directive:
SIMD-requiring paths MUST be JIT, so the JIT must not lack multi-arg.

## How senior runtimes do it (array-call ABI)

- **wasmtime**: `VMArrayCallNative = fn(callee_vmctx, caller_vmctx,
  *ValRaw, len) -> bool`. `ValRaw` = 16-byte union, one slot/value;
  args+results **share one buffer** sized `max(params,results)`.
  `Func::call` writes each arg via `to_raw()`, calls, reads each result
  via `from_raw`. The native-CC marshalling is a **Cranelift-generated
  trampoline** (`array_to_wasm_trampoline`: `load_values_from_array` →
  native CC args → call body → store results back), NOT hand asm.
  (`vmcontext.rs:46-51,1454-1553`; `func.rs:1177-1206`;
  `cranelift/src/compiler.rs:1420-1490`.)
- **wasmer**: same shape — Cranelift wrapper with a `values_vec` ptr;
  `load` each arg, `call_indirect` body, `store` each result.

## zwasm already has the analogue (ADR-0106 buffer-write ABI)

- `BufferWriteFn = fn(rt, results: [*]u64, args: [*]const u64)
  callconv(.c) ErrCode` (`entry_buffer_write.zig:65-69`). One **u64
  slot** per value (i32/f32 low-32; i64/f64/ref full-64).
- `invokeBufferWrite` (`entry_buffer_write.zig:84-101`) = the generic
  N-arg/N-result host entry, with the D-245/D-311 cohort-clobber
  trampoline.
- `JitInstance.invokeMulti` (`runner.zig:999-1031`) already drives it
  against ANY sig — gated on `module.hasThunk(func_idx)`.

## The actual gap = `wrapper_thunk.emit`

The per-function machine-code thunk that marshals the args/results u64
arrays ↔ the body's register CC (`wrapper_thunk.zig`). Today it only
emits:

- **arm64** (`emitAarch64:506`): GPR-class only; `n_results ∈ {2,3}`;
  `n_params ∈ {0,1}` (1 only for the 2-result shape).
- **x86_64 SysV** (`emitX8664SysV:181`): `params ≤ 1`; 2-int / 3-int-MEM
  results.
- **Win64** (`emitX8664Win64:312`): `params ∈ {0,1,3}` GPR; 2-int /
  3-int-MEM results.
- `all_gpr_class` gate (`:610`) rejects f32/f64/v128 entirely.

`hasThunk` is therefore false for: >1 param, any float, any v128,
>3 results, mixed FP+GPR.

## Plan (the array-call collapse ADR-0106 designed but never wired to `--invoke`)

1. **Generalize `wrapper_thunk.emit`** to arbitrary N args + N results,
   per-arch, classifying each value (GPR int/ref → X/RDI.. ; FP f32/f64
   → V/XMM.. ; v128 → see §v128) and assigning to the next register of
   its class per AAPCS64 / SysV / Win64, spilling to stack when the
   class's argument registers are exhausted. Load each arg from
   `args[8*i]`; store each result reg to `results[8*i]`.
2. **Re-point `runWasiLenient` `--invoke`** at `invokeMulti` /
   `invokeBufferWrite` for the >0-param / >1-result / FP shapes instead
   of `Error.UnsupportedEntrySignature` (`runner.zig:657`).
3. **Drop the CLI reject** (`main.zig:257`) for the JIT engine.
4. Optional cleanup: collapse the `dispatchScalar*` / `callXxx_yyy`
   shape explosion (CAREFUL — the spec-corpus runner consumes them).

### v128 (sibling, may need its own slice)

The buffer ABI is 8-byte slots; v128 is 16 bytes → does NOT fit a u64
slot. Options: 16-byte slots (wasmtime's choice) for a v128-capable
buffer variant, or keep the separate `callV128NoArgs`-style path for
v128 and route only scalar/ref through the buffer. Decide in the v128
slice; scalar+ref multi-arg is the first, highest-value target.

## Divergence vs ROADMAP §2 / wasmtime

wasmtime generates ONE sig-parameterised Cranelift trampoline at compile
time; zwasm hand-emits a per-shape wrapper thunk. The D-477 work keeps
the hand-emit (P3/P6 single-pass, no Cranelift) but generalises it to
arbitrary shapes — the same end capability, re-derived in zwasm's
emit-bytes idiom.

## Correctness-first (bundle gate)

Before extending the JIT thunk: pin the **interp multi-arg invoke** as
the oracle with characterization tests (multi i32/i64/f32/f64 args,
multi results), and a test that the JIT path now MATCHES the interp for
each shape as it lands. The current reject is also pinned so the
removal is deliberate.
