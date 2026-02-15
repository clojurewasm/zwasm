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

28.2 investigation complete. Mac: 103 failures (was 140). Fixed: 37 total.
Spec baseline: Mac 103 failures. Commit gate: failure count must not increase.

Remaining 103 categorized:
- linking/instance/imports4 36: multi-module state sharing (spec runner)
- GC subtyping ~48: type hierarchy checks (ref_test, type-subtyping, etc.)
- threads 4: need thread spawning
- table_grow 2: multi-module
- extern 1: externref(0) vs null conflation
- throw_ref 1: unimplemented opcode
- call 1: batch process state loss
- ref_is_null 1: externref table
- type-equivalence 3, type-rec 2: GC type canonicalization

## Previous Task

28.2: Spec failure reduction (140→103, -37 fixes): either v128 comparison, binary_filename preference, array_init dropped segment check.

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests now from main testsuite (no gc- prefix). 17 GC files + type-subtyping-invalid from external repo.

## Known Bugs

None. Mac 62,055/62,158 (99.8%).
103 failures: linking 16+6, instance 12, type-subtyping 11, ref_test 11,
array 7, i31 6, elem 6, array_new_elem 5, linking3 4,
type-equivalence 3, br_on_cast 2, br_on_cast_fail 2, imports4 2, ref_cast 2,
table_grow 2, type-rec 2, call 1, extern 1, loop 0→1?, ref_is_null 1, throw_ref 1, threads 4.
Ubuntu: +15 endianness64 (x86-specific).

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
