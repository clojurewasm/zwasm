# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19 all complete.
- Spec: 62,263/62,263 Mac+Ubuntu+Windows (100.0%, 0 skip).
- E2E: 792/792 (Mac+Ubuntu). Real-world: 50/50.
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- Binary: 1.29MB stripped. Memory: ~3.5MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. ClojureWasm updated to v1.5.0.

## Current Task

**W38 investigation** — on branch `perf/w38-simd-compiler-patterns`.

ARM64 JIT v128 sync fix committed: MOV copies simd_v128, CONST clears it.
Reentry guard OSR attempted but blocked by v128 state transfer issues.

### Investigation Summary

Root cause of 13-131x gap: C-compiled functions have reentry guards that
prevent JIT. Hot loops run entirely in register IR interpreter.
OSR (On-Stack Replacement) can bypass guards but SIMD v128 state doesn't
transfer correctly from interpreter to JIT for complex C functions.

### Open Work Items

| Item     | Description                          | Status       |
|----------|--------------------------------------|--------------|
| W38      | Compiler-generated SIMD patterns     | Investigated |
| Phase 18 | Lazy Compilation + CLI Extensions    | Not started  |

## Completed Phases (summary)

| Phase | Name                                  | Date       |
|-------|---------------------------------------|------------|
| 1     | Guard Pages + Module Cache            | 2026-03    |
| 3     | CI Automation + Documentation         | 2026-03    |
| 5     | C API + Conditional Compilation       | 2026-03    |
| 8     | Real-World Coverage + WAT Parity      | 2026-03    |
| 10    | Quality / Stabilization               | 2026-03    |
| 11    | Allocator Injection + Embedding       | 2026-03    |
| 13    | SIMD JIT (NEON + SSE)                 | 2026-03-23 |
| 15    | Windows Port                          | 2026-03    |
| 19    | JIT Reliability                       | 2026-03    |

## References

- `@./.dev/roadmap.md` — Phase roadmap
- `@./.dev/checklist.md` — W38 details (investigation steps, benchmarks, sources)
- `@./.dev/decisions.md` — architectural decisions (D131: epoch JIT timeout)
- `@./.dev/jit-debugging.md` — JIT debug techniques
- `bench/simd_comparison.yaml` — SIMD performance data (3 layers: baseline → post-opt → JIT)
- `bench/simd/src/` — C source for compiler-generated SIMD benchmarks
- `bench/run_simd_bench.sh` — SIMD microbenchmark runner
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
