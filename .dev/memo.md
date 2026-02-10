# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction** — COMPLETE (tasks 0.1-0.7)
- Source: 10,398 LOC, 11 files, 115 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark baseline: fib(35) = 586ms (ReleaseSafe, standalone)
- Spec test pass rate: TBD (no wast runner yet)

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

Stage 0.9: Independence & CLI (direction correction)

1. [x] 0.9.1: Fix license headers (EPL→MIT) and remove CW references from source
2. [x] 0.9.2: CLI tool (`zwasm run`, `zwasm inspect`, `zwasm validate`)
3. [ ] 0.9.3: wasmtime comparison benchmark (hyperfine zwasm vs wasmtime)
4. [ ] 0.9.4: Update roadmap for independent library + JIT optimization track

Stage 1 (planned): Library Quality + CLI Polish
Stage 2 (planned): Spec Conformance + wast test runner
Stage 3 (planned): JIT (ARM64) + Optimization

## Current Task

0.9.3: wasmtime comparison benchmark — hyperfine zwasm vs wasmtime on fib(35).
Establish the performance gap for optimization planning.

## Previous Task

0.9.2: CLI tool implemented — `zwasm run`, `zwasm inspect`, `zwasm validate`.
- src/cli.zig: argument parsing, WASI support, function signatures in inspect
- All 3 commands tested on fib + wasi_hello modules

## Known Issues

- No wasmtime comparison benchmark yet

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
