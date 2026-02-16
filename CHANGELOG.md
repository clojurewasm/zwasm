# Changelog

All notable changes to zwasm are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- mdBook documentation site with 12 chapters (Getting Started, Architecture, CLI, Embedding, Spec Coverage, Security, Performance, Memory, Comparison, FAQ, Contributing)
- GitHub Pages deployment for book
- CI benchmark regression detection (20% threshold)
- CI binary size check (1.5 MB limit)
- CI ReleaseSafe build verification
- E2E tests in CI (wasmtime misc_testsuite)
- Nightly sanitizer job (Debug build)
- Nightly fuzz campaign (60 min)
- CI caching for Zig build artifacts
- Overnight fuzz infrastructure (`test/fuzz/fuzz_overnight.sh`)
- API boundary documentation (`docs/api-boundary.md`)
- CHANGELOG.md

### Changed
- Error messages now use human-readable format (30 error variants)

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
