# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-18 — COMPLETE (Wasm 3.0 all 9 proposals)
- Source: ~32K LOC, 19 files, 239 tests all pass
- Opcode: 236 core + 256 SIMD (236 + 20 relaxed) + 31 GC = 523, WASI: ~27
- Spec: 61,344/61,451 Mac (99.8%), incl. GC 472/546, E2E: 356/356, CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- WAT parser: `zwasm run file.wat`, `WasmModule.loadFromWat()`, `-Dwat=false`
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.1.0 tag).
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
6. [x] 18.6: ref.eq + extern conversion
7. [x] 18.7: Array bulk + data/elem init
8. [x] 18.8: Subtype checking
9. [x] 18.9: Cast operations
10. [x] 18.10: Validation + predecode + remaining tests
11. [x] 18.11: Spec tests cleanup + documentation

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

Stage 19: Post-GC Improvements

Target: GC spec tests (W21), table.init修正 (W2), GC collector (W20), WASI P1全対応 (W4/W5).
~1,490 LOC, 14 tasks. 詳細設計: `.claude/plans/groovy-sprouting-horizon.md`

Group A: GC Spec Tests (wasm-tools 1.244.0で828 assertions変換)
1. [x] A1: convert.shにwasm-tools対応
2. [x] A2: run_spec.pyのGC ref型対応(value無しref, ref_anyマッチ)
3. [x] A3: GC spec実行 + パスカウント記録 — 472/546 (86.4%)

Group B: table.init修正 — RESOLVED
4. [x] B1: Already fixed in cdb0c10. spec table_init 729/729 + table_init64 819/819 = 1,548/1,548 (100%)

Group C: GC Collector — compact無しmark-and-sweep
5. [x] C1: GcSlot + free list (GcObject wrapping, alloc再利用)
6. [x] C2: Markフェーズ (ルートスキャン + BFS)
7. [x] C3: Sweepフェーズ (未到達解放 + free list追加)
8. [x] C4: VM統合 (threshold trigger, D115)

Group D: WASI P1 Full Support (~27/35 → 35/35)
9.  [x] D1: FdTable拡張 + path_open (最重要、250 LOC)
10. [x] D2: fd_readdir (directory iteration)
11. [ ] D3: fd_renumber + path_symlink + path_link
12. [ ] D4: stub関数実装 (fd_fdstat_set_flags, *_set_times, path_filestat_get)
13. [ ] D5: poll_oneoff簡易版 (CLOCKのみ)
14. [ ] D6: sock_* + 残り (NOSYS stub)

## Current Task

D3: fd_renumber + path_symlink + path_link

## Previous Task

D2: fd_readdir — full directory iteration via std.fs.Dir.iterate(). Writes WASI dirent entries (d_next, d_ino, d_namlen, d_type + name) to buffer. Cookie-based pagination. wasiFiletype helper for Entry.Kind → Filetype. Test verifies non-empty output for temp directory.

C1: GcSlot + free list. GcObject→GcSlot migration, intrusive free list, freeSlot/mark/clearMarks/sweep API.

## v0.1.0 Tag Replace Queue

Stage 19 is paused. Tag replace takes priority.

Phase 1: zwasm docs + full bench
- [x] 1.1: Full benchmark (`bash bench/record.sh --id="v0.1.0-pre" --reason="Pre-v0.1.0 full benchmark"`)
- [x] 1.2: Code comments + YAML cleanup (bench history tag→commit, proposals.yaml, spec-support.md)
- [x] 1.3: Public docs overhaul (README.md: Wasm coverage table, benchmarks, usage guide with docs/usage.md)
- [x] 1.4: Commit docs

Phase 2: zwasm tag operations (do in one session)
- [x] 2.1: Delete old v0.1.0 tag + release
- [x] 2.2: Replace tag refs in bench history (done in 1.2)
- [x] 2.3: Update build.zig.zon version to 0.1.0, commit, push
- [x] 2.4: CI green (bd2c852)
- [x] 2.5: Create new v0.1.0 tag, push

Phase 3: CW dependency + docs (CW repo)
- [x] 3.1: Switch CW build.zig.zon to zwasm v0.1.0 tar.gz
- [x] 3.2: Full benchmark + record
- [x] 3.3: Code comments + YAML cleanup (-alpha refs → v0.1.0)
- [x] 3.4: Public docs overhaul
- [x] 3.5: Commit, push, CI green

Phase 4: CW tag operations (do in one session, CW repo)
- [x] 4.1: Delete old -alpha tags + releases
- [x] 4.2: Create CW v0.1.0 tag, push

Phase 5: Cleanup old zwasm tags (zwasm repo)
- [x] 5.1: Delete all zwasm tags except v0.1.0
- [x] 5.2: Final verification (both repos: only v0.1.0 tag, tests pass, docs clean)

## Previous Task

v0.1.0 tag replace complete (2026-02-13): zwasm+CW both have only v0.1.0 tag.
Docs overhauled, benchmarks recorded, CI green on both repos.

## Wasm 3.0 Coverage

All 9 proposals complete: memory64, exception_handling, tail_call, extended_const, branch_hinting, multi_memory, relaxed_simd, function_references, gc.
GC spec tests via wasm-tools 1.244.0: 472/546 (86.4%), 18 files. W21 resolved.

## Known Bugs

None. Mac 61,344/61,451 (99.8%), 32 GC skips, 33 multi-module linking failures.
Note: Ubuntu Debug build has 11 extra timeouts on tail-call recursion tests (return_call/return_call_ref count/even/odd 1M iterations). Use ReleaseSafe for spec tests on Ubuntu.

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
