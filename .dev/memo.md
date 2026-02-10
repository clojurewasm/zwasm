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
  division/remainder (traps), memory load/store (14 ops), rotation, CLZ/CTZ, select, sign-ext
- **JIT call fast path**: JIT-to-JIT direct calls bypass callFunction dispatch
- **JIT code quality**: direct dest reg, selective reload, shared error epilogue
- **Inline self-call**: direct BL for self-recursive calls, cached &vm.reg_ptr in x27
- **Smart spill**: only spill caller-saved + arg vregs; direct physical reg arg copy
- **doCallDirectIR fast path**: regIR/JIT for callees of stack-IR functions (task 5.1)
- **RegIR opcodes**: br_table (with arity trampolines), memory.fill/copy, trunc_sat (task 5.2)

## Task Queue

Stage 5: JIT Coverage Expansion

Performance gaps: st_sieve 32x, st_matrix 31x, nbody 6.2x slower than wasmtime.
Root causes: missing JIT opcode coverage (st_sieve/matrix), missing f64 JIT (nbody).
st_fib2 fixed: 1754ms → 2.6x wasmtime (was 23.6x). st_ackermann: 6ms (beats wasmtime).

1. [x] 5.1: Profile shootout benchmarks + fix doCallDirectIR JIT bypass
2. [x] 5.2: Close remaining gaps (st_sieve/matrix regIR opcode coverage)
3. [ ] 5.3: f64 ARM64 JIT — codegen for f64 operations (key gap for nbody)
4. [ ] 5.4: Re-record cross-runtime benchmarks

## Current Task

5.3: f64 ARM64 JIT — codegen for f64 operations.
Key gap for st_nbody (6.2x slower than wasmtime). Need f64 arithmetic,
comparisons, conversions in ARM64 JIT codegen.

## Previous Task

5.2: Close remaining shootout regIR gaps — COMPLETE.
Added br_table (with arity trampoline for heterogeneous result_regs),
memory.fill/copy, trunc_sat (0xFC00-0xFC07), call_indirect stub.
Key finding: st_sieve and st_matrix now fully convert to regIR — no unsupported
opcodes remain. The 32x/31x gap vs wasmtime is register IR interpreter overhead,
not opcode coverage. Real fix requires expanding ARM64 JIT codegen to cover
these functions' instruction sets (memory ops, br_table, etc.).

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Zig tips: .claude/references/zig-tips.md
