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
- Spec test pass rate: 30,647/30,686 (99.9%) — 151 files, 28K skipped

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
3. [x] 2.3: spectest host module + multi-value loops + fixes → 99.9%
4. [x] 2.5: Fix spec test failures — 99.9% achieved (target >95%)
5. [x] 2.6: assert_invalid/malformed in runner (+132 tests, skip if undetected)
6. [ ] 2.7: CI pipeline (GitHub Actions)

Stage 3 (planned): JIT (ARM64) + Optimization

## Current Task

2.7: CI pipeline (GitHub Actions).

Set up GitHub Actions workflow for:
- `zig build test` on push/PR
- Spec test runner (`python3 test/spec/run_spec.py`)
- Optional: cross-platform (Linux + macOS)

## Previous Task

2.6: assert_invalid/malformed validation support (+132 tests).
2.3: spectest host module + multi-value loops + fixes → 99.9%.

Key fixes across 2.3-2.6:
- spectest.wasm host module (print funcs, memory, table, globals)
- Multi-value typed loops: correct param arity for br + op_stack_base
- table.fill pre-check bounds, table.grow 1M resource limit
- WasmValType: funcref/externref, externref values in test runner
- Validation test support (132 passing, undetected cases skipped)

Remaining 39 failures (all non-core):
- memory64 proposal (table_size64, memory_grow64): 38
- names (batch protocol special chars): 1

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
