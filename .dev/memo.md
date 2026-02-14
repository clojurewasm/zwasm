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

Final gap analysis (Stage 23 complete vs wasmtime 41.0.1):
- 3.0x: st_matrix (memory-bound, i32.load dominates, needs address mode folding)
- 1.9x: st_fib2 (deep recursion, prologue/epilogue overhead)
- 1.7x: fib (prologue overhead — 6 STP/LDP unconditional)
- 1.7x: tgo_mfr (memory + loop patterns)
- 1.6x: tgo_fib (recursive int, same as fib)
- 1.1x: tak, st_sieve, tgo_strops, tgo_nqueens (near parity)
- <1x: 12/21 benchmarks faster than wasmtime (nbody 0.4x, st_nestedloop 0.4x, etc.)

Root causes for remaining gaps:
1. Recursive overhead: unconditional 6 STP/LDP prologue saves all 12 callee-saved regs
2. Memory-bound: no address mode folding (base+offset in 1 instr)
3. reg_ptr bookkeeping: ldr+str per self-call (value cached in x27, addr in regs[reg_count])
Future: register-based calling convention, address mode folding, adaptive prologue.

ROI-ordered task list:

1. [x] 23.1: Liveness-aware spill/reload — only spill live regs on call sites
2. [x] 23.2: Guard pages for bounds check elimination — mmap 8GB + PROT_NONE + signal handler
3. [x] 23.3: Call overhead reduction — fast-path base case, prologue load elimination
4. [x] 23.4: FP register file — keep f64/f32 in D-registers, eliminate GPR↔FPR round-trips
5. [x] 23.5: Measure & tune — reg_ptr caching, gap analysis, benchmark recording

## Current Task

Stage 23 complete. Ready for merge to main.

## Previous Task

23.5: Measure & tune — reg_ptr value caching (x27=VALUE, addr cached in regs[reg_count]). Self-call BL-after 3→1 instr, 2→0 mem. Final: 13/21 benchmarks at or faster than wasmtime. nbody 4.9x speedup from v0.2.0.

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
