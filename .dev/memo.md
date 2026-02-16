# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-36 — ALL COMPLETE (+ Crash Hardening + Security Audit)
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

Stages 0-36 — all COMPLETE. See `roadmap.md` for details.
Stage 35 note: 35.4 24h fuzz campaign deferred as overnight background task.

## Task Queue (Stage 37: Error System Maturity)

See `private/roadmap-production.md` Phase 37 for full detail.

- [x] 37.1: Catalog all error types returned from public API (load, invoke, validate)
- [x] 37.2: CLI error formatting: human-readable messages with context (file, section, offset)
- [ ] 37.3: Validation error messages: spec-quality diagnostics (SHOULD — deferred, current messages actionable)
- [x] 37.4: Trap messages: clear distinction between trap types (unreachable, OOB, stack overflow, etc.)
- [x] 37.5: Library API error documentation: document every error enum variant (docs/errors.md)

## Current Task

Stage 37 complete (37.3 SHOULD deferred). Ready for merge.

## Previous Task

37.4-37.5: Trap messages already in formatWasmError (10 trap types with "trap:" prefix). Error docs in docs/errors.md from 37.1.

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
