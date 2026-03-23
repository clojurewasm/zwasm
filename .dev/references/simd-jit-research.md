# SIMD JIT Research (2026-03-22)

Research results for Phase 13 SIMD JIT implementation.
Referenced by: D130 decision, `.claude/rules/simd-jit.md`.

## 1. How Other Runtimes Handle SIMD JIT

### Approach Comparison

| Runtime          | Approach                                           | Register Classes         |
|------------------|----------------------------------------------------|--------------------------|
| Cranelift        | Unified IR, ISLE DSL per-ISA lowering              | Int + Float (v128 incl.) |
| V8 Liftoff       | Virtual stack + ISA-specific direct emission        | Int + Float              |
| V8 TurboFan      | Graph-based IR + ISA-specific lowering              | Int + Float              |
| SpiderMonkey     | MIR with single type (Int8x16) for all SIMD        | Float "punned" as v128   |
| Wasmer Singlepass | Direct lowering per-arch (machine_x64/arm64.rs)   | Int + Float              |
| WAMR             | SIMDe library (C compiler delegation)              | N/A                      |

**Consensus**: No runtime uses a "portable SIMD IR". All lower directly to ISA-specific
instructions. All unify Float and v128 into a single register class.

### Register Model

| Aspect         | x86_64 (XMM)                     | ARM64 (NEON V)                  |
|----------------|-----------------------------------|---------------------------------|
| Count          | 16 (xmm0-xmm15)                  | 32 (v0-v31)                     |
| Shared with FP | Yes                               | Yes                             |
| Spill cost     | 16 bytes (2x i64)                 | 16 bytes (2x i64)              |
| Shuffle        | Complex (14+ rules, pshufb)       | Simple (tbl one instruction)   |
| Minimum ISA    | SSE4.1                            | NEON (ARMv8 baseline)           |

### Cranelift Specifics (wasmtime reference impl)

- `RegClass::Float` holds both FP and v128. A third `RegClass::Vector` exists in
  regalloc2's enum but is marked `unreachable!()` on both x64 and aarch64.
- x86 shuffle lowering: 14+ priority-ordered ISLE rules (pblendw, palignr, pshuflw,
  pshufhw, pshufd, punpck*, shufps, pshufb fallback).
- ARM64: `tbl` as general fallback, `dup`/`ext`/`uzp1`/`uzp2` for special patterns.
- Spill slots: Float class sized by `vector_scale` (16 bytes for 128-bit).

### SpiderMonkey Specifics

- ARM64 baseline: `RABALDR_SIDEALLOC_V128` — "puns" double-precision float registers
  as 128-bit vectors to avoid restructuring the entire register allocator.
- All SIMD values use `MIRType::Int8x16` regardless of lane interpretation.
- 75x speedup achieved by optimizing `createMoveGroupsFromLiveRangeTransitions`
  for large ONNX wasm modules with heavy SIMD.

## 2. Real-World SIMD Usage Patterns

### Key Finding: SIMD Is Scattered in Large Functions

LLVM's pass ordering: **inlining runs FIRST, vectorization runs SECOND**.
Small helpers are inlined into callers before Loop Vectorizer runs.
Result: SIMD opcodes end up scattered in large mixed functions.

Source: [Nikita Popov, LLVM middle-end pipeline](https://www.npopov.com/2023/04/07/LLVM-middle-end-pipeline.html)

### Distribution Estimate

| Pattern                                   | Estimated % | Examples                                       |
|-------------------------------------------|-------------|------------------------------------------------|
| SIMD in large mixed functions (>100 ops)  | ~70-80%     | XNNPACK kernels, Halide, OpenCV, codecs        |
| SIMD in medium mixed functions (30-100)   | ~15-20%     | Small compute helpers surviving inlining       |
| SIMD in small dedicated functions (<30)   | ~5-10%      | Hand-written intrinsics wrappers               |

### SIMD Op Density in Functions

Even in dedicated SIMD functions (hand-written WAT benchmarks), SIMD instructions
are only 6-16% of total ops. The rest is loop control, address calculation, scalar setup.

| Benchmark   | Total Ops | SIMD Ops | SIMD % |
|-------------|-----------|----------|--------|
| matrix_mul  | 108       | 7        | 6%     |
| image_blend | 46        | 4        | 9%     |
| byte_search | 90        | 12       | 13%    |
| dot_product | 63        | 10       | 16%    |

### Implication for JIT

- "Partial SIMD JIT" (only some opcodes) has limited benefit for real-world code
- Full opcode coverage needed before real-world SIMD functions get JIT-compiled
- Hand-written WAT benchmarks benefit earlier (small dedicated functions)
- JIT must handle large functions with mixed scalar+vector register pressure

## 3. Complexity Hotspots

### Shuffle/Swizzle (Hardest Operation)

- **x86**: Cranelift needs 14+ priority-ordered pattern-matching rules.
  LLVM uses a pre-generated table of 26K entries for 32x4 shuffles.
  Pragmatic approach: `pshufb` (SSSE3) as universal fallback, special-case incrementally.
- **ARM64**: `tbl` (table lookup) handles the general case in one instruction.
  `dup`, `ext`, `uzp1`/`uzp2` for broadcast, concat-shift, deinterleave.

### x86 Integer/Float Domain Crossing Penalty

On x86, there's a penalty when integer SIMD result feeds a float SIMD op and vice versa.
Wasm SIMD conflates these. Reconstructing the distinction requires analysis passes
incompatible with single-pass JIT. The wasm spec group rejected adding separate variants.
Pragmatic response: accept the penalty in single-pass JIT (same as Liftoff, Singlepass).

### GC Interaction

v128 values are unmanaged (not reference types) — no GC tracing.
Only impact: spill cost (16 bytes vs 8 bytes for i64) increases register save/restore
cost around GC write barriers.

## 4. zwasm Current State

- **Interpreter**: 252/256 SIMD opcodes implemented (98.4%). `u128` on stack, `@bitCast` to `@Vector`.
- **Predecode**: Full SIMD support (memarg extraction, v128.const as 2x pool64, lane ops).
- **RegAlloc**: Zero SIMD support. Unknown opcodes → `return null` → entire function fallback.
- **JIT**: Zero SIMD codegen. Relies on regalloc bailout.
- **Build flag**: `-Dsimd=false` exists but has no JIT-side effect.
- **Benchmarks**: 4 SIMD microbenchmarks (dot_product, matrix_mul, byte_search, image_blend).
  SIMD currently 2.6-7.7x slower than scalar (interpreter overhead).

## 5. External References

- [Cranelift Progress 2022](https://bytecodealliance.org/articles/cranelift-progress-2022)
- [Cranelift regalloc2](https://cfallin.org/blog/2022/06/09/cranelift-regalloc2/)
- [LLVM Auto-Vectorization](https://llvm.org/docs/Vectorizers.html)
- [V8 SIMD features](https://v8.dev/features/simd)
- [V8 Liftoff baseline](https://v8.dev/blog/liftoff)
- [Wasmer 2.3 SIMD](https://wasmer.io/posts/wasmer-2_3)
- [SpiderMonkey ARM64 SIMD baseline (bug 1609381)](https://bugzilla.mozilla.org/show_bug.cgi?id=1609381)
- [SpiderMonkey Ion 75x optimization](https://spidermonkey.dev/blog/2024/10/16/75x-faster-optimizing-the-ion-compiler-backend.html)
- [WebAssembly SIMD shuffle discussion](https://github.com/WebAssembly/simd/issues/8)
- [WebAssembly SIMD int/float concern](https://github.com/WebAssembly/simd/issues/125)
- [TensorFlow.js SIMD](https://blog.tensorflow.org/2020/09/supercharging-tensorflowjs-webassembly.html)
- [Cornell CS 6120: LLVM Loop Autovectorization](https://www.cs.cornell.edu/courses/cs6120/2019fa/blog/llvm-autovec/)
- [Ben Titzer: Whose baseline compiler is it anyway?](https://arxiv.org/abs/2305.13241)
- Cranelift source: `~/Documents/OSS/wasmtime/cranelift/codegen/src/isa/{aarch64,x64}/`
