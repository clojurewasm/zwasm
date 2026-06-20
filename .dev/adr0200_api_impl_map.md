# ADR-0200 JIT-backed embedding API — implementation map

> **Doc-state**: ACTIVE
> Survey 2026-06-21 of the C-API + Zig-facade instantiate path, mapping where the
> per-instance engine fork (interp `Runtime` vs `JitInstance`) goes. Decided shape
> in ADR-0200 (§"API shape": `EngineKind{auto,jit,interp}`, default auto→JIT,
> per-instance, interp coexists). This is the multi-cycle execution map.

## Fork seam

- **Fork point (both surfaces)**: `instantiateInternal` (`src/api/instance.zig:716`)
  — the interp `Runtime` is alloc'd at `:734-735` (`runtime.Runtime.init`), budgets
  armed `:738-744`, `Instance{.runtime = inst_rt}` at `:751-755`. Branch on engine
  kind BEFORE `:734`: interp `Runtime` (current) vs `runner.JitInstance.init`/
  `initLinked`. The Zig facade `Module.instantiate` (`src/zwasm/module.zig:143`)
  already routes through `instantiateFacade`→`instantiateInternal`, so one fork
  covers both.
- **Instance struct** (`src/runtime/instance/instance.zig:43`, `runtime: ?*Runtime`
  at `:51`): add a PARALLEL `jit: ?*anyopaque` slot (NOT overloading `runtime` —
  `single_slot_dual_meaning`). `instance.zig` is **Zone 1**, must NOT import Zone-2
  `engine/`, so hold the JIT side as `?*anyopaque` (mirrors `module: ?*const anyopaque`
  `:50`); cast to `*JitInstance` only at the Zone-3 boundary (`api/` + `src/zwasm/`).
- **Engine knob home**: per-instance → `Module.InstantiateOpts` (`module.zig:126`)
  `engine` field; engine-wide default → `Engine.InitOpts` (`engine.zig:34`, empty today).
  Thread into `InstantiateLimits` (`instance.zig:704`) or a sibling param.

## JitInstance substrate (`src/engine/runner.zig:880-1115`)

Owns `compiled: CompiledWasm` + `owned: RuntimeOwned`; borrows `wasm_bytes`. Surface:
`init`/`initLinked` (`:885`), `invoke` (`:995`, D-477 buffer thunk), `invokeMulti`
(`:1082`, TypedResult[]), `setFuel` (`:968`), `setMemoryPagesLimit` (`:990`),
`setInterruptFlag` (`:960`, `*const atomic.Value(u32)`). **Must not move once referenced**
(`exportedFuncTarget` returns `&self.owned.rt`) → own via a stable heap pointer like
`inst_rt`. WASI: no host attached by init; set `jit_inst.owned.rt.wasi_host` (add a
setter). Export lookup is via `findExportFunc(wasm_bytes)` (`:996`) — JIT populates NO
`exports_storage`/`func_ptrs_storage` (the **largest divergence** from interp).

## Accessor blast radius (need a `runtime == null` JIT arm)

- C: `wasm_func_call` (`api/instance.zig:1659` `inst.runtime orelse return null`,
  interp `dispatch.run` at `:1693`) → route to `JitInstance.invoke`/`invokeMulti`.
- Facade MUTATORS (asserts `runtime != null` → replace with per-engine branch):
  `src/zwasm/instance.zig` interrupt `:54`, clearInterrupt `:60`, setMemoryPagesLimit
  `:76`, setTableElementsLimit `:87`, setFuel `:95` → call the JitInstance setters.
- Facade reads (null-safe today, need JIT arms to be useful): `fuelRemaining :100`,
  `memory :153`, `global :164`, `table :184`, `exportFuncSig :139`, `invoke :219`
  (whole interp body `:228-320`, `dispatch.run` `:301`).
- **setInterruptFlag flag**: interp `interrupt()` writes `rt.interrupt_flag_storage`
  directly; the JIT arm needs a host-owned atomic with a STABLE address (ADR-0179 #3a).

## Host imports + WASI (ADR-0200 plumbing #4)

Interp: `buildBindings` (`instance.zig:430+`) resolves imports → WASI via
`wasi.lookupWasiThunk` + `store.wasi_host` (`:445-453`), host funcs via `hostFuncThunk`
(`:507`), into `rt.host_calls[]`. JIT analog: `RuntimeOwned.dispatch[]`
(`setup.zig:259-261`, default `&hostDispatchTrap`) + cross-module via
`func_import_targets` (`initLinked :897-906`, `FuncImportTarget` setup.zig:35); WASI via
`rt.wasi_host` + `src/wasi/jit_dispatch.zig`. Wire `buildBindings`' resolution into
`initLinked`'s `func_import_targets` + set `rt.wasi_host`.

## Smallest first increment (opt-in JIT, ONE no-import compute export)

> **LANDED @7bfc49c8d** via the Zig-facade seam (not `instantiateInternal`): the fork
> lives in `instantiateFacade` + a new `instantiateJit` (C-path `wasm_func_call` arm +
> `wasm_instance_new` engine knob are a later slice). `.auto` still routes to interp
> pending the host-import bridge. Result typing uses `JitInstance.exportFuncSig` (added).

4 files (+1 optional):
1. `src/runtime/instance/instance.zig` — add `jit: ?*anyopaque` slot + deinit it.
2. `src/api/instance.zig` — fork in `instantiateInternal` (engine=jit → `JitInstance.init`,
   stable heap ptr into `Instance.jit`, `runtime = null`); JIT teardown; invoke arm in
   `wasm_func_call` (`runtime == null` → cast `jit`, marshal args→`[]u64`, `invoke`).
3. `src/zwasm/module.zig` — `engine` field on `InstantiateOpts` + thread to `instantiateInternal`.
4. `src/zwasm/instance.zig` — `invoke` JIT arm (`handle.runtime == null` → cast `handle.jit`,
   `JitInstance.invoke`, unpack `?u64`). (facade may import Zone-2 `engine/` — it already
   imports `interp/dispatch.zig`.)
5. (opt) `src/zwasm/engine.zig` — engine-wide default in `InitOpts`.

TDD: a Zig-facade test instantiating a `(param i32 i32)(result i32) add` module with
`engine = .jit`, calling it, asserting 5 — proving the opt-in JIT path end-to-end
(native arm64; Rosetta x86_64). Then iterate: SIMD export (the headline), accessors,
host-import bridge, D-314 sandbox sign-off, the C + Zig mini-consumer, cljw signal.
