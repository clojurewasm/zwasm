# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-23, 25 — COMPLETE (Wasm 3.0 + GC + WASI P1 + Component Model + JIT Optimization)
- Source: ~38K LOC, 22 files, 360+ tests all pass
- Component Model: WIT parser, binary decoder, Canonical ABI, WASI P2 adapter, CLI support (121 CM tests)
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) + 31 GC = 523, WASI: 46/46 (100%)
- Spec: 61,639/61,761 Mac (99.8%), 61,633/61,761 Ubuntu (99.8%), incl. GC 472/546, threads 306/310, E2E: 356/356
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR, lightweight self-call
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- WAT parser: `zwasm run file.wat`, `WasmModule.loadFromWat()`, `-Dwat=false`
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.2.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.
- **Size guard**: Binary ≤ 1.5MB, Memory ≤ 4.5MB (fib RSS). Current: 1.1MB / 3.3MB.

## Completed Stages

Stages 0-23, 25 — all COMPLETE. See `roadmap.md` for details.

## Task Queue

- [x] 26.0: Remove wasmer from benchmark infrastructure
- [x] 26.1: CMP+B.cond fusion (ARM64) — RegIR look-ahead in emitCmp32/emitCmp64
- [ ] 26.2: CMP+Jcc fusion (x86_64) — same pattern for x86 backend
- [ ] 26.3: Redundant MOV elimination — copy propagation tracking during emission
- [ ] 26.4: Constant materialization — MVN for -1, MOVN for negatives
- [ ] 26.5: Benchmark + evaluate + record

## Current Task

26.2: CMP+Jcc fusion (x86_64) — same pattern as ARM64 26.1 but for x86 backend.

## Previous Task

26.1: CMP+B.cond fusion (ARM64). Added tryFuseBranch + emitCmpResult to emitCmp32/emitCmp64/emitCmpImm32/eqz. Saves 1 insn per compare-and-branch.

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests via wasm-tools 1.244.0: 472/546 (86.4%), 18 files. W21 resolved.

## Known Bugs

None. Mac 61,639/61,761 (99.8%), Ubuntu 61,633/61,761 (99.8%).
4 thread-dependent failures (require real threading), 32 GC skips, 33 multi-module linking failures.
Ubuntu: +15 endianness64 (x86-specific), +2 call (cross-module linking).
Note: Ubuntu Debug build has 11 extra timeouts on tail-call recursion tests. Use ReleaseSafe for spec tests on Ubuntu.

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
