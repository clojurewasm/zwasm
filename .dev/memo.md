# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE (tasks 0.1-0.7, 0.9.1-0.9.4)
- **Stage 1: Library Quality + CLI Polish** — COMPLETE (tasks 1.1-1.7)
- **Stage 2: Spec Conformance** — COMPLETE (tasks 2.1-2.7)
- Source: ~14K LOC, 14 files (+ cli.zig, 3 examples), 132 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark: fib(35) = 103ms, sieve(1M) = 5.4ms (ReleaseSafe, CLI, JIT)
- vs wasmtime JIT: 52ms fib / 7ms sieve (2.0x / 0.8x gap — sieve beats wasmtime!)
- Benchmarks: 3 layers — 5 WAT, 6 TinyGo, 5 shootout (sub-ms precision)
- Spec test pass rate: 30,648/30,686 (99.9%) — 151 files, 28K skipped
- CI: GitHub Actions (ubuntu + macOS, zig build test + spec tests)
- **Register IR**: lazy conversion at first call, fallback to stack IR on failure
- **ARM64 JIT**: function-level codegen — arithmetic, control flow, function calls,
  division/remainder (traps), memory load/store (14 ops), rotation, CLZ/CTZ, select, sign-ext
- **JIT call fast path**: JIT-to-JIT direct calls bypass callFunction dispatch
- **JIT code quality**: direct dest reg, selective reload, shared error epilogue
- **Inline self-call**: direct BL for self-recursive calls, cached &vm.reg_ptr in x27
- **Smart spill**: only spill caller-saved + arg vregs; direct physical reg arg copy

## Task Queue

Stage 4: Polish & Robustness

1. [x] 4.1: Fix fib_loop TinyGo bug — regalloc aliasing in local.tee
2. [x] 4.2: Fix regalloc u8 overflow — graceful fallback to stack IR
3. [x] 4.3: Inline self-call for memory functions — recompute reg_ptr addr via SCRATCH
4. [x] 4.4: Cross-runtime benchmark update — recorded comparison vs 5 runtimes

## Current Task

(none — Stage 4 task queue empty)

## Previous Task

4.4: Cross-runtime benchmark update — COMPLETE.
Fixed record_comparison.sh to handle runtime failures gracefully.
Recorded comparison vs wasmtime/wasmer/bun/node (wasmer 5.0.4 fails TinyGo --invoke).
Key results: fib 104ms (2.0x wasmtime), sieve 5ms (beats wasmtime 6ms),
nqueens 2ms (beats all), tak 11ms (1.1x wasmtime).
Memory: zwasm 2-3MB vs wasmtime 12MB / bun 32MB / node 43MB.

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Zig tips: .claude/references/zig-tips.md
