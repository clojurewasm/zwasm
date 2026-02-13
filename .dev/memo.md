# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-15 — COMPLETE
- Source: ~28K LOC, 18 files, 239 tests all pass
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) = 492, WASI: ~27
- Spec: 60,873/60,906 Mac (99.9%), 7 skips, E2E: 356/356, CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- WAT parser: `zwasm run file.wat`, `WasmModule.loadFromWat()`, `-Dwat=false`
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.10.0 tag).
  All dev on feature branches. Merge gate: zwasm tests + CW tests + e2e.

## Completed Stages

Stages 0-7, 5E, 5F, 8-12 — all COMPLETE. See `roadmap.md` for details.
Key results: Spec 30,715/30,715 (100%), E2E 356/356 (100%, Zig runner), 20/21 bench < 2x wasmtime.

## Task Queue

**Execution order: 13 → 14 → 15 → 16 → 17 → 18**
(x86_64 JIT → Wasm 3.0 trivial → multi-memory → relaxed SIMD
→ function references → GC)

Stages 7-12: ALL COMPLETE (see roadmap.md for details).

Stage 13: x86_64 JIT Backend

Target: x86_64 codegen, CI on ubuntu.
Architecture: separate x86.zig (encoder + Compiler), dispatch from jit.zig.
ARM64 code untouched (zero regression). Trampolines/helpers shared via import.

1. [x] 13.1: x86_64 instruction encoder (src/x86.zig) + arch dispatch skeleton
2. [x] 13.2: Comparison, control flow, shifts, division, bit ops
3. [x] 13.3: Memory operations, globals, function calls, error stubs
4. [x] 13.4: Floating-point SSE2 (f64/f32 arithmetic + conversions)
5. [x] 13.5: Ubuntu verification + benchmarks + CI

Stage 14: Wasm 3.0 — Trivial Proposals

Target: extended_const, branch_hinting, tail_call.
Three small proposals batched together (~330 LOC total).

1. [x] 14.1: Extended constant expressions (i32/i64 add/sub/mul in const exprs)
2. [x] 14.2: Branch hinting (custom section parsing, store per-function hints)
3. [x] 14.3: Tail call — return_call (0x12) bytecode interpreter
4. [x] 14.4: Tail call — return_call_indirect (0x13) bytecode interpreter
5. [x] 14.5: Tail call — predecode/regir support + spec tests

Stage 15: Wasm 3.0 — Multi-memory

Target: Multiple memories per module (~400 LOC).
All load/store/memory.* get memidx immediate. Binary format: memarg bit 6.

1. [x] 15.1: Module decoding — memarg bit 6, memidx for size/grow/fill/copy/init
2. [x] 15.2: Bytecode interpreter — memidx plumbing in load/store/memory ops
3. [x] 15.3: Predecode IR — memidx encoding in PreInstr + executeIR dispatch
4. [x] 15.4: Spec tests + cleanup

Stage 13B: Spec Test Fixes + JIT FP Completion

Target: Fix all 5 pre-existing spec test failures, implement all 24 bailed FP
opcodes on x86_64, implement 18 shared missing FP opcodes on ARM64.
Remove --allow-failures workaround from CI → zero tolerance.

Group A: Spec test failures (interpreter level, 5 failures → 0)
1. [x] A1: spectest.wasm — add missing print_f64_f64 export (fixes imports:85,86)
2. [x] A2: br_if false path — fix copy propagation fold (fixes br_if:393)
3. [x] A3: elem declarative segment — drop at instantiation (fixes elem:360)
4. [x] A4: elem imported funcref global — resolve store addr + remap (fixes elem:700)

Group B: x86_64-only JIT FP (6 opcodes, ARM64 already handles these)
5. [x] B1: f32/f64 min/max — branch-free NaN-propagating sequences (4 opcodes)
6. [x] B2: f32/f64.convert_i64_u — sign-bit branch + shift trick (2 opcodes)

Group C: Shared JIT FP (28 opcodes total, both x86_64 and ARM64)
7. [x] C1: f32/f64 copysign — ANDPS/ANDNPS/ORPS (x86), AND/ORR (ARM64)
8. [x] C2: f32/f64 ceil/floor/trunc/nearest — ROUNDSS/SD (x86), FRINTP/M/Z/N (ARM64)
9. [x] C3: i32/i64.trunc_f32/f64_s/u — NaN+boundary check + CVTT (x86), FCMP+FCVTZS/U (ARM64)

Group D: CI cleanup
10. [x] D1: Remove --allow-failures from CI

Stage 16: Wasm 3.0 — Relaxed SIMD

Target: 20 non-deterministic SIMD ops (~600 LOC).
ARM64 NEON native mapping. Implementation-defined results.

1. [x] 16.1: Opcode + interpreter — add 20 opcodes (0x100-0x113) with full vm.zig implementation
2. [x] 16.2: Spec tests + v128 invoke support — 85/85 relaxed SIMD pass, v128 batch protocol, select/branch v128 fix

Stage 17: Wasm 3.0 — Function References

Target: Typed function references, call_ref (~1200 LOC).
Prerequisite for GC. Generalized ref types, local init tracking.

New opcodes: call_ref (0x14), return_call_ref (0x15),
ref.as_non_null (0xD4), br_on_null (0xD5), br_on_non_null (0xD6).
Type system: ValType tagged union (ref/ref_null with heap type index).

1. [x] 17.1: ValType tagged union + codebase-wide compilation fix
2. [x] 17.2: Decode new ref type encoding (0x63/0x64 + heap type)
3. [x] 17.3: New instructions — call_ref, return_call_ref, ref.as_non_null
4. [x] 17.4: New instructions — br_on_null, br_on_non_null
5. [x] 17.5: Validation — local initialization tracking for non-defaultable types
6. [x] 17.6: Fix module loading, predecode, block type for typed refs
7. [x] 17.7: Spec tests + proposals.yaml update

Stage 18: Wasm 3.0 — GC

Target: Struct/array heap objects, garbage collector (~3500 LOC).
Largest proposal. Depends on Stage 17 (function_references).

1. [x] 18.1: CompositeType migration + abstract heap types
2. [x] 18.2: Type section decode — rec/sub/struct/array
3. [x] 18.3: GC heap + i31 instructions
4. [x] 18.4: Struct operations
5. [x] 18.5: Array core operations
6. [ ] 18.6: ref.eq + extern conversion
7. [ ] 18.7: Array bulk + data/elem init
8. [ ] 18.8: Subtype checking
9. [ ] 18.9: Cast operations
10. [ ] 18.10: Validation + predecode + remaining tests
11. [ ] 18.11: Spec tests cleanup + documentation

Stage 16V: Spec Test Validation Coverage

Target: 4,416 skips → 0. All tests evaluated. Pass count ~60,800.

Task Queue:
1. [x] A1: assert_exhaustion handler (15 skips → 0)
2. [x] A2: Global read actions / get command (1 skip → 0)
3. [x] A3: Named module invocations (132 skips → ~99 pass, 33 fail due to shared-state limitation)
4. [x] B1: UTF-8 validation (528 skips → 0)
5. [x] B2: Simple structural checks (~300 skips → 0)
6. [x] B3: Unknown index checks (~125 skips → 0)
7. [x] C1: WAT validation tests (1,119 skips → 0)
8. [x] D1-D5: Full type checker + section validation (~2,186 skips → 5)

## Current Task

18.6: ref.eq + extern conversion.

## Previous Task

18.5: Array core operations — array.new/new_default/new_fixed/get/get_s/get_u/set/len (8 opcodes), packed i8/i16 support.

## Wasm 3.0 Coverage

Implemented: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references (8/10 finished proposals).
NOT implemented: gc (1 proposal).
GC requires function_references (done).

## Known Bugs

None. Mac 60,873/60,906 (99.9%), 7 skips, 33 multi-module linking failures.
Note: Ubuntu Debug build has 11 extra timeouts on tail-call recursion tests (return_call/return_call_ref count/even/odd 1M iterations). Use ReleaseSafe for spec tests on Ubuntu.

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
