# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4 — COMPLETE
- Source: ~15K LOC, 16 files, 148 tests all pass
- Opcode: 225 core + 236 SIMD = 461, WASI: ~27
- Spec: 30,665/30,703 (99.9%), E2E: 178/181 (98.3%), CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.1.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.

## Task Queue

Stage 5E: E2E Test Porting & Compliance (correctness phase before optimization)

1. [x] 5E.1: Infrastructure — compliance.yaml, e2e scripts, run_spec.py --dir
2. [x] 5E.2: Batch 1 — Core MVP & Traps (25 files, 78/87 pass)
3. [x] 5E.3: Batch 2 — Float & Reference Types (15 files, all pass)
4. [x] 5E.4: Batch 3 — Programs & Regressions (14 files, all pass)
5. [x] 5E.5: Batch 4 — SIMD (14 files, all pass)
6. [x] 5E.6: Final compliance update

Stage 5 (resumed after 5E): JIT Coverage Expansion

**Target: ALL benchmarks within 2x of wasmtime (ideal: 1x).**

Current results (task 5.5, from bench/history.yaml):
st_sieve 462ms, st_matrix 355ms, st_fib2 1738ms, fib 105ms, nbody 58ms.
Gaps vs wasmtime (from bench/runtime_comparison.yaml):
st_matrix ~3.8x, st_fib2 ~2.3x, nbody ~2.4x, fib ~2.0x, st_sieve ~2.1x.
st_nestedloop and st_ackermann at parity (≤1.1x).

1. [x] 5.1: Profile shootout benchmarks + fix doCallDirectIR JIT bypass
2. [x] 5.2: Close remaining gaps (st_sieve/matrix regIR opcode coverage)
3. [x] 5.3: f64/f32 ARM64 JIT — nbody 133→60ms (2.2x speedup)
4. [x] 5.4: Re-record cross-runtime benchmarks
5. [x] 5.5: JIT memory ops + call_indirect + popcnt + reload ordering fix
6. [ ] 5.6: Profile and optimize remaining gaps
7. [ ] 5.7: Re-record benchmarks, verify exit criteria

## Current Task

5.6: Profile and optimize remaining gaps

**Sub-task A: Copy propagation in regalloc**
Problem: regIR generates many redundant MOV instructions (~24% of all instrs).
Pattern: `op rTEMP = ...; mov rLOCAL = rTEMP` → fold to `op rLOCAL = ...`.
Approach: O(n) post-pass in regalloc.zig convert(). For each adjacent pair,
if code[i+1] is MOV, code[i].rd == code[i+1].rs1, and code[i].rd >= local_count
(temp, used once), fold: set code[i].rd = code[i+1].rd, delete code[i+1].
Key files: src/regalloc.zig

## Previous Task

JIT void self-call fix: emitInlineSelfCall unconditionally copied callee result,
corrupting caller regs for void functions. nqueens(8) now returns 92 (was 0).
Added result_count plumbing through compileFunction chain.

## Known Bugs

See MEMORY.md § Active Bugs

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
