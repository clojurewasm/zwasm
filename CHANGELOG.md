# Changelog

All notable changes to zwasm are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

Developer / CI infrastructure improvements. **No public API or runtime
behaviour change for embedders.**

### Added
- `.github/versions.lock` (mirrors `flake.nix` pins for Windows + CI
  YAML) replaces the old `.github/tool-versions`. Single source of
  truth for Zig, wasm-tools, wasmtime, WASI SDK, Rust pins; comments
  must live on their own line per file header (the Python reader in
  `ci.yml` does a plain `split('=', 1)`). (#60, D136)
- `.dev/environment.md` — developer onboarding doc covering Mac /
  Linux / Windows native setup, Nix devshell contents, CI ↔ local
  gate mapping, and the remaining Windows-skipped CI items as a
  Plan C tracker. (#60)
- `scripts/lib/versions.sh`, `scripts/sync-versions.sh`,
  `scripts/gate-commit.sh`, `scripts/gate-merge.sh`, `scripts/run-bench.sh`
  — unified Commit Gate / Merge Gate runners that work identically on
  macOS, Linux (Nix devshell), and Windows (Git Bash). `gate-commit.sh`
  auto-clones wasmtime `tests/misc_testsuite` into a gitignored
  `.cache/` directory and chains `build_all.py && run_compat.py` for
  realworld so a fresh checkout works without manual setup. Auto-skips
  `ffi` on Windows to mirror the existing CI guard. (#61)
- `scripts/windows/install-tools.ps1` — provisions Zig + wasm-tools +
  wasmtime + WASI SDK from `versions.lock` into
  `%LOCALAPPDATA%\zwasm-tools`. Updates user PATH + `WASI_SDK_PATH`.
  Auto-installs Microsoft Visual C++ Redistributable via winget when
  `vcruntime140.dll` is missing (WASI SDK clang.exe needs it).
  Idempotent; `--Force` re-extracts; `-OnlyTool` selects one. (#61)
- `versions-lock-sync` CI job mechanises Merge Gate item #9 — fails
  the PR if `flake.nix` and `versions.lock` disagree on a tool pin.
  Runs in parallel with the existing test matrix in well under a
  second. (#62)
- Memory usage check on Windows via PowerShell `Process.PeakWorkingSet64`
  — first of the eight Windows-skip CI guards removed. Same 4.5 MB
  budget as the POSIX path. (#64)
- `zig build shared-lib` now runs on Windows in CI. Zig produces
  `zwasm.dll` + `zwasm.lib` natively from
  `addLibrary({.linkage = .dynamic})` — the old guard was a no-op.
  Plan C-a.
- `zig build static-lib -Dpic=true -Dcompiler-rt=true` and
  `test/c_api/run_static_link_test.sh` now run on Windows in CI.
  The C link tests use `zig cc` (portable across Mac/Linux/Windows)
  instead of system `cc`. PIE coverage is preserved on Linux. Plan C-d.
- `examples/rust` `cargo run` now runs on Windows in CI. `build.rs`
  gained a Windows arm: dynamic linking copies `zwasm.dll` next to
  the cargo target binary so the OS finds it via the executable
  directory at runtime (PE has no `-Wl,-rpath`); static linking uses
  `zwasm.lib` and skips the POSIX-only `-lc` / `-lm`. Plan C-c.
- `-Dstrip=true` build option in `build.zig` strips the CLI binary at
  link time via LLD. Used by the Binary size check and the size-matrix
  CI jobs so they no longer depend on a host `strip` tool — portable
  across ELF / Mach-O / PE. The Binary size check now runs on
  `windows-latest` (with a 1.80 MB ceiling reflecting PE overhead;
  Mac 1.30 MB, Linux 1.60 MB unchanged) and `size-matrix` is a 3-OS
  matrix (Ubuntu / macOS / Windows). Plan C-e + C-f.
- `test/c_api/test_ffi.c` ported to Windows: dynamic loading via
  `LoadLibraryA` + `GetProcAddress`, threading via `CreateThread` +
  `WaitForSingleObject`, pipes via `_pipe` (binary mode). Sources are
  selected by `#ifdef _WIN32` blocks; POSIX path unchanged. The
  runner switches from system `gcc` to `zig cc` so it does not
  require a host C compiler. The `if: runner.os != 'Windows'` CI
  guard on `Run FFI tests` is dropped accordingly. `gate-commit.sh`
  no longer auto-skips `ffi` on Windows. Plan C-b.

### Changed
- WASI SDK version bumped 25 → 30 to align CI with `flake.nix` (which
  was already at 30). Realworld 50/50 PASS verified locally on
  macOS aarch64 with the new SDK. (#60)
- `CLAUDE.md` Commit Gate / Merge Gate sections point at
  `bash scripts/gate-commit.sh` / `gate-merge.sh` as the one-liner
  entry points; example commands switched to the `.py` runners that
  CI exercises. (#61)
- `.github/workflows/ci.yml` benchmark job sources `HYPERFINE_VERSION`
  from `versions.lock` instead of hardcoding the version twice. (#65)

### Internal
- D136 (in `decisions.md`): Nix-as-SSoT design recorded with the
  Plan B / Plan C scope (unified gate scripts, Nix-based CI,
  Windows native installer, removal of the remaining Windows-skipped
  CI steps).

## [1.11.0] - 2026-04-26

W46 + W48: re-disable `link_libc` on the core build and trim the release
binary back under the original 1.60 MB ceiling. No public API changes;
embedders upgrading from 1.10.0 should see a smaller binary and identical
behaviour.

### Changed
- **Binary size ceiling**: pulled back from the Zig 0.16 transition value
  1.80 MB to 1.60 MB. Stripped Mac aarch64 binary is ~1.18 MB; Linux ELF
  is ~1.56 MB stripped. The original 1.50 MB target remains tracked as
  W48 Phase 2 (non-blocking).

### Fixed
- `WasmModule.loadCore` now frees `export_fns` and `cached_fns` (and the
  inner `param_types` / `result_types` slices) on the failure path when
  the Wasm `start` function traps. The earlier `errdefer` chain unwound
  vm/instance/wasi_ctx/module/store/self but skipped the export caches,
  leaking the slices for any module with a non-empty export and a
  trapping start function. The fix mirrors `deinit` so the failure path
  is symmetric with normal teardown. (Issue #42)
- OOM test in `loadLinked` now heap-allocates the `FailingAllocator` so
  its address remains stable while the partially-loaded module is held;
  the prior stack-allocated form was use-after-free under the test's
  search loop. (PR #56 by @jtakakura)

### Internal
- **W46 Phase 1+2** (`link_libc=false` restoration): `build.zig` core
  modules flipped to `.link_libc = false` while C API targets
  (shared-lib, static-lib, c-test) keep `link_libc=true`. WASI
  path-based ops, `cErrnoToWasi`, `trace.zig` stderr writes, and
  `platform.appCacheDir` all routed through `platform.pfd*` helpers so
  the core no longer pulls in libc on either OS. Linux direct syscalls
  used where stdlib bindings are missing in 0.16 (`std.os.linux.statx`,
  etc.).
- **W48 Phase 1**: release binary trimmed via panic handler tightening,
  segfault handler disabled in ReleaseSafe, and `main` return type
  narrowed to `u8`. Combined effect restores the ceiling back below the
  original 1.60 MB target.
- Test-site `std.c.{pipe,dup,dup2,read,nanosleep}` calls gated for Linux
  where the bindings are empty (W46 Phase 1c).
- Credit @notxorand for the initial Zig 0.16.0 migration draft (PR #41,
  superseded by the v1.10.0 work).

## [1.10.0] - 2026-04-24

Toolchain bump from Zig 0.15.2 → **Zig 0.16.0** ("I/O as an Interface"). No
public API removals or signature changes; downstream source stays compatible
but consumers must upgrade to Zig 0.16.0 to build.

### Changed
- **Zig toolchain: 0.15.2 → 0.16.0.** Flake pins and all CI workflows
  updated.
- `WasmModule.Config` gained `io: ?std.Io = null` and `Vm` gained `io:
  std.Io` — when `Config.io` is null, `loadCore`/`loadLinked` stand up a
  private `std.Io.Threaded` owned by the module (see D135). Existing
  embedders pass nothing and get the default behaviour.
- LEB128 decoding pinned to the pre-0.16 stdlib algorithm. 0.16's
  `std.Io.Reader.takeLeb128` does not enforce WASM's "integer too large"
  overshoot rule; the zwasm decoder was rewritten inline (40 lines) with
  the 0.15 `@shlWithOverflow`-based algorithm so spec test
  `binary-leb128.77/78` continue to reject malformed 10-byte i64
  encodings.

### Fixed
- **Cross-platform fstat**: on Linux, `std.c.fstat` / `std.c.fstatat` /
  `std.c.Stat` are all unavailable (empty bindings) and `std.posix.Stat` is
  `void`. `path_filestat_get` now dispatches to `std.os.linux.statx` on
  Linux (decoded to a neutral `FileStat`) and `std.c.fstatat` on Darwin.
  Test helpers that only needed the file size moved to
  `lseek(SEEK_END)`.
- `build.zig` modules explicitly set `link_libc = true`. Mac's Zig
  toolchain was lenient about `extern "c"` without explicit libc linkage;
  Ubuntu 0.16 rejects it hard.

### Internal
- `Vm` struct: `io: std.Io = undefined` field (set by loader).
- `WasmModule.owned_io`: holds the auto-constructed `std.Io.Threaded` when
  the embedder did not supply one.
- `main(init: std.process.Init)` on entry points (CLI, e2e_runner) so they
  can grab `init.io` / `init.gpa` / args from the runtime's start.zig.
- WASI handlers: use `std.c.*` with `file.handle` for the POSIX ops that
  `std.posix` dropped (fsync/mkdirat/unlinkat/renameat/ftruncate/futimens/
  pread/pwrite/dup/readlinkat/symlinkat/linkat/close/pipe/getenv). Errno
  → `Errno` via a single local `cErrnoToWasi()` helper.
- `@Vector` runtime indexing was rejected by 0.16's compiler; SIMD
  extract/replace_lane and lane-memory ops rewritten to use `[N]T` arrays
  with `@bitCast` at push time.
- Closes PR #41 (notxorand's migration draft) as superseded.

## [1.9.1] - 2026-04-24

### Changed
- `invoke`/`invokeInterpreterOnly` now return `error.ModuleNotFullyLoaded` if the underlying VM is uninitialized (e.g., after OOM in `loadLinked`). This is a new error variant in the public API. Embedders matching on specific errors should handle this case. See API docs for details. (PR #40 by @jtakakura, closes #39)

### Fixed
- `WasmModule.cancel()` no longer segfaults on a partially-loaded module (`vm == null` after OOM in `loadLinked`). Matches the C API contract that documents cancel as a no-op on idle modules.

## [1.9.0] - 2026-04-24

### Added
- Asynchronous execution cancellation (PR #28 by @jtakakura, closes #27). A host thread can now abort a running invocation:
  - Zig API: `WasmModule.cancel()` / `Vm.cancel()` — thread-safe, returns `error.Canceled` from `invoke()` at the next ~1024-instruction checkpoint (or JIT fuel interval).
  - C API: `void zwasm_module_cancel(zwasm_module_t *)` and `void zwasm_config_set_cancellable(zwasm_config_t *, bool)`.
  - CLI: reports `execution canceled` when the runtime returns `error.Canceled`.
- `WasmModule.Config.cancellable: ?bool` — opt-out of periodic cancellation checks for peak JIT throughput when the host never cancels.

### Changed
- By default, JIT-compiled loops now fire the fuel-check helper every `DEADLINE_JIT_INTERVAL` iterations even when no fuel/deadline is set, so cancellation takes effect without host instrumentation. Pass `cancellable = false` to restore the pre-v1.9.0 unconditional `jit_fuel = maxInt(i64)` behaviour.

## [1.8.0] - 2026-04-21

### Added
- `WasmModule.Config` — unified configuration struct for module loading (PR #30 by @jtakakura)
- `WasmModule.loadWithOptions(allocator, wasm_bytes, config)` — new primary entry point that consolidates all load variants
- C API configuration setters: `zwasm_config_set_fuel`, `zwasm_config_set_timeout`, `zwasm_config_set_max_memory`, `zwasm_config_set_force_interpreter`

### Changed
- Resource limits (fuel, timeout, max_memory_bytes, force_interpreter) now apply during the start function. Previously the CLI applied them post-load, leaving the start function unconstrained.
- Fuel budget is now decremented across successive `invoke()` calls, matching the pre-existing `/// Persistent fuel budget` doc comment. Previously each invoke reset fuel to the originally-configured value.
- CLI `--link` fallback retry is now scoped to `error.ImportNotFound`. Previously any error on the imports-enabled load attempt triggered a retry without imports.
- `loadWithImports` / `loadWasiWithImports` accept `?[]const ImportEntry` (source-compatible with existing `[]const ImportEntry` callers via Zig optional coercion).

### Fixed
- `loadLinked`: `store.deinit()` is now called on decode/instantiate failure paths (resource leak fix).
- `loadCore`: `errdefer allocator.destroy(self.vm)` protects against VM leak on post-allocation failures.

### Notes
- All existing `load*` helpers (`load`, `loadWithFuel`, `loadFromWat`, `loadWasi`, `loadWasiWithOptions`, `loadWithImports`, `loadWasiWithImports`) are retained as thin wrappers over `loadWithOptions`, so embedders do not need to update call sites.

## [1.7.2] - 2026-04-21

### Fixed
- ARM64 JIT: `i32.rem_s/u` and `i64.rem_s/u` produced wrong remainders when
  the destination register aliased the divisor (`rd == rs2`). UDIV/SDIV
  clobbered the divisor before MSUB could read it, so MSUB computed
  `dividend - quotient * quotient` instead of `dividend - quotient * divisor`.
  Triggered by TinyGo-compiled `gcd` (IR: `r3 = r0 % r3`), causing infinite
  loops after JIT compilation (HOT_THRESHOLD). The prior fix in v1.7.1
  only covered `rd == rs1`. This commit preserves whichever operand `rd`
  aliases before the divide.

## [1.7.1] - 2026-04-21

### Added
- `-Dpic` and `-Dcompiler-rt` build options for static library consumers (PR #24)

### Fixed
- Preserve caller-set `vm.*` settings (fuel, deadline, max_memory_bytes, force_interpreter)
  across `invoke()` and `invokeInterpreterOnly()` — previously reset to defaults between
  invocations (PR #31, #32)
- `setup-orbstack.md`: broken Zig download URL (PR #35)

### Changed
- Spec testsuite bumped to `f9c743a` (from `072bd0d`)

## [1.7.0] - 2026-04-03

### Added
- SIMD JIT: ARM64 NEON (253/256 native) and x86_64 SSE (244/256 native) (Phase 13)
- SIMD JIT optimizations: v128 base address cache (W43), Q-reg/XMM register class (W44), loop persistence (W45), guard page bounds check elimination (W46), FMLA/FMLS instruction fusion (W47)
- C API: FD-based WASI stdio and preopen configuration (`zwasm_wasi_config_set_stdin_fd` etc.) (D133)
- C API: `zwasm_module_invoke` args marked `const` (PR #16)
- JIT fuel check at back-edges: enables timeout support for JIT-compiled code (Phase 19.2)
- Epoch-based JIT timeout (D131): cooperative timeout via shared fuel counter
- Multi-value return support in RegIR (`OP_RETURN_MULTI`)
- `--interp` CLI flag for interpreter-only execution (debugging/differential testing)
- Wide-arithmetic validation support (i64.add128, i64.sub128, i64.mul_wide_s/u)
- 5 real-world SIMD benchmarks (C -msimd128): grayscale, box_blur, sum_reduce, byte_freq, nbody
- 3 additional SIMD benchmarks: mandelbrot, matmul (C, wasi-sdk), blake2b_simd (Rust), simd_chain
- SIMD benchmark comparison infrastructure (`bench/run_simd_bench.sh`, `bench/simd_comparison.yaml`)
- Rust FFI example using zwasm C API
- FFI tests in CI and commit/merge gate checklists

### Fixed
- memory64: u64 offset decoding and i64 address handling across decoder, validator, predecoder, and VM — fixes wasm-tools 1.246.1 compatibility
- JIT correctness sweep (Phase 20): 8 real-world compat programs fixed (45→50/50)
  - ARM64 fuel check clobbering vreg 20 (x0) at loop back-edges
  - `written_vregs` pre-scan: stale reload in loops after call sites
  - Void self-call result clobber (`n_results` vs `result_count`)
  - Void-call `reloadVreg` clobbering live local variables
  - ARM64 ABI register clobbering in `emitMemFill`/`emitMemCopy`/`emitMemGrow`
  - Remainder register aliasing when rd == rs1 (MSUB on ARM64)
  - Stale scratch cache in signed division overflow check
  - x86 i32 div/rem signed edge case: 32-bit CMP for -1 check
- JIT memory64 bounds check and custom-page-sizes (CI failure since 3/24)
- JIT `memory_grow64` truncation and cross-module call instance
- JIT `extract_lane` encoding and back-edge poisoning
- ARM64 JIT `simd_v128` sync in MOV/CONST for SIMD correctness
- Q-cache stale read in `extract_lane` upper-half fallback
- ARM64 JIT `emitGlobalSet` ABI clobber: vreg r21 overwritten before reading value (W35)
- x86_64 wide-arithmetic E2E: 19 tests fixed (validator + Debug i128 build mode)
- `i32.store16` access size in interpreter
- `--interp` flag incomplete for `doCallDirectIR` path
- Windows C API: `intptr_t` for host fd, cross-platform `File.close` for stdio handles
- Shared library segfault on Linux x86_64 (PR #11)

### Changed
- SIMD operations now JIT-compiled (was: stack interpreter only, ~22x slower)
- SIMD microbenchmarks: image_blend **4.7x**, matrix_mul **1.6x** (beats wasmtime)
- HOT_THRESHOLD lowered from 10 to 3 for earlier JIT compilation
- Contiguous v128 storage layout for SIMD JIT (W37)
- Real-world compat: Mac 50/50, Ubuntu 50/50 (was 42/50)
- E2E tests: 795/795 on Mac (was 773/792 on Ubuntu)
- Spec tests: 62,263/62,263 (100%, 0 skip)
- Binary size: 1.29 MB stripped. Memory: ~3.5 MB RSS.
- wasm-tools bumped to 1.246.1
- E2E runner built with ReleaseSafe (fixes x86_64 Debug i128 issues)

## [1.3.0] - 2026-03-02

### Added
- Module cache for predecoded IR (Phase 1.2): reuse compiled module state across invocations
- Cache-enabled benchmark variants for all bench scripts (`--cache` flag)

### Changed
- Benchmark suite expanded with cached variants for real-world programs
- CI: pinned wasmtime version to avoid broken install script on macOS
- Release process: migrated Ubuntu testing from SSH to OrbStack
- Project docs reorganized for post-v1.2.0 phase planning

## [1.2.0] - 2026-02-27

### Added
- Real-world compatibility tests: 30 programs (C, C++, Go, Rust) verified against wasmtime
- On-Stack Replacement (OSR) for back-edge JIT: enter at loop body, bypass prologue side effects
- Spec test strict mode: `--strict` flag exits non-zero on skips, enforced in CI
- 11 new unit tests (521 total)
- E2E tests expanded: 792/792 assertions (from 356)

### Fixed
- Spec validation: 87 previously skipped tests now enforced (GC typed references, subtyping, table types, exception handling catch clauses, rec group boundaries)
- Spec infra: 18 `assert_exception` tests now handled by spec runner
- E2E memory leak: `errdefer` in void-returning function was a no-op in Zig 0.15
- JIT self-call stack overflow use-after-free (E2E segfault on aarch64)
- Back-edge JIT restart corrupting Go WASI state machines (side-effect detection)
- ARM64 OSR prologue: push FP callee-saved d8-d15 (stack corruption fix)
- x86_64 OSR prologue: load physically-mapped vregs (stale register fix)
- x86_64 select aliasing: val2 clobbered when rd == val2_idx
- JIT IR instruction limit (MAX_JIT_IR_INSTRS=1500) prevents miscompilation of large functions
- Go state machine detection: br_table boundary inclusive of target instruction

### Changed
- Spec tests: 62,263/62,263 passed (100.0%, 0 skip — up from 62,158 with 105 skips)
- Benchmark results: 20/29 match or beat wasmtime, 27/29 within 1.5x (up from 14/23)
- st_sieve: 0.97x wasmtime (restored from 30.82x regression via OSR)
- GC benchmarks: gc_alloc 0.50x, gc_tree 0.73x wasmtime (JIT for struct ops)
- nbody: 0.97x wasmtime (FP cache D2-D15 expansion)
- Nightly CI: spec tests now run ReleaseSafe (eliminates Debug tail-call timeouts)

## [1.1.0] - 2026-02-18

### Added
- WAT parser spec parity: GC type annotations, memory64 syntax, typed select, NaN payloads
- WAT roundtrip 100%: 62,156/62,156 spec test modules parse and re-encode correctly
- SIMD interpreter fast-path: predecoded IR dispatch for v128 ops (~2x improvement)
- SIMD performance analysis and 3-phase optimization roadmap
- Japanese documentation (book/ja/) with language switcher
- GC benchmarks in runtime comparison recording

### Changed
- Binary size: 1.31 MB (ReleaseSafe, from 1.28 MB — WAT parser improvements)
- Runtime memory: 3.44 MB RSS (fib benchmark)
- Benchmark results: 14/23 match or beat wasmtime (up from 13/21, at v1.1.0 time)
- Updated all documentation with fresh benchmark data

## [1.0.0] - 2026-02-17

First stable release. API frozen under SemVer guarantees.

### Added
- mdBook documentation site with 12 chapters
- GitHub Pages deployment for book
- CI benchmark regression detection (20% threshold)
- CI binary size check (1.5 MB limit), ReleaseSafe build verification
- E2E tests in CI (wasmtime misc_testsuite, 356 assertions)
- Nightly sanitizer job (Debug build) and fuzz campaign (60 min)
- CI caching for Zig build artifacts
- Overnight fuzz infrastructure (`test/fuzz/fuzz_overnight.sh`)
- API boundary documentation (`docs/api-boundary.md`)
- CONTRIBUTING.md, CODE_OF_CONDUCT.md, issue templates
- Release automation: tag-triggered cross-platform builds
- Install script (`install.sh`), Homebrew formula template
- Host function and WASI examples (5 examples total)
- CHANGELOG.md
- SemVer versioning policy, deprecation guarantees

### Changed
- **BREAKING**: `loadWasi()` defaults to `cli_default` capabilities (stdio, clock, random, proc_exit). Use `loadWasiWithOptions(.{ .caps = .all })` for full access.
- `--env KEY=VALUE` injected variables now accessible without `--allow-env`
- Error messages now use human-readable format (30 error variants)
- README: badges, install section, documentation links

### Added (security)
- `--sandbox` CLI flag: deny-all capabilities + fuel 1B + memory 256MB
- `Capabilities.sandbox` preset for library API
- Restrictive library API defaults for safe embedding

## [0.3.0] - 2026-02-15

### Added
- GC proposal: 31 opcodes (struct, array, i31, cast operations)
- Threads: 79 atomic operations (load/store/RMW/cmpxchg), shared memory, wait/notify
- Exception handling: throw, throw_ref, try_table
- Function references: call_ref, br_on_null/non_null, ref.as_non_null
- Wide arithmetic: add128, sub128, mul_wide_s/u
- Custom page sizes proposal
- Multi-memory proposal
- JIT optimizations: inline self-call, smart spill, direct call, depth guard caching
- x86_64 JIT backend
- Fuel-based execution limits
- Max memory limits
- Resource limit enforcement (section counts, locals, nesting depth)
- Security audit (.dev/archive/audit-36.md, docs/security.md, SECURITY.md)
- Fuzz testing infrastructure with 25K+ corpus

### Changed
- Spec test coverage: 62,158/62,158 (100%)
- E2E tests: 356/356 from wasmtime misc_testsuite
- Binary size: 1.28 MB (ReleaseSafe)

## [0.2.0] - 2026-02-10

### Added
- Component Model: WIT parser, binary decoder, Canonical ABI, WASI P2 adapter
- WAT text format parser (`zwasm run file.wat`)
- WASI Preview 1: 46/46 syscalls (100%)
- Capability-based WASI security model
- Module linking (`--link name=file`)
- Host function imports
- Memory read/write API
- Batch mode (`--batch`)
- Inspect and validate commands
- ARM64 JIT backend
- Register IR with register allocation
- SIMD: 236 v128 opcodes + 20 relaxed SIMD

## [0.1.0] - 2026-02-08

### Added
- Initial release
- WebAssembly MVP: 172 core opcodes
- Stack-based interpreter
- Basic CLI (`zwasm run`)
- Zig library API (`WasmModule.load`, `invoke`)
