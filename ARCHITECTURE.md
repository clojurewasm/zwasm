# Architecture

zwasm is a standalone Zig WebAssembly runtime — both a library and CLI tool.
This document describes the execution pipeline and file organization.

## Execution Pipeline

```
                         ┌─────────────────────────────────────────────┐
                         │              zwasm pipeline                 │
                         └─────────────────────────────────────────────┘

  .wasm bytes ──► Decode ──► Validate ──► Predecode ──► RegAlloc ──► JIT ──► Execute
                 module.zig  validate.zig  predecode.zig  regalloc.zig  jit.zig   vm.zig
                                                                        x86.zig

  Tier 0: Raw bytecode (decode only, cold start)
  Tier 1: Predecoded IR (fixed-width 8-byte PreInstr, eliminates LEB128)
  Tier 2: Register IR (3-address RegInstr, register file instead of stack)
  Tier 3: Native JIT (ARM64 via jit.zig, x86_64 via x86.zig)
```

## File Map

### Core — Binary Format & Decode

| File | Description |
|------|-------------|
| `src/module.zig` | Wasm binary decoder — sections 0-12, direct bytecode slices |
| `src/opcode.zig` | Opcode definitions — MVP, 0xFC misc, 0xFD SIMD, 0xFB GC |
| `src/types.zig` | Module/function types, public API (`WasmModule`, `WasmFn`) |
| `src/leb128.zig` | LEB128 variable-length integer decoding |

### Core — Execution Engines

| File | Description |
|------|-------------|
| `src/vm.zig` | Stack-based interpreter — switch dispatch for all opcodes |
| `src/predecode.zig` | Bytecode → fixed-width 8-byte `PreInstr` conversion |
| `src/regalloc.zig` | Stack IR → register IR conversion (single-pass) |
| `src/jit.zig` | ARM64 JIT compiler — `RegInstr` → native machine code |
| `src/x86.zig` | x86_64 JIT compiler — parallel backend to ARM64 |

### Core — Validation & Types

| File | Description |
|------|-------------|
| `src/validate.zig` | Operand/control stack type checker per Wasm spec |
| `src/type_registry.zig` | Hash-consing type canonicalization for rec groups |

### Runtime State

| File | Description |
|------|-------------|
| `src/store.zig` | Runtime store — functions, memories, tables, globals |
| `src/instance.zig` | Module instantiation — import linking, initializers |
| `src/memory.zig` | Linear memory — page-based, bounds-checked, little-endian |
| `src/guard.zig` | Virtual memory guard pages for JIT bounds elimination |
| `src/gc.zig` | GC heap — arena allocator for struct/array (GC proposal) |

### Host & System

| File | Description |
|------|-------------|
| `src/wasi.zig` | WASI Preview 1 — 19 host functions (I/O, fs, clock, random) |
| `src/c_api.zig` | C ABI export layer — 29 `zwasm_*` functions for FFI embedding |
| `src/cache.zig` | Module cache — predecoded IR serialization (`ZWCACHE` format) |
| `src/trace.zig` | Debug tracing — JIT, RegIR, execution analysis (zero-cost) |
| `src/cli.zig` | CLI — `run`, `inspect`, `validate`, `compile` commands |

### Text Formats

| File | Description |
|------|-------------|
| `src/wat.zig` | WAT parser — `.wat` → `.wasm` (conditional: `-Dwat=false`) |
| `src/wit.zig` | WIT parser — interface type signatures |
| `src/wit_parser.zig` | Minimal WIT subset parser for function signatures |

### Component Model

| File | Description |
|------|-------------|
| `src/component.zig` | Component binary format decoder (layer 1) |
| `src/canon_abi.zig` | Canonical ABI — value lifting/lowering |

### Fuzzing

| File | Description |
|------|-------------|
| `src/fuzz_gen.zig` | Structure-aware fuzz module generator |
| `src/fuzz_loader.zig` | Binary wasm fuzz harness |
| `src/fuzz_wat_loader.zig` | WAT text fuzz harness |

### Build & Config

| File | Description |
|------|-------------|
| `build.zig` | Build system — targets, feature flags (`-Dwat`, `-Doptimize`) |
| `.github/versions.lock` | Centralized pinned tool versions (mirror of flake.nix) |

## Test Suites

| Suite | Command | Coverage |
|-------|---------|----------|
| Unit tests | `zig build test` | All src files |
| Spec tests | `python3 test/spec/run_spec.py --build --summary` | 62,263 tests |
| E2E tests | `python3 test/e2e/run_e2e.py --convert --summary` | 796 tests |
| Real-world | `python3 test/realworld/run_compat.py` | 50 programs (Mac/Ubuntu); 25 (Windows C+C++ subset) |
| FFI tests | `bash test/c_api/run_ffi_test.sh --build` | 80 cases (Mac/Ubuntu/Windows) |
| Fuzz | `bash test/fuzz/fuzz_campaign.sh --duration=60` | Continuous |

## Allocator Flow

All components receive the same `std.mem.Allocator` from the caller.
No global allocator. C API wraps external alloc/free callbacks into the same interface.

```
Caller allocator
  └─ WasmModule.load(alloc, bytes)
       ├─ Store.init(alloc)
       │    ├─ GcHeap.init(alloc)        ← WasmGC struct/array arena
       │    └─ TypeRegistry.init(alloc)   ← rec group dedup
       ├─ Module.init(alloc, bytes)      ← parsed sections
       ├─ Instance.init(alloc, ...)      ← address mappings
       └─ Vm.init(alloc)                ← execution state

C API path:
  zwasm_module_new()              → internal GPA as allocator
  zwasm_module_new_configured()   → NULL config: internal GPA
                                  → with config: C callback-wrapped allocator
```

Wasm linear memory (`memory.grow`) is separately managed per spec — unaffected
by the host allocator choice.

## Cross-References

- **Design decisions**: `.dev/decisions.md` (D116+), `.dev/decisions-archive.md` (D100-D115)
- **Data structures**: `docs/data-structures.md`
- **Embedding guide**: `docs/embedding.md`
- **Proposal tracking**: `.dev/proposal-watch.md`
- **Roadmap**: `.dev/roadmap.md`
- **API boundary**: `docs/api-boundary.md`
