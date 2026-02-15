# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-23, 25 — COMPLETE (Wasm 3.0 + GC + WASI P1 + Component Model + JIT Optimization)
- Source: ~38K LOC, 22 files, 360+ tests all pass
- Component Model: WIT parser, binary decoder, Canonical ABI, WASI P2 adapter, CLI support (121 CM tests)
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) + 31 GC = 523, WASI: 46/46 (100%)
- Spec: 62,147/62,158 Mac (100.0%), 62,144/62,158 Ubuntu (100.0%, wasm-tools). GC+EH integrated, threads 310/310, E2E: 356/356
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR, lightweight self-call
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- WAT parser: `zwasm run file.wat`, `WasmModule.loadFromWat()`, `-Dwat=false`
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.2.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.
- **Size guard**: Binary ≤ 1.5MB, Memory ≤ 4.5MB (fib RSS). Current: 1.22MB / 3.57MB.

## Completed Stages

Stages 0-28 — all COMPLETE. See `roadmap.md` for details.

## Task Queue (v0.3.0)

- [x] 27.0: Ubuntu x86_64 verification of Stage 26
- [x] 27.1: Switch spec runner to ReleaseSafe default (--build flag)
- [x] 27.2: Migrate wabt → wasm-tools (docs, rules, scripts, CI, flake.nix)
- [x] 28.0: Regenerate GC spec tests with wasm-tools
- [x] 28.1: Fix spec failures (225→140): JIT FP cache, nullexnref, table init, S33 heap types, block type range
- [x] 28.2a: Spec runner `either` comparison for relaxed_simd (-32 failures)
- [x] 28.2b: Prefer pre-compiled binary for text modules in spec runner (-3 failures)
- [x] 28.2c: Spec runner multi-module linking (36→13 failures, shared-store approach)
- [x] 28.2d1: array_init_data/elem dropped segment bounds check (-2 failures)
- [x] 28.2e: endianness64 x86 JIT call arg spill fix (-15 failures on Ubuntu)
- [x] 28.3: GC subtyping / type hierarchy (type-subtyping 8 + ref_test 1 fixed, 48→40)
- [x] 28.4: GC type canonicalization (canonical IDs, matchesCallIndirectType, isTypeSubtype)
- [x] 28.5: externref representation fix (EXTERN_TAG encoding, -18 failures: 90→72)
- [x] 28.6: throw_ref opcode implementation (exnref store + re-throw)
- [x] 28.7: JIT self-call depth guard + unconditional arg spill (call:as-load-operand pre-existing)
- [x] 29.0: Thread toolchain setup (Rust wasm32-wasip1-threads + env.memory import)
- [x] 29.1: Thread test suite + spawning mechanism in zwasm
- [x] 29.2: Fix threads spec failures (310/310)
- [x] 30.0: st_matrix / tgo_mfr codegen analysis (cranelift comparison)
- [x] 30.1: Widen RegInstr to u16 regs (st_matrix func#42: u8 reg limit → interpreter fallback)
- [x] 30.2: Increase MAX_PHYS_REGS (tgo_mfr: 23 regs spill 3, eliminate hot-loop spills)
- [ ] 31.0: GC stress test suite creation
- [ ] 31.1: GC benchmark (zwasm vs wasmtime vs node)
- [ ] 31.2: GC collector improvement decision

## Current Task

31.0: GC stress test suite creation.

## Previous Task

30.2: Increased ARM64 MAX_PHYS_REGS 20→23 (vreg 20→x0, 21→x1, 22→x17). tgo_mfr gap: 1.55x→1.03x vs wasmtime. tgo_list: 57→34ms.

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests now from main testsuite (no gc- prefix). 17 GC files + type-subtyping-invalid from external repo.

## Known Bugs

None. Mac 11 failures, Ubuntu TBD (ReleaseSafe via --build).
Mac: type-subtyping 4, imports4 2, type-rec 2,
call 1, instance 1, table_grow 1.
Ubuntu: TBD (needs verification after thread changes).

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
