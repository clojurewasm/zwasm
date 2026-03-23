# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 11, 13, 15, **19** complete.
- Spec: 62,263/62,263 Mac+Ubuntu+Windows (100.0%, 0 skip). E2E: 792/792 (Mac), 773/792 (Ubuntu). Real-world: 50/50.
- Wasm 3.0: all 9 proposals. WASI: 46/46 (100%). WAT parser complete.
- JIT: Register IR + ARM64/x86_64 + **SIMD (NEON 253/256, SSE 244/256)**.
- **C API**: c_allocator + ReleaseSafe default (#11 fix). 64-test FFI suite.
- **CLI**: `--interp` flag for interpreter-only execution (Phase 19 debug tool).
- **main = stable**. ClojureWasm updated to v1.5.0. Phase 13 merged 2026-03-23.

## Current Task

**Fix: x86_64 wide-arithmetic E2E failures** — 19 tests fail on Ubuntu x86_64.

Pre-existing on main (not a Phase 13 regression). Symptoms:
- Line 3: decode error (Overflow)
- Lines 69+: assert_return mismatches — values doubled (1→2), inverted (0xFFFF→0x0)
- Likely x86_64 JIT codegen bug for wide-arithmetic operations (i64.mul_wide_s/u etc.)

### Remaining Workarounds

| Workaround              | Status | Plan                       |
|--------------------------|--------|----------------------------|
| jitSuppressed(deadline) | Active | Epoch-based check (future) |

## Phase 13 Summary (completed 2026-03-23)

- **SIMD JIT**: ARM64 NEON 253/256 native, x86 SSE 244/256 native
- **Benchmarks**: image_blend 4.7x, matrix_mul 1.6x (beats wasmtime!), byte_search 1.2x
- **Real-world C -msimd128**: 5 benchmarks, box_blur 1.4x, sum_reduce 1.1x SIMD win
- **Future**: W37 (contiguous v128), W38 (compiler patterns). See checklist.

## Handover Notes

### W35/W36 (resolved, 2026-03-22)
- W35: ARM64 JIT `emitGlobalSet` ABI clobber + `--interp` + `i32.store16`. Commit 1429f81.
- W36: Was W35 side-effect. 3 consecutive 50/50 PASS after W35 merge.

## References

- `@./.dev/roadmap.md` — Phase roadmap
- `@./.dev/checklist.md` — W37/W38 open items
- `@./.dev/decisions.md` — architectural decisions
- `@./.dev/jit-debugging.md` — JIT debug techniques
- `bench/simd_comparison.yaml` — SIMD JIT benchmark data
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
