# zwasm

[![CI](https://github.com/clojurewasm/zwasm/actions/workflows/ci.yml/badge.svg)](https://github.com/clojurewasm/zwasm/actions/workflows/ci.yml)
[![Spec Tests](https://img.shields.io/badge/spec_tests-62%2C263%2F62%2C263-brightgreen)](https://github.com/clojurewasm/zwasm)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/chaploud?logo=githubsponsors&logoColor=white&color=ea4aaa)](https://github.com/sponsors/chaploud)

A small, fast WebAssembly runtime written in Zig. Library and CLI.

## Why zwasm

> **Note**: zwasm is under active development. Real-world Wasm compatibility
> testing and benchmark verification are ongoing. The API and behavior may
> change between releases. Not yet recommended for production use.

Most Wasm runtimes are either fast but large (wasmtime ~56MB) or small but slow (wasm3 ~0.3MB, interpreter only). zwasm targets the gap between them: **~1.2MB with ARM64 + x86_64 JIT compilation**.

| Runtime  | Binary  | Memory | JIT            |
|----------|--------:|-------:|----------------|
| zwasm    | 1.2MB   | ~4.5MB | ARM64 + x86_64 |
| wasmtime | 56MB    | ~12MB  | Cranelift      |
| wasm3    | 0.3MB   | ~1MB   | None           |

zwasm was extracted from [ClojureWasm](https://github.com/clojurewasm/ClojureWasm) (a Zig reimplementation of Clojure) where optimizing a Wasm subsystem inside a language runtime created a "runtime within runtime" problem. Separating it produced a cleaner codebase, independent optimization, and a reusable library. ClojureWasm remains the primary consumer.

## Features

- **581+ opcodes**: Full MVP + SIMD (236 + 20 relaxed) + Exception handling + Function references + GC + Threads (79 atomics)
- **4-tier execution**: bytecode > predecoded IR > register IR > ARM64/x86_64 JIT
- **100% spec conformance**: 62,263/62,263 spec tests, 792/792 E2E tests, 50 real-world programs (Mac + Ubuntu)
- **All Wasm 3.0 proposals**: See [Spec Coverage](#wasm-spec-coverage) below
- **Component Model**: WIT parser, Canonical ABI, component linking, WASI P2 adapter
- **WAT support**: `zwasm file.wat`, build-time optional (`-Dwat=false`)
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

18/18 proposals complete. 521 unit tests, 792/792 E2E tests, 50 real-world compatibility tests.

## Performance

Benchmarked on Apple M4 Pro against wasmtime 41.0.1 (Cranelift JIT).
16 of 29 benchmarks match or beat wasmtime. 25/29 within 1.5x.
Memory usage 3-4x lower than wasmtime, 8-10x lower than Bun/Node.

| Benchmark       | zwasm  | wasmtime | Bun    | Node   |
|-----------------|-------:|---------:|-------:|-------:|
| nqueens(8)      | 2ms    | 5ms      | 14ms   | 23ms   |
| nbody(1M)       | 22ms   | 22ms     | 32ms   | 36ms   |
| gcd(12K,67K)    | 2ms    | 5ms      | 14ms   | 23ms   |
| sieve(1M)       | 5ms    | 7ms      | 17ms   | 29ms   |
| tak(24,16,8)    | 5ms    | 9ms      | 17ms   | 29ms   |
| fib(35)         | 46ms   | 51ms     | 36ms   | 52ms   |
| st_fib2         | 900ms  | 674ms    | 353ms  | 389ms  |

Full results (29 benchmarks): `bench/runtime_comparison.yaml`

> **Note**: SIMD benchmarks are not included above. SIMD operations currently run on the
> stack interpreter (no JIT), resulting in ~22x slower than wasmtime for SIMD-heavy workloads.
> See [SIMD Performance](#known-limitations) below.

## Install

```bash
# From source (requires Zig 0.15.2)
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/zwasm ~/.local/bin/

# Or use the install script
curl -fsSL https://raw.githubusercontent.com/clojurewasm/zwasm/main/install.sh | bash

# Or via Homebrew (macOS/Linux) — coming soon
# brew install clojurewasm/tap/zwasm
```

## Usage

### CLI

```bash
zwasm module.wasm                         # Run a WASI module (run is optional)
zwasm module.wasm -- arg1 arg2            # With arguments
zwasm module.wat                          # Run a WAT text module
zwasm module.wasm --invoke fib 35         # Call a specific function
zwasm run module.wasm --allow-all         # Explicit run subcommand also works
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

### C API

zwasm also exposes a C API for use from any FFI-capable language (C, Python, Rust, Go, etc.):

```bash
zig build lib    # Build libzwasm (.dylib / .so / .a)
```

```c
#include "zwasm.h"

zwasm_module_t *mod = zwasm_module_new(wasm_bytes, len);
uint64_t results[1] = {0};
zwasm_module_invoke(mod, "f", NULL, 0, results, 1);
zwasm_module_delete(mod);
```

See the [C API chapter](https://clojurewasm.github.io/zwasm/en/c-api.html) in the book for the full API reference.

## Examples

### WAT examples (`examples/wat/`)

33 numbered educational WAT files, ordered from simple to advanced:

| # | Category | Examples |
|---|----------|----------|
| 01-09 | Basics | `hello_add`, `if_else`, `loop`, `factorial`, `fibonacci`, `select`, `collatz`, `stack_machine`, `counter` |
| 10-15 | Types | `i64_math`, `float_math`, `bitwise`, `type_convert`, `sign_extend`, `saturating_trunc` |
| 16-19 | Memory | `memory`, `data_string`, `grow_memory`, `bulk_memory` |
| 20-24 | Functions | `multi_return`, `multi_value`, `br_table`, `mutual_recursion`, `call_indirect` |
| 25-26 | Wasm 3.0 | `return_call` (tail calls), `extended_const` |
| 27-29 | Algorithms | `bubble_sort`, `is_prime`, `simd_add` |
| 30-33 | WASI | `wasi_hello`, `wasi_echo`, `wasi_args`, `wasi_write_file` |

Each file includes a run command in its header comment:

```bash
zwasm examples/wat/01_hello_add.wat --invoke add 2 3   # → 5
zwasm examples/wat/05_fibonacci.wat --invoke fib 10    # → 55
zwasm examples/wat/30_wasi_hello.wat --allow-all       # → Hi!
```

### Zig embedding examples (`examples/zig/`)

5 examples showing the library API: `basic`, `memory`, `inspect`, `host_functions`, `wasi`.

### C API examples (`examples/c/`)

C example using `libzwasm`: load a module, invoke an export, read the result.

### Python examples (`examples/python/`)

Python ctypes example: same workflow as C, no compiled bindings needed.

## Build

Requires Zig 0.15.2.

```bash
zig build              # Build (Debug)
zig build test         # Run all tests (521 tests)
./zig-out/bin/zwasm run file.wasm
```

### Feature flags

Strip features at compile time to reduce binary size:

| Flag | Description | Default |
|------|-------------|---------|
| `-Djit=false` | Disable JIT compiler | `true` |
| `-Dcomponent=false` | Disable Component Model | `true` |
| `-Dwat=false` | Disable WAT parser | `true` |
| `-Dsimd=false` | Disable SIMD opcodes | `true` |
| `-Dgc=false` | Disable GC proposal | `true` |
| `-Dthreads=false` | Disable threads/atomics | `true` |

Minimal build (~940 KB, −24%): `zig build -Doptimize=ReleaseSafe -Djit=false -Dcomponent=false -Dwat=false`

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
- [x] Stage 32: 100% spec conformance (62,263/62,263 on Mac + Ubuntu)
- [x] Stage 33: Fuzz testing (differential testing, extended fuzz campaign, 0 crashes)
- [x] Stages 35-41: Production hardening (crash safety, CI/CD, docs, API stability, distribution)
- [x] Stages 42-43: Community preparation, v1.0.0 release
- [x] Stages 44-47: WAT parser spec parity, SIMD perf analysis, book i18n, WAT roundtrip 100%
- [x] Reliability: Cross-platform verification (50 real-world programs), JIT correctness (OSR, back-edge, guard pages)
- [x] Phase 8: Real-world coverage (50 programs), WAT parity 100%, 5 JIT codegen fixes
- [ ] Future: SIMD JIT (NEON/SSE), Windows port, WASI P3/async

## Known Limitations

### SIMD Performance

SIMD (v128) operations are functionally complete (256 opcodes, 100% spec tests) but run on the
stack interpreter tier, not the register IR or JIT tiers. This results in ~22x slower SIMD
execution compared to wasmtime's Cranelift NEON/SSE backend.

**Root cause**: The register IR uses a `u64` register file that cannot hold 128-bit values.
SIMD functions fall back to the slower stack interpreter with per-instruction dispatch overhead.

**Planned fix**: Extend register IR with `v128` register support (Phase 1), then add selective
JIT NEON/SSE emission (Phase 2). See `.dev/roadmap.md` Phase 13 for the detailed plan.

Scalar (non-SIMD) performance is unaffected — 16/29 scalar benchmarks beat wasmtime.

## Versioning

zwasm follows [Semantic Versioning](https://semver.org/). The public API surface is defined in [docs/api-boundary.md](docs/api-boundary.md).

- **Stable** types and functions (WasmModule, WasmFn, etc.) won't break in minor/patch releases
- **Experimental** types (runtime.\*, WIT) may change in minor releases
- **Deprecation**: At least one minor version notice before removal

## Documentation

- [Book (English)](https://clojurewasm.github.io/zwasm/en/) — Getting started, architecture, embedding guide, CLI reference
- [Book (日本語)](https://clojurewasm.github.io/zwasm/ja/) — 日本語ドキュメント
- [API Boundary](docs/api-boundary.md) — Stable vs experimental API surface
- [CHANGELOG](CHANGELOG.md) — Version history

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, development workflow, and CI checks.

## License

MIT

## Support

Developed in spare time alongside a day job. If you'd like to support
continued development, sponsorship is welcome via
[GitHub Sponsors](https://github.com/sponsors/chaploud).
