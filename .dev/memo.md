# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-40 — ALL COMPLETE (+ Crash Hardening → CI/CD → Book → API Stabilization)
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

Stages 0-40 — all COMPLETE. See `roadmap.md` for details.
Stage 35 note: 35.4 overnight fuzz — run `nohup bash test/fuzz/fuzz_overnight.sh > /dev/null 2>&1 &`
  then check `.dev/fuzz-overnight-result.txt` next session. Run after all stages complete (user schedules).
Stage 37 note: 37.3 SHOULD deferred (validation context diagnostics).

## Task Queue (Stage 40: API Stabilization)

See `private/roadmap-production.md` Phase 40 for full detail.

- [x] 40.1: Public API boundary: explicit list of stable types and functions
- [x] 40.2: Internal API separation: @import("zwasm") exposes only public surface
- [x] 40.3: Stability annotations in docs: stable / experimental / internal
- [x] 40.4: Versioning policy: SemVer commitment, what constitutes breaking change
- [x] 40.5: Deprecation policy: minimum 1 minor version notice before removal
- [x] 40.6: CHANGELOG.md: structured change tracking

## Current Task

Stage 40 complete — all 6 tasks done. Ready for merge gate.

## Previous Task

40.1-40.6: API boundary doc, stability annotations, SemVer policy in README, CHANGELOG.md.

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
