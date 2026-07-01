# zwasm v2 — Zig API design spec (target)

**Status**: Live consumer spec for the native Zig API. ADR-0109
**Accepted 2026-05-25** authorizes the rewrite; ROADMAP §10 /
10.J carries the implementation cycles.
**Audience**: Zig consumers embedding zwasm v2 as a Wasm runtime
library (ClojureWasm v1 dogfooding, and any other Zig project).
**Implementation status (2026-06-06 amend)**: SHIPPED. The §10 /
10.J rewrite is complete — the native facade (`Engine` / `Module` /
`Linker` / `Instance` / `TypedFunc` / `Memory` / `Global` / `Table` /
`Caller` + full 12-variant `Trap` + allocator strict-pass) lives in
`src/zwasm/*.zig` and is the primary surface. Phase-16 (feature-complete)
follow-ups added module introspection (`Module.imports`/`.exports`),
`Memory.grow`/`.sliceAt`, `Engine.linker()`, and
`Linker.defineInstance`. The signatures below are the original
**target sketch**; where a shipped signature diverges (notably the
introspection methods take an allocator + are fallible, since the
import/export sections are decoded on demand), the **source is
authoritative** — read `src/zwasm/<type>.zig`.

This doc is self-contained: read top-to-bottom to understand
the consumer-facing contract without needing to read the
ADRs. References at the bottom point to ADRs / code for
deeper dives.

## §1 — Design principles

Five principles drive every shape below:

1. **Native Zig is the primary surface; c_api is a separate
   downstream layer.** The Zig API does not delegate to
   wasm-c-api internally. The c_api binding (`src/api/`) is
   for cross-language consumers and stays as a Zone-3
   sibling.
2. **Allocator strict-pass.** Every alloc goes through the
   caller-provided `std.mem.Allocator`. No `c_allocator`
   fallback, no hidden globals.
3. **Comptime-typed signatures are the central UX.** Most
   consumer code uses `instance.typedFunc(fn(i32, i32) i32,
   "add")` rather than raw `Value` slices. The runtime
   marshals.
4. **Wasm linear memory is exposed as a bounds-checked `[]u8`
   slice view.** No double allocation: host alloc and Wasm
   linear memory are separate by construction, and the host
   gets a slice into the Wasm side rather than a copy.
5. **Trap is a narrow error union, not a catchall.** Every
   spec-defined trap variant (`IntDivByZero`, `OutOfBoundsLoad`,
   `StackOverflow`, etc.) is preserved through the API boundary.

## §2 — API surface (overview)

```zig
const zwasm = @import("zwasm");

// Top-level: Engine
pub const Engine = struct {
    pub fn init(alloc: std.mem.Allocator, opts: InitOpts) !Engine;
    pub fn deinit(self: *Engine) void;
    pub fn compile(self: *Engine, bytes: []const u8) !Module;
    pub fn linker(self: *Engine) Linker;
};

// Module: compile-once, instantiate-many
pub const Module = struct {
    pub fn deinit(self: *Module) void;
    // Introspection (shipped): allocator-taking + fallible (the import/
    // export sections are decoded on demand). Result owns its strings;
    // call `.deinit()`. `ModuleImports.items: []const ImportItem`
    // (module+name+kind); `ModuleExports.items: []const ExportItem`
    // (name+kind). `ExternKind = { func, table, memory, global, tag }`.
    pub fn imports(self: *const Module, gpa: Allocator) IntrospectError!ModuleImports;
    pub fn exports(self: *const Module, gpa: Allocator) IntrospectError!ModuleExports;
};

// Linker: builder for imports
pub const Linker = struct {
    pub fn defineFunc(self: *Linker, mod: []const u8, name: []const u8, func: anytype) !void;
    pub fn defineMemory(self: *Linker, mod: []const u8, name: []const u8, mem: *Memory) !void;
    pub fn defineGlobal(self: *Linker, mod: []const u8, name: []const u8, g: *Global) !void;
    pub fn defineTable(self: *Linker, mod: []const u8, name: []const u8, t: *Table) !void;
    pub fn defineInstance(self: *Linker, mod: []const u8, inst: *Instance) !void;
    pub fn defineWasi(self: *Linker, cfg: WasiConfig) !void;
    pub fn instantiate(self: *Linker, module: Module) !Instance;
    pub fn deinit(self: *Linker) void;
};

// Instance: runnable Wasm module
pub const Instance = struct {
    pub fn deinit(self: *Instance) void;
    pub fn typedFunc(self: *Instance, comptime Sig: type, name: []const u8) !TypedFunc(Sig);
    pub fn call(self: *Instance, comptime Sig: type, name: []const u8, args: anytype) !ReturnOf(Sig);
    pub fn invoke(self: *Instance, name: []const u8, args: []const Value, results: []Value) !void;
    pub fn memory(self: *Instance) ?*Memory;
    pub fn global(self: *Instance, name: []const u8) ?*Global;
    pub fn table(self: *Instance, name: []const u8) ?*Table;
};

// Typed function handle (cache for hot-path calls)
pub fn TypedFunc(comptime Sig: type) type { ... }

// Wasm linear memory view
pub const Memory = struct {
    pub fn slice(self: *Memory) []u8;
    pub fn sliceAt(self: *Memory, offset: u32, len: u32) ![]u8;
    pub fn readBytes(self: *Memory, offset: u32, len: u32) ![]u8;
    pub fn writeBytes(self: *Memory, offset: u32, data: []const u8) !void;
    pub fn read(self: *Memory, comptime T: type, offset: u32) !T;
    pub fn write(self: *Memory, offset: u32, value: anytype) !void;
    pub fn grow(self: Memory, delta: u32) ?u32;  // → prev pages, null = refused (no trap)
    pub fn size(self: *Memory) u32;     // in pages (64 KiB)
    pub fn grow(self: *Memory, delta_pages: u32) !u32;
};

// Untagged 16-byte slot per ADR-0110 (v128 first-class; no separate V128 type)
pub const Value = extern union {
    bits128: u128,
    v128: [16]u8 align(16),
    bits64: u64,
    i32: i32, u32: u32, i64: i64, u64: u64,
    f32_bits: u32, f64_bits: u64,
    ref: u64,
};
pub const ValueKind = enum { i32, i64, f32, f64, v128, funcref, externref };

// Trap — full spec set, no catchall
pub const Trap = error{
    Unreachable, IntOverflow, IntDivByZero, InvalidConversionToInt,
    OutOfBoundsLoad, OutOfBoundsStore, OutOfBoundsTableAccess,
    UninitializedElement, IndirectCallTypeMismatch,
    StackOverflow, CallStackExhausted, OutOfMemory,
};

// Host function context (passed as first arg of host funcs)
pub const Caller = struct {
    pub fn engine(self: *Caller) *Engine;
    pub fn memory(self: *Caller) ?*Memory;  // calling instance's memory
    pub fn instance(self: *Caller) *Instance;
    pub fn alloc(self: *Caller) std.mem.Allocator;
};
```

## §3 — Canonical usage examples

### §3.1 — Hello world

```zig
const std = @import("std");
const zwasm = @import("zwasm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var engine = try zwasm.Engine.init(gpa.allocator(), .{});
    defer engine.deinit();

    const wasm_bytes = @embedFile("hello.wasm");
    var module = try engine.compile(wasm_bytes);
    defer module.deinit();

    var linker = engine.linker();
    defer linker.deinit();

    var instance = try linker.instantiate(module);
    defer instance.deinit();

    const add = try instance.typedFunc(fn(i32, i32) i32, "add");
    const sum = try add.call(.{ 2, 3 });
    std.debug.print("2 + 3 = {d}\n", .{sum});
}
```

### §3.2 — Host imports (Zig function as Wasm import)

```zig
fn hostPrint(caller: *zwasm.Caller, ptr: u32, len: u32) void {
    const mem = caller.memory() orelse return;
    const s = mem.sliceAt(ptr, len) catch return;
    std.debug.print("{s}\n", .{s});
}

fn hostAbort(_: *zwasm.Caller, code: i32) noreturn {
    std.process.exit(@intCast(code));
}

// ...
try linker.defineFunc("env", "print", hostPrint);  // signature inferred
try linker.defineFunc("env", "abort", hostAbort);
const inst = try linker.instantiate(module);
```

The runtime infers each Wasm import signature from the Zig
function's type via `@typeInfo(.@"fn")`. Mismatches between
the host function signature and the Wasm import declaration
fail at `instantiate()` time with a typed error.

The first parameter of a host function must be `*Caller` —
this gives the host code access to the calling instance's
memory, allocator, and runtime state. Subsequent parameters
must be `i32 / u32 / i64 / u64 / f32 / f64` (and in the
future `[16]u8` / `u128` for v128 + `?u64` for ref types
per the §4 Value union; no separate `V128` type per ADR-0110).

### §3.3 — Multi-result

```zig
// Wasm: (func (export "divmod") (param i32 i32) (result i32 i32) ...)
const divmod = try instance.typedFunc(fn(i32, i32) struct { i32, i32 }, "divmod");
const r = try divmod.call(.{ 10, 3 });
std.debug.print("quot={d} rem={d}\n", .{ r[0], r[1] });

// Or named tuple fields via Zig struct
const DivMod = struct { quot: i32, rem: i32 };
const dm = try instance.typedFunc(fn(i32, i32) DivMod, "divmod");
const r2 = try dm.call(.{ 10, 3 });
std.debug.print("quot={d} rem={d}\n", .{ r2.quot, r2.rem });
```

### §3.4 — Memory access (no double allocation)

```zig
const mem = instance.memory() orelse return error.NoMemory;

// Zero-copy view of the entire linear memory
const all = mem.slice();
std.debug.print("memory size: {d} bytes\n", .{all.len});

// Bounds-checked slice helper
const window = try mem.sliceAt(0x1000, 256);
@memcpy(window[0..5], "hello");

// Typed read/write (little-endian, alignment-respecting)
try mem.write(0x2000, @as(i32, 42));
const back = try mem.read(i32, 0x2000);

// String pattern: write to Wasm-side allocator, then call
const wasm_alloc = try instance.typedFunc(fn(u32) u32, "alloc");
const wasm_free  = try instance.typedFunc(fn(u32, u32) void, "free");
const greet      = try instance.typedFunc(fn(u32, u32) void, "greet");

const msg = "hello from Zig";
const ptr = try wasm_alloc.call(.{ @intCast(msg.len) });
defer wasm_free.call(.{ ptr, @intCast(msg.len) }) catch {};
try mem.writeBytes(ptr, msg);
try greet.call(.{ ptr, @intCast(msg.len) });
```

**Memory management contract**:

- `mem.slice()` returns a `[]u8` that aliases the Wasm
  linear memory directly. No copy, no extra alloc.
- The slice is invalidated by `memory.grow()` and by
  re-entering Wasm code that may grow memory. Hold it only
  across non-Wasm-calling Zig sequences.
- Host alloc (the Engine's `std.mem.Allocator`) and Wasm
  linear memory are **separate by construction**. Host
  pointers cannot be passed to Wasm directly (sandbox);
  data must be copied into Wasm memory (or pre-loaded at
  instantiation time via imports).
- Wasm-side alloc/free (via exported functions) is the
  responsibility of the Wasm module. The host calls these
  to allocate Wasm-side buffers but must free them with
  the corresponding deallocator.

### §3.5 — Untyped invoke (REPL / dynamic dispatch)

For cases where the function signature isn't known at
comptime (REPL, inspector tools, dynamic dispatch):

```zig
var args = [_]zwasm.Value{
    .{ .i32 = 10 },
    .{ .i32 = 3 },
};
var results: [2]zwasm.Value = undefined;
try instance.invoke("divmod", &args, &results);
// results[0].i32 == 3, results[1].i32 == 1
```

The caller is responsible for matching `args` / `results`
counts and types to the Wasm function signature. Type
mismatches surface as `error.ArgTypeMismatch` /
`error.ResultTypeMismatch`.

### §3.6 — Trap handling

```zig
const div = try instance.typedFunc(fn(i32, i32) i32, "div");

const r = div.call(.{ 10, 0 }) catch |err| switch (err) {
    error.IntDivByZero    => return error.UserDivisionError,
    error.IntOverflow     => return error.UserOverflowError,
    error.OutOfBoundsLoad => unreachable,  // div doesn't load
    error.StackOverflow   => return error.UserStackError,
    else => return err,
};
```

All spec-defined trap variants from `Trap` are preserved
through `TypedFunc.call`, `Instance.invoke`, and `Instance.call`.
The error union is the union of (export-lookup errors,
arg/result marshal errors, `Trap`).

### §3.7 — Sharing memory between instances

```zig
var inst_a = try linker_a.instantiate(module_a);
defer inst_a.deinit();

// Build a second linker that shares inst_a's memory
var linker_b = engine.linker();
defer linker_b.deinit();
try linker_b.defineMemory("env", "shared_mem", inst_a.memory().?);

var inst_b = try linker_b.instantiate(module_b);
defer inst_b.deinit();
// inst_a and inst_b now share the same linear memory.
```

### §3.8 — WASI

As-built `WasiConfig` (`src/zwasm/linker.zig`) carries `args` / `envs` /
`preopens` (+ `io`); after `defineWasi` every `wasi_snapshot_preview1` import in
the module is satisfied as a unit:

```zig
try linker.defineWasi(.{
    .args = &.{ "prog", "arg1", "arg2" },
    .envs = &.{ .{ .name = "LANG", .value = "C" } },           // → environ_get
    .io = my_io,                                                // your std.Io
    .preopens = &.{ .{ .host_path = ".", .guest_path = "/" } }, // → path_open
});
// All wasi_snapshot_preview1 imports are defined as a unit.
const inst = try linker.instantiate(module);
```

`args` / `envs` / `preopens` are settable on the Zig `WasiConfig` (preopens are
opened at `instantiate` via the caller-provided `io`; the embedder owns the event
loop). Only stdin / stdout / stderr *capture* is still facade-unwired (D-251) —
use the C API for stdio redirection.

### §3.9 — Component Model: typed invoke (ADR-0183, as-built)

Component support is gated by the WASI tier `-Dwasi>=p2` (default `p2`, so on
by default; `-Dwasi=p1` opts out — ADR-0193 folded the former `-Dcomponent`
flag into the WASI version axis). The host surface lives at `zwasm.feature.component.host`
(`src/api/component.zig`); the component binary is **self-describing** —
no `.wit` sidecar is needed (CWFS ADR-0135 "the binary IS the interface").

```zig
const comp = zwasm.feature.component.host;

// 1. Introspect: what typed funcs does this component export?
//    Includes interface-nested funcs, path-qualified `<iface>#<func>`
//    (e.g. "zwasm:restest/counter-api#[method]counter.get") — names
//    are returned in exactly the form `invokeTyped` accepts.
var ci = try comp.instantiate(&engine, alloc, bytes); // single-module component
defer ci.deinit();
const funcs = try ci.exportedFuncs(alloc); // []ExportedFunc{name, params, result}
defer zwasm.feature.component.types.TypeInfo.freeExportedFuncs(alloc, funcs);

// 2. Typed invoke through the canonical ABI. Args are `ComponentValue`
//    trees validated against the export's WIT signature.
const out = try ci.invokeTyped("greet", &.{.{ .string = "zwasm" }}, alloc);
defer if (out) |o| o.deinit(alloc); // caller owns the result tree
// out.?.string == "Hello, zwasm!"
```

Real-toolchain components (wit-bindgen Rust / TinyGo) import `wasi:*`, so
they go through the general graph builder instead of `instantiate`:

```zig
var host = try zwasm.wasi.host.Host.init(alloc);
defer host.deinit();
host.io = io;
var built = try comp.buildWasiP2Component(&engine, alloc, bytes, &host);
defer built.deinit();
const r = try comp.invokeTypedBuilt(&built, "process", &args, alloc);
```

`comp.open(engine, alloc, bytes, host, opts)` (REQ-1) is the UNIFIED entry: it
auto-selects single-module vs the WASI-P2 / multi-instance graph (structural
— a component with host imports or > 1 embedded core module needs the graph)
and returns one `Opened` handle that drives both paths through the same
methods (`exportedFuncs` / `invokeTyped` / `resolveFuncSig` / `dropResource` /
`typeInfo` / `deinit`) — no try-catch fallback, no two-way dispatch.
`comp.componentNeedsWasi(alloc, bytes)` is the cheap pre-instantiation
predicate.

```zig
var opened = try comp.open(&engine, alloc, bytes, &host, .{});
defer opened.deinit();
const out = try opened.invokeTyped("greet", &.{.{ .string = "zwasm" }}, alloc);
// Guest-defined resources: a host that caches an `own` handle frees it via
//   try opened.dropResource(handle); // REQ-5 — removes the handle + runs the
//                                     // declared destructor (own handles)
```

`ComponentValue` (`src/feature/component/value.zig`) mirrors the WIT value
model: `record` keeps field **names** (borrowed from the instance's decoded
type info), `option`/`result`/`tuple` stay specialized (the canonical ABI's
despecialization is internal), and `deinit(alloc)` frees the whole tree.
Rich shapes round-trip — the pinned proof is
`record{list<u32>, string} ⇄ result<record, string>` over a committed
wit-bindgen fixture (`test/component/typed_payload.wasm`).

A lifted `.@"enum"` / `.variant` / `.flags` carries its LABEL(s) (REQ-2,
borrowed from the decoded type info): `.@"enum" = {index, label}`,
`.variant = {case, case_name, payload}`, `.flags = {bits, labels}` (bit `i`
⇔ `labels[i]`). On a host-constructed INPUT value the label fields are
empty and invoke dispatches by the numeric ordinal/bits — map a host label
to its ordinal with `resolveFuncSig` (below), whose `WitType` enum/flags
arms list the labels in order.

`resolveFuncSig(arena, name)` / `resolveType(arena, info, vt)` (REQ-3,
`feature/component/wit_type.zig`) resolve an export's signature to a
`WitType` TYPE tree — the type counterpart to `ComponentValue`:
specialization-preserving (`option`/`result`/`tuple` distinct) and
label-carrying (`enum_`/`variant`/`flags`), with the decoded 2-space
resolution rule hidden. Both `ComponentInstance` and `BuiltComponent`
expose `resolveFuncSig`.

Component instantiation takes a budget: `instantiate(engine, alloc, bytes,
opts)` / `buildWasiP2Component(…, opts)` accept
`component.InstantiateOpts{fuel, max_memory_pages}` (REQ-4); `.{}` = the
default budget.

Guest-defined RESOURCES (D-322) work through the same surface: a
constructor returns `ComponentValue.own` (an opaque handle into the
component instance's table); methods take `.borrow` handles (the
runtime translates handle→rep per the canonical ABI's owner-component
rule). Func exports inside an exported interface are addressed with an
instance path:

```zig
const h = (try comp.invokeTypedBuilt(&built,
    "zwasm:restest/counter-api#[constructor]counter",
    &.{.{ .u32 = 5 }}, alloc)).?; // h == .own
const v = (try comp.invokeTypedBuilt(&built,
    "zwasm:restest/counter-api#[method]counter.get",
    &.{.{ .borrow = h.own }}, alloc)).?; // v.u32 == 5
```

Manifest-driven coverage: the component spec corpus runner's
`assert_typed` directive (`test/spec/component_model_assert_runner.zig`)
drives this same path from text, e.g.
`assert_typed process ({xs: [1, 2, 3], label: "sum"}) -> ok({xs: [1, 2, 3, 6], label: "sum!"})`.

### §3.10 — Engine selection (JIT vs interpreter, ADR-0200)

Engine choice is **per-instance, at instantiate time** (never per-call); both
engines coexist in one build. The Zig facade carries it on
`Module.InstantiateOpts.engine`:

```zig
var jit_inst = try module.instantiate(.{ .engine = .jit }); // native JIT
var int_inst = try module.instantiate(.{ .engine = .interp }); // interpreter
var auto_inst = try module.instantiate(.{}); // .auto (default)
```

`EngineKind = enum { auto, jit, interp }`. **`.auto` is the default** and is
documented to resolve to the runtime's best choice — currently the interpreter
until the JIT host-import/WASI bridge lands, then JIT-on-arches-with-a-backend
(interp fallback on a JIT-less arch). Because the default's *meaning* is what is
specified (not a fixed engine), the resolution can change without an API break.
An explicit `.jit` on a JIT-less arch fails instantiation rather than silently
downgrading. The call boundary (`invoke` / `typedFunc().call()`) is
engine-agnostic — identical args/results contract across engines (cw runs a
dual-engine differential oracle on exactly this property).

The C ABI mirrors this with the `zwasm_instance_new_ex(store, module, imports,
trap_out, engine_kind)` extension (`include/zwasm.h`; `ZWASM_ENGINE_AUTO=0` /
`JIT` / `INTERP`) — stock `wasm_instance_new` is `.auto`. Worked end-to-end
mini-consumers: `docs/examples/zig_host/jit_engine.zig` + `docs/examples/c_host/`…`jit_engine.c`
(`test-c-api-conformance`), each instantiating `engine=jit` and calling a
multi-arg export plus a SIMD-body export (SIMD executes on the JIT).

## §4 — Value layout (uniform 16-byte slot per ADR-0110)

The `Value` type is an **untagged `extern union` of width 16
bytes** (matching the internal JIT slot post-ADR-0110 Accept
`9204847a` 2026-05-24). v128 is **first-class** in the union —
no separate `V128` type. NaN-boxing-friendly: float values
store their IEEE-754 bit pattern in `f32_bits` / `f64_bits`
(no canonicalization at the slot level — canonicalization
happens only at Wasm op boundaries that the spec requires).

```zig
pub const Value = extern union {
    // 16-byte raw view (largest variant; v128 reads/writes go here)
    bits128: u128,
    v128: [16]u8 align(16),

    // 8-byte scalar variants (occupy low 8 bytes; upper 8 zero by convention)
    bits64: u64,
    i32: i32, u32: u32,
    i64: i64, u64: u64,
    f32_bits: u32,         // IEEE-754 bit pattern (32 bits in low half)
    f64_bits: u64,         // IEEE-754 bit pattern
    ref: u64,              // funcref/externref, see §4.1
};
```

The internal JIT-emitted code reads/writes a single 16-byte
cell per Value slot (uniform stride; per ADR-0110 §"Decision"
the `idx * 16` stride is what makes globals / locals
pointer-aliasable across instances + Q-reg / MOVUPS-friendly
on both arm64 and x86_64). The facade exposes the same union
so consumer code can address any variant without a separate
v128 type.

Caller responsibility: the union has no runtime tag. Wasm
type is determined by the function signature; the caller
must select the correct field. Mismatched-field reads are
silent UB at the Wasm spec level (the runtime will use the
bits as the signature-declared type).

### §4.1 — Reference type encoding

- **funcref**: `ref` field holds `@intFromPtr(*const FuncEntity)`
  for non-null references. The pointer carries source-instance
  identity (enabling cross-instance `call_indirect`). `null_ref`
  is encoded as `ref = 0` — `c_allocator.alloc` cannot return
  address 0 on supported platforms, so 0 is a safe sentinel.
- **externref**: `ref` field holds an opaque 64-bit host
  handle. Same `0` sentinel for null.

### §4.2 — v128 (first-class per ADR-0110)

v128 is the union's natural width — no special-case
wrapper type. For TypedFunc signatures consumers use
`[16]u8` / `u128` directly (or a thin `V128` alias in
consumer code if they prefer a named type; zwasm itself does
not export one).

For the c_api boundary v128 is **permanently NOT exposed**
(spec-prohibited per `wasm-c-api include/wasm.h:329-338`;
see `.dev/lessons/2026-05-24-c_api-v128-spec-boundary.md`).
The native Zig API is the only consumer-visible v128 access
path.

### §4.3 — NaN-boxing-friendly bit ownership

For consumers (notably ClojureWasm v1) that wish to NaN-box
their own value representation **inside** the Wasm float
slot:

- Float values pass through the API as **bit patterns**
  (`f32_bits` / `f64_bits`). zwasm does NOT canonicalize
  NaNs at the Value boundary — canonicalization happens
  only inside `f32.add` / `f64.div` / etc. handlers per
  Wasm §6.2.3 spec requirement.
- Therefore, NaN payloads survive round-trips through
  `typedFunc.call` and `invoke` as long as the Wasm
  function itself doesn't perform an op that demands
  canonicalization.
- The full 64 bits of `f64_bits` (or 32 bits of `f32_bits`)
  are usable for tagging. Sign bit, exponent bits, and
  payload bits are all preserved across the boundary.

## §5 — Comparison to current state

| Component | Current `src/zwasm.zig` | Target (this doc) |
|---|---|---|
| Top-level | `Runtime` (wraps wasm_engine + wasm_store) | `Engine` (internal physical struct renamed `JitRuntime` to preserve JIT ABI surface) |
| Module load | `Module.parse(rt, bytes)` (calls `wasm_module_new`) | `engine.compile(bytes)` |
| Imports | imports not in opts | `Linker` builder (`InstantiateOpts` now carries `fuel`/`max_memory_pages` budgets, ADR-0179) |
| Typed call | none (114 internal `callXxx_yyy`) | `TypedFunc(Sig)` comptime-generic |
| Memory access | none | `Memory.slice()` + helpers |
| Value type | tagged `union(enum)` (~16+ bytes, v128 = u128) | untagged `extern union` (uniform 16 bytes per ADR-0110; v128 first-class — **no separate `V128` type**) |
| Trap | `error.Trap` catchall in `InvokeError` | full `Trap` error set preserved |
| Allocator | accepted but ignored (`c_allocator` used) | strict-pass through `Engine.init` |
| WASI | none in facade | `linker.defineWasi(cfg)` |
| Host functions | none in facade | `linker.defineFunc(mod, name, zigFn)` with comptime marshal |

The rewrite touches:
- `src/zwasm.zig` (~500 line replacement)
- New `src/api/host_func_marshal.zig` (comptime fn-type → Wasm-sig adapter generator)
- New `src/api/linker.zig` (Zone-2-or-3 builder; positioning TBD per ADR-0109)
- New `src/api/memory_view.zig` (slice view over Wasm linear memory)
- Internal `Runtime` → `JitRuntime` rename (physical struct stays — ABI is JIT-emitted-code-stable)

Estimated 6-8 cycles of autonomous work, parallelizable.

## §6 — Open questions for cw v1 review

1. **Multi-result return shape**: the spec defaults to `struct { i32, i32 }`
   (anonymous tuple) for multi-result. Does cw v1 prefer named
   fields (`struct { quot: i32, rem: i32 }`) as the primary shape?
   Both work; the question is which is the documented "blessed"
   pattern.
2. **Caller as first arg of host funcs**: required (above shows
   `fn(caller: *Caller, ...)`)? Or optional (omit when not
   needed)? Required is simpler to teach; optional is less
   boilerplate for pure functions.
3. **Memory invalidation on grow**: should `mem.slice()` return
   a slice that grows alongside? Or a snapshot at-call-time?
   Snapshot is simpler + matches Wasm spec (each `memory.grow`
   may relocate); growth-tracking slice would require pointer
   dereference per access.
4. **WasiConfig granularity**: full `defineWasi(cfg)` all-at-once vs
   per-syscall `defineWasiFd / defineWasiClock / ...`. CW likely
   wants the bulk path; embedded/restricted hosts might want
   per-syscall.
5. **TypedFunc cache lifetime**: tied to `*Instance` (must
   re-lookup after `defineFunc` adds host functions)? Or
   stable across the Instance's lifetime?
6. **`?u64` for ref-typed args**: `funcref` / `externref`
   as host-func parameters — `?u64` (nullable raw handle) or
   typed `FuncRef` / `ExternRef` wrappers?

cw v1 should raise these (and any others discovered while
prototyping against this spec) so they get fixed before
impl lands.

## §7 — References

- **ADRs**:
  - ADR-0014 — Allocator + zombie-instance contract.
  - ADR-0025 — Zig library facade (the originally-proposed
    minimum subset; superseded by ADR-0109 for the target
    shape).
  - ADR-0052 — Globals representation (scalar-only today).
  - ADR-0061 — Reftype 8-byte slot encoding.
  - ADR-0106 — Multi-result return convention (wrapper thunk).
  - ADR-0107 — Byte-buffer globals for v128 cross-module
    (Proposed).
  - ADR-0109 — **This design's formal record** (Proposed;
    supersedes ADR-0025 minimum-subset target).
- **Code** (current state):
  - `src/zwasm.zig` — current facade (c_api veneer).
  - `src/runtime/value.zig` — internal `Value` extern union.
  - `src/runtime/trap.zig` — full Trap error set.
  - `src/runtime/runtime.zig::Runtime` — physical struct
    (will rename to `JitRuntime`).
  - `src/api/instance.zig` — wasm-c-api binding (stays as
    Zone-3 sibling, not deleted).
  - `src/engine/codegen/shared/entry.zig` — 114-entry typed
    helper catalog (internal; TypedFunc comptime layer
    replaces the consumer-facing equivalent).
- **Industry precedents** surveyed:
  - **wasmtime** (Rust): `Engine` + `Store<T>` + `Linker<T>` +
    `TypedFunc<Params, Results>`.
  - **wasmer** (Rust): `Engine` + `Store` + `Imports` (via
    `imports!` macro) + `TypedFunction<Args, Rets>`.
  - **wasmi** (Rust): sister of wasmtime, same shape.
  - **wasm3** (C): `IM3Environment` (engine) + `IM3Runtime`
    (per-execution state — distinct from "Engine").
  - **WAMR** (C): `wasm_engine_t` + `wasm_runtime_init`.
  - **zware** (Zig): `Store` + `Instance` (no `Engine`).
  - **v1 zwasm** (Zig, predecessor): `WasmModule.load(alloc,
    bytes)` — 1-step, host imports inline via
    `loadWithImports`. Predates the Linker pattern; this
    spec inherits the allocator-strict-pass + 1-step
    intuition while adopting the Linker for reuse.

## §8 — Revision history

- 2026-05-24 — Initial draft. Conversation-derived from
  Phase 9 close cycle 35 discussion: c_api → native-Zig
  inversion + v1-shape inspiration tempered by
  first-principles analysis (Engine + Linker + TypedFunc
  via Zig fn type + Memory slice view + NaN-boxing-friendly
  Value).
- 2026-05-25 — **§4 Value section rewritten** for ADR-0110
  Accept (`9204847a` 2026-05-24): internal Value is now
  uniform 16-byte with v128 first-class; the original
  "8-byte slot + separate `V128` 16-byte struct" split is
  obsolete. The facade exposes a single `extern union`
  with all variants (`bits128` / `v128` / `bits64` / `i32`
  / `i64` / `f32_bits` / `f64_bits` / `ref`). §5
  Comparison table updated to match. v128 stays
  permanently NOT exposed through the c_api boundary
  (spec-prohibited per `include/wasm.h:329-338`); the
  native Zig API is the only v128-typed consumer path.
- 2026-05-25 — ADR-0109 **Accepted** (Status: Proposed →
  Accepted, user collab review at Phase 10 open). This
  doc is the live consumer spec; impl scheduled as
  ROADMAP §10 / 10.J. **Pre-impl investigation +
  execution plan + test strategy** (subagent-driven) is
  the next chunk after the amend round; the resulting
  plan doc gates the first J.* impl chunk.
- 2026-06-13 — **§3.9 added** (Component Model typed invoke,
  as-built per ADR-0183): `exportedFuncs` introspection +
  `invokeTyped` / `invokeTypedBuilt` + `ComponentValue`
  ownership contract + the corpus `assert_typed` pointer.
- 2026-06-13 — **§3.9 extended** (campaign close): guest-defined
  resources — own/borrow `ComponentValue` handles + the
  `<iface>#<func>` instance-path addressing.
