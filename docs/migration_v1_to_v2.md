# zwasm v1 → v2 migration guide

zwasm **v2** is a ground-up rewrite (releases `v1.0.0`–`v1.11.0` are v1; v2 is
published as `v2.x.x` pre-release tags such as `v2.0.0-alpha.1`). It keeps full
Wasm spec coverage (Wasm 1.0/2.0/3.0, WASI 0.1) but **breaks the surfaces on
purpose** — the C API, the Zig API, and the CLI all changed. This guide tells you
what to do to port, then documents what changed and why.

## License change: v1 (MIT) → v2 (Apache-2.0)

v1 was **MIT**; v2 is **Apache-2.0**. It is still a permissive license, but it
adds an explicit patent grant and an attribution requirement (keep the `LICENSE`
notice when redistributing). Review it if your project has license-compliance
constraints.

## How this guide was written

Every claim was checked against the v2 source tree, not its prose docs (those
drift). Repo-relative `path:line` anchors are given throughout so you can
re-verify — see [Part 4](#part-4--verify-it-yourself).

---

## Part 1 — Should you migrate yet?

Most users can migrate now. **Check this list first** — if you depend on something
in it, either stay on v1 for now, or use the noted alternative.

| If you rely on…                                                      | Status in v2                                                                                                              | What to do                                                                |
|-----------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------|
| **`.wat` (text format) loading**                                      | **Removed by design** — v2 only consumes binary `.wasm`                                                                  | Pre-assemble with `wasm-tools` / `wabt` (`wat2wasm`) and feed the `.wasm` |
| **fuel / timeout / cancellation / memory-limit via the C API or CLI** | **Shipped**: C `zwasm_instance_*` setters in `zwasm.h`; CLI `--fuel`/`--timeout`/`--max-memory` (both engines)           | Migrate to the instance-level setters (v1 was config-level)               |
| **WASI directory preopen via the C API**                              | **Shipped** — `wasi.h` has `zwasm_wasi_config_preopen_dir` + `inherit_env` (plus args/envs/inherit-stdio)               | Use the C API directly, or the CLI `--dir` / the Zig facade               |
| **Custom host allocator via the C API**                               | **Removed** (standard wasm-c-api has no allocator hook)                                                                   | No direct replacement; raise an issue if you need it                      |
| **C-API linear-memory copy helpers** (`..._memory_read/write`)        | **Removed** — reach memory via `wasm_memory_data` / `wasm_memory_data_size`                                              | Copy through the raw `wasm_memory_data` pointer yourself                  |
| **watchOS / 32-bit (ILP32) targets**                                  | **Deferred**                                                                                                              | Stay on v1                                                                |

Everything else — running `.wasm`, WASI 0.1, the embedding lifecycle, full Wasm
3.0 — is available. Pick your surface below and port.

---

## Part 2 — How to migrate, by surface

### 2.1 CLI users

v2's CLI is deliberately minimal (only `run` and `compile`); inspection and text
tooling are delegated to `wasm-tools` / `wabt`.

| Task                    | v1                                            | v2                                                                                               |
|-------------------------|-----------------------------------------------|--------------------------------------------------------------------------------------------------|
| Run a module            | `zwasm run f.wasm` / bare `zwasm f.wasm`      | `zwasm run f.wasm` (no bare-file shorthand)                                                      |
| Run `.wat`              | `zwasm f.wat`                                 | pre-assemble to `.wasm` first (no `.wat` support)                                                |
| Invoke a named export   | `--invoke fn` / `--batch`                     | `--invoke <name>[=a,b,…]` (no `--batch`)                                                        |
| Pick the engine         | `--interp` (JIT otherwise)                    | `--engine <interp\|jit>` (**interp is the default**; jit adds SIMD)                              |
| Preopen a directory     | `--dir`, plus `--allow-*`, `--sandbox`        | `--dir <host>[:<guest>]` (no `--allow-*`, no `--sandbox`)                                        |
| Pass env vars           | `--env`                                       | `--env KEY=VAL`                                                                                  |
| Link extra modules      | `--link name=file`                            | not in the CLI — use the Zig/C `Linker`                                                         |
| Resource limits         | `--fuel`, `--timeout`, `--max-memory`         | `--fuel` / `--timeout` / `--max-memory` (both engines; fuel units are engine-specific)           |
| Compile / cache to disk | `--cache` → predecoded-IR `.zwcache`         | `zwasm compile f.wasm -o out.cwasm` → AOT `.cwasm`; `run` auto-detects it                       |
| Inspect / validate      | `inspect`, `validate`, `features` subcommands | **removed** — use `wasm-tools`; validation is programmatic (the API validates on compile)       |
| Diagnostics             | `--profile`, `--trace`, `--dump-regir/-jit`   | env-driven: `ZWASM_DEBUG`, `ZWASM_DIAG` (no CLI dump flags)                                      |

**Note:** both engines run the **full WASI** surface, but the **interpreter does
not execute SIMD** — SIMD code requires `--engine jit` (this is by design; see
[§3.2](#32-behavioral--internal-differences)).

### 2.2 C-API users

v1 shipped a single custom header (`include/zwasm.h`, ~38 `zwasm_*` functions with
a `uint64_t[]` value convention and a thread-local last-error). **v2's C ABI is the
standard upstream [wasm-c-api](https://github.com/WebAssembly/wasm-c-api)**
(`include/wasm.h`, ~300 `wasm_*` exports) plus a small hand-authored `include/wasi.h`
for WASI host setup. `include/zwasm.h` is now an empty placeholder.

**Lifecycle** — rewrite to the wasm-c-api sequence:

```c
wasm_engine_t*   engine = wasm_engine_new();
wasm_store_t*    store  = wasm_store_new(engine);
wasm_module_t*   module = wasm_module_new(store, &wasm_bytes);
wasm_instance_t* inst   = wasm_instance_new(store, module, &imports, &trap);
wasm_func_call(func, &args, &results);
```

**Symbol map:**

| v1 (`zwasm.h`)                                              | v2 (wasm-c-api + `wasi.h`)                                                                                                             |
|-------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| `zwasm_module_t` / `_config_t` / `_imports_t`               | `wasm_engine_t` / `wasm_store_t` / `wasm_module_t` / `wasm_instance_t` / `wasm_func_t` …                                              |
| `zwasm_module_new[_wasi][_configured]`, `_with_imports`     | `wasm_module_new` → `wasm_instance_new` (imports via `wasm_extern_vec_t`)                                                             |
| `zwasm_module_invoke(uint64_t* args, results)`              | `wasm_func_call(func, wasm_val_vec_t args, results)`                                                                                   |
| `zwasm_module_validate`                                     | `wasm_module_validate`                                                                                                                 |
| `zwasm_module_export_{count,name,param_count,result_count}` | `wasm_module_exports` → `wasm_exporttype_vec_t` / `wasm_functype_*`                                                                   |
| `zwasm_module_memory_{data,size,read,write}`                | `wasm_memory_data` / `wasm_memory_data_size` (no copy-read/write helpers)                                                              |
| `zwasm_last_error_message` (thread-local)                   | `wasm_trap_t` from the call + `wasm_trap_message`                                                                                      |
| host imports via `zwasm_import_{new,add_fn}`                | `wasm_func_new` + `wasm_extern_vec_t` passed to `wasm_instance_new`                                                                    |
| `zwasm_wasi_config_{set_argv,set_env}`                      | `wasi.h`: `zwasm_wasi_config_set_args` / `_set_envs`                                                                                   |
| `zwasm_wasi_config_{preopen_dir,preopen_fd,set_stdio_fd}`   | `wasi.h`: `zwasm_wasi_config_preopen_dir` + `inherit_env` + `inherit_stdio`; `preopen_fd`/`set_stdio_fd` have no equivalent            |
| `zwasm_config_set_{fuel,timeout,max_memory,…}`             | `zwasm.h` instance-level: `zwasm_instance_set_fuel` / `_set_memory_pages_limit` / `_interrupt` (timeout = host timer + interrupt)      |
| `zwasm_config_set_allocator`                                | **no equivalent**                                                                                                                      |
| `zwasm_module_cancel`                                       | `zwasm.h`: `zwasm_instance_interrupt` (+ `_clear_interrupt`)                                                                           |

**WASI host setup** (`include/wasi.h`) — the full surface is:

```c
zwasm_wasi_config_t* cfg = zwasm_wasi_config_new();
zwasm_wasi_config_set_args(cfg, argc, argv);
zwasm_wasi_config_set_envs(cfg, count, keys, vals);
zwasm_wasi_config_inherit_env(cfg);              // snapshot host environ
zwasm_wasi_config_inherit_stdio(cfg);
zwasm_wasi_config_preopen_dir(cfg, ".", "/");    // preopen host dir → guest path
zwasm_store_set_wasi(store, cfg);   // takes ownership of cfg
```

**Building / linking from C or Rust:**

```sh
zig build static-lib     # → zig-out/lib/libzwasm.a + zig-out/include/{wasm,wasi,zwasm}.h

cc -Izig-out/include app.c zig-out/lib/libzwasm.a -lm                      # macOS
cc -Izig-out/include app.c zig-out/lib/libzwasm.a -lm -Wl,-z,noexecstack   # Linux
```

`-lm` is required (zwasm references `trunc`/`truncf`/…). On Linux,
`-Wl,-z,noexecstack` silences a benign linker warning (the link succeeds without
it). No `compiler-rt` shim is needed — Zig bundles it into the archive (v1 needed
`-Dcompiler-rt`).

### 2.3 Zig API users

v1 exposed a monolithic `WasmModule` (load == instantiate). v2 separates the
lifecycle into `Engine` → `Module` → `Instance` (compile once, instantiate many),
with comptime-typed calls and a named-trap error set.

**Before (v1):**

```zig
const zwasm = @import("zwasm");
var module = try zwasm.WasmModule.load(allocator, wasm_bytes); // load == instantiate
defer module.deinit();
var args = [_]u64{ 10, 20 };
var results = [_]u64{0};
try module.invoke("add", &args, &results);   // results[0] == 30
```

**After (v2):**

```zig
const zwasm = @import("zwasm");
var eng = try zwasm.Engine.init(allocator, .{});
defer eng.deinit();
var module = try eng.compile(wasm_bytes);     // parse + validate; immutable, reusable
defer module.deinit();
var instance = try module.instantiate(.{});
defer instance.deinit();

// untyped call (tagged-union values, not u64)
var args = [_]zwasm.Value{ .{ .i32 = 10 }, .{ .i32 = 20 } };
var results = [_]zwasm.Value{.{ .i32 = 0 }};
try instance.invoke("add", &args, &results);  // results[0].i32 == 30

// or a comptime-typed call
const add = instance.typedFunc(fn (i32, i32) i32, "add");
const sum = try add.call(.{ 10, 20 });         // 30
```

**Method map:**

| v1 (`WasmModule`)                         | v2                                                                                                                                            |
|-------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| `WasmModule` (load == instantiate)        | `Engine` / `Module` / `Instance` (one Module → many Instances)                                                                               |
| `load`, `loadWithOptions`                 | `Engine.init` + `engine.compile` + `module.instantiate`                                                                                       |
| `loadFromWat`                             | **none** (assemble `.wat` → `.wasm` externally)                                                                                              |
| `loadWasi[WithOptions]`                   | `Linker.defineWasi(.{})` then `linker.instantiate(&module)`                                                                                   |
| `loadWithImports` / `loadWasiWithImports` | `Linker.defineFunc("mod", "name", fn(*Caller, …) R, fn)` / `defineMemory` / …                                                               |
| `invoke(name, []u64, []u64)`              | `instance.invoke(name, []Value, []Value)`                                                                                                     |
| (no typed call)                           | `instance.typedFunc(fn(P…) R, name).call(.{…})`                                                                                             |
| `invokeInterpreterOnly`                   | engine chosen at build/run time (`-Dengine`, `--engine`)                                                                                      |
| `memoryRead` / `memoryWrite`              | `instance.memory()` → `Memory.read(T, addr)` / `.write(addr, v)` / `.size()`                                                                 |
| coarse error + `last_error` string        | Zig error set with named traps (`error.DivByZero`, `error.OutOfBoundsLoad`, …); compile splits `error.ParseFailed` vs `error.ValidateFailed` |

The public facade (`src/zwasm.zig`) exports: `Engine`, `Module`, `Instance`,
`Linker`, `Caller`, `TypedFunc`, `Memory`, `Global`, `Table`, `Trap`, `Value`,
`ExternKind`, plus `ImportItem` / `ExportItem` / `ModuleImports` / `ModuleExports`
for introspection.

**Sandboxing (Zig API).** The v1 `Vm`/`Config` resource controls map onto
`InstantiateOpts` + `Instance` methods. **Budgets are finite by default**, so
`module.instantiate(.{})` is bounded out of the box — pass `.unmetered` to opt out
for trusted code.

```zig
var inst = try module.instantiate(.{
    .fuel = .{ .limited = 5_000_000 },   // default: .{ .limited = 1_000_000_000 }
    .max_memory_pages = .{ .limited = 64 }, // default: .{ .limited = 4096 } (256 MiB)
});
// dynamic adjust:
inst.setFuel(1000);                  // → error.OutOfFuel on exhaustion
_ = inst.fuelRemaining();
inst.setMemoryPagesLimit(128);       // memory.grow past it returns -1
inst.setTableElementsLimit(10_000);  // table.grow past it returns -1
inst.interrupt();                    // from any thread → guest traps error.Interrupted
inst.clearInterrupt();
_ = inst.interruptRequested();
```

For a wall-clock timeout, run a host timer thread that calls `inst.interrupt()`
after the deadline. The facade `Instance` produces interpreter-backed instances,
so these setters drive the interpreter; the **CLI** `--engine jit` enforces
`--fuel` / `--timeout` / `--max-memory` directly via the JIT's prologue +
back-edge polls.

---

## Part 3 — Reference: what changed and why

### 3.1 Feature parity

| Capability                                       | v1                            | v2                                                                                                                   |
|--------------------------------------------------|-------------------------------|----------------------------------------------------------------------------------------------------------------------|
| Fuel / instruction budget                        | `Vm.fuel`, `--fuel`, C API    | Zig API + C `zwasm_instance_set_fuel` + CLI `--fuel`, BOTH engines (JIT units = entries + loop iterations)           |
| Timeout / deadline                               | `Vm.deadline_ns`, `--timeout` | CLI `--timeout <ms>` (both engines) + host timer → interrupt (Zig/C)                                                |
| Cooperative cancellation                         | `Vm.cancel()`, C API          | Zig `Instance.interrupt()` + C `zwasm_instance_interrupt`                                                            |
| Host memory-size limit                           | `--max-memory`, C API         | **Zig API** (`InstantiateOpts.max_memory_pages`, `Instance.setMemoryPagesLimit`)                                     |
| Table-elements limit                             | —                            | **new in v2** (`Instance.setTableElementsLimit`)                                                                     |
| WAT text-format loading                          | full `.wat` parser            | **removed by design** (delegated to `wasm-tools` / `wabt`)                                                           |
| Custom host allocator (C API)                    | yes                           | **removed** (no wasm-c-api hook)                                                                                     |
| C-API memory copy helpers                        | `..._memory_read/write`       | **removed** (use `wasm_memory_data`)                                                                                 |
| C-API WASI directory preopen                     | yes                           | **shipped** (`zwasm_wasi_config_preopen_dir` + `inherit_env`)                                                        |
| Rich CLI verbs (`inspect`/`validate`/`features`) | yes                           | **removed** (lean CLI; use `wasm-tools` + programmatic validation)                                                   |

The sandboxing controls (fuel/timeout/cancel/mem-cap) are **fully present on BOTH
engines** (the JIT polls at function entry + every loop back-edge) and exposed on
all three surfaces — Zig API, C `zwasm.h` setters, and the CLI flags.

### 3.2 Behavioral & internal differences

| Area                          | v1                                                   | v2                                                                                                                                                             |
|-------------------------------|------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Engine model**              | one `WasmModule` (load == instantiate)               | `Engine` → `Module` → `Instance` (compile once, instantiate many)                                                                                            |
| **Default engine**            | JIT by default                                       | **interpreter by default**; `--engine jit` opt-in                                                                                                              |
| **SIMD**                      | interpreter-only (codegen was stubbed)               | **JIT-only**; the interpreter does **not** execute SIMD (by design — in an interpreter the dispatch cost dominates the vector work, so it carries no benefit) |
| **GC**                        | mark-and-sweep, on by default                        | mark-sweep with conservative native-stack root scan; **opt-in** (`-Dgc`, default off)                                                                          |
| **Atomics (threads opcodes)** | on by default                                        | implemented (validated + lowered + interpreted); broader shared-memory/spawn is a reserved stub                                                                |
| **Compile to disk**           | `--cache` → predecoded-IR `.zwcache`                | `compile` → AOT `.cwasm`; `run` auto-detects it                                                                                                               |
| **Component Model**           | decoder, on by default                               | decoder + canonical ABI + structural validation + WIT; gated by `-Dwasi>=p2` (default `p2`, so **on**); a real `wasm32-wasip2` component runs e2e             |
| **Build defaults**            | `wat`/`jit`/`simd`/`gc`/`threads`/`component` all on | `-Dwasm=v3_0`, `-Dwasi=p2`, `-Dengine=both`; component **on** (via `-Dwasi>=p2`), `gc` default **off**                                                         |

### 3.3 WASI

Both ship **WASI 0.1 (preview1)**. In v2:

- WASI runs on **all execution paths** — interpreter, `--engine jit`, and AOT
  `.cwasm` — with a deny-by-default capability model and `--dir` preopen at the CLI.
- **WASI 0.2 / preview2** (Component Model) is **default-ON** via the WASI tier
  `-Dwasi>=p2` (default `p2`; `-Dwasi=p1` for a lean opt-out — the former
  `-Dcomponent` flag is folded into the version axis) — real `wasm32-wasip2` Rust/Go
  components run e2e (corpus 158/0/0). **WASI 0.3 / preview3** (async) compiles at
  `-Dwasi=p3` (opt-in; the default `p2` keeps it out until it settles).
- **C-API preopen** is **shipped** (`zwasm_wasi_config_preopen_dir`
  + `inherit_env`); the CLI `--dir` and Zig facade also cover it.
- **Preopen confinement:** guest paths are escape-guarded (absolute and `..` are
  rejected), and a guest cannot plant an escaping symlink (`path_symlink` refuses a
  target that would leave the preopen root). Following a *pre-existing* on-disk
  symlink that escapes a writable preopen is not yet beneath-confined — only
  relevant when an untrusted guest is given a writable preopen.

### 3.4 What v2 gains over v1

The standard **wasm-c-api** C ABI; the **Engine/Module/Instance** lifecycle with
comptime-**typed calls**; **AOT `.cwasm`** artifacts; **real JIT SIMD** (x86-64
SysV + Win64, arm64); a **collecting** GC with conservative native-stack rooting;
deeper **Component Model** support with structural validation; a zone-layered
internal architecture; and a named-trap Zig error set.

---

## Part 4 — Verify it yourself

Claims above are anchored to the v2 source tree (paths are repo-relative):

- **Sandboxing / budgets:** `src/zwasm/module.zig` (`InstantiateOpts`, `Budget`,
  finite defaults), `src/zwasm/instance.zig` (`setFuel` / `interrupt` / limit
  setters), `src/interp/dispatch.zig` (per-instruction fuel decrement + throttled
  interrupt poll), `src/runtime/runtime.zig` (`fuel` / `interrupt` fields).
- **C API:** `include/wasm.h` (wasm-c-api), `include/wasi.h` (WASI host setup),
  `include/zwasm.h` (placeholder), `src/api/`.
- **CLI:** `src/cli/` (`dispatch.zig` usage text, `main.zig` flag parsing,
  `compile.zig`).
- **SIMD JIT-only:** `src/interp/` has no SIMD handlers; per-op v128 files under
  `src/instruction/wasm_2_0/` are not interpreter-wired; real codegen lives in
  `src/engine/codegen/{arm64,x86_64}/op_simd_*.zig`; the spec SIMD runner
  (`test/spec/simd_assert_runner.zig`) JIT-executes.
- **Build defaults:** `build.zig` (`-Dwasm` / `-Dwasi` / `-Dengine` / `-Dgc`;
  component + P3-async are derived from the `-Dwasi` tier).
- **WASI confinement:** `src/wasi/path.zig` (`symlinkTargetEscapes`), `src/wasi/fd.zig`.

To build and run:

```sh
zig build                       # compile (needs Zig 0.16.0)
zig build run -- run f.wasm     # run a module through the CLI
zig build test-all              # all enabled test layers
zig build static-lib            # libzwasm.a + headers for C/Rust consumers
```
