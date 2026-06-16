# zwasm v2 — Zig embedding API, current-state handoff (ClojureWasm)

> Audience: ClojureWasm (cljw / CWFS) maintainers embedding zwasm **v2** from Zig.
> This is a **current-state reference** — "here is the API as it stands now",
> not a changelog. For deep design rationale see
> [`zig_api_design.md`](zig_api_design.md); for the v1→v2 delta see
> [`migration_v1_to_v2.md`](migration_v1_to_v2.md); the prior cljw handoff is
> [`handoff_cw_v1.md`](handoff_cw_v1.md).
>
> **Status (2026-06-14)**: v2 is feature-complete + 3-host green (Mac aarch64 /
> Linux x86_64 / Windows x86_64). Default engine is the **interpreter** (the
> hardened default); `--engine jit` is the CLI surface. No tag is cut (tagging
> is a manual, user-only act — ADR-0156). Signatures below are accurate as of
> HEAD; the facade is interp-backed (J.2→J.3 transition; no embedder-visible
> surface change is planned from that).

## 1. Mental model

Four layers, each with a strict **outlives** relationship (no GC, no borrow
checker — lifetime is by convention, like wasmtime's `Store`):

```
Engine  ──owns allocator──►  Module  ──►  Instance
   │                                          ▲
   └──► Linker ──(host imports + cross-module aliases)──┘
```

- **Engine** owns the user allocator and threads it through every internal
  allocation (allocator strict-pass invariant, ADR-0109 §4.1). **Engine must
  outlive every Module.**
- **Module** = parsed + validated bytes. **Must outlive every Instance.** One
  Module → many independent Instances.
- **Instance** = live runtime (memory / globals / tables / fuel). **Must outlive
  every `TypedFunc` / `Memory` / `Global` / `Table` handle taken from it.**
- **Linker** = the import registry. **Must outlive every Instance it instantiates
  that imports a host or cross-module function** (the importer's runtime holds
  raw pointers into Linker-owned `CallCtx`). Deinit the Linker **last**.

All `*.zig` entry points are under the `zwasm` facade (`src/zwasm.zig`).

## 2. Lifecycle — compile → (link) → instantiate → invoke

```zig
const zwasm = @import("zwasm");

var engine = try zwasm.Engine.init(gpa, .{});
defer engine.deinit();

var mod = try engine.compile(wasm_bytes);   // CompileError!Module
defer mod.deinit();

// (a) no imports → instantiate straight off the Module:
var inst = try mod.instantiate(.{});         // InstantiateOpts (fuel / max_memory)
defer inst.deinit();

// (b) with host/WASI/cross-module imports → go through a Linker (see §4):
var lk = engine.linker();
defer lk.deinit();                            // deinit AFTER every instance below
// ... lk.defineFunc / defineWasi / defineInstance ...
var inst2 = try lk.instantiate(&mod, .{});
defer inst2.deinit();
```

`Engine.compile` splits failure into `error.ParseFailed` (structural) vs
`error.ValidateFailed` (type/subtype/index) — D-197.

`Module.InstantiateOpts` (budgets default to **finite** so untrusted modules are
bounded out of the box):

```zig
pub const Budget = union(enum) { unmetered, limited: u64 };
pub const InstantiateOpts = struct {
    fuel:            Budget = .{ .limited = 1_000_000_000 },
    max_memory_pages: Budget = .{ .limited = 4096 },
};
// InstantiateError: InstantiateFailed | StartTrapped | MemoryLimitExceeded
```

## 3. Invoking exports

Two paths — pick by whether you want comptime type-marshalling:

```zig
// (a) untyped — raw Value slices (Wasm §4.5.3):
var results: [1]zwasm.Value = undefined;
try inst.invoke("add", &.{ .{ .i32 = 2 }, .{ .i32 = 3 } }, &results);
// InvokeError: ExportNotFound | NotAFunc | ArgArityMismatch
//            | ResultArityMismatch | ProcExit | Trap

// (b) typed — comptime-marshalled from a Zig fn type (multi-result via struct):
const add = inst.typedFunc(fn (i32, i32) i32, "add");
const sum = try add.call(.{ 2, 3 });
// Supported scalar types: i32/u32/i64/u64/f32/f64. NaN payloads bit-exact.
```

`inst.exportFuncSig(name) ?FuncType` for signature introspection.

## 4. Host imports — `Linker`

```zig
// First param of every host fn MUST be *Caller; the Wasm signature is
// comptime-derived from the rest + the return type.
fn hostAdd(caller: *zwasm.Caller, a: i32, b: i32) i32 { _ = caller; return a + b; }
try lk.defineFunc("env", "add", fn (*zwasm.Caller, i32, i32) i32, hostAdd);

// With opaque host context (recovered via Caller.data(T)):
try lk.defineFuncCtx("env", "tick", &my_state, fn (*zwasm.Caller) void, hostTick);
```

`Caller` (passed first to every host fn) exposes the **importing** instance:

```zig
pub fn memory(self: Caller) ?Memory          // importer's linear memory
pub fn allocator(self: Caller) std.mem.Allocator
pub fn data(self: Caller, comptime T: type) *T   // ctx from defineFuncCtx (asserts present)
```

`host_data` passed to `defineFuncCtx` **must outlive** every Instance that calls it.

## 5. Cross-module linking

Alias another already-instantiated module's exports into the importer's
namespace. **The exporter Instance must outlive every importer** (its live
runtime/memory/global/table storage is aliased, not copied).

```zig
lk.defineInstance("a", &inst_a) // register EVERY export of inst_a under "a" (sugar)
lk.defineCrossModuleFunc(module, name, &src_inst, src_name)   // one func
lk.defineGlobal(module, name, &src_inst, src_name)            // one global (shared cell)
lk.defineMemory(module, name, mem)                            // memory0 (D-199)
lk.defineMemoryInstance(module, name, *MemoryInstance)        // multi-memory (D-195b)
lk.defineTable(module, name, TableInstance)                  // table (D-201b)
lk.defineCrossModuleTag(module, name, &src_inst, tag_index)   // EH tag (ADR-0114)
```

`defineCrossModuleFunc` runs import-subtype + finality + distinct-layout
type-definition checks (D-202 A/B/C) before binding.

## 6. WASI (Preview 1)

```zig
try lk.defineWasi(.{
    .args = &.{ "prog", "arg1" },
    .envs = &.{ .{ .name = "LANG", .value = "C" } },         // → environ_get
    .io = my_io,                                              // your std.Io (event loop)
    .preopens = &.{ .{ .host_path = ".", .guest_path = "/" } }, // → path_open
});
// installs all 46 WASI 0.1 thunks; at-most-once per Linker.
```

`WasiConfig` carries `args` + `envs` + filesystem `preopens`. **`preopens` need
`.io`** — the embedder brings its own `std.Io` (event loop; no engine-owned thread);
the dirs are opened at `instantiate` and the Host closes them on deinit. stdin /
stdout / stderr *capture* is still facade-unwired (use the C API). A named WASI
import with no registered thunk surfaces as `error.UnsupportedWasiImport` (distinct
from `UnknownImport`).

## 7. Instance state access + sandboxing

```zig
inst.memory() ?Memory          // Memory{ size, read(T,off), write(off,v), grow(pages), slice() }
inst.global(name) ?Global      // Global{ get() Value, set(Value) error{Immutable}!void }  (D-272)
inst.table(name) ?Table        // Table{ size, get, set, grow }                            (D-272)

// Sandboxing (ADR-0179) — interp/default engine in v0.1 (JIT path is D-314, post-v0.1):
inst.setFuel(?u64)                  // #3b instruction budget; traps error.OutOfFuel at 0
inst.fuelRemaining() ?u64
inst.setMemoryPagesLimit(?u64)      // #3c memory.grow cap; over-cap = spec −1, not a trap
inst.setTableElementsLimit(?u64)    // D-316 table.grow cap; over-cap = spec −1
inst.interrupt() / clearInterrupt() / interruptRequested()  // #3a cooperative cancel (any thread)
```

## 8. Component Model + WASI 0.2 (default-ON; gated by `-Dwasi>=p2`, ADR-0193)

The cljw-facing entry is the **unified `open`** (REQ-1) returning an `Opened`
handle that drives both the graph-engine and typed paths through one method set
(ADR-0183 + the cljw CM-API finished-form campaign):

```zig
const comp = @import("zwasm").component.host;   // (Zone 3 orchestration)
var opened = try comp.open(&engine, alloc, component_bytes, &host, .{});  // Opened
defer opened.deinit();

// introspect + typed-invoke through the canonical ABI:
const funcs = try opened.exportedFuncs(alloc);              // path-qualified "<iface>#<func>"
const sig   = try opened.resolveFuncSig(arena, "greet");   // ?FuncSig (WIT type tree)
const out   = try opened.invokeTyped("greet", &.{ .{ .string = "cw" } }, alloc);  // ?ComponentValue
defer if (out) |*v| v.deinit(alloc);
try opened.dropResource(handle);                            // REQ-5 drop a guest resource handle
// typed-invoke diagnostics (REQ-6): setDiag at unresolved-export / encoding / arity / per-arg.
```

WIT type tree (REQ-3 — specialization-preserving: `option`/`result`/`tuple`
stay distinct from `variant`/`record`; enum/variant/flags carry **labels**):

```zig
pub const WitType = union(enum) {
    prim: PrimValType, list: *const WitType, record: []const Field, tuple: []const WitType,
    variant: []const Case, enum_: []const []const u8, option: *const WitType,
    result: Result, flags: []const []const u8, own: u32, borrow: u32,
};
pub const FuncSig = struct { params: []const Param, result: ?WitType };
```

`ComponentValue` is a 21-variant union (bool / s8…u64 / f32 / f64 / string / char
/ list / record / `variant{case,payload}` / `enum{case,labels}` /
`flags{bits,labels}` / option / result / `own:u32` / `borrow:u32`). Budget
(fuel/max-memory) threads via `InstantiateOpts` (REQ-4). Lower-level entry points
(`invokeCore` / `invokeFlat` / `invokeString[Export]` / `canonContext`) exist on
the underlying `ComponentInstance` for non-typed paths. Detail + worked examples:
[`zig_api_design.md`](zig_api_design.md) §3.9 + [`component_model_plan.md`](../.dev/component_model_plan.md).

## 9. Trap set (`Instance.Trap`)

Wasm 1.0: `Unreachable DivByZero IntOverflow InvalidConversionToInt
OutOfBoundsLoad OutOfBoundsStore OutOfBoundsTableAccess UninitializedElement
IndirectCallTypeMismatch StackOverflow CallStackExhausted OutOfMemory`.
Wasm 3.0: `NullReference UncaughtException CastFailure`. Threads:
`UnalignedAtomic ExpectedSharedMemory`. Host (ADR-0179): `Interrupted OutOfFuel`.

`InvokeError` adds `ProcExit` (WASI requested a clean process-exit unwind).

## 10. Lifetime contracts (the one thing to get right)

| Holder                      | Must outlive                                                                             |
|-----------------------------|------------------------------------------------------------------------------------------|
| `Engine`                    | every `Module`                                                                           |
| `Module`                    | every `Instance`                                                                         |
| `Instance`                  | every `TypedFunc`/`Memory`/`Global`/`Table` taken from it                                |
| **`Linker`**                | every Instance it instantiated that imports host/cross-module funcs (deinit Linker LAST) |
| cross-module `source_inst`  | every importer                                                                           |
| `host_data` (defineFuncCtx) | every Instance that calls it                                                             |

All by convention — no runtime guard (a debug-guard was evaluated + consciously
rejected as cross-path-fragile, D-297; the contract mirrors wasmtime's Store
ownership).

## 11. Known gaps (current residuals)

| Gap                                            | Ticket | Note                                                       |
|------------------------------------------------|--------|------------------------------------------------------------|
| Zig `WasiConfig` stdio (stdin/out/err) capture | —     | preopens shipped (D-177 closed); stdio capture stays C-API |
| JIT fuel / memory-cap / table-cap              | D-314  | interp/default engine has them in v0.1; JIT path post-v0.1 |
| Standalone host-constructed `Global`/`Memory`  | D-178  | v0.2; only import-aliasing in v0.1                         |
| Callable funcref handle                        | D-269  | tracked                                                    |

## 12. Pointers

- [`zig_api_design.md`](zig_api_design.md) — full design + §3.8 WASI / §3.9 component.
- [`handoff_cw_v1.md`](handoff_cw_v1.md) — prior (v1-era) cljw handoff.
- [`migration_v1_to_v2.md`](migration_v1_to_v2.md) — v1→v2 surface delta + gap analysis.
- [`reference/zig_api.md`](reference/zig_api.md) — API reference index.
