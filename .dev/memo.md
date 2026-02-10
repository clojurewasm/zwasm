# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- **Stage 0: Extraction & Independence** — COMPLETE
- **Stage 1: Library Quality + CLI Polish** — COMPLETE
- **Stage 2: Spec Conformance** — COMPLETE
- **Stage 4: Polish & Robustness** — COMPLETE (tasks 4.1-4.4)
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

Stage 5: JIT Coverage Expansion

Performance gaps: shootout 23-33x, nbody 6.2x slower than wasmtime.
Root causes: functions not getting JIT'd, missing f64 JIT, interpreter overhead.

1. [ ] 5.1: Profile shootout benchmarks — identify JIT coverage gaps
2. [ ] 5.2: Close identified gaps (based on 5.1 findings)
3. [ ] 5.3: f64 ARM64 JIT — codegen for f64 operations (key gap for nbody)
4. [ ] 5.4: Re-record cross-runtime benchmarks

## Current Task

5.1: Profile shootout benchmarks — identify why 23-33x slower than wasmtime.

## Previous Task

4.4: Cross-runtime benchmark update — COMPLETE.
Key results: fib 104ms (2.0x wasmtime), sieve 5ms (beats wasmtime 6ms).
Memory: zwasm 2-3MB vs wasmtime 12-43MB.

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Zig tips: .claude/references/zig-tips.md
