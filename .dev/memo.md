# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-42 — ALL COMPLETE (... → Distribution → Community Preparation)
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

Stages 0-42 — all COMPLETE. See `roadmap.md` for details.
Stage 35 note: 35.4 overnight fuzz — run `nohup bash test/fuzz/fuzz_overnight.sh > /dev/null 2>&1 &`
  then check `.dev/fuzz-overnight-result.txt` next session. Run after all stages complete (user schedules).
Stage 37 note: 37.3 SHOULD deferred (validation context diagnostics).

## Task Queue (Stage 43: v1.0.0 Release)

See `private/roadmap-production.md` Phase 43 for full detail.

- [x] 43.1: Test suite pass: unit (425) + spec (62,158) + E2E (356) — PASS. Fuzz 24h deferred (user schedules).
- [x] 43.2: Security audit: Phase 36 complete (SECURITY.md, docs/security.md, docs/audit-36.md)
- [x] 43.3: Documentation: Phase 39 complete (12-chapter book, API boundary, embedding guide)
- [x] 43.4: Cross-platform: Ubuntu unit tests PASS, spec 62,158/62,158 (100%). Bench timeout (known hyperfine issue, not a bug).
- [x] 43.5: Performance baseline recorded (v1.0.0-baseline, 23 benchmarks)
- [x] 43.6: Binary audit: 1.28MB, no debug symbols, no secrets in ReleaseSafe
- [x] 43.7: CHANGELOG updated for v1.0.0
- [ ] 43.8: Tag v1.0.0 + publish — awaiting: fuzz results + user approval

## Current Task

44.GC: Complete. All 4 phases done. Merge gate next.

## Previous Task

44.GC Phase 4: WAT validation hardening — recursion depth limit (1000), 8 validation tests for malformed WAT input.

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
