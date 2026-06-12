# zwasm v2

A from-scratch WebAssembly runtime in Zig 0.16.0.

> **Status: feature-complete (Phase 16 — 完成形), not yet tagged.** Full
> WebAssembly 3.0 + WASI preview1, interpreter + JIT (arm64 / x86_64) +
> AOT (`.cwasm`), and the C / Zig / CLI surfaces are settled and green on
> the 3-host gate (Mac aarch64 + Linux x86_64 + Windows x86_64). A
> `v0.1.0` tag is a deliberate, manual step and has not been cut.

v2 is a ground-up redesign of [zwasm v1](https://github.com/clojurewasm/zwasm)
with day-one design for WebAssembly 3.0, wasm-c-api conformance, and
dual-backend (interpreter + JIT-arm64 + JIT-x86) differential testing.
v1 ABI compatibility is out of scope — see the
[migration guide](docs/migration_v1_to_v2.md).

## Supported platforms (verified hosts)

| Role         | Machine                 | OS                                          | Arch    | CPU                     | RAM   |
|--------------|-------------------------|---------------------------------------------|---------|-------------------------|-------|
| Development  | MacBook Pro (Mac16,8)   | macOS                                       | aarch64 | Apple M4 Pro            | 48 GB |
| Linux gate   | `ubuntunote` (mini PC)  | Ubuntu (Determinate Nix + flake-pinned Zig) | x86_64  | Intel i7-1195G7 (4C/8T) | 32 GB |
| Windows gate | `windowsmini` (mini PC) | Windows 11 Pro (native, MSVC ABI)           | x86_64  | Intel N100 (4C/4T)      | 16 GB |

These are the only machines on which CI/dev runs are verified. Windows
ARM64, Linux aarch64, and 2nd-Windows-machine cross-validation are
out of scope for v0.1.0.

## Coverage

### Wasm versions

| Spec                                                                                                            | Status  | Notes                                                    |
|-----------------------------------------------------------------------------------------------------------------|---------|----------------------------------------------------------|
| Wasm 1.0                                                                                                        | ✅ 100% | spec testsuite green on the 3-host gate                  |
| Wasm 2.0 (multi-value, SIMD-128, bulk-memory, reference-types, non-trapping FP→int, sign-ext, mutable globals) | ✅ 100% | `skip-impl == 0`; bit-identical across hosts             |
| Wasm 3.0 (GC, EH, tail-call, memory64, multi-memory, typed func refs, extended-const, relaxed-simd)             | ✅ 100% | all 9 proposals; spec testsuite green on the 3-host gate |

### WASI

| Spec                                 | Status                               | Notes                                                                                                                                                                     |
|--------------------------------------|--------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| WASI 0.1 (preview1)                  | ✅ functional                        | interpreter: args / env / preopened dirs / clock / random / fd I/O                                                                                                        |
| WASI 0.2 (preview2, Component Model) | 🚧 functional, opt-in (`-Dcomponent`) | a real `wasm32-wasip2` component runs e2e; structural validation rules 1-4; embedding API not yet frozen + deeper conformance parked (see `.dev/component_model_plan.md`) |

All three execution paths do full WASI I/O — the interpreter, the JIT
(`--engine jit`, D-244), and AOT (`.cwasm`, D-251). The JIT additionally
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
adversarial use-after-free test on aarch64 + x86_64 (ADR-0160).

## CLI

```sh
zwasm                                  # print version + build options
zwasm run <file.wasm|.cwasm> [args...] # run a module (WASI _start / main)
    [--invoke <name>[=a,b,…]]          #   run a named export; =args prints typed results
    [--engine <interp|jit>]            #   interp (default) or jit (both full WASI; jit adds SIMD)
    [--dir <host>[:<guest>]]           #   preopen a host directory for WASI
zwasm compile <file.wasm> -o <out.cwasm>  # compile to a .cwasm AOT artifact
zwasm --version | -V
zwasm --help | -h | help
```

The CLI is deliberately `run` + `compile` (ADR-0159) — the
wasmtime/wazero-aligned shape for a runtime. Validation is programmatic
(C-API `wasm_module_validate` / Zig `Engine.compile`); wat↔wasm
conversion and module introspection are `wasm-tools` / `wabt`'s job.

Runtime env vars: `ZWASM_DEBUG=<categories>` (dbg category filter),
`ZWASM_DIAG=<channels>` (diagnostic trace ringbuffer drain).

## Embedding

zwasm is a library first, with two host surfaces.

**Zig** (native facade, ADR-0109) — add zwasm as a `build.zig.zon`
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
`Trap` / `Value`. Runnable: [`examples/zig_dep/`](examples/zig_dep/)
(external path-dep consumer) and [`examples/zig_host/`](examples/zig_host/).

**Sandboxing untrusted guests** (interpreter engine): `mod.instantiate(.{})`
is **bounded by default** — `InstantiateOpts.fuel` and `.max_memory_pages` carry
finite defaults (a deterministic instruction budget → `error.OutOfFuel`, and a
linear-memory cap), so a forgotten budget still yields a metered instance; pass
`.unmetered` for trusted code. `Instance.interrupt()` stops a runaway guest from
another thread (timeout or cancellation → `error.Interrupted`);
`setFuel`/`setMemoryPagesLimit`/`setTableElementsLimit` adjust the budgets on a
live instance. The **JIT engine carries the same triad** (ADR-0179): polls at
function entry + every loop back-edge deliver interruption and fuel (units there
= entries + loop iterations), and `memory.grow` honours the host cap. From C,
use the `zwasm_instance_*` setters in [`include/zwasm.h`](include/zwasm.h);
from the CLI, `--fuel` / `--timeout` / `--max-memory` (both engines).

**C** (wasm-c-api) — [`include/wasm.h`](include/wasm.h) is byte-identical
to the upstream standard (the interface wasmtime/wasmer follow); WASI
host-setup is the hand-authored [`include/wasi.h`](include/wasi.h). See
[`examples/c_host/`](examples/c_host/) and
[`docs/reference/c_api.md`](docs/reference/c_api.md).

## Build flags

```
-Dwasm=3.0|2.0|1.0          # default 3.0; lower levels omit later proposals
-Dwasi=p1|p2|both|none      # default p1 (v0.1.0)
-Dengine=both|jit|interp    # default both
-Dcomponent=true|false      # default false; opt-in Component Model + WASI-P2 (functional, API not yet frozen; ADR-0170)
-Dstrip=true|false          # default false
```

## Quick start

```sh
# Mac native
zig build              # compile zwasm binary
zig build test         # unit tests
zig build test-all     # all enabled layers

# Cross-compile sanity check from Mac (catches Win64 compile errors in ~3s)
zig build -Dtarget=x86_64-windows-gnu

# Linux x86_64 via SSH (see .dev/ubuntunote_setup.md)
bash scripts/run_remote_ubuntu.sh test-all

# Windows x86_64 via SSH (see .dev/windows_ssh_setup.md;
# tools provisioned by scripts/windows/install_tools.ps1)
bash scripts/run_remote_windows.sh test-all
```

Nix + direnv is the supported dev environment. `direnv allow` loads
the pinned Zig 0.16.0 and tool surface (`flake.nix`: hyperfine,
wasm-tools, wasmtime, wabt, yq-go, lldb, nasm).

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
- [`docs/v1_contributor_history.md`](docs/v1_contributor_history.md) — v1 community contributors + their PRs/issues
- [`CHANGELOG.md`](CHANGELOG.md) — release notes

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — mission, principles, phase plan
- [`.dev/decisions/`](.dev/decisions/) — ADRs (deviations from ROADMAP)

## License

Copyright 2026 zwasm Contributors. Licensed under Apache-2.0 — see `LICENSE`.
