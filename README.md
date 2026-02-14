# zwasm

A small, fast WebAssembly runtime written in Zig. Library and CLI.

## Why zwasm

Most Wasm runtimes are either fast but large (wasmtime ~56MB, wasmer ~118MB) or small but slow (wasm3 ~0.3MB, interpreter only). zwasm targets the gap between them: **~1.1MB with ARM64 + x86_64 JIT compilation**.

| Runtime  | Binary  | Memory | JIT            |
|----------|--------:|-------:|----------------|
| zwasm    | 1.1MB   | ~3MB   | ARM64 + x86_64 |
| wasmtime | 56MB    | ~12MB  | Cranelift      |
| wasmer   | 118MB   | ~30MB  | LLVM/Cranelift |
| wasm3    | 0.3MB   | ~1MB   | None           |

zwasm was extracted from [ClojureWasm](https://github.com/niclas-ahden/ClojureWasm) (a Zig reimplementation of Clojure) where optimizing a Wasm subsystem inside a language runtime created a "runtime within runtime" problem. Separating it produced a cleaner codebase, independent optimization, and a reusable library. ClojureWasm remains the primary consumer.

## Features

- **581+ opcodes**: Full MVP + SIMD (236 + 20 relaxed) + Exception handling + Function references + GC + Threads (79 atomics)
- **4-tier execution**: bytecode > predecoded IR > register IR > ARM64/x86_64 JIT
- **99.8% spec conformance**: 61,650/61,761 spec tests passing
- **All Wasm 3.0 proposals**: See [Spec Coverage](#wasm-spec-coverage) below
- **Component Model**: WIT parser, Canonical ABI, component linking, WASI P2 adapter
- **WAT support**: `zwasm run file.wat`, build-time optional (`-Dwat=false`)
- **WASI Preview 1 + 2**: 46/46 P1 syscalls (100%), P2 via component adapter
- **Threads**: Shared memory, 79 atomic operations (load/store/RMW/cmpxchg), wait/notify
- **Security**: Deny-by-default WASI, capability flags, resource limits
- **Zero dependencies**: Pure Zig, no libc required
- **Allocator-parameterized**: Caller controls memory allocation

## Wasm Spec Coverage

All ratified Wasm proposals through 3.0 are implemented.

| Spec     | Proposals                                                                         | Status       |
|----------|-----------------------------------------------------------------------------------|--------------|
| Wasm 1.0 | MVP (172 opcodes)                                                                | Complete     |
| Wasm 2.0 | Sign extension, Non-trapping f->i, Bulk memory, Reference types, Multi-value, Fixed-width SIMD (236) | All complete |
| Wasm 3.0 | Memory64, Exception handling, Tail calls, Extended const, Branch hinting, Multi-memory, Relaxed SIMD (20), Function references, GC (31) | All complete |
| Phase 3  | Wide arithmetic (4), Custom page sizes                                           | Complete     |
| Phase 4  | Threads (79 atomics)                                                             | Complete     |
| Layer    | Component Model (WIT, Canon ABI, WASI P2)                                       | Complete     |

18/18 proposals complete. 388 unit tests, 356/356 E2E tests.

## Performance

Benchmarked on Apple M4 Pro against wasmtime 41.0.1 (Cranelift JIT).
13 of 21 benchmarks match or beat wasmtime. 20/21 within 2x.
Memory usage 3-4x lower across all benchmarks.

| Benchmark       | zwasm   | wasmtime | Ratio    |
|-----------------|--------:|---------:|---------:|
| nqueens(8)      | 2.6ms   | 6.9ms    | **0.4x** |
| nbody(1M)       | 8.6ms   | 21.9ms   | **0.4x** |
| gcd(1B)         | 2.6ms   | 6.0ms    | **0.4x** |
| sieve(1M)       | 5.1ms   | 5.9ms    | **0.9x** |
| tak(24,16,8)    | 10.1ms  | 11.6ms   | **0.9x** |
| fib(35)         | 52ms    | 51ms     | 1.0x     |
| st_fib2(40)     | 1086ms  | 686ms    | 1.6x     |

Full results (21 benchmarks, 5 runtimes): `bench/runtime_comparison.yaml`

## Usage

### CLI

```bash
zwasm run module.wasm              # Run a WASI module
zwasm run module.wasm -- arg1 arg2 # With arguments
zwasm run module.wat               # Run a WAT text module
zwasm run component.wasm           # Run a component (auto-detected)
zwasm inspect module.wasm          # Show exports, imports, memory
zwasm validate module.wasm         # Validate without running
zwasm features                     # List supported proposals
zwasm features --json              # Machine-readable output
```

### Library

```zig
const zwasm = @import("zwasm");

var module = try zwasm.WasmModule.load(allocator, wasm_bytes);
defer module.deinit();

var args = [_]u64{35};
var results = [_]u64{0};
try module.invoke("fib", &args, &results);
// results[0] == 9227465
```

See [docs/usage.md](docs/usage.md) for detailed library and CLI documentation.

## Build

Requires Zig 0.15.2.

```bash
zig build              # Build (Debug)
zig build test         # Run all tests (388 tests)
./zig-out/bin/zwasm run file.wasm
```

## Architecture

```
 .wat text    .wasm binary    .wasm component
      |            |                |
      v            |                v
 WAT Parser        |          Component Decoder
 (optional)        |          (WIT + Canon ABI)
      |            |                |
      +------>-----+-----<---------+
               |
               v
         Module (decode + validate)
               |
               v
         Predecoded IR (fixed-width, cache-friendly)
               |
               v
         Register IR (stack elimination, peephole opts)
               |                          \
               v                           v
         RegIR Interpreter           ARM64/x86_64 JIT
         (fallback)              (hot functions)
```

Hot functions are detected via call counting and back-edge counting,
then compiled to native code. Functions that use unsupported opcodes
fall back to the register IR interpreter.

## Project Philosophy

**Small and fast, not feature-complete.** zwasm prioritizes binary size and
runtime performance density (performance per byte of binary). It does not
aim to replace wasmtime or wasmer for general use. Instead, it targets
environments where size and startup time matter: embedded systems, edge
computing, CLI tools, and as an embeddable library in Zig projects.

**ARM64-first, x86_64 supported.** Primary optimization on Apple Silicon and ARM64 Linux.
x86_64 JIT also available for Linux server deployment.

**Spec fidelity over expedience.** Correctness comes before performance.
The spec test suite runs on every change.

## Roadmap

- [x] Stages 0-4: Core runtime (extraction, library API, spec conformance, ARM64 JIT)
- [x] Stage 5: JIT coverage (20/21 benchmarks within 2x of wasmtime)
- [x] Stages 7-12: Wasm 3.0 (memory64, exception handling, wide arithmetic, custom page sizes, WAT parser)
- [x] Stage 13: x86_64 JIT backend
- [x] Stages 14-18: Wasm 3.0 proposals (tail calls, multi-memory, relaxed SIMD, function references, GC)
- [x] Stage 19: Post-GC improvements (GC spec tests, WASI P1 full coverage, GC collector)
- [x] Stage 20: `zwasm features` CLI
- [x] Stage 21: Threads (shared memory, 79 atomic operations)
- [x] Stage 22: Component Model (WIT, Canon ABI, WASI P2)
- [x] Stage 23: JIT optimization (smart spill, direct call, FP cache, self-call inline)
- [x] Stage 25: Lightweight self-call (fib now matches wasmtime)
- [ ] Future: WASI P3/async, GC collector upgrade, liveness-based regalloc

## License

MIT
