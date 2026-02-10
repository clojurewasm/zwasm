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

Claude Code infrastructure setup — COMPLETE.
Next: resume 3.9 JIT task.

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

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Zig tips: .claude/references/zig-tips.md
