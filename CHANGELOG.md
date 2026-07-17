# Changelog

All notable changes to zwasm are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning
will follow [SemVer](https://semver.org/) from the first tag.

zwasm v2 is a ground-up redesign of v1. **v1 ABI compatibility is out of
scope** — see [`docs/migration_v1_to_v2.md`](docs/migration_v1_to_v2.md).
SemVer compatibility guarantees start at the first stable `v2.0.0` tag.

## [Unreleased]

_No changes yet._

## [2.3.0] - 2026-07-17

Inventory sweep against the officially released **WASI 0.3.0**
(2026-06-11): the first slice of the official interface set, plus a
docs truth-sweep and Homebrew packaging.

### Added

- **Official WASI 0.3.0 clocks surface** — `wasi:clocks/system-clock`
  (0.3.0's renamed `wall-clock`; `instant{seconds: s64, nanoseconds:
  u32}`, pre-1970 instants representable with the floored split) and
  `get-resolution` on both clocks, served on the component host. The
  async `wait-until` / `wait-for` need scheduler-wired timer waitables
  and are tracked as debt (D-524).
- **Homebrew**: `brew install clojurewasm/tap/zwasm` (macOS arm64,
  Linux x86_64 / aarch64), packaging the release binaries.

### Changed

- **wasip3 fixture toolchain repinned** nightly-2026-06-14 →
  nightly-2026-06-24 (the newest nightly that can still `-Z build-std`
  wasm32-wasip3 — 2026-07-08/-16 hit an upstream std regression) and
  the conformance fixtures regenerated. Measured: the emitted imports
  are unchanged (wasi 0.2.6) because they come from the borrowed
  wasip2 wasi-libc, not the nightly's std bindings — the official-WIT
  fixture gap remains open as D-523.

### Fixed

- **`zwasm --help` engine wording**: the usage text claimed
  `interp (default)`; the real default (since 2.0.0) is `auto` — prefers
  the JIT with transparent interpreter fallback. The help now matches
  `docs/reference/cli.md` and the README, and also lists the `--cache` /
  `--cache-clear` flags shipped in 2.2.0.

### Documentation

- **WASI 0.3 documented**: README gains a WASI 0.3 row (Component-Model
  native-async core, opt-in `-Dwasi=p3`; official WASI 0.3.0 released
  2026-06-11 — `wasi:filesystem`/`wasi:sockets` data-plane and `wasi:http`
  pending), and the migration guide's "until it settles" framing is
  replaced accordingly.
- **GC build default corrected in the migration guide**: WasmGC is
  compiled in and executes by default (part of `-Dwasm=v3_0`); the guide
  previously described it as opt-in via `-Dgc`, which is inert (tracked
  as debt).
- **README gains an Install section** (Homebrew + prebuilt release
  binaries).

## [2.2.1] - 2026-07-16

Binary-size campaign (ADR-0204, PRs #144-#146), triggered by downstream
embedder measurement (cljw): the zwasm binary shrank ~21% (ReleaseSafe
arm64 CLI 5,282,584 → 4,173,736 B) with no API, behaviour, or JIT-output
change.

### Changed

- **JIT host-callback FP thunks share their bridge bodies** (D-522
  stage 1): the `f32`/`f64`-arg host-call thunks previously monomorphized
  the full marshalling body per (arg-kinds × result × slot) —
  ~300 B × 3,840 instantiations. The bodies now live in 60 shared
  `noinline` bridges; each per-slot thunk is a ~23 B tail-forwarder.
  `api.jit_host_bridge` code: 1,311 KB → 232 KB (−82%). Thunk C-ABI
  signatures, trap semantics, and the embedder-facing API are unchanged.

### Internal

- Binary-size baseline + per-stage rows recorded in
  `bench/results/size_history.yaml`; campaign record in ADR-0204
  (including the measured refutation of the "table-driven dispatch
  shrinks the emitter" hypothesis — D-521 discharged).

## [2.2.0] - 2026-07-09

AOT-full-fidelity campaign (ADR-0203, PRs #136-#142): `.cwasm` is now a
real deployment-grade artifact, and compilation is transparently cacheable.

### Added

- **Transparent compilation cache** (`zwasm run --cache[=DIR]`, D-508):
  modules are keyed by content hash and the `.cwasm` artifact of a previous
  run is reused — parse/validate/codegen skipped (measured 2.2x cold start
  on a 3 MB Go module). Deploy artifact stays `.wasm`; the cache lives in
  the platform user-cache dir under a versioned subdirectory. Any cache
  defect (corrupt entry, unserializable module, I/O failure) degrades to a
  miss or bypass — the cache can never make `run` fail. `--cache-clear`
  deletes this build's cache subdirectory.
- **`.cwasm` format v0.5**: embeds the original module bytes plus per-func
  frame/EH/oob metadata, so an artifact loads back into the FULL runtime.

### Changed

- **`zwasm run x.cwasm` now runs through the full runtime** — identical
  WASI, sandbox limits (`--fuel`/`--timeout`/`--max-memory`/
  `--max-table-elements`), `--invoke NAME=ARGS`, and start-function
  behaviour to running the source `.wasm` (cache-hit == cache-miss by
  construction). The former compute-only AOT mini-runtime is retired, and
  the `.cwasm` sandbox-flag refusal is gone.
- **Bounds-check-elided artifacts serialize** (guard-page hosts): `zwasm
  compile` output now carries the elision bit and re-registers trap
  entries at load; non-guarded hosts refuse the artifact loudly.
- `--engine interp` with a `.cwasm` input is now a loud exit-2 refusal
  (the artifact is precompiled JIT code); with `--cache` it bypasses the
  cache and runs the interpreter as asked.

### Fixed

- **JIT helper addresses are no longer baked into emitted code** (D-516):
  a `.cwasm` produced by one process crashed (or worse) in another under
  ASLR — all 36 helper call sites now route through position-independent
  runtime slots. A cross-process differential gate
  (`zig build test-aot-diff`, 63 fixtures) pins the fix.
- **`(start)` function now runs on the lenient JIT path** (Wasm §4.5.4) —
  a pre-existing `--engine jit` spec bug the campaign's differential
  harness caught.
- CI: the `ci-required` aggregator no longer reports green when its
  change-detection job fails.

## [2.1.0] - 2026-07-06

### Added

- **table64 compiles natively in the JIT** (D-475) — i64-indexed tables (the
  memory64 proposal's table extension) no longer fall back to the interpreter:
  the JIT table descriptors widened to u64 (`TableSlice.len`/`max`,
  `table_size`), and every table op (`table.get/set/size/grow/fill/copy/init`),
  `call_indirect`, and `return_call_indirect` now emits the index width
  declared by the table's type on both arm64 and x86_64, with wrap-safe
  64-bit bounds sums. i32 tables keep the byte-identical fast path.

### Fixed

- **table64 element segments under the JIT engine**: an active elem segment
  with an `i64.const` offset failed instantiation on the JIT path (masked by
  the interp fallback) — offsets now evaluate at u64 width, matching the
  interpreter.
- **Instantiate-time bounds hardening**: a guest-chosen 64-bit element offset
  can no longer wrap the table bounds check.
- **AOT**: a table64 whose minimum size exceeds the `.cwasm` u32 field is now
  rejected loudly instead of silently saturated.

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
  extended-const, relaxed-SIMD, custom annotations. Plus full Wasm 1.0 + 2.0 (multi-value,
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
