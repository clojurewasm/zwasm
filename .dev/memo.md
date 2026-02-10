# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE (tasks 0.1-0.7, 0.9.1-0.9.4)
- **Stage 1: Library Quality + CLI Polish** — COMPLETE (tasks 1.1-1.7)
- Source: ~11K LOC, 12 files (+ cli.zig, 3 examples), 115 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark: fib(35) = 544ms (ReleaseSafe, CLI)
- vs wasmtime JIT: 58ms (9.4x gap — interpreter vs JIT)
- Spec test pass rate: 30,332/30,383 (99.8%) — 151 files, 28K skipped

## Strategic Position

**zwasm is an independent Zig WebAssembly runtime — library AND CLI tool.**

- NOT a ClojureWasm subproject. CW is just one potential consumer.
- Two delivery modes: `@import("zwasm")` library + `zwasm` CLI (like wasmtime)
- Benchmark target: **wasmtime** (measure gap, close it with JIT)
- Optimization target: ARM64 Mac first, x86_64 later
- Position: smallest, fastest Zig-native Wasm runtime

**IMPORTANT**: Do NOT make design decisions based on CW's needs.
Design for the Zig ecosystem. CW adapts to zwasm's API, not the reverse.

## Task Queue

Stage 2: Spec Conformance

1. [x] 2.1: Download spec test suite + convert .wast to JSON with wast2json
2. [x] 2.2: Wast test runner (Python) + initial pass rate: 80.0%
3. [ ] 2.3: spectest host module (memory, table, globals, print functions)
4. [x] 2.5: Fix spec test failures — 99.8% achieved (target >95%)
5. [ ] 2.6: assert_invalid + assert_malformed support
6. [ ] 2.7: CI pipeline (GitHub Actions)

Stage 3 (planned): JIT (ARM64) + Optimization

## Current Task

2.3: spectest host module — provide spectest imports (memory, table, globals, print functions).

The Wasm spec test suite expects a "spectest" module with specific exports:
- `memory`: 1-page memory (min=1, max=2)
- `table`: 10-element funcref table (min=10, max=20)
- `global_i32`: i32 global = 666
- `global_i64`: i64 global = 666
- `global_f32`: f32 global = 666.6
- `global_f64`: f64 global = 666.6
- `print`, `print_i32`, `print_i64`, `print_f32`, `print_f64`, `print_f32_f64`, `print_i32_f32`: no-op functions

This will fix the 3 func_ptrs failures and any other tests requiring spectest imports.

## Previous Task

2.5: Fix spec test failures — 99.8% achieved (30,332/30,383, target >95%).

Key fixes in final iteration:
- Multi-module linking (`--link name=path.wasm` CLI flag + test runner support)
- Wasm bytes lifetime fix (keep linked module bytes alive)
- IR predecoder misc opcode mapping fix (0x0C-0x11 were swapped)
- Active element/data segments dropped after instantiation (per spec)

Remaining 51 failures:
- memory64 proposal (table_size64, memory_grow64): 40
- spectest host module needed (func_ptrs): 3
- externref/timeout: 5
- names (special chars): 2
- fac (timeout): 1

## Known Issues

- None currently open

## Reference Chain

Session resume: read this file → follow references below.

### zwasm documents

| Topic              | Location                                          |
|--------------------|---------------------------------------------------|
| Roadmap            | `.dev/roadmap.md`                                 |
| Decisions          | `.dev/decisions.md`                               |
| Deferred items     | `.dev/checklist.md` (W## items)                   |
| Spec coverage      | `.dev/spec-support.md`                            |
| Wasm spec refs     | `.dev/references/wasm-spec.md`                    |

### External references

| Source                | Location                                                      | Purpose                      |
|-----------------------|---------------------------------------------------------------|------------------------------|
| wasmtime              | `/Users/shota.508/Documents/OSS/wasmtime/`                    | Performance target, API ref  |
| WasmResearch docs     | `/Users/shota.508/Documents/MyProducts/WasmResearch/docs/`    | Spec analysis, proposals     |
| zware reference impl  | `/Users/shota.508/Documents/OSS/zware/`                       | Alt Zig Wasm impl            |
| Zig tips              | `/Users/shota.508/Documents/MyProducts/ClojureWasm/.claude/references/zig-tips.md` | Zig 0.15.2 pitfalls |
| Wasm spec tests       | https://github.com/WebAssembly/spec/tree/main/test/core       | Conformance target           |

## Handover Notes

- zwasm is an independent Zig Wasm runtime (library + CLI)
- Originated from ClojureWasm src/wasm/ extraction, but now fully independent
- Repo: `clojurewasm/zwasm` (private)
- Workflow instructions: CW `.claude/CLAUDE.md` → "zwasm Development" section
- Session memory: CW MEMORY.md "zwasm Project" section
- **Design principle**: zwasm serves the Zig ecosystem, not CW specifically
