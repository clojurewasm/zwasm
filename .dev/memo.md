# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 11, 15, **19** complete. **v1.6.0+** (main 2be62cd).
- Spec: 62,263/62,263 Mac+Ubuntu+Windows (100.0%, 0 skip). E2E: 792/792. Real-world: 50/50.
- Wasm 3.0: all 9 proposals. WASI: 46/46 (100%). WAT parser complete.
- JIT: Register IR + ARM64/x86_64. Fuel check at back-edges (Phase 19.2).
- **C API**: c_allocator + ReleaseSafe default (#11 fix). 64-test FFI suite.
- **CLI**: `--interp` flag for interpreter-only execution (Phase 19 debug tool).
- **main = stable**. ClojureWasm updated to v1.5.0.

## Current Task

**Phase 13: SIMD JIT** — Branch `phase13/simd-jit`. Decision D130.

### Status

- **13.0-13.2 DONE**: RegIR SIMD adapter, v128 split storage, JIT trampoline
- **13.2+ DONE — ARM64 NEON**: **253/256 native (98.8%)**
  - All arithmetic, comparisons, shifts, extend/narrow, extmul, convert, rounding
  - All lane/load/store ops, shuffle (TBL), bitselect, swizzle, bitmask, any/all_true
  - Relaxed: madd/nmadd (FMLA/FMLS), laneselect (BSL), q15mulr, trunc, min/max
  - Trampoline only: relaxed_dot (2 ops), relaxed_laneselect (1 op) — ternary ops
  - Trampoline only: relaxed_dot (2 ops), relaxed_laneselect (1 op) — ternary ops
- **13.3 DONE — x86 SSE**: **244/256 native (95.3%)**
  - Same coverage as ARM64 except: i8x16 byte shift (3), popcnt (1),
    i64x2.shr_s (1), unsigned trunc/convert (5), relaxed_dot (2)
  - SSE4.1 minimum. v128 via PINSRQ/PEXTRQ. SysV + Windows ABI trampoline.
  - Ubuntu x86_64: 62,263/62,263 spec tests pass
- **13.7 DONE — SIMD benchmarks & wasmtime comparison** (2026-03-23):
  - **Microbenchmarks (WAT)**: image_blend **4.7x**, matrix_mul **1.6x** (beats wasmtime!),
    byte_search **1.2x** SIMD faster. dot_product 0.75x (v128.load overhead).
  - **Real-world (C -msimd128)**: 5 new benchmarks (grayscale, box_blur, sum_reduce,
    byte_freq, nbody). box_blur **1.4x**, sum_reduce **1.1x** SIMD faster.
    Others slower due to compiler-generated patterns (i16x8.replace_lane).
  - **vs wasmtime gap**: Microbench best **0.83x** (matrix_mul beats wasmtime!).
    Real-world scalar gap 13-131x (C runtime + WASI overhead).
  - Full data: `bench/simd_comparison.yaml`
- **Phase 13.8 TODO**: gate check, `-Dsimd=false` minimal build, record benchmarks
- **Long-term**: contiguous v128 storage (close split-storage gap), compiler-generated code perf
- See `@./.dev/roadmap.md` Phase 13 for step breakdown (13.0-13.8)

### Key Design (D130)

- Float register class (GP + Float, industry standard)
- ARM64 + x86 per opcode group (no big-bang porting)
- SSE4.1 minimum, tbl/pshufb shuffle fallback
- Full opcode coverage needed for real-world benefit (SIMD in large mixed functions)
- `-Dsimd=false` excludes codegen via comptime

### Remaining Workarounds

| Workaround              | Status | Plan                       |
|--------------------------|--------|----------------------------|
| jitSuppressed(deadline) | Active | Epoch-based check (future) |

## Handover Notes

### W35/W36 (resolved, 2026-03-22)
- W35: ARM64 JIT `emitGlobalSet` ABI clobber + `--interp` + `i32.store16`. Commit 1429f81.
- W36: Was W35 side-effect. 3 consecutive 50/50 PASS after W35 merge.

## References

- `@./.dev/roadmap.md` — Phase 13 SIMD JIT plan (13.0-13.8)
- `@./.dev/references/simd-jit-research.md` — SIMD JIT research
- `@./.dev/decisions.md` — D130 SIMD JIT architecture
- `@./.claude/rules/simd-jit.md` — auto-loaded rules for SIMD work
- `@./.dev/checklist.md` — open items
- `@./.dev/jit-debugging.md` — JIT debug techniques
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
