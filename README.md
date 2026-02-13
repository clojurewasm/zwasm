# zwasm

A small, fast WebAssembly runtime written in Zig. Library and CLI.

## Why zwasm

Most Wasm runtimes are either fast but large (wasmtime ~56MB, wasmer ~118MB) or small but slow (wasm3 ~0.3MB, interpreter only). zwasm targets the gap between them: **~1.1MB with ARM64 + x86_64 JIT compilation**.

| Runtime  | Binary  | Memory | JIT            |
|----------|--------:|-------:|----------------|
| zwasm    | 1.1MB   | ~3MB   | ARM64 + x86_64 |
| wasmtime | 56MB    | ~13MB  | Cranelift      |
| wasmer   | 118MB   | ~25MB  | LLVM/Cranelift |
| wasm3    | 0.3MB   | ~1MB   | None           |

zwasm was extracted from [ClojureWasm](https://github.com/niclas-ahden/ClojureWasm) (a Zig reimplementation of Clojure) where optimizing a Wasm subsystem inside a language runtime created a "runtime within runtime" problem. Separating it produced a cleaner codebase, independent optimization, and a reusable library. ClojureWasm remains the primary consumer.

## Features

- **523 opcodes**: Full MVP + SIMD (236 + 20 relaxed) + Exception handling + Function references + GC
- **4-tier execution**: bytecode > predecoded IR > register IR > ARM64/x86_64 JIT
- **99.9% spec conformance**: 60,873/60,906 spec tests passing
- **All Wasm 3.0 proposals**: See [Spec Coverage](#wasm-spec-coverage) below
- **WAT support**: `zwasm run file.wat`, build-time optional (`-Dwat=false`)
- **WASI Preview 1**: ~27 syscalls (fd, path, clock, environ, args, proc, random)
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

9/9 Wasm 3.0 proposals implemented. 239 unit tests, 356/356 E2E tests.

## Performance

Benchmarked on Apple M4 Pro against wasmtime 41.0.1 (Cranelift JIT).
10 of 21 benchmarks match or beat wasmtime. 18/21 within 2x.
Memory usage 3-4x lower across all benchmarks.

| Benchmark       | zwasm   | wasmtime | Ratio    |
|-----------------|--------:|---------:|---------:|
| sieve(1M)       | 3.6ms   | 7.1ms    | **0.5x** |
| nqueens(8)      | 2.5ms   | 8.4ms    | **0.3x** |
| tak(24,16,8)    | 10.6ms  | 10.7ms   | **1.0x** |
| gcd(1B)         | 1.5ms   | 5.3ms    | **0.3x** |
| ackermann(3,11) | 7.0ms   | 8.6ms    | **0.8x** |
| fib(35)         | 92ms    | 53ms     | 1.7x     |
| nbody(1M)       | 52ms    | 25ms     | 2.1x     |

Full results (21 benchmarks, 5 runtimes): `bench/runtime_comparison.yaml`

## Usage

### CLI

```bash
zwasm run module.wasm              # Run a WASI module
zwasm run module.wasm -- arg1 arg2 # With arguments
zwasm run module.wat               # Run a WAT text module
zwasm inspect module.wasm          # Show exports, imports, memory
zwasm validate module.wasm         # Validate without running
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
zig build test         # Run all tests (239 tests)
./zig-out/bin/zwasm run file.wasm
```

## Architecture

```
 .wat text          .wasm binary
      |                  |
      v                  |
 WAT Parser (optional)   |
      |                  |
      +-------->---------+
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
- [x] Stages 14-18: Wasm 3.0 proposals (tail calls, extended const, branch hinting, multi-memory, relaxed SIMD, function references, GC)
- [ ] Future: GC collector, WASI P1 full coverage, Component Model, WASI P2

## License

MIT
