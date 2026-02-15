# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-23, 25 — COMPLETE (Wasm 3.0 + GC + WASI P1 + Component Model + JIT Optimization)
- Source: ~38K LOC, 22 files, 360+ tests all pass
- Component Model: WIT parser, binary decoder, Canonical ABI, WASI P2 adapter, CLI support (121 CM tests)
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) + 31 GC = 523, WASI: 46/46 (100%)
- Spec: 62,018/62,271 Mac (99.6%, wasm-tools), Ubuntu 61,781/62,018. GC+EH integrated, threads 306/310, E2E: 356/356
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
- [x] 28.0: Regenerate GC spec tests with wasm-tools
- [x] 28.1: Fix spec failures (225→140): JIT FP cache, nullexnref, table init, S33 heap types, block type range
- [x] 28.2a: Spec runner `either` comparison for relaxed_simd (-32 failures)
- [x] 28.2b: Prefer pre-compiled binary for text modules in spec runner (-3 failures)
- [ ] 28.2c: Spec runner multi-module linking (linking/instance ~36 failures — deep)
- [x] 28.2d1: array_init_data/elem dropped segment bounds check (-2 failures)
- [ ] 28.2e: endianness64 x86 byte order fix (15 failures, Ubuntu SSH)
- [ ] 28.3: GC subtyping / type hierarchy (~48 failures: ref_test, type-subtyping, br_on_cast, i31, array, elem)
- [ ] 28.4: GC type canonicalization (type-equivalence 3, type-rec 2 = 5 failures)
- [x] 28.5: externref representation fix (EXTERN_TAG encoding, -18 failures: 90→72)
- [ ] 28.6: throw_ref opcode implementation (1 failure — currently returns error.Trap stub)
- [ ] 28.7: call batch state loss in spec runner (1 failure — needs_state approach regresses, needs alternative)
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

28.3: GC subtyping (remaining). Investigate elem 6, array 1 failures.

Spec baseline: Mac 55 failures (was 72). Commit gate: failure count must not increase.

Remaining 55 categorized:
- multi-module state sharing ~22: linking 14, linking3 4, imports4 2, table_grow 2, linking0 1, linking1 1
- GC type canonicalization ~16: type-subtyping 11, type-equivalence 3, type-rec 2
- elem 6, array 1, ref_test 1 (canon)
- threads 2: threads-wait_notify
- Other: call 1, instance 1

## Previous Task

28.3/28.5: GC table/elem widen + externref EXTERN_TAG encoding (103→55, -48 fixes).

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests now from main testsuite (no gc- prefix). 17 GC files + type-subtyping-invalid from external repo.

## Known Bugs

None. Mac 55 failures.
linking 14, type-subtyping 11, elem 6, linking3 4, type-equivalence 3,
imports4 2, table_grow 2, threads 2, type-rec 2,
array 1, call 1, instance 1, linking0 1, linking1 1, ref_test 1.
Ubuntu: +15 endianness64 (x86-specific).

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
