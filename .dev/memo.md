# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-42 — ALL COMPLETE (... → Distribution → Community Preparation)
- Source: ~38K LOC, 24 files, 510 unit tests all pass
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
- **main = stable**: CW depends on main via GitHub URL (v1.1.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.
- **Size guard**: Binary ≤ 1.5MB, Memory ≤ 4.5MB (fib RSS). Current: 1.31MB / 3.44MB.

## Completed Stages

Stages 0-42 — all COMPLETE. See `roadmap.md` for details.
Stage 35 note: 35.4 overnight fuzz — run `nohup bash test/fuzz/fuzz_overnight.sh > /dev/null 2>&1 &`
  then check `.dev/fuzz-overnight-result.txt` next session. Run after all stages complete (user schedules).
Stage 37 note: 37.3 SHOULD deferred (validation context diagnostics).

## Task Queue (Stage 46: Book i18n)

See `private/roadmap-production.md` Phase 46 for full detail.

- [x] 46.1: Directory restructure (book/src/ → book/en/src/, book/ja/src/)
- [x] 46.2: Root redirect (docs/book/index.html)
- [x] 46.3: CI update (build both languages)
- [x] 46.4: Japanese translation (all 12 chapter files)
- [x] 46.5: Language switcher (theme override)
- [x] 46.6: README update

## Current Task

Reliability improvement (branch: `strictly-check/reliability-001`).
Plan: `.dev/reliability-plan.md`. Progress: `.dev/reliability-handover.md`.
Phases A-C complete, F.3 done. W34 root cause fixed (reentry guard detection).
Next: merge to main, then D.1 (E2E failures).

## Previous Task

W34 JIT back-edge reentry bug — FIXED. Root cause: C/C++ `__wasm_call_ctors` reentry guard
traps when back-edge JIT restarts function. Fix: `hasReentryGuard()` in vm.zig detects
early branch-to-unreachable and skips back-edge JIT. 12/13 compat pass, 0 benchmark regression.

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests now from main testsuite (no gc- prefix). 17 GC files + type-subtyping-invalid from external repo.

## Known Bugs

None. W34 (back-edge JIT reentry) fixed. Mac 62,158/62,158 (100%), Ubuntu 62,158/62,158 (100%).

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
**Reliability**: .dev/reliability-plan.md (plan), .dev/reliability-handover.md (progress)
**Production roadmap**: private/roadmap-production.md (Stages 35+ detail)
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
