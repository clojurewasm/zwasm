# Architecture

zwasm processes a WebAssembly module through a multi-stage pipeline: decode, validate, predecode to register IR, and execute via interpreter or JIT.

## Pipeline

```
.wasm binary
      |
      v
+-----------+
|  Decode   |  module.zig -- parse binary format, sections, types
+-----+-----+
      |
      v
+-----------+
| Validate  |  validate.zig -- type checking, operand stack simulation
+-----+-----+
      |
      v
+-----------+
| Predecode |  predecode.zig -- stack machine -> register IR
+-----+-----+
      |
      v
+-----------+
| Regalloc  |  regalloc.zig -- virtual -> physical register assignment
+-----+-----+
      |
      v
+----------------------+
|      Execution       |
|  +----------------+  |
|  |  Interpreter   |  |  vm.zig -- register IR dispatch loop
|  +-------+--------+  |
|          | hot path  |
|  +-------v--------+  |
|  |  JIT Compiler  |  |  jit.zig (ARM64), x86.zig (x86_64)
|  +----------------+  |
+----------------------+
```

## Execution tiers

zwasm uses tiered execution with automatic promotion:

1. **Interpreter** — Executes register IR instructions directly. All functions start here.
2. **JIT (ARM64/x86_64)** — When a function's call count or back-edge count exceeds a threshold, the register IR is compiled to native machine code. Subsequent calls execute the native code directly.

The JIT threshold is adaptive: hot loops trigger compilation faster via back-edge counting.

## Source map

| File | Role | LOC |
|------|------|-----|
| `module.zig` | Binary decoder, section parsing, LEB128 | ~2K |
| `validate.zig` | Type checker, operand stack simulation | ~1.7K |
| `predecode.zig` | Stack IR → register IR conversion | ~2K |
| `regalloc.zig` | Virtual → physical register allocation | ~1.8K |
| `vm.zig` | Interpreter, execution engine, store | ~7.3K |
| `jit.zig` | ARM64 JIT backend | ~4.9K |
| `x86.zig` | x86_64 JIT backend | ~3.9K |
| `types.zig` | Core type definitions, value types | ~1.3K |
| `opcode.zig` | Opcode definitions (523 total) | ~1.3K |
| `wasi.zig` | WASI Preview 1 (46 syscalls) | ~2.5K |
| `gc.zig` | GC proposal: heap, struct/array types | ~1.4K |
| `wat.zig` | WAT text format parser | ~3K |
| `cli.zig` | CLI frontend | ~1.9K |
| `instance.zig` | Module instantiation, linking | ~1K |

## Register IR

Instead of interpreting the WebAssembly stack machine directly, zwasm converts each function body to a register-based intermediate representation (IR) during predecode. This eliminates operand stack bookkeeping at runtime:

- **Stack IR**: `local.get 0` / `local.get 1` / `i32.add` (3 stack operations)
- **Register IR**: `add r2, r0, r1` (1 instruction)

The register IR uses virtual registers, which are then mapped to physical registers by the register allocator. Functions with few locals map directly; functions with many locals spill to memory.

## JIT compilation

The JIT compiler translates register IR to native machine code:

- **ARM64**: Full support — arithmetic, control flow, floating point, memory, call_indirect, SIMD
- **x86_64**: Full support — same coverage as ARM64

Key JIT optimizations:
- Inline self-calls (recursive functions call themselves without trampoline overhead)
- Smart spill/reload (only spill registers that are live across calls)
- Direct function calls (bypass function table lookup for known targets)
- Depth guard caching (call depth check in register instead of memory)

The JIT uses W^X memory protection: code is written to RW pages, then switched to RX before execution. A signal handler converts memory faults in JIT code back to Wasm traps.

## Module instantiation

```
WasmModule.load(bytes)       -> decode + validate + predecode
    |
    v
Instance.instantiate(store)  -> link imports, init memory/tables/globals
    |
    v
Vm.invoke(func_name, args)   -> execute via interpreter or JIT
```

The `Store` holds all runtime state: memories, tables, globals, function instances. Multiple module instances can share a store for cross-module linking.
