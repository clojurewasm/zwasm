# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-22 — COMPLETE (Wasm 3.0 + GC + WASI P1 + Component Model)
- Source: ~38K LOC, 22 files, 360+ tests all pass
- Component Model: WIT parser, binary decoder, Canonical ABI, WASI P2 adapter, CLI support (121 CM tests)
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) + 31 GC = 523, WASI: 46/46 (100%)
- Spec: 61,650/61,761 Mac (99.8%), incl. GC 472/546, threads 306/310, E2E: 356/356, CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- WAT parser: `zwasm run file.wat`, `WasmModule.loadFromWat()`, `-Dwat=false`
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.2.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.
- **Size guard**: Binary ≤ 1.5MB, Memory ≤ 4.5MB (fib RSS). Current: 1.1MB / 3.3MB.

## Completed Stages

Stages 0-22 — all COMPLETE. See `roadmap.md` for details.

## Task Queue

Stage 23: JIT Optimization — wasmtime parity

Target: Close performance gap to wasmtime 1x across all 21 benchmarks.
Constraints: Binary ≤ 1.5MB, memory ≤ 4.5MB (fib RSS).

Gap analysis (v0.2.0 vs wasmtime 41.0.1):
- 3.3x: st_matrix (array ops, bounds check overhead)
- 2.1x: tgo_mfr (map/filter/reduce, memory patterns)
- 2.0x: nbody (f64 heavy, no FMADD, GPR↔FPR round-trips)
- 2.0x: st_fib2 (deep recursion, call overhead)
- 1.8x: fib, st_nestedloop, tgo_fib (recursive/loop int)
- 1.4x: tak (deep recursion)
- ≤1.2x: 7 benchmarks near parity
- <1x: 7 benchmarks already faster than wasmtime

ROI-ordered task list:

1. [x] 23.1: Liveness-aware spill/reload — only spill live regs on call sites
2. [ ] 23.2: Loop bounds check hoisting — prove memory safety at loop entry, elide inner checks
3. [ ] 23.3: Address calculation optimization — strength reduction, scaled offset addressing
4. [ ] 23.4: FP register file — keep f64/f32 in D-registers, eliminate GPR↔FPR round-trips
5. [ ] 23.5: Measure & tune — re-benchmark, profile remaining gaps, targeted fixes

## Current Task

23.2: Loop bounds check hoisting — prove memory safety at loop entry, elide inner checks.

## Previous Task

23.1: Liveness-aware spill/reload — forward-scan liveness analysis at call sites (ARM64+x86).

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests via wasm-tools 1.244.0: 472/546 (86.4%), 18 files. W21 resolved.

## Known Bugs

None. Mac 61,650/61,761 (99.8%), 4 thread-dependent failures (require real threading), 32 GC skips, 33 multi-module linking failures.
Note: Ubuntu Debug build has 11 extra timeouts on tail-call recursion tests (return_call/return_call_ref count/even/odd 1M iterations). Use ReleaseSafe for spec tests on Ubuntu.

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
