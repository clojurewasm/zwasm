# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE (tasks 0.1-0.7, 0.9.1-0.9.4)
- **Stage 1: Library Quality + CLI Polish** — COMPLETE (tasks 1.1-1.7)
- **Stage 2: Spec Conformance** — COMPLETE (tasks 2.1-2.7)
- Source: ~12K LOC, 13 files (+ cli.zig, 3 examples), 121 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark: fib(35) = 443ms (ReleaseSafe, CLI, register IR + fusion)
- vs wasmtime JIT: 58ms (7.6x gap — interpreter vs JIT)
- Spec test pass rate: 30,648/30,686 (99.9%) — 151 files, 28K skipped
- CI: GitHub Actions (ubuntu + macOS, zig build test + spec tests)
- **Register IR**: lazy conversion at first call, fallback to stack IR on failure

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

1. [x] 3.1: Profiling infrastructure — opcode frequency + function call counters
2. [x] 3.2: Benchmark suite expansion — tak, sieve, nbody + updated scripts
3. [x] 3.3: Profile hot paths — analyzed, documented in .dev/profile-analysis.md
4. [x] 3.3b: TinyGo benchmark port — CW TinyGo wasm to zwasm, update scripts
5. [x] 3.4: Register IR design — D104 decision for IR representation
6. [x] 3.5: Register IR implementation — stack-to-register conversion pass
7. [ ] 3.6: Register IR validation — benchmark, target 2-3x speedup over stack interpreter
8. [ ] 3.7: ARM64 codegen design — D## decision for JIT architecture
9. [ ] 3.8: ARM64 basic block codegen — arithmetic + control flow
10. [ ] 3.9: ARM64 function-level JIT — compile entire hot functions
11. [ ] 3.10: Tiered execution — interpreter → JIT with hot function detection

## Current Task

3.6: Register IR validation — benchmark, target 2-3x speedup over stack interpreter.

Current register IR results (1.01-1.18x) are below target. Investigate bottlenecks:
1. Profile register IR execution to identify overhead sources
2. Expand opcode coverage (more functions converted = more benefit)
3. Optimize function call path for register IR functions
4. Consider specialized register IR paths for hot patterns
5. Target: fib 2x, nbody 2-3x improvement over stack interpreter

## Previous Task

3.5: Register IR implementation — COMPLETE.
- `src/regalloc.zig` (~850 LOC): PreInstr→RegInstr single-pass converter
- `executeRegIR()` in vm.zig (~500 LOC): register-file-based execution loop
- Lazy conversion: first call triggers conversion, cached on WasmFunction
- Fallback: functions that fail conversion use existing executeIR()
- Heap-allocated register file: `reg_stack[4096]u64` in Vm struct (avoids stack overflow)
- Dead code elimination: unreachable_depth tracking after return/br/unreachable
- 121 unit tests pass, spec tests 30,648/30,686 (no regression, +1 improvement)
- Benchmarks: fib 1.01x, sieve 1.04x, nbody 1.18x faster
- Key bugs fixed: f32/f64 trunc type swap, shr_s/shr_u swap, NaN propagation,
  loop result_reg allocation, dead code vstack underflow

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
| Bench strategy     | `.dev/bench-strategy.md`                          |
| Profile analysis   | `.dev/profile-analysis.md`                        |
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
