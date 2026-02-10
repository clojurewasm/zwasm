# Design Decisions

Architectural decisions for zwasm. Reference by searching `## D##`.
Only architectural decisions — not bug fixes or one-time migrations.

Shares D## numbering with ClojureWasm (start from D100 to avoid conflicts).

---

## D100: Extraction from ClojureWasm

**Decision**: Extract CW `src/wasm/` as standalone library rather than rewriting.

**Rationale**:
- 11K LOC of battle-tested code (461 opcodes, SIMD, predecoded IR)
- CW has been using this code in production since Phase 35W (D84)
- Rewriting would lose optimizations (superinstructions, VM reuse, sidetable)

**Constraints**:
- Must remove all CW dependencies (Value, GC, Env, EvalError)
- Public API must be CW-agnostic (no Clojure concepts in interface)
- CW becomes a consumer via build.zig.zon dependency

---

## D101: Engine / Module / Instance API Pattern

**Decision**: Three-tier API matching Wasm spec concepts.

```
Engine  — runtime configuration, shared compilation cache
Module  — decoded + validated Wasm binary (immutable)
Instance — instantiated module with memory, tables, globals (mutable)
```

**Rationale**:
- Matches wasmtime/wasmer mental model (familiarity)
- Matches Wasm spec terminology (Module, Instance, Store)
- Clean separation: decode once → instantiate many

---

## D102: Allocator-Parameterized Design

**Decision**: All zwasm types take `std.mem.Allocator` as parameter. No global allocator.

**Rationale**:
- Follows CW's D3 (no global mutable state)
- Enables: arena allocator for short-lived modules, GPA for debugging, fixed-buffer for embedded
- Zig idiom: caller controls allocation strategy

---

## D103: types.zig Split — Pure Wasm vs CW Bridge

**Decision**: Split CW's `types.zig` (891 LOC) into two layers:

1. **zwasm layer** (extract): `WasmModule` struct + raw u64 invoke API
2. **CW bridge layer** (stays in CW): Value↔u64 conversion, host callback dispatch

### zwasm Public API

```zig
const zwasm = @import("zwasm");

// Load a module from .wasm bytes
var module = try zwasm.Module.load(allocator, wasm_bytes);
defer module.deinit();

// Load with WASI support
var wasi_mod = try zwasm.Module.loadWasi(allocator, wasm_bytes);

// Invoke an exported function (raw u64 interface)
var args = [_]u64{ 3, 4 };
var results = [_]u64{0};
try module.invoke("add", &args, &results);
// results[0] == 7

// Memory access
const data = try module.memoryRead(allocator, offset, length);
try module.memoryWrite(offset, data);

// Export introspection
const info = module.getExportInfo("add");
// info.param_types = [.i32, .i32], info.result_types = [.i32]
```

### Import Mechanism (zwasm-native, replaces CW Value maps)

```zig
// Link modules: import functions from another module
var app = try zwasm.Module.loadWithImports(allocator, app_bytes, &.{
    .{ .module = "math", .source = .{ .wasm_module = math_mod } },
});

// Host functions: generic callback interface
var app2 = try zwasm.Module.loadWithImports(allocator, bytes, &.{
    .{ .module = "env", .source = .{ .host_fns = &.{
        .{ .name = "print_i32", .callback = myPrintFn, .context = ctx_id },
    }}},
});
```

### Design Rationale

**Why u64 as the raw interface**:
- Wasm spec defines 4 value types: i32/i64/f32/f64 — all fit in u64
- CW already uses `invoke(name, []u64, []u64)` internally
- Embedders (CW, or any Zig project) wrap u64 in their own type system
- Zero-cost: no conversion at the zwasm boundary

**Why struct-based imports instead of Value maps**:
- CW's `lookupImportSource/Fn` uses PersistentArrayMap.get() — CW-specific
- Struct-based: `[]const ImportEntry` is Zig-native, no allocations needed
- Compile-time known: embedder builds import list statically
- Type safe: `union(enum) { wasm_module, host_fns }` vs runtime tag checks

**What stays in CW**:
- `valueToWasm(Value, WasmValType) -> u64` — CW Value → zwasm u64
- `wasmToValue(u64, WasmValType) -> Value` — zwasm u64 → CW Value
- `WasmFn.call([]Value) -> Value` — high-level Clojure-friendly API
- `hostTrampoline` — invokes Clojure fn from Wasm callback
- `lookupImportFn/Source` — navigates CW PersistentArrayMap

**Host function callback signature** (unchanged from CW):
```zig
pub const HostFn = *const fn (*anyopaque, usize) anyerror!void;
```
This is already CW-agnostic. The Vm pointer is passed as `*anyopaque`,
and the `usize` context_id lets embedders store arbitrary state.

### Import Types

```zig
pub const ImportEntry = struct {
    module: []const u8,
    source: ImportSource,
};

pub const ImportSource = union(enum) {
    wasm_module: *Module,
    host_fns: []const HostFnEntry,
};

pub const HostFnEntry = struct {
    name: []const u8,
    callback: HostFn,
    context: usize,
};
```

---
