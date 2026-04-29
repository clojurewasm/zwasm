# zwasm

[![CI](https://github.com/clojurewasm/zwasm/actions/workflows/ci.yml/badge.svg)](https://github.com/clojurewasm/zwasm/actions/workflows/ci.yml)
[![Spec Tests](https://img.shields.io/badge/spec_tests-62%2C263%2F62%2C263-brightgreen)](https://github.com/clojurewasm/zwasm)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/chaploud?logo=githubsponsors&logoColor=white&color=ea4aaa)](https://github.com/sponsors/chaploud)

A small, full-featured WebAssembly runtime written in Zig. Library and CLI.

Supported host targets:
- `aarch64-macos`
- `x86_64-linux`, `aarch64-linux`
- `x86_64-windows`

## At a glance

| Runtime  | Binary (stripped) | Memory (fib) | Execution                    | Wasm 3.0 |
|----------|------------------:|-------------:|------------------------------|:--------:|
| zwasm    | 1.20–1.56 MB      | ~3.5 MB      | Interp + ARM64/x86_64 JIT    |   Full   |
| wasmtime | ~56 MB            | ~12 MB       | Cranelift AOT/JIT            |   Full   |
| wasmer   | 30+ MB            | ~15 MB       | LLVM/Cranelift/Singlepass    | Partial  |
| wazero   | 8–12 MB           | ~6 MB        | Pure Go interp + Compiler    | Partial  |
| wasm3    | ~0.3 MB           | ~1 MB        | Pure interpreter             | Partial  |

zwasm sits in the niche between "tiny but limited" runtimes (wasm3, WAMR) and "full-featured but large" ones (wasmtime, wasmer): full Wasm 3.0 with JIT and SIMD in roughly the same byte budget as a pure interpreter.

zwasm was extracted from [ClojureWasm](https://github.com/clojurewasm/ClojureWasm) (a Zig reimplementation of Clojure) where keeping a Wasm subsystem inside the language runtime created a "runtime within runtime" layering problem. ClojureWasm remains the primary consumer.

## Features

- **Full Wasm 3.0**. Core MVP plus all 9 ratified 3.0 proposals (GC, exception handling, tail calls, function references, multi-memory, memory64, branch hinting, extended const, relaxed SIMD), plus threads (79 atomics) and wide arithmetic. 581+ opcodes total.
- **4-tier execution**. Bytecode → predecoded IR → register IR → ARM64/x86_64 JIT. Hot functions promote automatically (HOT_THRESHOLD=3).
- **SIMD JIT**. ARM64 NEON 253/256 native, x86_64 SSE 244/256 native. Contiguous v128 register storage with Q-cache (Q16–Q31 / XMM6–XMM15).
- **WASI Preview 1 + Component Model**. 46/46 P1 syscalls (100%); P2 via component-model adapter, WIT parser, Canonical ABI.
- **Spec conformance**. 62,263 / 62,263 spec tests on Mac aarch64, Linux x86_64, Windows x86_64 (CI). 796 / 796 E2E tests on all three. 50 / 50 real-world programs (Rust + C + C++ + Go + TinyGo) on Mac and Linux; Windows runs the C+C++ subset (25 / 25) until rustup / Go / TinyGo provisioning lands (tracked as W52).
- **WAT support**. Run `.wat` text files directly; build-optional via `-Dwat=false`.
- **Security**. Deny-by-default WASI capabilities, fuel metering, wall-clock timeout, memory ceiling, JIT W^X pages, signal-handled traps.
- **No libc**. CLI / library / tests link `link_libc = false` (Mac uses libSystem auto-link). C-API shared/static targets keep `link_libc = true` because `std.heap.c_allocator` is exposed.
- **Allocator-parameterized**. The library takes a `std.mem.Allocator` at load time; embedders own all allocation.

## Wasm spec coverage

| Spec layer | Proposals included                                                                                          | Status   |
|------------|-------------------------------------------------------------------------------------------------------------|----------|
| Wasm 1.0   | MVP (172 opcodes)                                                                                           | Complete |
| Wasm 2.0   | Sign extension, non-trapping float→int, bulk memory, reference types, multi-value, fixed-width SIMD (236)   | Complete |
| Wasm 3.0   | Memory64, exception handling, tail calls, extended const, branch hinting, multi-memory, relaxed SIMD (20), function references, GC (31) | Complete |
| Phase 3    | Wide arithmetic (4), custom page sizes                                                                      | Complete |
| Phase 4    | Threads (79 atomics)                                                                                        | Complete |
| Layer      | Component Model (WIT, Canon ABI, WASI P2 adapter)                                                           | Complete |

18 / 18 proposals complete. 399 unit tests, 796 / 796 E2E tests, 50 / 50 real-world programs (Rust, C, C++, TinyGo compiler outputs). Per-proposal opcode and test counts are in the [Spec Coverage](https://clojurewasm.github.io/zwasm/en/spec-coverage.html) chapter.

## Performance

Apple M4 Pro, ReleaseSafe, hyperfine 5 runs / 3 warmup; vs wasmtime 41.0.1 (Cranelift JIT), Bun 1.3.8, Node v24.13.0:

| Benchmark       | zwasm | wasmtime | Bun   | Node  |
|-----------------|------:|---------:|------:|------:|
| nqueens(8)      |  2 ms |     5 ms | 14 ms | 23 ms |
| nbody(1M)       | 22 ms |    22 ms | 32 ms | 36 ms |
| sieve(1M)       |  5 ms |     7 ms | 17 ms | 29 ms |
| tak(24,16,8)    |  5 ms |     9 ms | 17 ms | 29 ms |
| fib(35)         | 46 ms |    51 ms | 36 ms | 52 ms |
| st_fib2         | 900 ms |   674 ms | 353 ms | 389 ms |

Of 29 benchmarks, the majority match or beat wasmtime; a few compute-heavy long-running ones (e.g. `st_fib2`) still trail Cranelift AOT. Memory usage is roughly 3–4× lower than wasmtime and 8–10× lower than Bun/Node. Full data: `bench/runtime_comparison.yaml`.

SIMD microbenchmarks (ARM64 NEON / x86_64 SSE JIT):

| Benchmark              | zwasm scalar | zwasm SIMD | wasmtime SIMD |
|------------------------|-------------:|-----------:|--------------:|
| matrix_mul (16×16)     |        10 ms |       6 ms |          8 ms |
| image_blend (128×128)  |        73 ms |      16 ms |         12 ms |
| byte_search (64 KB)    |        52 ms |      43 ms |          5 ms |

Hand-written SIMD kernels (`matrix_mul`, `image_blend`) are competitive with wasmtime; `matrix_mul` is faster, `image_blend` is within 1.4×. Compiler-generated SIMD code (e.g. C `-msimd128` with heavy `i16x8.replace_lane`) still shows larger gaps; further work is tracked in `.dev/checklist.md`. Full data: `bench/simd_comparison.yaml`.

## Install

macOS / Linux:

```bash
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/zwasm ~/.local/bin/

# or one-liner:
curl -fsSL https://raw.githubusercontent.com/clojurewasm/zwasm/main/install.sh | bash
```

Windows (PowerShell):

```powershell
zig build -Doptimize=ReleaseSafe
Copy-Item zig-out\bin\zwasm.exe "$env:LOCALAPPDATA\Microsoft\WindowsApps\zwasm.exe"

irm https://raw.githubusercontent.com/clojurewasm/zwasm/main/install.ps1 | iex
```

## Usage

### CLI

```bash
zwasm module.wasm                       # Run a WASI module (run is implicit)
zwasm module.wat                        # Run a WAT text module directly
zwasm module.wasm -- arg1 arg2          # WASI args after `--`
zwasm module.wasm --invoke fib 35       # Call a specific exported function
zwasm run module.wasm --allow-all       # Explicit `run` subcommand
zwasm inspect module.wasm               # Show imports, exports, memory
zwasm validate module.wasm              # Validate without executing
zwasm compile module.wasm               # Pre-warm the IR cache to disk
zwasm features [--json]                 # List supported proposals
```

### Zig library

```zig
const zwasm = @import("zwasm");

var module = try zwasm.WasmModule.load(allocator, wasm_bytes);
defer module.deinit();

var args = [_]u64{35};
var results = [_]u64{0};
try module.invoke("fib", &args, &results);
// results[0] == 9227465
```

See [docs/usage.md](docs/usage.md) for fuel / timeout / memory limits, host functions, multi-module linking, and WASI configuration.

### C API

```bash
zig build lib    # libzwasm.{dylib,so,dll} + .a + include/zwasm.h
```

```c
#include "zwasm.h"

zwasm_module_t *mod = zwasm_module_new(wasm_bytes, len);
uint64_t results[1] = {0};
zwasm_module_invoke(mod, "f", NULL, 0, results, 1);
zwasm_module_delete(mod);
```

For execution limits use `zwasm_config_t`: `zwasm_config_set_fuel`, `zwasm_config_set_timeout`, `zwasm_config_set_max_memory`, `zwasm_config_set_force_interpreter`, `zwasm_config_set_cancellable`. Fuel applies to module startup (`_start`) as well as subsequent invocations.

Full reference: [C API chapter](https://clojurewasm.github.io/zwasm/en/c-api.html). Working examples in `examples/c/`, `examples/python/`, `examples/rust/` (same workflow from Python ctypes and Rust `extern "C"`).

## Examples

### `examples/wat/` — 33 numbered tutorial files

| # | Category | Examples |
|---|----------|----------|
| 01–09 | Basics | `hello_add`, `if_else`, `loop`, `factorial`, `fibonacci`, `select`, `collatz`, `stack_machine`, `counter` |
| 10–15 | Types | `i64_math`, `float_math`, `bitwise`, `type_convert`, `sign_extend`, `saturating_trunc` |
| 16–19 | Memory | `memory`, `data_string`, `grow_memory`, `bulk_memory` |
| 20–24 | Functions | `multi_return`, `multi_value`, `br_table`, `mutual_recursion`, `call_indirect` |
| 25–26 | Wasm 3.0 | `return_call` (tail calls), `extended_const` |
| 27–29 | Algorithms | `bubble_sort`, `is_prime`, `simd_add` |
| 30–33 | WASI | `wasi_hello`, `wasi_echo`, `wasi_args`, `wasi_write_file` |

```bash
zwasm examples/wat/01_hello_add.wat --invoke add 2 3   # → 5
zwasm examples/wat/05_fibonacci.wat --invoke fib 10    # → 55
zwasm examples/wat/30_wasi_hello.wat --allow-all       # → Hi!
```

Other languages: `examples/zig/` (5 embedding examples), `examples/c/`, `examples/python/`, `examples/rust/`.

## Build

Requires Zig 0.16.0.

```bash
zig build              # Debug build
zig build test         # Run all unit tests (399 tests)
zig build c-test       # Run C API tests
./zig-out/bin/zwasm run file.wasm
```

On Windows use `zig-out\bin\zwasm.exe`.

### Feature flags

Strip features at compile time:

| Flag                | Description             | Default |
|---------------------|-------------------------|---------|
| `-Djit=false`       | Disable JIT compiler    | `true`  |
| `-Dcomponent=false` | Disable Component Model | `true`  |
| `-Dwat=false`       | Disable WAT parser      | `true`  |
| `-Dsimd=false`      | Disable SIMD opcodes    | `true`  |
| `-Dgc=false`        | Disable GC proposal     | `true`  |
| `-Dthreads=false`   | Disable threads/atomics | `true`  |

Linux x86_64 ReleaseSafe stripped, measured on the current `main`:

| Variant         | Flags                                          |    Size |  Delta |
|-----------------|------------------------------------------------|--------:|-------:|
| Full (default)  | (none)                                         | 1.56 MB |     —  |
| No JIT          | `-Djit=false`                                  | 1.41 MB |   −10% |
| No WAT          | `-Dwat=false`                                  | 1.41 MB |   −10% |
| Minimal         | `-Djit=false -Dcomponent=false -Dwat=false`    | 1.26 MB |   −19% |

(`-Dcomponent=false` alone is currently neutral — the Component Model code path is already dead-code-eliminated when not exercised; combining it with `-Djit=false -Dwat=false` is what produces the 300 KB saving.)

Mac aarch64 stripped is roughly 350 KB smaller than the Linux numbers (1.20 MB full / 0.92 MB minimal). CI enforces a 1.60 MB ceiling on the stripped Linux binary.

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
             RegIR Interpreter           ARM64 / x86_64 JIT
             (default)                   (HOT_THRESHOLD=3)
```

Hot functions are detected via call counting and back-edge counting, then compiled to native code. Functions using opcodes outside the JIT's coverage continue to run in the register-IR interpreter. JIT pages use W^X protection — code is RW during emit, then switched to RX before execution; signal handlers translate guard-page faults back into Wasm traps.

## Project philosophy

**Small, full, fast — pick three.** zwasm tries to keep the byte budget of an interpreter while delivering the feature set of a tier-1 runtime. The primary metric is performance per byte of binary; secondary metrics are spec fidelity and startup latency.

**Spec fidelity over expedience.** Every change runs the 62,263-test spec suite, the 796 E2E assertions, and the 50 real-world program suite. We don't keep "known limitations".

**ARM64 + x86_64 first class.** Apple Silicon is the primary optimization target; x86_64 Linux and Windows are equally supported. Both backends ship the same SIMD coverage.

## Versioning

zwasm follows [Semantic Versioning](https://semver.org/). The public API surface is defined in [docs/api-boundary.md](docs/api-boundary.md).

- **Stable** types and functions (`WasmModule`, `WasmFn`, etc.) won't break in minor/patch releases
- **Experimental** types (`runtime.*`, WIT) may change in minor releases
- **Deprecation**: at least one minor version notice before removal

## Documentation

- [Book (English)](https://clojurewasm.github.io/zwasm/en/) — getting started, architecture, embedding, CLI reference
- [Book (日本語)](https://clojurewasm.github.io/zwasm/ja/)
- [API Boundary](docs/api-boundary.md) — stable vs experimental surface
- [CHANGELOG](CHANGELOG.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build, workflow, and CI checks.

## License

MIT.

## Support

Developed in spare time alongside a day job. Sponsorship via [GitHub Sponsors](https://github.com/sponsors/chaploud) is welcome and helps keep work going.
