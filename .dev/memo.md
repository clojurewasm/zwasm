# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-2, 4, 7-12 — COMPLETE
- Source: ~24K LOC, 16 files, 209 tests all pass
- Opcode: 234 core + 236 SIMD = 470, WASI: ~27
- Spec: 30,715/30,715 (100%), E2E: 356/356 (100%, Zig runner), CI: ubuntu + macOS
- Benchmarks: 3 layers (WAT 5, TinyGo 11, Shootout 5 = 21 total)
- Register IR + ARM64 JIT: full arithmetic/control/FP/memory/call_indirect
- JIT optimizations: fast path, inline self-call, smart spill, doCallDirectIR
- Embedder API: Vm type, inspectImportFunctions, WasmModule.loadWithImports
- WAT parser: `zwasm run file.wat`, `WasmModule.loadFromWat()`, `-Dwat=false`
- Debug trace: --trace, --dump-regir, --dump-jit (zero-cost when disabled)
- Library consumer: ClojureWasm (uses zwasm as zig dependency)
- **main = stable**: CW depends on main via GitHub URL (v0.7.0 tag).
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

- extended_const: allow i32/i64 add/sub/mul in const exprs (trivial, ~50 LOC)
- branch_hinting: custom section parsing, advisory hints (trivial, ~80 LOC)
- tail_call: return_call, return_call_indirect (medium, ~200 LOC)

(Task breakdown TBD.)

Stage 15: Wasm 3.0 — Multi-memory

Target: Multiple memories per module (~400 LOC).
All load/store/memory.* get memidx immediate. Binary format: memarg bit 6.

(Task breakdown TBD.)

Stage 16: Wasm 3.0 — Relaxed SIMD

Target: 20 non-deterministic SIMD ops (~600 LOC).
ARM64 NEON native mapping. Implementation-defined results.

(Task breakdown TBD.)

Stage 17: Wasm 3.0 — Function References

Target: Typed function references, call_ref (~800 LOC).
Prerequisite for GC. Generalized ref types, local init tracking.

(Task breakdown TBD.)

Stage 18: Wasm 3.0 — GC

Target: Struct/array heap objects, garbage collector (~3000 LOC).
Largest proposal. Depends on Stage 17 (function_references).

(Task breakdown TBD.)

## Current Task

Stage 13 complete. Next: Stage 14 (Wasm 3.0 Trivial Proposals) — task breakdown TBD.

## Previous Task

13.5: Ubuntu verification + benchmarks + CI for x86_64 JIT.

## Wasm 3.0 Coverage

Implemented: memory64, exception_handling (2/10 finished proposals).
NOT implemented: tail_call, extended_const, function_references, gc, multi_memory,
relaxed_simd, branch_hinting (7 proposals, see proposals.yaml).
GC requires function_references first. Stages 9-10 (wide_arithmetic, custom_page_sizes)
are Phase 3, not yet ratified as Wasm 3.0.

## Known Bugs

None.

## References

.dev/ docs: roadmap.md, decisions.md, checklist.md, spec-support.md,
bench-strategy.md, profile-analysis.md, jit-debugging.md, references/wasm-spec.md
Proposals: .dev/status/proposals.yaml, .dev/references/proposals/, .dev/references/repo-catalog.yaml
Ubuntu x86_64: .dev/ubuntu-x86_64.md (gitignored — SSH commands, tools, JIT debug)
External: wasmtime (~/Documents/OSS/wasmtime/), zware (~/Documents/OSS/zware/)
Spec repos: ~/Documents/OSS/WebAssembly/ (16 repos — see repo-catalog.yaml)
Zig tips: .claude/references/zig-tips.md
