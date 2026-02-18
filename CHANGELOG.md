# Changelog

All notable changes to zwasm are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

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
- Benchmark results: 14/23 match or beat wasmtime (up from 13/21)
- Updated all documentation with fresh benchmark data

### Known Limitations
- SIMD operations run on stack interpreter (~22x slower than wasmtime). Planned: RegIR v128 extension + selective JIT NEON/SSE.

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
- Security audit (docs/audit-36.md, docs/security.md, SECURITY.md)
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
