# Changelog

All notable changes to zwasm are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
will follow [SemVer](https://semver.org/) from the first tag.

zwasm v2 is a ground-up redesign of v1. **v1 ABI compatibility is out of
scope** — see [`docs/migration_v1_to_v2.md`](docs/migration_v1_to_v2.md).
SemVer compatibility guarantees start at the first `v0.1.0` tag.

## [Unreleased]

The v2 redesign is feature-complete (Phase 16 — 完成形) and verified on the
3-host gate (Mac aarch64 + Linux x86_64 + Windows x86_64); a `v0.1.0` tag
has not yet been cut.

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
  use-after-free test on aarch64 + x86_64 (ADR-0160).
- **WASI preview1** — args, environment, preopened directories, clock,
  random, fd I/O (under the interpreter).
- **C API** — `include/wasm.h` byte-identical to the upstream wasm-c-api
  standard (the interface wasmtime/wasmer follow), with full coverage of
  the standard surface, plus `wasi.h` + `zwasm.h` extensions.
- **Zig embedding API** (ADR-0109) — native `Engine` / `Module` /
  `Instance` / `Linker` / `Caller` / `Memory` / `Global` / `Table` /
  `TypedFunc` / `Trap` / `Value` facade, consumable as an external
  `build.zig.zon` dependency.
- **CLI** — `zwasm run` (WASI exec, `--invoke` / `--engine` / `--dir` /
  `--env`) and `zwasm compile` (`.cwasm` AOT), plus `--version` /
  `--help` (ADR-0159).
- **Sandboxing (ADR-0179)** — cooperative interruption (cancel/timeout),
  deterministic fuel metering, and a host memory-growth cap, on BOTH
  engines (the JIT polls at function entry + every loop back-edge):
  Zig facade setters, C `zwasm_instance_*` setters + `zwasm_trap_kind`
  (`zwasm.h`), and CLI `--fuel` / `--timeout` / `--max-memory`.

### Changed (from v1)

- Breaking redesign of the C / Zig / CLI surfaces to the あるべき論,
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
