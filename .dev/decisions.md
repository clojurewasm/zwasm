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

## D104: Register IR — Stack-to-Register Conversion

**Decision**: Add a register-based IR tier between predecoded stack IR and JIT.
Convert stack-based PreInstr to register-based RegInstr at function load time.

### Problem

Profiling (task 3.3) shows stack traffic (local.get/set) = 30-50% of all instructions.
The operand stack is in memory (u128 array), so every push/pop is a memory access.
Register IR eliminates the operand stack by mapping values to virtual registers.

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

Same size as PreInstr — no cache penalty. Fields:
- `rd`: destination register for result
- `rs1`: first source register
- `operand`: polymorphic — rs2 packed in bits [7:0], or full 32-bit immediate

### Register Allocation

**Strategy**: Abstract interpretation of the Wasm operand stack.

1. Wasm locals → fixed registers `r0..r(N-1)` where N = param_count + local_count
2. Stack temporaries → sequential registers `rN, rN+1, ...` allocated during conversion
3. Total register count = N + max_stack_depth (known from Wasm validation)
4. Values stored in `u64[]` register file (one per function frame)

**Conversion**: Single pass over PreInstr[], maintaining a virtual stack of register indices:
- `local.get X` → push `rX` onto virtual stack (no instruction emitted!)
- `local.set X` → pop `rSrc` from virtual stack, emit `mov rX, rSrc`
- `i32.add` → pop `rB`, pop `rA`, allocate `rD`, emit `add rD, rA, rB`, push `rD`
- `i32.const C` → allocate `rD`, emit `const rD, C`, push `rD`

### Control Flow

Basic blocks with direct PC targets (same as current IR):
- `block`/`loop`/`if`: Push onto block stack with result register info
- `br depth`: Copy arity values to target block's result registers, jump
- `end`: Pop block, no instruction if block has 0 arity

Branch targets are still absolute RegInstr indices (like PreInstr).
Label stack is replaced by a simpler block info stack (result register + target PC).

### Function Calls

- Caller: place args in sequential registers starting from a chosen base
- Callee: receives args as its first N registers (natural mapping)
- Return value: in r0 of the called frame
- Operand stack still used for cross-frame value passing (invoke interface)

### Integration Path

```
Wasm bytecode
  ↓ predecode.zig (existing)
PreInstr[] (stack-based fixed-width IR)
  ↓ regalloc.zig (NEW — task 3.5)
RegInstr[] + register file metadata
  ↓ vm.zig:executeRegIR() (NEW — task 3.5)
Execution with virtual register file
```

Fallback: functions that fail register conversion use existing executeIR().
SIMD, multi-value returns > 1, very large functions can fall back.

### Expected Impact

- **fib**: 2-3x speedup (stack traffic 31% → 0%, plus implicit control flow)
- **sieve**: 1.5-2x (less stack traffic, already loop-optimized)
- **nbody**: 1.5-2x (memory ops dominate, but i32.const offset folding helps)
- **Overall**: Register IR is the foundation for JIT — same IR feeds ARM64 codegen

### Alternatives Considered

1. **Superinstruction expansion only**: +10-20% max, doesn't eliminate stack
2. **Direct bytecode→register**: Skips predecode, but loses superinstruction fusion
3. **12-byte instructions with 3 explicit registers**: Cleaner but 50% cache penalty
4. **Threaded code**: Platform-specific, doesn't help with JIT path

**Chose**: 8-byte 3-address with rs2 packed in operand. Same cache footprint as
existing IR, natural upgrade path to JIT (RegInstr → ARM64 instructions 1:1).
