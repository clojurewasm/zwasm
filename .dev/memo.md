# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-38 — ALL COMPLETE (+ Crash Hardening + Security Audit + Error System + CI/CD)
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

Stages 0-38 — all COMPLETE. See `roadmap.md` for details.
Stage 35 note: 35.4 overnight fuzz — run `nohup bash test/fuzz/fuzz_overnight.sh > /dev/null 2>&1 &`
  then check `.dev/fuzz-overnight-result.txt` next session. Run after all stages complete (user schedules).
Stage 37 note: 37.3 SHOULD deferred (validation context diagnostics).

## Task Queue (Stage 39: Documentation & Book)

See `private/roadmap-production.md` Phase 39 for full detail.

- [x] 39.1: SSG setup: mdBook, deployed to GitHub Pages
- [x] 39.2: Getting Started (install, run first module, 5-minute guide)
- [x] 39.3: Architecture Overview (4-tier execution, decode→IR→JIT pipeline)
- [x] 39.4: Embedding Guide (Zig library usage, allocator control, error handling)
- [x] 39.5: CLI Reference (all commands, flags, examples)
- [ ] 39.6: Wasm Spec Coverage table (1.0/2.0/3.0, proposal status, spec level)
- [ ] 39.7: Security Model (threat model, WASI capabilities, sandbox boundaries)
- [ ] 39.8: Performance Guide (JIT tiers, when JIT kicks in, benchmark methodology)
- [ ] 39.9: Memory Model (linear memory, GC heap, allocator parameterization)
- [ ] 39.10: Comparison page (vs wasmtime, wasm3, wasmer — size/speed/features)
- [ ] 39.11: FAQ / Troubleshooting
- [ ] 39.12: Contributor Guide (build, test, PR process, code structure)

## Current Task

39.6: Wasm Spec Coverage table.

## Previous Task

39.5: CLI reference — all commands, run options tables, batch mode, exit codes.

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
