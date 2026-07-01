# Changelog

All notable changes to zwasm are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
will follow [SemVer](https://semver.org/) from the first tag.

zwasm v2 is a ground-up redesign of v1. **v1 ABI compatibility is out of
scope** — see [`docs/migration_v1_to_v2.md`](docs/migration_v1_to_v2.md).
SemVer compatibility guarantees start at the first stable `v2.0.0` tag.

## [Unreleased]

_No changes yet._

## [2.0.0] - 2026-07-01

First **stable** release. Carries the complete feature set of `v2.0.0-rc.1`
(below), promoted to stable after the final hardening pass.

### Added

- **JIT `table.grow` for no-max tables** — a table declared without an upper
  bound now grows under the JIT up to a synthesized cap (`max(min*2, 1024)`,
  matching WAMR), where it previously returned the spec `-1` (D-501).

### Fixed

- **Docs / reference / examples** corrected to the code truth: the default
  engine is `.auto` (JIT-preferring, interp fallback); `include/zwasm.h` carries
  the sandboxing + engine-selection + `zwasm_instance_get_func` surface;
  `Linker.instantiate` takes `(module, opts)`; the build flag is `-Dwasm=v3_0`.
  The `docs/examples/zig_dep` external consumer builds and runs again.
- **Repo layout** decluttered: `CLAUDE.md` → `.claude/`, `THIRD_PARTY.md` →
  `legal/`, `examples/` → `docs/examples/`, community-health files → `.github/`.
- **Test harness**: guest std streams no longer leak to the real process fd 1/2
  in test builds (removed a phantom `failed command: … --listen=-` that appeared
  even when every test passed).

## [2.0.0-rc.1] - 2026-07-01

The first tagged **release candidate** for `v2.0.0`. The v2 redesign is
feature-complete and verified on the 3-host gate (Mac aarch64 + Linux x86_64 +
Windows x86_64). Earlier pre-releases were tagged `v2.0.0-alpha.*`.

### Added

- **WebAssembly 3.0** — all 9 proposals: GC, exception handling, tail
  calls, memory64, multi-memory, typed function references,
  extended-const, relaxed-SIMD. Plus full Wasm 1.0 + 2.0 (multi-value,
  SIMD-128, bulk-memory, reference-types, non-trapping FP→int conversion,
  sign-extension, mutable globals). Spec testsuite green, `skip-impl == 0`.
- **Execution backends** — interpreter (full WASI), JIT for ARM64
  (AAPCS64) + x86_64 SysV + x86_64 Win64 (MSVC ABI), and AOT (`.cwasm`
  compile + load + run). `interp == jit` differential testing.
- **Memory-safe GC-on-JIT** — a conservative native-stack-scan collector
  roots live references across collections; verified by an adversarial
  use-after-free test on aarch64 + x86_64.
- **WASI preview1** — args, environment, preopened directories, clock,
  random, fd I/O (under the interpreter).
- **C API** — `include/wasm.h` byte-identical to the upstream wasm-c-api
  standard (the interface wasmtime/wasmer follow), with full coverage of
  the standard surface, plus `wasi.h` + `zwasm.h` extensions.
- **Zig embedding API** — native `Engine` / `Module` /
  `Instance` / `Linker` / `Caller` / `Memory` / `Global` / `Table` /
  `TypedFunc` / `Trap` / `Value` facade, consumable as an external
  `build.zig.zon` dependency.
- **CLI** — `zwasm run` (WASI exec, `--invoke` / `--engine` / `--dir` /
  `--env`) and `zwasm compile` (`.cwasm` AOT), plus `--version` /
  `--help`.
- **Sandboxing** — cooperative interruption (cancel/timeout),
  deterministic fuel metering, and a host memory-growth cap, on BOTH
  engines (the JIT polls at function entry + every loop back-edge):
  Zig facade setters, C `zwasm_instance_*` setters + `zwasm_trap_kind`
  (`zwasm.h`), and CLI `--fuel` / `--timeout` / `--max-memory`.

### Changed (from v1)

- Breaking redesign of the C / Zig / CLI surfaces to the first-principles,
  industry-standard shape (not v1 parity). The CLI drops v1's
  `validate` / `inspect` / `features` / `wat` / `wasm` subcommands and
  capability-flag sprawl — validation is programmatic; conversion and
  introspection delegate to `wasm-tools` / `wabt`.

### Known limitations

- WASI 0.1 (preview1) `sock_*` calls have no host socket layer (they
  validate the fd and return `notsock`; preview1 has no socket-open).
  Real socket support — including TCP listeners — is available via
  WASI 0.2 (`wasi:sockets/tcp`), which is default-ON (Component Model
  functional, not deferred).
- Table funcref slots surface as opaque handles (not yet directly
  callable from the host).
