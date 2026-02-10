# zwasm

A small, fast WebAssembly runtime written in Zig. Library and CLI.

## Why zwasm

Most Wasm runtimes are either fast but large (wasmtime ~56MB, wasmer ~110MB) or small but slow (wasm3 ~0.3MB, interpreter only). zwasm targets the gap between them: **under 1MB with ARM64 JIT compilation**.

| Runtime  | Binary  | Memory | JIT     |
|----------|--------:|-------:|---------|
| zwasm    | 0.7MB   | ~3MB   | ARM64   |
| wasmtime | 56MB    | ~13MB  | Cranelift |
| wasmer   | 110MB   | ~25MB  | LLVM/Cranelift |
| wasm3    | 0.3MB   | ~1MB   | None    |

zwasm was extracted from [ClojureWasm](https://github.com/clojurewasm/ClojureWasm) (a Zig reimplementation of Clojure) where optimizing a Wasm subsystem inside a language runtime created a "runtime within runtime" problem. Separating it produced a cleaner codebase, independent optimization, and a reusable library. ClojureWasm remains the primary dog fooding target.

## Features

- **461 opcodes**: Full MVP + SIMD (236 v128 instructions)
- **4-tier execution**: bytecode > predecoded IR > register IR > ARM64 JIT
- **99.9% spec conformance**: 30,648/30,686 spec tests passing
- **WASI Preview 1**: ~27 syscalls (fd, path, clock, environ, args, proc, random)
- **Zero dependencies**: Pure Zig, no libc required
- **Allocator-parameterized**: Caller controls memory allocation

### Performance (vs wasmtime JIT)

Some benchmarks already match or beat wasmtime. JIT coverage expansion is ongoing.

| Benchmark     | zwasm   | wasmtime | Ratio    |
|---------------|--------:|---------:|---------:|
| sieve(1M)     | 6ms     | 7ms      | **0.8x** |
| nqueens(8)    | 2ms     | 5ms      | **0.5x** |
| tak(24,16,8)  | 14ms    | 11ms     | 1.3x     |
| fib(35)       | 117ms   | 54ms     | 2.2x     |
| nbody(1M)     | 64ms    | 24ms     | 2.7x     |

## Usage

### CLI

```bash
zwasm run module.wasm              # Run a WASI module
zwasm run module.wasm -- arg1 arg2 # With arguments
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
zig build test         # Run all tests (137 tests)
./zig-out/bin/zwasm run file.wasm
```

## Architecture

```
 .wasm binary
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
 RegIR Interpreter           ARM64 JIT
 (fallback)              (hot functions)
```

Hot functions are detected via call counting and back-edge counting,
then compiled to native ARM64 code. Functions that use unsupported
opcodes fall back to the register IR interpreter.

## Project Philosophy

**Small and fast, not feature-complete.** zwasm prioritizes binary size and
runtime performance density (performance per byte of binary). It does not
aim to replace wasmtime or wasmer for general use. Instead, it targets
environments where size and startup time matter: embedded systems, edge
computing, CLI tools, and as an embeddable library in Zig projects.

**ARM64-first.** Optimization effort focuses on Apple Silicon and ARM64 Linux.
x86_64 JIT is a future goal but not a current priority.

**Spec fidelity over expedience.** Correctness comes before performance.
The spec test suite runs on every change.

## Roadmap

- [x] Stage 0: Extraction from ClojureWasm
- [x] Stage 1: Library API + CLI
- [x] Stage 2: Spec conformance (99.9%)
- [x] Stage 3: ARM64 JIT (fib within 2x of wasmtime)
- [x] Stage 4: Polish + robustness
- [ ] Stage 5: JIT coverage expansion (f64 done, memory/br_table JIT next)
- [ ] Future: Component Model, WASI P2, x86_64 JIT

## License

MIT
