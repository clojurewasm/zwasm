# §11.3 — SIMD per-op gap profile (zwasm JIT vs wasmtime/wazero/wasmer)

> **Doc-state**: ACTIVE
>
> Generated 2026-06-03 (`8eca59e3`, Mac aarch64) via
> `nix develop --command bash scripts/run_bench.sh --simd --quick --compare=all`
> then `bash scripts/simd_gap_analysis.sh`. Corpus: `bench/runners/wasm/simd/`
> (12 per-op micro-benches, 5M-iteration loops). zwasm runs via `run --engine=jit`
> (ADR-0136); the interp has no SIMD. Regenerate with the two commands above.

## Result: zwasm JIT SIMD is competitive — 0 ops lag the median by > 3×

| op | zwasm_ms | wasmtime | wazero | wasmer | median | zwasm/median |
|----|---------:|---------:|-------:|-------:|-------:|-------------:|
| i16x8.mul        | 10.49 | 10.08 |  7.67 | 22.35 | 10.08 | 1.04× |
| f32x4.div        | 12.58 | 16.24 | 14.71 | 22.50 | 16.24 | 0.77× |
| f32x4.add        |  5.82 |  9.33 |  6.63 | 13.93 |  9.33 | 0.62× |
| i32x4.sub        |  5.48 |  9.12 |  6.91 | 14.15 |  9.12 | 0.60× |
| f32x4.min        |  5.22 |  8.73 |  6.46 | 13.38 |  8.73 | 0.60× |
| i32x4.mul        |  6.01 | 10.13 |  7.84 | 14.96 | 10.13 | 0.59× |
| i32x4.min_s      |  5.01 |  8.56 |  7.29 | 13.62 |  8.56 | 0.59× |
| i32x4.add        |  4.69 |  8.41 |  6.45 | 13.40 |  8.41 | 0.56× |
| i8x16.add        |  4.74 |  8.74 |  6.26 | 13.36 |  8.74 | 0.54× |
| f32x4.mul        |  6.31 | 11.66 |  8.41 | 15.89 | 11.66 | 0.54× |
| v128.and         |  4.80 |  8.93 |  6.99 | 14.04 |  8.93 | 0.54× |
| i8x16.swizzle    |  4.72 |  9.07 |  6.30 | 13.54 |  9.07 | 0.52× |

**12 ops analysed; 0 lag the comparator median by > 3× (the §11.3 threshold).**

## Findings → Phase 15

1. **No per-op > 3× perf gap** among the JIT-emitted ops on this corpus — zwasm's
   single-pass NEON codegen is at or below the (wasmtime, wazero, wasmer) median
   wall-clock here. So the §9.10 Track A speculative candidates (AVX-path adoption,
   MOVAPS-preamble peephole, SIMD coalescing) are NOT justified by a measured > 3×
   gap on these micro-benches; they remain *opportunistic* Phase-15 work, not
   gap-driven. **Caveat**: `--quick` (1 warmup / 3 runs) over short modules is
   partly startup/compile-confounded — the comparators pay an optimizing-compile
   cost zwasm's single pass avoids, which flatters zwasm. A steady-state re-profile
   (≥10× iterations, or subtract a no-op-module baseline to isolate execution) is
   the Phase-15 refinement before acting on any per-op ratio.
2. **Categorical gap — arm64 JIT does not emit `i32x4.dot_i16x8_s` or
   `i16x8.extmul_*`** (compileWasm → `NotImplemented`); the x86_64 codegen has them
   (`x86_64/ops/wasm_2_0/*extmul*`). This is an arm64-emit hole, not a perf gap, and
   is the concrete §11.3 → Phase-15 carry (filed as debt). Other un-probed SIMD ops
   (narrow/extend/q15mulr/relaxed) may share it; a coverage sweep belongs in Phase 15.
