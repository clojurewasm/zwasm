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
- Benchmark: fib(35) = 105ms, sieve(1M) = 5.4ms (ReleaseSafe, CLI, JIT)
- vs wasmtime JIT: 52ms fib / 7ms sieve (2.0x / 0.8x gap — sieve beats wasmtime!)
- Benchmarks: 3 layers — 5 WAT, 6 TinyGo, 5 shootout (sub-ms precision)
- Spec test pass rate: 30,001/30,686 (97.8%) — 151 files, 28K skipped
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
- **RegIR opcodes**: br_table, memory.fill/copy, trunc_sat, call_indirect (task 5.2, 5.5)
- **JIT memory ops**: global.get/set, memory.grow/fill/copy, i32/i64.popcnt (task 5.5)
- **JIT call_indirect**: table lookup + type check + call via trampoline (task 5.5)

## Task Queue

Stage 5: JIT Coverage Expansion

**Target: ALL benchmarks within 3x of wasmtime (ideal: 2x).**

Current results (task 5.5): st_sieve 462ms, st_matrix 355ms, st_fib2 1738ms.
Remaining gaps vs wasmtime: st_sieve ~30x, st_matrix ~32x, st_fib2 ~2.6x.
st_sieve/matrix now JIT'd (not crashing) but still slow — needs profiling.

1. [x] 5.1: Profile shootout benchmarks + fix doCallDirectIR JIT bypass
2. [x] 5.2: Close remaining gaps (st_sieve/matrix regIR opcode coverage)
3. [x] 5.3: f64/f32 ARM64 JIT — nbody 133→60ms (2.2x speedup)
4. [x] 5.4: Re-record cross-runtime benchmarks
5. [x] 5.5: JIT memory ops + call_indirect + popcnt + reload ordering fix
6. [ ] 5.6: Profile and optimize remaining gaps
7. [ ] 5.7: Re-record benchmarks, verify exit criteria

## Current Task

5.5: COMPLETE. Added JIT codegen for global.get/set, memory.grow/fill/copy,
i32/i64.popcnt, and call_indirect (regalloc + vm + jit). Fixed critical
reload-ordering bug: reloadCallerSaved must happen AFTER emitLoadMemCache
(BLR clobbers x9-x15). st_sieve 462ms, st_matrix 355ms (were crashing).

## Previous Task

5.4: Re-record cross-runtime benchmarks — COMPLETE.
JIT'd: sieve 0.8x, nqueens 0.5x, tak 1.3x, fib 2.2x, nbody 2.7x.
Non-JIT'd gaps: st_sieve 30x, st_matrix 31x (need memory/br_table JIT).

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Zig tips: .claude/references/zig-tips.md
