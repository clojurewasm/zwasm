# Spec Coverage

zwasm targets full WebAssembly 3.0 compliance. All spec tests pass on macOS ARM64 and Linux x86_64.

**Test results**: 62,158 / 62,158 (100.0%)

## Core specification

| Feature | Opcodes | Status |
|---------|---------|--------|
| MVP (core) | 172 | Complete |
| Sign extension | 7 | Complete |
| Non-trapping float-to-int | 8 | Complete |
| Bulk memory | 9 | Complete |
| Reference types | 5 | Complete |
| Multi-value | - | Complete |
| **Total core** | **201+** | **100%** |

## SIMD

| Feature | Opcodes | Status |
|---------|---------|--------|
| SIMD (v128) | 236 | Complete |
| Relaxed SIMD | 20 | Complete |
| **Total SIMD** | **256** | **100%** |

## Wasm 3.0 proposals

All 9 Wasm 3.0 proposals are fully implemented:

| Proposal | Opcodes | Spec tests | Status |
|----------|---------|------------|--------|
| Memory64 | extends existing | Pass | Complete |
| Tail calls | 2 | Pass | Complete |
| Extended const | extends existing | Pass | Complete |
| Branch hinting | metadata section | Pass | Complete |
| Multi-memory | extends existing | Pass | Complete |
| Relaxed SIMD | 20 | 85/85 | Complete |
| Exception handling | 3 | Pass | Complete |
| Function references | 5 | 104/106 | Complete |
| GC | 31 | Pass | Complete |

## Additional proposals

| Proposal | Opcodes | Status |
|----------|---------|--------|
| Threads | 79 (0xFE prefix) | Complete (310/310 spec) |
| Wide arithmetic | 4 | Complete (99/99 e2e) |
| Custom page sizes | - | Complete (18/18 e2e) |

## WASI Preview 1

46 / 46 syscalls implemented (100%):

| Category | Count | Functions |
|----------|-------|-----------|
| args | 2 | args_get, args_sizes_get |
| environ | 2 | environ_get, environ_sizes_get |
| clock | 2 | clock_time_get, clock_res_get |
| fd | 14 | read, write, close, seek, stat, prestat, readdir, ... |
| path | 8 | open, create_directory, remove, rename, symlink, ... |
| proc | 2 | exit, raise |
| random | 1 | random_get |
| poll | 1 | poll_oneoff |
| sock | 4 | NOSYS stubs |

## Component Model

| Feature | Status |
|---------|--------|
| WIT parser | Complete |
| Binary decoder | Complete |
| Canonical ABI | Complete |
| WASI P2 adapter | Complete |
| CLI support | Complete |

121 Component Model tests pass.

## WAT parser

The text format parser supports:
- All value types including v128
- Named locals, globals, functions, types
- Inline exports and imports
- S-expression and flat syntax
- Data and element sections
- All prefix opcodes: 0xFC (bulk memory, trunc_sat), 0xFD (SIMD + lane ops), 0xFE (atomics)
- Wasm 3.0 opcodes: try_table, call_ref, br_on_null, throw_ref, etc.
- GC prefix (0xFB) deferred — requires type annotation parser extensions

## Total opcode count

| Category | Count |
|----------|-------|
| Core | 201+ |
| SIMD | 256 |
| GC | 31 |
| Threads | 79 |
| Others | 14+ |
| **Total** | **581+** |
