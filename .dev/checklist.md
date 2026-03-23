# Deferred Work Checklist

Open items only. Resolved items in git history.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Open Items

- [ ] W38: SIMD JIT — compiler-generated code performance
  C compiler (`wasm32-wasi-clang -O2 -msimd128`) patterns are much slower than
  hand-written WAT. Gap vs wasmtime: microbench 1.2-3.8x, C-generated 13-131x.

  **Root cause identified**: C-compiled functions have reentry guards (`__cxa_atexit`
  init pattern) that prevent back-edge JIT. The hot loop runs entirely in the
  interpreter (register IR), which is 13-131x slower than wasmtime's JIT.

  **Investigation progress** (2026-03-24):
  1. ~~JIT bail for reentry guard~~ — identified as the primary cause.
     OSR (On-Stack Replacement) can bypass the guard, but has v128 state sync
     issues: SIMD accumulator values don't transfer correctly from interpreter
     to JIT when vregs carry interleaved scalar/SIMD values.
  2. **v128 sync fix applied**: ARM64 JIT now copies simd_v128 in MOV and clears
     in CONST32/CONST64 (matches x86 backend). This is a correctness fix for
     existing SIMD JIT, not yet sufficient for OSR.
  3. **OSR blocker**: The JIT's SIMD v128 state at OSR entry doesn't match
     the interpreter's state for complex C functions. Needs deeper analysis of
     how the JIT's native SIMD path interacts with scalar register reuse across
     MOV chains. The x86 backend has the same limitation.

  **Next steps**:
  - Investigate alternative to OSR: function splitting (compile only the loop body)
  - Or: fix v128 state transfer for OSR (needs tracking of which vregs carry v128
    at each PC, and proper state marshaling at OSR entry)
  - replace_lane fusion (independent optimization, lower priority)

  **Key data**: `bench/simd_comparison.yaml` (3 layers: baseline → post-opt → JIT)
  **Benchmark sources**: `bench/simd/src/` (grayscale.c, box_blur.c, sum_reduce.c,
  byte_freq.c, nbody_simd.c). Build: `bash bench/simd/build_simd_bench.sh`
  **Microbench WAT**: `bench/simd/` (dot_product.wat, matrix_mul.wat, etc.)
  **Run**: `bash bench/run_simd_bench.sh [--quick]`

## Resolved (summary)

W37: Contiguous v128 storage. W39: Multi-value return JIT (guard removed).
W40: Epoch-based JIT timeout (D131).

W2-W36: See git history. All resolved through Stages 0-47 and Phases 1-19.
