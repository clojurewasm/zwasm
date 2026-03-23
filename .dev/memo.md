# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19 all complete.
- Spec: 62,263/62,263 Mac+Ubuntu+Windows (100.0%, 0 skip).
- E2E: 792/792 (Mac+Ubuntu). Real-world: 50/50.
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- Binary: 1.23MB stripped. Memory: ~3.5MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. ClojureWasm updated to v1.5.0.

## Current Task

**Performance & reliability** — Branch `perf/epoch-jit-timeout`.

W40 + W37 complete. JIT now coexists with deadline timeouts (D131) and uses
contiguous v128 storage for single-instruction SIMD load/store. Next: W39.

### Open Work Items

| Item     | Description                            |
|----------|----------------------------------------|
| ~~W37~~  | Contiguous v128 storage (DONE)          |
| W38      | Compiler-generated SIMD patterns       |
| W39      | Multi-value return JIT                 |
| Phase 18 | Lazy Compilation + CLI Extensions      |

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
- `@./.dev/checklist.md` — W37/W38 open items
- `@./.dev/decisions.md` — architectural decisions
- `@./.dev/jit-debugging.md` — JIT debug techniques
- `bench/simd_comparison.yaml` — SIMD JIT benchmark data
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
