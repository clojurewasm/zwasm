# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE (tasks 0.1-0.7, 0.9.1-0.9.4)
- **Stage 1: Library Quality + CLI Polish** — COMPLETE (tasks 1.1-1.7)
- **Stage 2: Spec Conformance** — COMPLETE (tasks 2.1-2.7)
- Source: ~11K LOC, 12 files (+ cli.zig, 3 examples), 115 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark: fib(35) = 544ms (ReleaseSafe, CLI)
- vs wasmtime JIT: 58ms (9.4x gap — interpreter vs JIT)
- Spec test pass rate: 30,647/30,686 (99.9%) — 151 files, 28K skipped
- CI: GitHub Actions (ubuntu + macOS, zig build test + spec tests)

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

Stage 3: JIT + Optimization (ARM64)

1. [ ] 3.1: Profiling infrastructure — opcode frequency + function call counters
2. [ ] 3.2: Benchmark suite expansion — add nbody, binary-trees, sieve Wasm benchmarks
3. [ ] 3.3: Profile hot paths — analyze benchmark profiles, document bottleneck patterns
4. [ ] 3.4: Register IR design — D## decision for IR representation
5. [ ] 3.5: Register IR implementation — stack-to-register conversion pass
6. [ ] 3.6: Register IR validation — benchmark, target 2-3x speedup over stack interpreter
7. [ ] 3.7: ARM64 codegen design — D## decision for JIT architecture
8. [ ] 3.8: ARM64 basic block codegen — arithmetic + control flow
9. [ ] 3.9: ARM64 function-level JIT — compile entire hot functions
10. [ ] 3.10: Tiered execution — interpreter → JIT with hot function detection

## Current Task

3.1: Profiling infrastructure.

Add instrumentation to the interpreter to collect:
- Opcode execution frequency (per-opcode counter)
- Function call counts (which exports/internal functions are hot)
- Basic block execution counts (optional, for later JIT decisions)

Implementation approach:
- Add `--profile` flag to CLI
- Counters in Vm struct (conditional compilation or runtime flag)
- Print profile summary after execution
- Output format: sorted by frequency, top-N opcodes/functions

## Previous Task

2.7: CI pipeline (GitHub Actions) — COMPLETE.
Set up ubuntu + macOS matrix, zig 0.15.2, unit tests + spec tests.

Stage 2 achievements:
- Spec test pass rate: 30,647/30,686 (99.9%)
- spectest host module, multi-value typed loops, table fixes
- assert_invalid/malformed validation support (+132 tests)
- CI pipeline with cross-platform testing

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
- **Stage 3 approach**: Incremental JIT — profile first, register IR, then ARM64 codegen
- Benchmark baseline: fib(35) 544ms interpreter vs 58ms wasmtime JIT (9.4x gap)
