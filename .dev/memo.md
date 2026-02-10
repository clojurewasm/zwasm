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
- Spec test pass rate: 29,338/30,383 (96.6%) — 151 files, 28K skipped

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
4. [ ] 2.5: Fix spec test failures (iterate until >95%)
5. [ ] 2.6: assert_invalid + assert_malformed support
6. [ ] 2.7: CI pipeline (GitHub Actions)

Stage 3 (planned): JIT (ARM64) + Optimization

## Current Task

2.5: Fix spec test failures — 96.6% achieved (29,338/30,383).

Fixes applied:
- CLI exit code propagation for trap detection
- Batch mode for stateful multi-invocation tests
- truncSat overflow bounds (power-of-2 exact bounds)
- Length-prefixed batch protocol for Unicode function names
- Fallback to single-process for problematic function names
- roundToEven -0.0 sign preservation (f32/f64 nearest)
- Start function execution on module load
- i32/f32 result truncation in CLI output (endianness fix)
- call_indirect full type comparison (not just length)
- Ref null convention: stack uses addr+1, 0=null (table_get/set/grow/fill)
- ref.func pushes store address (not module index)
- table.init + table.copy implementation
- memory.init/data.drop via instance dataaddrs
- Elem/Data store population during instantiation
- Dropped segments: effective length 0 (n=0 succeeds per spec)
- BrokenPipeError cleanup in test runner

Remaining failure categories:
- table_copy/init (multi-module linking): ~982
- table_size64 (memory64 proposal): 36
- bulk ops (multi-module/table state): ~12
- fac (timeout/infinite loop): 1
- table_get/set (externref test runner limitation): ~4
- names (special chars): 2
- memory_grow64 (memory64 proposal): 2

## Previous Task

2.2: Wast test runner — Python-based (test/spec/run_spec.py).
Parses wast2json JSON, runs assert_return/assert_trap via CLI --invoke.
Initial result: 80.0% pass rate across 151 test files.

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
