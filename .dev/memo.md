# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-23, 25 — COMPLETE (Wasm 3.0 + GC + WASI P1 + Component Model + JIT Optimization)
- Source: ~38K LOC, 22 files, 360+ tests all pass
- Component Model: WIT parser, binary decoder, Canonical ABI, WASI P2 adapter, CLI support (121 CM tests)
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) + 31 GC = 523, WASI: 46/46 (100%)
- Spec: 61,787/62,018 Mac (99.6%, wasm-tools), Ubuntu pending re-run. GC 472/546, threads 306/310, E2E: 356/356
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

Stages 0-26 — all COMPLETE. See `roadmap.md` for details.

## Task Queue (v0.3.0)

- [x] 27.0: Ubuntu x86_64 verification of Stage 26
- [x] 27.1: Switch spec runner to ReleaseSafe default (--build flag)
- [x] 27.2: Migrate wabt → wasm-tools (docs, rules, scripts, CI, flake.nix)
- [ ] 28.0: Regenerate GC spec tests with wasm-tools
- [ ] 28.1: Investigate multi-module 33 failures (check history for regressions)
- [ ] 29.0: Thread toolchain setup (Emscripten or Rust wasm32-wasip1-threads)
- [ ] 29.1: Thread test suite + spawning mechanism in zwasm
- [ ] 29.2: Fix threads spec 4 failures
- [ ] 30.0: st_matrix / tgo_mfr codegen analysis (cranelift comparison)
- [ ] 30.1: st_matrix improvement (MAX_PHYS_REGS expansion or other single-pass approach)
- [ ] 30.2: tgo_mfr improvement (loop optimization within single-pass)
- [ ] 31.0: GC stress test suite creation
- [ ] 31.1: GC benchmark (zwasm vs wasmtime vs node)
- [ ] 31.2: GC collector improvement decision

## Current Task

28.0: Regenerate GC spec tests with wasm-tools.

## Previous Task

27.2: Migrated wabt → wasm-tools. Spec total: 61,787/62,018 (+148 passes, +257 test cases). Added exnref to spec runner ref_types.

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests via wasm-tools 1.244.0: 472/546 (86.4%), 18 files. W21 resolved.

## Known Bugs

None. Mac 61,787/62,018 (99.6% with wasm-tools — more tests now converted).
231 failures: ref_null 28, gc-br_on_cast_fail 21, type-subtyping 17, linking 16,
instance 12, relaxed_* 26, call_indirect 11, GC ~66, threads 4, other.
Ubuntu: +15 endianness64 (x86-specific), +2 call (cross-module linking).
Tail-call timeouts eliminated by ReleaseSafe default (27.1).

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
