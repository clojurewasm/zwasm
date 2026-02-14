# Design Decisions — Archive (D100-D115)

Archived from decisions.md. Reference by `D##` number.

---

## D100: Extraction from ClojureWasm

**Decision**: Extract CW `src/wasm/` as standalone library rather than rewriting.

**Background**: ClojureWasm (Clojure's Zig reimplementation) needed Wasm FFI, but
the Wasm processing code embedded within CW was becoming a performance bottleneck.
Optimizing it in-place would mean developing a runtime within a runtime — the Wasm
subsystem has its own IR, JIT, interpreter, and optimization concerns that are
orthogonal to the Clojure language implementation. Extracting it as a separate
project keeps both codebases clean, allows independent optimization, and produces
a reusable library for the broader Zig ecosystem. CW remains the primary dog
fooding target: improvements to zwasm directly accelerate CW's Wasm FFI.

**Rationale**:
- 11K LOC of battle-tested code (461 opcodes, SIMD, predecoded IR)
- CW has been using this code in production since Phase 35W (D84)
- Rewriting would lose optimizations (superinstructions, VM reuse, sidetable)
- Separate project avoids "runtime within runtime" complexity
- Independent optimization cadence (JIT, regalloc, benchmarks)
- Reusable as a standalone library and CLI tool

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

## D104: Register IR — Stack-to-Register Conversion

**Decision**: Add a register-based IR tier between predecoded stack IR and JIT.
Convert stack-based PreInstr to register-based RegInstr at function load time.

### Instruction Format: 8-byte 3-address

```zig
pub const RegInstr = extern struct {
    op: u16,       // instruction type
    rd: u8,        // destination register
    rs1: u8,       // source register 1
    operand: u32,  // rs2 (low byte) | immediate | branch target | pool index
};
comptime { assert(@sizeOf(RegInstr) == 8); }
```

### Register Allocation

**Strategy**: Abstract interpretation of the Wasm operand stack.
1. Wasm locals → fixed registers `r0..r(N-1)` where N = param_count + local_count
2. Stack temporaries → sequential registers `rN, rN+1, ...` allocated during conversion
3. Total register count = N + max_stack_depth (known from Wasm validation)
4. Values stored in `u64[]` register file (one per function frame)

### Integration Path

```
Wasm bytecode
  ↓ predecode.zig (existing)
PreInstr[] (stack-based fixed-width IR)
  ↓ regalloc.zig (NEW)
RegInstr[] + register file metadata
  ↓ vm.zig:executeRegIR()
Execution with virtual register file
```

---

## D105: ARM64 JIT — Function-Level Codegen Architecture

**Decision**: Compile hot functions from RegInstr to ARM64 machine code using
direct code emission. Function-level compilation, no external codegen libraries.

### Tiered Execution Model

```
Tier 0: Bytecode (decode)        — cold startup
Tier 1: Predecoded IR (PreInstr) — after first call
Tier 2: Register IR (RegInstr)   — after first call (if convertible)
Tier 3: ARM64 JIT                — after N calls (hot functions)
```

### Register Mapping

| ARM64 reg | Purpose                               |
|-----------|---------------------------------------|
| x0-x7    | Wasm function args + return value      |
| x8-x15   | Wasm temporaries (caller-saved)        |
| x16-x17  | Scratch (IP0/IP1, linker use)          |
| x18      | Platform reserved (macOS)              |
| x19-x28  | Wasm locals (callee-saved, preserved)  |
| x29      | Frame pointer (FP)                     |
| x30      | Link register (LR)                     |
| SP       | Stack pointer                          |

---

## D106: Build-time Feature Flags

**Decision**: Zig build options. `-Dwat=false` excludes WAT parser code.
`build_options.enable_wat` checked at comptime for dead code elimination.

---

## D110: CompositeType migration (GC proposal)

**Decision**: `TypeDef { composite: CompositeType, super_types, is_final }`.
`CompositeType = union(enum) { func, struct_type, array_type }`.
`getTypeFunc(idx) ?FuncType` helper for safe extraction at call sites.
Impact: 9 files, ~80 call sites.

---

## D111: GC heap — no-collect allocator

**Decision**: No-collect allocator (append-only). `GcHeap` with `allocStruct/allocArray/getObject`.
Collector interface deferred to W20.

---

## D112: i31 representation — unboxed tagged value

**Decision**: Encode on operand stack u128: bit 63 = 1 (i31 tag), bits 0-30 = value.
Null i31ref = 0. No heap interaction.

---

## D113: GC ref encoding on operand stack

**Decision**: `(gc_heap_index + 1) | (GC_TAG << 32)`. Tag bits distinguish GC refs
from funcref. Zero = null.

---

## D114: Subtype checking — linear scan

**Decision**: Linear scan of `TypeDef.super_types` chain. Type counts are small.
Display vector optimization deferred to W20.

---

## D115: FP register cache — D2-D7

**Decision**: Use ARM64 D2-D7 as 6-slot FP register cache. Cache maps vreg→Dn,
allowing `FADD Dd, Dn, Dm` directly without GPR round-trips. Eviction writes back
via `FMOV Xscratch, Dn` + `storeVreg()`. Evict all before: branches, BLR calls.
Result: nbody 43ms→8ms (5.4x), 2.4x faster than wasmtime.
