# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE (tasks 0.1-0.7, 0.9.1-0.9.4)
- **Stage 1: Library Quality + CLI Polish** — COMPLETE (tasks 1.1-1.7)
- **Stage 2: Spec Conformance** — COMPLETE (tasks 2.1-2.7)
- Source: ~14K LOC, 14 files (+ cli.zig, 3 examples), 130 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark: fib(35) = 331ms, sieve(1M) = 5.8ms (ReleaseSafe, CLI, JIT)
- vs wasmtime JIT: 52ms fib / 7ms sieve (6.4x / 0.8x gap — sieve beats wasmtime!)
- Benchmarks: 3 layers — 5 WAT, 6 TinyGo, 5 shootout (sub-ms precision)
- Spec test pass rate: 30,648/30,686 (99.9%) — 151 files, 28K skipped
- CI: GitHub Actions (ubuntu + macOS, zig build test + spec tests)
- **Register IR**: lazy conversion at first call, fallback to stack IR on failure
- **ARM64 JIT**: function-level codegen — arithmetic, control flow, function calls,
  division/remainder (traps), memory load/store (14 ops), rotation, CLZ/CTZ, select, sign-ext

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
10. [x] 3.9: ARM64 function-level JIT — compile entire hot functions
11. [x] 3.10: Tiered execution — interpreter → JIT with hot function detection

## Current Task

(Stage 3 task queue complete — planning next stage)

## Previous Task

3.10: Tiered execution — COMPLETE.
Key changes:
- Back-edge counting in executeRegIR: BACK_EDGE_THRESHOLD=1000, loop iterations trigger JIT
- JitRestart signal: JIT compiles mid-execution, callFunction re-executes via JIT
- HOT_THRESHOLD lowered 100→10 (call-count threshold)
- sieve: 42→5.8ms (7.3x speedup), single-call functions now JIT'd
- Architecture: 4-tier (bytecode → stack IR → register IR → ARM64 JIT)
  with two JIT triggers: call count (10) + back-edge counting (1000)

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Zig tips: .claude/references/zig-tips.md
