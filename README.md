# zwasm

A small, fast WebAssembly runtime written in Zig. Library and CLI.

## Why zwasm

Most Wasm runtimes are either fast but large (wasmtime ~56MB, wasmer ~110MB) or small but slow (wasm3 ~0.3MB, interpreter only). zwasm targets the gap between them: **~1MB with ARM64 + x86_64 JIT compilation**.

| Runtime  | Binary  | Memory | JIT            |
|----------|--------:|-------:|----------------|
| zwasm    | 1.0MB   | ~3MB   | ARM64 + x86_64 |
| wasmtime | 56MB    | ~13MB  | Cranelift      |
| wasmer   | 110MB   | ~25MB  | LLVM/Cranelift |
| wasm3    | 0.3MB   | ~1MB   | None           |

zwasm was extracted from [ClojureWasm](https://github.com/niclas-ahden/ClojureWasm) (a Zig reimplementation of Clojure) where optimizing a Wasm subsystem inside a language runtime created a "runtime within runtime" problem. Separating it produced a cleaner codebase, independent optimization, and a reusable library. ClojureWasm remains the primary consumer.

## Features

- **472 opcodes**: Full MVP + SIMD (236 v128) + Exception handling + Wide arithmetic
- **4-tier execution**: bytecode > predecoded IR > register IR > ARM64/x86_64 JIT
- **100% spec conformance**: 32,231/32,236 spec tests passing (204 test files)
- **Wasm 3.0**: memory64, exception handling, tail calls, extended const, branch hinting, multi-memory, wide arithmetic, custom page sizes
- **WAT support**: `zwasm run file.wat`, build-time optional (`-Dwat=false`)
- **WASI Preview 1**: ~27 syscalls (fd, path, clock, environ, args, proc, random)
- **Security**: Deny-by-default WASI, capability flags, resource limits
- **Zero dependencies**: Pure Zig, no libc required
- **Allocator-parameterized**: Caller controls memory allocation

### Performance (vs wasmtime JIT)

11 of 21 benchmarks match or beat wasmtime. 20/21 within 2x.

| Benchmark     | zwasm   | wasmtime | Ratio    |
|---------------|--------:|---------:|---------:|
| sieve(1M)     | 5ms     | 8ms      | **0.6x** |
| nqueens(8)    | 3ms     | 7ms      | **0.4x** |
| tak(24,16,8)  | 12ms    | 12ms     | **1.0x** |
| fib(35)       | 97ms    | 56ms     | 1.7x     |
| nbody(1M)     | 41ms    | 25ms     | 1.6x     |

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

## Build

Requires Zig 0.15.2.

```bash
zig build              # Build (Debug)
zig build test         # Run all tests (229 tests)
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

- [x] Stage 0-4: Core runtime (extraction, library API, spec conformance, ARM64 JIT)
- [x] Stage 5: JIT coverage (20/21 benchmarks within 2x of wasmtime)
- [x] Stage 7-12: Wasm 3.0 proposals (memory64, exception handling, wide arithmetic, custom page sizes, WAT parser)
- [x] Stage 13: x86_64 JIT backend
- [x] Stage 14: Wasm 3.0 trivial proposals (extended const, branch hinting, tail calls)
- [x] Stage 15: Wasm 3.0 multi-memory
- [ ] Stage 16: Relaxed SIMD
- [ ] Stage 17: Function references
- [ ] Stage 18: GC
- [ ] Future: Component Model, WASI P2, threads

## License

MIT
