# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-34 — ALL COMPLETE (Wasm 3.0 + GC + WASI P1 + CM + JIT + Fuzz + TypeRegistry)
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

Stages 0-34 — all COMPLETE. See `roadmap.md` for details.

## Task Queue (Stage 35: Crash Hardening)

See `private/roadmap-production.md` Phase 35 for full detail.

- [x] 35.1: Expand fuzz corpus with wasm-tools smith-generated modules (1000+)
- [x] 35.2: Structure-aware fuzzing: valid-but-tricky module generator
- [ ] 35.3: Phase-separate fuzzing: decoder, validator, predecode, regalloc as independent targets
- [ ] 35.4: Extended fuzz campaign: 24h+ continuous run, 0 crashes
- [ ] 35.5: Audit all `unreachable` in non-test paths — convert to error returns or prove unreachability
- [ ] 35.6: Audit all `@intCast` — verify no negative-value panics
- [ ] 35.7: Resource limit enforcement: nesting depth, section count, type count

## Current Task

35.3: Phase-separate fuzzing — decoder, validator, predecode, regalloc as independent targets.

## Previous Task

35.2: Structure-aware fuzzing — fuzz_gen.zig with 8 generators (deep nesting, many locals, unreachable code, many types/functions, br_table, memory boundary, if/else chain). All parameterized, run through full pipeline.

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
