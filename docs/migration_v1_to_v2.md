# zwasm v1 → v2: differences, gaps, and migration

> **Version mapping** (per the maintainer): **v1 = `$MY/zwasm`** (published
> `clojurewasm/zwasm`, releases `v1.0.0`–`v1.11.0`); **v2 = `$MY/zwasm_from_scratch`**
> (this redesign). Where an earlier note said "v0 vs v1", read it as **v1 vs v2**.
>
> **Focus**: this document leads with **what v1 has that v2 does *not*** (features
> *and* internal behavior) — the direction that matters for the v2 release. The
> reverse (v2-only gains) is summarized briefly at the end.
>
> **Method (anti-hallucination)**: every claim below was checked against the
> **actual source of both trees**, not their READMEs/ROADMAP/CHANGELOG (which were
> found to be stale in several places — e.g. v1's `gc.zig` header says "no-collect"
> but the code is mark-and-sweep; v2's `feature/threads/` is a stub README while the
> atomic *opcodes* are fully implemented elsewhere). Concrete `file:line` anchors
> are given so any claim can be re-verified. This supersedes the previous
> hastily-audited guide.

---

## 1. What v1 has that v2 does NOT (headline)

| Capability                                 | v1 (verified)                                                                                                                                                                                                    | v2                                                                                                 | Nature                                                                                          |
|--------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| **Fuel / instruction-budget metering**     | `Vm.fuel: ?u64`, `consumeInstructionBudget()`, `FuelExhausted` trap (`src/vm.zig`); `--fuel`, `zwasm_config_set_fuel`                                                                                            | **Absent** (0 matches for `fuel`/`instruction_budget` in `src/`)                                   | **Deferred**                                                                                    |
| **Timeout / deadline traps**               | `Vm.deadline_ns: ?i128`, ~1024-instr deadline checks, `TimeoutExceeded` (`src/vm.zig`); `--timeout`, `zwasm_config_set_timeout`                                                                                  | **Absent** (0 matches for `deadline`/`TimeoutExceeded`)                                            | **Deferred**                                                                                    |
| **Cooperative cancellation (host thread)** | `Vm.cancelled: std.atomic.Value(bool)`, `Vm.cancel()`, `zwasm_module_cancel()` (`src/vm.zig`, `src/c_api.zig`)                                                                                                   | **Absent** (only a WASI `cancel` syscall stub, unrelated)                                          | **Deferred**                                                                                    |
| **WAT (text format) loading**              | full 6019-line parser `src/wat.zig` (`watToWasm`), `-Dwat`, `loadFromWat`, CLI accepts `.wat`                                                                                                                    | **Absent by design** — delegated to `wasm-tools`/`wabt` (ADR-0159)                                | **Intentional**                                                                                 |
| **Custom host allocator via C API**        | `zwasm_config_set_allocator`, `zwasm_alloc_fn_t`/`zwasm_free_fn_t`                                                                                                                                               | wasm-c-api has no allocator hook                                                                   | **Intentional (API model change)**                                                              |
| **C-API linear-memory accessors**          | `zwasm_module_memory_{data,size,read,write}`                                                                                                                                                                     | reach memory via wasm-c-api `wasm_memory_data/_size` (different shape; no read/write copy helpers) | **Model change**                                                                                |
| **C-API WASI preopen / fd config**         | `zwasm_wasi_config_{preopen_dir,preopen_fd,set_stdio_fd}` (jtakakura #17/#20)                                                                                                                                    | `wasi.h` ships args/env/inherit-stdio only; **preopen deferred (ADR-0143 / D-251)**                | **Deferred**                                                                                    |
| **Rich CLI** (see §5)                     | `inspect`, `validate`, `features` subcommands; `--batch`, `--link`, `--profile`, `--sandbox`, `--allow-*`, `--max-memory`, `--fuel`, `--timeout`, `--interp`, `--trace`, `--dump-regir`, `--dump-jit`, `--cache` | only `run`/`compile` + `--invoke`/`--engine`/`--dir`/`--env`                                       | **Mixed** (lean CLI intentional, ADR-0159; resource flags follow the deferred runtime features) |

**Two buckets to be clear about:**

- **Intentional drops** — WAT parsing and the rich CLI verbs (`validate`/`inspect`/
  `features`/`wat`/`wasm`) are deliberately *not* in v2: validation is programmatic
  (`wasm_module_validate` / `Engine.compile`) and text/inspection is `wasm-tools`'
  job (ADR-0159). The custom C API was replaced wholesale by standard wasm-c-api.
- **Deferred (genuine v1-has/v2-lacks regressions)** — **fuel, timeout, and
  cooperative cancellation** are real runtime features that exist in v1 (several of
  them community-contributed: cancellation = jtakakura #28, timeout = DeanoC #6) and
  are **not yet present anywhere in v2** (`src/include/zwasm.h` is an empty
  placeholder reserving exactly these). The **C-API WASI preopen** path (also a
  jtakakura contribution, #17/#20) is likewise deferred. If v2's release intends to
  serve v1's embedders, these are the gaps to weigh.

---

## 2. Behavioral / internal differences (changed, not strictly missing)

| Area                                   | v1                                                                                                                                                                          | v2                                                                                                                                                                                                                                                                         |
|----------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **SIMD execution**                     | **interpreter-only** — `simd_x86.zig`/`simd_arm64.zig` are 15-line stubs (`emit()` returns `false`); v128 ops run in `src/vm.zig`                                          | **JIT-only** — real codegen in `engine/codegen/{arm64,x86_64}/op_simd_*.zig`; the **interpreter skips SIMD** (D-244)                                                                                                                                                      |
| **Engine model**                       | one monolithic `WasmModule` (load == instantiate)                                                                                                                           | `Engine` → `Module` → `Instance` (compile once, instantiate many)                                                                                                                                                                                                        |
| **Default engine**                     | JIT by default                                                                                                                                                              | **interpreter by default**; `--engine=jit` opt-in                                                                                                                                                                                                                          |
| **GC**                                 | `src/gc.zig` — header says "no-collect / append-only" but code is **mark-and-sweep with free-list reuse** (`shouldCollect`, `marked`); on by default (`-Dgc` default true) | **mark-sweep with conservative native-stack root scan** (`feature/gc/collector_mark_sweep.zig`); **opt-in** (`-Dgc=true`, default false)                                                                                                                                   |
| **Compile-to-disk**                    | `--cache` writes a **predecoded-IR cache** (`ZWCACHE` magic, `.zwcache`, `src/cache.zig`) keyed by hash                                                                     | `compile` produces a **`.cwasm` AOT artifact** (`engine/codegen/aot/`, ADR-0039); auto-detected by `run`                                                                                                                                                                   |
| **Atomics (threads proposal opcodes)** | `-Dthreads` (default true)                                                                                                                                                  | **present** — `i32/i64.atomic.*`, `atomic.rmw*`, `memory.atomic.wait/notify` validated + lowered + interp-handled (`instruction/wasm_1_0/memory.zig`, `validate/validator.zig`, `ir/lower.zig`). NB: `feature/threads/` (broader shared-memory/spawn) is a reserved stub. |
| **Feature build defaults**             | `wat`, `jit`, `simd`, `gc`, `threads`, `component` all **default true**                                                                                                     | `gc`, `component` **default false** (opt-in); `-Dwasm=v3_0`, `-Dwasi=p1`, `-Dengine=both` default                                                                                                                                                                          |
| **Component Model**                    | `src/component.zig` decoder + `canon_abi.zig` + `wit*.zig`, default-on                                                                                                      | `feature/component/` decoder + canon + **structural validation rules 1-4** + WIT lexer/parser/resolve; **opt-in** (`-Dcomponent`), e2e proven; embedding API not yet frozen                                                                                                |

---

## 3. C API migration (v1 custom `zwasm_*` → v2 wasm-c-api)

v1 shipped a single custom header `include/zwasm.h` (38 `zwasm_*` functions, a
`uint64_t[]` value convention, thread-local last-error). v2's primary C ABI is the
**upstream wasm-c-api** (`include/wasm.h`, ~300 `wasm_*` exports) plus a small
hand-authored `include/wasi.h`; `include/zwasm.h` is a near-empty placeholder.

| v1 (`zwasm.h`)                                                                  | v2                                                                                                   |
|---------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `zwasm_module_t` / `zwasm_config_t` / `zwasm_imports_t` / `zwasm_wasi_config_t` | wasm-c-api `wasm_engine_t` / `wasm_store_t` / `wasm_module_t` / `wasm_instance_t` / `wasm_func_t` … |
| `zwasm_module_new[_wasi][_configured]`, `_with_imports`                         | `wasm_module_new` → `wasm_instance_new` (imports via `wasm_extern_vec_t`)                           |
| `zwasm_module_invoke(args: uint64_t*, results)`                                 | `wasm_func_call(func, wasm_val_vec_t args, results)`                                                 |
| `zwasm_module_validate`                                                         | `wasm_module_validate`                                                                               |
| `zwasm_module_export_{count,name,param_count,result_count}`                     | `wasm_module_exports` → `wasm_exporttype_vec_t` / `wasm_functype_*`                                 |
| `zwasm_module_memory_{data,size,read,write}`                                    | `wasm_memory_data` / `wasm_memory_data_size` (no copy-read/write helpers)                            |
| `zwasm_config_set_{fuel,timeout,max_memory,force_interpreter,cancellable}`      | **no equivalent** (fuel/timeout/cancel deferred; see §1)                                            |
| `zwasm_config_set_allocator` (+ `zwasm_alloc_fn_t`)                             | **no equivalent**                                                                                    |
| `zwasm_wasi_config_{set_argv,set_env}`                                          | `wasi.h`: `zwasm_wasi_config_set_args` / `_set_envs`                                                 |
| `zwasm_wasi_config_{preopen_dir,preopen_fd,set_stdio_fd}`                       | `wasi.h`: `inherit_stdio` only; **preopen deferred (D-251)**                                         |
| `zwasm_module_cancel`                                                           | **no equivalent** (deferred)                                                                         |
| `zwasm_last_error_message` (thread-local string)                                | `wasm_trap_t` returned from calls; `wasm_trap_message`                                               |
| host imports via `zwasm_import_{new,add_fn}`                                    | `wasm_func_new` + `wasm_extern_vec_t` passed to `wasm_instance_new`                                  |

**Porting**: rewrite to the wasm-c-api lifecycle (`wasm_engine_new` →
`wasm_store_new` → `wasm_module_new` → `wasm_instance_new` → `wasm_func_call`).
WASI host setup moves to `wasi.h` (`zwasm_wasi_config_*` + `zwasm_store_set_wasi`).
There is currently **no C-API path for fuel/timeout/cancellation or directory
preopen** — embedders relying on those must stay on v1 or wait for the deferred work.

---

## 4. Zig API migration (`WasmModule` → `Engine`/`Module`/`Instance`/`Linker`)

v1 (`src/types.zig`, module root) exposed a monolithic `WasmModule` with many
load variants; v2 (`src/zwasm.zig` facade) separates the lifecycle.

**v1:**
```zig
const zwasm = @import("zwasm");
var module = try zwasm.WasmModule.load(allocator, wasm_bytes); // load == instantiate
defer module.deinit();
var args = [_]u64{ 10, 20 };
var results = [_]u64{0};
try module.invoke("add", &args, &results);   // results[0] == 30
```

**v2:**
```zig
const zwasm = @import("zwasm");
var eng = try zwasm.Engine.init(allocator, .{});
defer eng.deinit();
var module = try eng.compile(wasm_bytes);     // parse + validate, immutable + reusable
defer module.deinit();
var instance = try module.instantiate(.{});
defer instance.deinit();

var args = [_]zwasm.Value{ .{ .i32 = 10 }, .{ .i32 = 20 } };  // tagged union, not u64
var results = [_]zwasm.Value{.{ .i32 = 0 }};
try instance.invoke("add", &args, &results);  // results[0].i32 == 30

const add = instance.typedFunc(fn (i32, i32) i32, "add"); // comptime-typed call
const sum = try add.call(.{ 10, 20 });        // 30
```

| v1 (`WasmModule`)                                     | v2                                                                                                                                                                                                                                                               |
|-------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `WasmModule` (load==instantiate)                      | `Engine` / `Module` / `Instance` (one Module → many Instances)                                                                                                                                                                                                  |
| `load`, `loadWithOptions(Config)`                     | `Engine.init` + `engine.compile` + `module.instantiate`                                                                                                                                                                                                          |
| `loadFromWat` / `loadFromWatWithFuel`                 | **none** (WAT → wasm-tools; fuel deferred)                                                                                                                                                                                                                      |
| `loadWithFuel`, `Config{fuel,timeout,…}`             | **none** (deferred)                                                                                                                                                                                                                                              |
| `loadWasi[WithOptions]`                               | `Linker.defineWasi(.{})` then `lk.instantiate(&module)`                                                                                                                                                                                                          |
| `loadWithImports` / `loadWasiWithImports`             | `Linker.defineFunc("mod","name", fn(*Caller,…)R, fn)`                                                                                                                                                                                                           |
| `loadLinked(shared_store)`                            | shared imports via `Linker` (`defineMemory`, etc.)                                                                                                                                                                                                               |
| `invoke(name, []const u64, []u64)`                    | `instance.invoke(name, []Value, []Value)` (untyped)                                                                                                                                                                                                              |
| (no typed call)                                       | `instance.typedFunc(fn(P…)R, name).call(.{…})`                                                                                                                                                                                                                 |
| `invokeInterpreterOnly`                               | engine selected at build/run (`-Dengine`, `--engine`)                                                                                                                                                                                                            |
| `cancel()`                                            | **none** (deferred)                                                                                                                                                                                                                                              |
| `memoryRead(alloc,off,len)` / `memoryWrite(off,data)` | `instance.memory()` → `Memory.read(T,addr)` / `.write(addr,v)` / `.size()`                                                                                                                                                                                      |
| coarse error + `last_error` string                    | Zig error set with named traps (`error.DivByZero`, `error.Unreachable`, `error.IntOverflow`, `error.OutOfBoundsLoad`/`...Store`, `error.IndirectCallTypeMismatch`, `error.CallStackExhausted`, …); compile split: `error.ParseFailed` vs `error.ValidateFailed` |

Public v2 facade (`src/zwasm.zig`): `Engine`, `Module`, `Instance`, `Linker`,
`Caller`, `TypedFunc`, `Memory`, `Global`, `Table`, `Trap`, `Value`, `ExternKind`,
plus `ImportItem`/`ExportItem`/`ModuleImports`/`ModuleExports` introspection.

---

## 5. CLI migration

v1 (`src/cli.zig`) had 6 subcommands and ~25 flags; v2 (`src/cli/`) is
deliberately minimal (ADR-0159) — the embedding APIs are the primary surface.

|                     | v1                                                                                                 | v2                                                                            |
|---------------------|----------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| **Subcommands**     | `run`, `inspect`, `validate`, `compile`, `features`, `help`; bare `file.wasm`/`file.wat` shorthand | `run`, `compile`, `help`, `--version`; **no** `inspect`/`validate`/`features` |
| **Invoke**          | `--invoke <fn>`, `--batch` (stdin)                                                                 | `--invoke <name>[=a,b,…]` (no `--batch`)                                     |
| **Engine**          | `--interp` (else JIT default)                                                                      | `--engine <interp\|jit>` (interp default)                                     |
| **WASI**            | `--dir`, `--env`, `--allow-read/write/env/path/all`, `--sandbox`                                   | `--dir <host>[:<guest>]`, `--env KEY=VAL` (no `--allow-*`, no `--sandbox`)    |
| **Imports**         | `--link name=file`                                                                                 | **none** (use the Zig/C `Linker`)                                             |
| **Resource limits** | `--fuel <N>`, `--timeout <ms>`, `--max-memory <N>`                                                 | **none** (deferred)                                                           |
| **AOT/cache**       | `--cache` (predecoded-IR `.zwcache`); `compile` → cache                                           | `compile -o out.cwasm` (AOT `.cwasm`); `run` auto-detects `.cwasm`            |
| **Diagnostics**     | `--profile`, `--trace=CATS`, `--dump-regir=N`, `--dump-jit=N`                                      | env-driven `ZWASM_DEBUG` / `ZWASM_DIAG` (no CLI dump flags)                   |

---

## 6. WASI

Both ship **WASI 0.1 (preview1)** (v1: ~19 preview1 functions; v2: a fuller
preview1 surface wired across interp + JIT + AOT, with a deny-by-default
capability model and `--dir` preopen at the CLI). **Differences:**

- v2 runs WASI on **all three execution paths** (interp / JIT `--engine=jit` /
  AOT `.cwasm`); v1's WASI was tied to its engine selection.
- **WASI 0.2 / preview2** (Component Model) is **opt-in experimental in v2**
  (`-Dcomponent`, a real `wasm32-wasip2` component runs e2e) — absent in v1.
- **C-API WASI preopen** regressed: present in v1's `zwasm.h`, deferred in v2's
  `wasi.h` (§1 / §3, D-251). CLI `--dir` preopen works in both.

---

## 7. What v2 gains over v1 (brief — reverse direction)

For completeness (less of a release concern): standard **wasm-c-api** C ABI;
**Engine/Module/Instance** lifecycle with comptime-**typed calls**; **AOT
`.cwasm`**; **real JIT SIMD** (x86_64 SysV + Win64 + arm64); a **collecting** GC
with conservative native-stack rooting; deeper **Component Model** + structural
validation; the **zone-layered** architecture; and a named-trap Zig error set.

---

## 8. Verification appendix (how to re-check)

- v1 tree: `/Users/shota.508/Documents/MyProducts/zwasm/` — `src/vm.zig` (fuel/
  deadline/cancel), `src/wat.zig` (WAT), `src/c_api.zig` + `include/zwasm.h`
  (C API), `src/cli.zig` (CLI), `src/gc.zig`, `src/cache.zig`, `build.zig`.
- v2 tree: this repo — `src/zwasm.zig` (Zig facade), `include/{wasm,wasi,zwasm}.h`
  (C API), `src/cli/` (CLI), `src/feature/`, `src/instruction/`, `build.zig`.
- Absence checks used: `grep -rniE 'fuel|deadline|TimeoutExceeded' src --include='*.zig'`
  → **0** in v2; `feature/threads/` is a stub but atomic opcodes are implemented in
  `instruction/wasm_1_0/memory.zig` + `validate/validator.zig` + `ir/lower.zig`.
- Reference: ADR-0159 (CLI/WAT delegation), ADR-0143 / D-251 (WASI preopen defer),
  ADR-0039 (`.cwasm`), ADR-0170 (Component Model), `docs/v1_contributor_history.md`
  (the v1 community features — cancellation/timeout/preopen — now listed as gaps).
