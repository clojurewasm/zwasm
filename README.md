# zwasm

[![CI](https://github.com/clojurewasm/zwasm/actions/workflows/ci.yml/badge.svg)](https://github.com/clojurewasm/zwasm/actions/workflows/ci.yml)
[![Spec Tests](https://img.shields.io/badge/spec_tests-62%2C158%2F62%2C158-brightgreen)](https://github.com/clojurewasm/zwasm)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A small, fast WebAssembly runtime written in Zig. Library and CLI.

## Why zwasm

Most Wasm runtimes are either fast but large (wasmtime ~56MB) or small but slow (wasm3 ~0.3MB, interpreter only). zwasm targets the gap between them: **~1.2MB with ARM64 + x86_64 JIT compilation**.

| Runtime  | Binary  | Memory | JIT            |
|----------|--------:|-------:|----------------|
| zwasm    | 1.2MB   | ~3MB   | ARM64 + x86_64 |
| wasmtime | 56MB    | ~12MB  | Cranelift      |
| wasm3    | 0.3MB   | ~1MB   | None           |

zwasm was extracted from [ClojureWasm](https://github.com/niclas-ahden/ClojureWasm) (a Zig reimplementation of Clojure) where optimizing a Wasm subsystem inside a language runtime created a "runtime within runtime" problem. Separating it produced a cleaner codebase, independent optimization, and a reusable library. ClojureWasm remains the primary consumer.

## Features

- **581+ opcodes**: Full MVP + SIMD (236 + 20 relaxed) + Exception handling + Function references + GC + Threads (79 atomics)
- **4-tier execution**: bytecode > predecoded IR > register IR > ARM64/x86_64 JIT
- **100% spec conformance**: 62,158/62,158 spec tests passing (Mac + Ubuntu)
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

18/18 proposals complete. 425 unit tests, 356/356 E2E tests.

## Performance

Benchmarked on Apple M4 Pro against wasmtime 41.0.1 (Cranelift JIT).
13 of 21 benchmarks match or beat wasmtime. 20/21 within 2x.
Memory usage 3-4x lower across all benchmarks.

| Benchmark       | zwasm   | wasmtime | Ratio    |
|-----------------|--------:|---------:|---------:|
| nqueens(8)      | 2.4ms   | 4.6ms    | **0.5x** |
| nbody(1M)       | 9.7ms   | 20.8ms   | **0.5x** |
| gcd(1B)         | 2.3ms   | 5.1ms    | **0.5x** |
| sieve(1M)       | 4.4ms   | 5.9ms    | **0.7x** |
| tak(24,16,8)    | 7.3ms   | 10.7ms   | **0.7x** |
| fib(35)         | 54ms    | 51ms     | 1.1x     |
| st_fib2(40)     | 1033ms  | 673ms    | 1.5x     |

Full results (21 benchmarks): `bench/runtime_comparison.yaml`

## Install

```bash
# From source (requires Zig 0.15.2)
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/zwasm ~/.local/bin/

# Or use the install script
curl -fsSL https://raw.githubusercontent.com/clojurewasm/zwasm/main/install.sh | bash

# Or via Homebrew (macOS/Linux)
brew install clojurewasm/tap/zwasm
```

## Usage

### CLI

```bash
zwasm run module.wasm                     # Run a WASI module
zwasm run module.wasm -- arg1 arg2        # With arguments
zwasm run module.wat                      # Run a WAT text module
zwasm run --invoke fib math.wasm 35       # Call a specific function
zwasm run math.wasm --invoke fib 35       # Same (options after file)
zwasm run component.wasm                  # Run a component (auto-detected)
zwasm inspect module.wasm                 # Show exports, imports, memory
zwasm validate module.wasm                # Validate without running
zwasm features                            # List supported proposals
zwasm features --json                     # Machine-readable output
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
zig build test         # Run all tests (425 tests)
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
aim to replace wasmtime for general use. Instead, it targets
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
- [x] Stages 26-31: JIT peephole, platform verification, spec cleanup, GC benchmarks
- [x] Stage 32: 100% spec conformance (62,158/62,158 on Mac + Ubuntu)
- [x] Stage 33: Fuzz testing (differential testing, extended fuzz campaign, 0 crashes)
- [x] Stages 35-41: Production hardening (crash safety, CI/CD, docs, API stability, distribution)
- [ ] Stage 42-43: Community preparation, v1.0.0 release
- [ ] Future: WASI P3/async, GC collector upgrade, liveness-based regalloc

## Versioning

zwasm follows [Semantic Versioning](https://semver.org/). The public API surface is defined in [docs/api-boundary.md](docs/api-boundary.md).

- **Stable** types and functions (WasmModule, WasmFn, etc.) won't break in minor/patch releases
- **Experimental** types (runtime.\*, WIT) may change in minor releases
- **Deprecation**: At least one minor version notice before removal

## Documentation

- [Book](https://clojurewasm.github.io/zwasm/) — Getting started, architecture, embedding guide, CLI reference
- [API Boundary](docs/api-boundary.md) — Stable vs experimental API surface
- [CHANGELOG](CHANGELOG.md) — Version history

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, development workflow, and CI checks.

## License

MIT
