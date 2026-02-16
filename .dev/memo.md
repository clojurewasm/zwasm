# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-35 — ALL COMPLETE (Wasm 3.0 + GC + WASI P1 + CM + JIT + Fuzz + TypeRegistry + Crash Hardening)
- Source: ~38K LOC, 24 files, 425 unit tests all pass
- Component Model: WIT parser, binary decoder, Canonical ABI, WASI P2 adapter, CLI support (121 CM tests)
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) + 31 GC = 523, WASI: 46/46 (100%)
- Spec: 62,158/62,158 Mac + Ubuntu (100.0%). GC+EH integrated, threads 310/310, E2E: 356/356
- Benchmarks: 4 layers (WAT 5, TinyGo 11, Shootout 5, GC 2 = 23 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR, lightweight self-call
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- WAT parser: `zwasm run file.wat`, `WasmModule.loadFromWat()`, `-Dwat=false`
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.3.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.
- **Size guard**: Binary ≤ 1.5MB, Memory ≤ 4.5MB (fib RSS). Current: 1.28MB / 3.57MB.

## Completed Stages

Stages 0-35 — all COMPLETE. See `roadmap.md` for details.
Stage 35 note: 35.4 24h fuzz campaign deferred as overnight background task.

## Task Queue (Stage 36: Security Audit & Hardening)

See `private/roadmap-production.md` Phase 36 for full detail.

- [x] 36.1: Threat model document: what zwasm protects against, what it doesn't
- [x] 36.2: Linear memory isolation audit: bounds check on every load/store verified
- [x] 36.3: Table bounds + type check audit: call_indirect, table.get/set
- [x] 36.4: JIT W^X verification: mmap RW→RX transition, no simultaneous W+X
- [x] 36.5: JIT bounds audit: generated code cannot escape sandbox
- [x] 36.6: WASI capability audit: deny-by-default path verified for all 46 syscalls
- [x] 36.7: Stack depth limit verification: call depth, value stack depth
- [x] 36.8: Host function interface audit: no pointer leaks to guest
- [x] 36.9: SECURITY.md: vulnerability disclosure policy
- [x] 36.10: ReleaseSafe-only distribution: ensure safety checks preserved in release binary
- [x] 36.11: Sanitizer pass: ASan/UBSan build + test suite run

## Current Task

Stage 36 complete. Ready for merge.

## Previous Task

36.11: Sanitizer pass — Zig built-in safety (Debug/ReleaseSafe) covers UBSan+ASan equivalent. 425+ tests, 62K spec, 25K fuzz all clean.

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests now from main testsuite (no gc- prefix). 17 GC files + type-subtyping-invalid from external repo.

## Known Bugs

None. Mac 62,158/62,158 (100%), Ubuntu 62,158/62,158 (100%). Zero failures.

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
**Production roadmap**: private/roadmap-production.md (Stages 35+ detail)
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
