# Data Structures

Key types organized by pipeline stage. See `ARCHITECTURE.md` for the full pipeline.

## Binary Format & Decode

| Type | File | Description |
|------|------|-------------|
| `Module` | `src/module.zig` | Decoded Wasm binary — section slices, function bodies, types, imports/exports. Immutable after decode. |
| `FuncType` | `src/module.zig` | Function signature — parameter types + result types. |
| `TypeDef` | `src/module.zig` | GC composite type definition — `func`, `struct_type`, or `array_type` with supertypes. |

## Predecoded IR (Tier 1)

| Type | File | Description |
|------|------|-------------|
| `PreInstr` | `src/predecode.zig` | Fixed-width 8-byte instruction: `opcode:u16, extra:u16, operand:u32`. Eliminates LEB128 at dispatch. |
| `IrFunc` | `src/predecode.zig` | Predecoded function — `PreInstr[]` code array + `u64[]` constant pool. |

## Register IR (Tier 2)

| Type | File | Description |
|------|------|-------------|
| `RegInstr` | `src/regalloc.zig` | 12-byte 3-address instruction: `op:u16, rd:u16, rs1:u16, rs2:u16, operand:u32`. Virtual register indices. |
| `RegFuncInfo` | `src/regalloc.zig` | Register IR metadata — register count, call info, self-call flag, loop headers. |

## Runtime State

| Type | File | Description |
|------|------|-------------|
| `Store` | `src/store.zig` | Runtime store — function registry, memories, tables, globals. Shared across instances. |
| `Instance` | `src/instance.zig` | Instantiated module — resolved imports, allocated memories/tables/globals. |
| `Memory` | `src/memory.zig` | Linear memory — page array (64 KiB pages), current/max page count, optional guard pages. |
| `GcHeap` | `src/gc.zig` | GC heap — arena-based allocation for struct/array objects. Adaptive collection threshold. |

## Public API

| Type | File | Description |
|------|------|-------------|
| `WasmModule` | `src/types.zig` | High-level API — load from bytes, invoke exports, access memory. Wraps `Module` + `Store` + `Instance`. |
| `WasmFn` | `src/types.zig` | Callable function handle — `invoke([]u64, []u64)` raw interface. |

## JIT

| Type | File | Description |
|------|------|-------------|
| `JitFn` | `src/jit.zig` | Compiled native function — executable memory, entry point, PC map for OSR. |
| `Emitter` | `src/jit.zig` | ARM64 code emitter — instruction encoding, register mapping, branch patching. |
| `X86Emitter` | `src/x86.zig` | x86_64 code emitter — REX/VEX encoding, System V ABI. |

## Validation

| Type | File | Description |
|------|------|-------------|
| `TypeRegistry` | `src/type_registry.zig` | Hash-consing registry — canonicalizes rec groups for O(1) cross-module type identity. |

## Host

| Type | File | Description |
|------|------|-------------|
| `HostFn` | `src/types.zig` | Host function callback — `fn(*anyopaque, usize) anyerror!void`. Embedder-defined. |
| `Cache` | `src/cache.zig` | Module cache — `ZWCACHE` binary format with SHA-256 key and version field. |
