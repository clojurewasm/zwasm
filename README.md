# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

[![CI](https://github.com/clojurewasm/zwasm/actions/workflows/ci.yml/badge.svg)](https://github.com/clojurewasm/zwasm/actions/workflows/ci.yml)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/)
[![WebAssembly 3.0](https://img.shields.io/badge/WebAssembly-3.0-654ff0?logo=webassembly&logoColor=white)](https://webassembly.org/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/chaploud?logo=githubsponsors&logoColor=white&color=ea4aaa)](https://github.com/sponsors/chaploud)

> **Status: feature-complete and green on the 3-host gate**
> (Mac aarch64 + Linux x86_64 + Windows x86_64). Full WebAssembly 3.0 + WASI
> preview1 & preview2 (Component Model), interpreter + JIT (arm64 / x86_64) +
> AOT (`.cwasm`), and the C / Zig / CLI surfaces are settled. Completion is the
> line, not a release date; tagging and publishing are a
> deliberate, manual step. The v2 line is pre-release (currently tagged
> `v2.0.0-rc.1`).

v2 is a ground-up redesign of [zwasm v1](https://github.com/clojurewasm/zwasm)
with day-one design for WebAssembly 3.0, wasm-c-api conformance, and
dual-backend (interpreter + JIT-arm64 + JIT-x86) differential testing.
v1 ABI compatibility is out of scope — see the
[migration guide](docs/migration_v1_to_v2.md).

## Supported platforms

zwasm is built and tested on these host targets:

| Platform | Arch    | Notes                                           |
|----------|---------|-------------------------------------------------|
| macOS    | aarch64 | primary development target                      |
| Linux    | x86_64  | native, spec + full test gate                   |
| Linux    | aarch64 | cross-built (not in the per-release test gate)  |
| Windows  | x86_64  | native, MSVC ABI                                |

Each release is verified on native macOS-aarch64, Linux-x86_64, and
Windows-x86_64 hosts. Linux-aarch64 is cross-built but not covered by that
per-release test gate. Windows ARM64 and other targets are out of scope for
now (demand-driven).

## Coverage

### Wasm versions

| Spec                                                                                                            | Status  | Notes                                                    |
|-----------------------------------------------------------------------------------------------------------------|---------|----------------------------------------------------------|
| Wasm 1.0                                                                                                        | ✅ 100% | spec testsuite green on the 3-host gate                  |
| Wasm 2.0 (multi-value, SIMD-128, bulk-memory, reference-types, non-trapping FP→int, sign-ext, mutable globals) | ✅ 100% | `skip-impl == 0`; bit-identical across hosts             |
| Wasm 3.0 (GC, EH, tail-call, memory64, multi-memory, typed func refs, extended-const, relaxed-simd)             | ✅ 100% | all 9 proposals; spec testsuite green on the 3-host gate |

### WASI

| Spec                                 | Status                    | Notes                                                                                                                                                                                                                                                                                                                                                         |
|--------------------------------------|---------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| WASI 0.1 (preview1)                  | ✅ functional             | interpreter: args / env / preopened dirs / clock / random / fd I/O                                                                                                                                                                                                                                                                                            |
| WASI 0.2 (preview2, Component Model) | ✅ functional, default-ON | wasmtime-equivalent campaign complete (2026-06-13): real `wasm32-wasip2` Rust/TinyGo components run e2e (fs, sockets incl. TCP listeners, guest-defined resources); typed embedder API (introspection + `invokeTyped`); validation rules 1-12, official corpus 158/0/0; gated by `-Dwasi>=p2` (default), `-Dwasi=p1` = lean opt-out |

All three execution paths do full WASI I/O — the interpreter, the JIT
(`--engine jit`), and AOT (`.cwasm`). The JIT additionally
executes SIMD-128 (the interpreter does not).

### Execution backends

| Backend                              | Status        |
|--------------------------------------|---------------|
| Interpreter (full WASI)              | ✅ functional |
| JIT — ARM64 (AAPCS64)               | ✅ functional |
| JIT — x86_64 SysV (Linux/macOS)     | ✅ functional |
| JIT — x86_64 Win64 (MSVC ABI)       | ✅ functional |
| AOT — `.cwasm` compile + load + run | ✅ functional |

The GC-on-JIT path is memory-safe: a conservative native-stack-scan
collector roots live references across collections, verified by an
adversarial use-after-free test on aarch64 + x86_64.

## CLI

```sh
zwasm                                  # print version + build options
zwasm run <file.wasm|.cwasm> [args...] # run a module (WASI _start / main)
    [--invoke <name>[=a,b,…]]          #   run a named export; =args prints typed results
    [--engine <interp|jit>]            #   default: auto (prefers JIT, interp fallback); interp|jit force one (both full WASI; jit adds SIMD)
    [--dir <host>[:<guest>]]           #   preopen a host directory for WASI
    [--env <KEY=VAL>]                  #   set a WASI env var (repeatable)
    [--fuel <N>]                       #   trap after a deterministic budget (error.OutOfFuel)
    [--timeout <ms>]                   #   interrupt after a wall-clock deadline
    [--max-memory <bytes>]             #   refuse memory.grow past this many bytes
    [--max-table-elements <N>]         #   refuse table growth past this many elements
zwasm compile <file.wasm> -o <out.cwasm>  # compile to a .cwasm AOT artifact
zwasm --version | -V                   # version + build identity (wasm/wasi/engine)
zwasm --help | -h | help
```

The CLI is deliberately `run` + `compile` — the
wasmtime/wazero-aligned shape for a runtime. Validation is programmatic
(C-API `wasm_module_validate` / Zig `Engine.compile`); wat↔wasm
conversion and module introspection are `wasm-tools` / `wabt`'s job.
Full flag table + exit codes: [`docs/reference/cli.md`](docs/reference/cli.md).

Runtime env vars: `ZWASM_DEBUG=<categories>` (dbg category filter),
`ZWASM_DIAG=<channels>` (diagnostic trace ringbuffer drain).

## Embedding

zwasm is a library first, with two host surfaces.

**Zig** (native facade) — add zwasm as a `build.zig.zon`
dependency, pull its module (`b.dependency("zwasm", .{}).module("zwasm")`),
then:

```zig
const zwasm = @import("zwasm");

var eng = try zwasm.Engine.init(alloc, .{});
defer eng.deinit();
var mod = try eng.compile(&wasm_bytes);
defer mod.deinit();
var inst = try mod.instantiate(.{});
defer inst.deinit();

const add = inst.typedFunc(fn (i32, i32) i32, "add");
const r = try add.call(.{ 2, 40 }); // 42
```

Surface: `Engine` / `Module` / `Instance` / `Linker` (host imports via
`defineFunc` + `Caller`) / `Memory` / `Global` / `Table` / `TypedFunc` /
`Trap` / `Value`. Runnable: [`docs/examples/zig_dep/`](docs/examples/zig_dep/)
(external path-dep consumer) and [`docs/examples/zig_host/`](docs/examples/zig_host/).

**Sandboxing untrusted guests** (both engines): `mod.instantiate(.{})`
is **bounded by default** — `InstantiateOpts.fuel` and `.max_memory_pages` carry
finite defaults (a deterministic instruction budget → `error.OutOfFuel`, and a
linear-memory cap), so a forgotten budget still yields a metered instance; set an
axis to `.unmetered` (e.g. `.{ .fuel = .unmetered }`) for trusted code. `Instance.interrupt()` stops a runaway guest from
another thread (timeout or cancellation → `error.Interrupted`);
`setFuel`/`setMemoryPagesLimit`/`setTableElementsLimit` adjust the budgets on a
live instance. The **JIT engine carries the same triad**: polls at
function entry + every loop back-edge deliver interruption and fuel (units there
= entries + loop iterations), and `memory.grow` honours the host cap. From C,
use the `zwasm_instance_*` setters in [`include/zwasm.h`](include/zwasm.h);
from the CLI, `--fuel` / `--timeout` / `--max-memory` (both engines).

**C** (wasm-c-api) — [`include/wasm.h`](include/wasm.h) is byte-identical
to the upstream standard (the interface wasmtime/wasmer follow); WASI
host-setup is the hand-authored [`include/wasi.h`](include/wasi.h). See
[`docs/examples/c_host/`](docs/examples/c_host/) and
[`docs/reference/c_api.md`](docs/reference/c_api.md).

**Any FFI language** — [`docs/examples/rust_host/`](docs/examples/rust_host/)
(`zig build run-rust-host`) declares the same `wasm.h` ABI from Rust and
links `libzwasm`, demonstrating the C surface is consumable from any
FFI-capable language, not just C.

## Build flags

```
-Dwasm=v3_0|v2_0|v1_0       # default v3_0; lower levels omit later proposals
-Dwasi=none|p1|p2|p3        # default p2; ordered tier. p2 = Component Model / WASI-P2 host,
                            #   p3 = + Preview-3 async. -Dwasi=p1 = lean build (~-8%)
-Dengine=both|jit|interp    # default both
-Dstrip=true|false          # default false
```

## Quick start

```sh
zig build              # compile the zwasm binary
zig build test         # unit tests
zig build test-all     # all enabled test layers

# Cross-compile sanity check (catches, e.g., Win64 compile errors in ~3s)
zig build -Dtarget=x86_64-windows-gnu
```

Run `zig build test-all` on each platform you care about — macOS, Linux,
and Windows are all first-class. Multi-OS verification is handled
automatically by CI; the `scripts/run_remote_*.sh` helpers are a
maintainer convenience for driving the gate across a personal host farm
over SSH (host aliases are configurable via `ZWASM_UBUNTU_HOST` /
`ZWASM_WINDOWS_HOST`).

Nix + direnv is the supported dev environment. `direnv allow` loads
the pinned Zig 0.16.0 and tool surface (`flake.nix`: hyperfine,
wasm-tools, wasmtime, yq-go, lldb, nasm).

## Layout

```
src/         Zig sources (parse/ validate/ ir/ runtime/ instruction/ feature/
             engine/ interp/ wasi/ api/ cli/ diagnostic/ support/ platform/)
include/     Public C headers (wasm.h / wasi.h / zwasm.h)
build.zig    Build script
flake.nix    Nix dev shell pinned to Zig 0.16.0
docs/        Migration guide + design docs
.dev/        ROADMAP + handover + ADRs + lessons + setup notes
.claude/     Claude Code settings, skills, rules (auto-loaded)
scripts/     gate_commit, zone_check, file_size_check, bench, run_remote_*
test/        per-layer suites; unified `zig build test-all`
bench/       benchmark history (append-only)
private/     gitignored agent scratch
```

## Documentation

- [`docs/tutorial.md`](docs/tutorial.md) — getting started (build, run, embed)
- [`docs/reference/`](docs/reference/) — API reference:
  [Zig](docs/reference/zig_api.md) · [C](docs/reference/c_api.md) · [CLI](docs/reference/cli.md)
- [`docs/benchmarks.md`](docs/benchmarks.md) — performance vs other runtimes + across engines
- [`docs/migration_v1_to_v2.md`](docs/migration_v1_to_v2.md) — v1 → v2 migration + the honest v1-vs-v2 gap analysis
- [`docs/handoff_cw_v2_zig_api.md`](docs/handoff_cw_v2_zig_api.md) — current-state Zig embedding API (ClojureWasm handoff)
- [`docs/v1_contributor_history.md`](docs/v1_contributor_history.md) — v1 community contributors + their PRs/issues
- [`CHANGELOG.md`](CHANGELOG.md) — release notes

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — mission, principles, phase plan
- [`.dev/decisions/`](.dev/decisions/) — ADRs (deviations from ROADMAP)

## License

Copyright 2026 zwasm Contributors. Licensed under Apache-2.0 — see `LICENSE`.

---

Developed in spare time alongside a day job. Sponsorship via [GitHub Sponsors](https://github.com/sponsors/chaploud) is welcome and helps keep work going.
