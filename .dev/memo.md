# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE (tasks 0.1-0.7, 0.9.1-0.9.4)
- **Stage 1: Library Quality + CLI Polish** — COMPLETE (tasks 1.1-1.7)
- **Stage 2: Spec Conformance** — COMPLETE (tasks 2.1-2.7)
- Source: ~13K LOC, 14 files (+ cli.zig, 3 examples), 127 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark: fib(35) = 443ms (ReleaseSafe, CLI, register IR + fusion)
- vs wasmtime JIT: 58ms (7.6x gap — interpreter vs JIT)
- Benchmarks: 3 layers — 5 WAT, 6 TinyGo, 19 shootout (all 5 runtimes)
- Spec test pass rate: 30,648/30,686 (99.9%) — 151 files, 28K skipped
- CI: GitHub Actions (ubuntu + macOS, zig build test + spec tests)
- **Register IR**: lazy conversion at first call, fallback to stack IR on failure
- **ARM64 JIT**: basic block codegen for i32/i64 arithmetic + control flow + function calls

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
7. [x] 3.6: Register IR validation — benchmark + peephole optimization
8. [x] 3.7: ARM64 codegen design — D105 decision for JIT architecture
9. [x] 3.8: ARM64 basic block codegen — arithmetic + control flow
10. [ ] 3.9: ARM64 function-level JIT — compile entire hot functions
11. [ ] 3.10: Tiered execution — interpreter → JIT with hot function detection

## Current Task

3.9: ARM64 function-level JIT — compile entire hot functions.

Extend JIT to handle more opcodes:
1. Memory load/store (i32.load, i32.store, etc.)
2. Global get/set
3. Division, remainder, clz, ctz, popcnt
4. f32/f64 floating point operations
5. Memory size/grow
6. Benchmark: measure JIT speedup vs register IR interpreter

## Previous Task

3.8: ARM64 basic block codegen — COMPLETE.
- `src/jit.zig` (~1400 LOC): ARM64 code emission, mmap W^X, icache flush
- Compiler: RegInstr→ARM64 compilation for i32/i64 arithmetic, comparisons, control flow
- Call trampoline: JIT→interpreter function calls via C calling convention
- Register mapping: x22-x28 (callee-saved r0-r6), x9-x15 (caller-saved r7-r13)
- Calling convention: fn(regs, vm, instance) callconv(.c) u64
- Hot threshold: 100 calls (configurable)
- Integration: WasmFunction.jit_code field, Vm.callFunction dispatch
- Profiling-aware: skip JIT when profile is active
- Cross-module safe: reset JIT state on function import copy
- Bugs fixed: CSET Rn encoding (W0→WZR), pc_map indexing (iteration→PC)
- 6 new tests: encoding, vreg mapping, const return, i32 add, branch, fib smoke
- JIT debugging doc: `.dev/jit-debugging.md`

## Known Issues

- **fib_loop TinyGo execution bug**: zwasm returns 196608 for fib_loop(25), correct is 75025
- **regalloc u8 overflow**: Complex WASI programs with >255 virtual registers cause panic

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
| JIT debugging      | `.dev/jit-debugging.md`                           |
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
