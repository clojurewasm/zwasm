# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE
- **Stage 1: Library Quality + CLI Polish** — COMPLETE
- **Stage 2: Spec Conformance** — COMPLETE
- **Stage 4: Polish & Robustness** — COMPLETE (tasks 4.1-4.4)
- Source: ~14K LOC, 14 files (+ cli.zig, 3 examples), 137 tests all pass
- Opcode coverage: 225 core + 236 SIMD = 461
- WASI syscalls: ~27
- Benchmark: fib(35) = 103ms, sieve(1M) = 5.4ms (ReleaseSafe, CLI, JIT)
- vs wasmtime JIT: 52ms fib / 7ms sieve (2.0x / 0.8x gap — sieve beats wasmtime!)
- Benchmarks: 3 layers — 5 WAT, 6 TinyGo, 5 shootout (sub-ms precision)
- Spec test pass rate: 30,648/30,686 (99.9%) — 151 files, 28K skipped
- CI: GitHub Actions (ubuntu + macOS, zig build test + spec tests)
- **Register IR**: lazy conversion at first call, fallback to stack IR on failure
- **ARM64 JIT**: function-level codegen — arithmetic, control flow, function calls,
  division/remainder (traps), memory load/store (14 ops), rotation, CLZ/CTZ, select, sign-ext,
  f64/f32 arithmetic (add/sub/mul/div/sqrt/abs/neg/min/max), FP comparisons, FP conversions
- **JIT call fast path**: JIT-to-JIT direct calls bypass callFunction dispatch
- **JIT code quality**: direct dest reg, selective reload, shared error epilogue
- **Inline self-call**: direct BL for self-recursive calls, cached &vm.reg_ptr in x27
- **Smart spill**: only spill caller-saved + arg vregs; direct physical reg arg copy
- **doCallDirectIR fast path**: regIR/JIT for callees of stack-IR functions (task 5.1)
- **RegIR opcodes**: br_table (with arity trampolines), memory.fill/copy, trunc_sat (task 5.2)

## Task Queue

Stage 5: JIT Coverage Expansion

Performance gaps: st_sieve 32x, st_matrix 31x, nbody 2.7x slower than wasmtime.
Root causes: regIR interpreter overhead (st_sieve/matrix — need JIT expansion for memory/br_table).
st_fib2: 1754ms (2.6x wasmtime). st_ackermann: 6ms (beats wasmtime). nbody: 60ms (was 134ms).

1. [x] 5.1: Profile shootout benchmarks + fix doCallDirectIR JIT bypass
2. [x] 5.2: Close remaining gaps (st_sieve/matrix regIR opcode coverage)
3. [x] 5.3: f64/f32 ARM64 JIT — nbody 133→60ms (2.2x speedup)
4. [ ] 5.4: Re-record cross-runtime benchmarks

## Current Task

5.4: Re-record cross-runtime benchmarks after Stage 5 improvements.

## Previous Task

5.3: f64/f32 ARM64 JIT — COMPLETE.
Added full f64/f32 JIT codegen: arithmetic (add/sub/mul/div), unary (sqrt/abs/neg),
min/max, comparisons (NaN-safe: MI/LS conditions for lt/le), conversions
(i32/i64↔f64/f32, promote/demote). Strategy: GPR↔FPR via FMOV, compute in
d0/d1 scratch FP regs. nbody: 133ms → 60ms (2.2x speedup), gap vs wasmtime
reduced from 6.2x to 2.7x.
Key remaining gap: st_sieve/st_matrix still use regIR interpreter (no JIT for
memory load/store with bounds check, br_table). Need JIT expansion for these.

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Zig tips: .claude/references/zig-tips.md
