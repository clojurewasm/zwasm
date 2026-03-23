---
paths:
  - "src/simd_arm64.zig"
  - "src/simd_x86.zig"
  - "bench/simd/**"
---

# SIMD JIT Rules

Phase 13 work. Decision: D130. Research: `.dev/references/simd-jit-research.md`.

## Architecture (D130)

- **Two register classes**: GP (existing) + Float (v128 + FP, new)
- **Spill**: GP = 8B, Float = 16B (class-separate)
- **x86 minimum**: SSE4.1
- **Files**: `simd_arm64.zig` (NEON), `simd_x86.zig` (SSE), modified `regalloc.zig`, `jit.zig`, `x86.zig`
- **Build**: `-Dsimd=false` excludes SIMD codegen via `comptime if`

## Implementation Order (both ISAs per step)

1. Float register class + spill_simd + comptime scaffolding
2. v128 load/store/const
3. i32x4/i64x2 arithmetic + bitwise
4. f32x4/f64x2 arithmetic
5. Comparison + select + splat + lane ops
6. Type conversion (extend/narrow/convert)
7. Shuffle/swizzle (tbl/pshufb generic fallback)
8. Real-world bench + gate

## Both ISAs Rule (W35 lesson)

**Every opcode group must be implemented on ARM64 AND x86 before committing.**
Do NOT accumulate ARM64-only or x86-only code. The W35 ARM64 ABI clobber bug
went undetected because x86 worked fine. Test both platforms per commit.

## Testing Checklist

1. `zig build test` — all pass (includes SIMD unit tests)
2. `python3 test/spec/run_spec.py --build --summary` — SIMD spec tests pass
3. `bash bench/run_simd_bench.sh` — verify SIMD faster than scalar (post-JIT)
4. `zig build test -Dsimd=false` — minimal build still works
5. `zig build test -Djit=false -Dsimd=true` — interpreter-only SIMD still works

## Shuffle Complexity Warning

x86 shuffle is the hardest SIMD operation to lower. Cranelift uses 14+ rules.
Start with `pshufb` as universal fallback. Add special patterns only when
benchmarks show measurable benefit. ARM64 `tbl` covers the general case.

## Reference Implementations

- Cranelift ARM64: `~/Documents/OSS/wasmtime/cranelift/codegen/src/isa/aarch64/`
- Cranelift x86: `~/Documents/OSS/wasmtime/cranelift/codegen/src/isa/x64/`
- zwasm SIMD interpreter: `src/vm.zig` line ~6527 (`executeSimdIR`)
- zwasm SIMD predecode: `src/predecode.zig` line ~297 (`predecodeSimd`)

## Pitfalls from Research

- x86 int/float domain crossing penalty: accept it in single-pass JIT (no analysis pass)
- v128 register pressure on x86 (16 XMM shared with FP) — spill aggressively
- Real-world SIMD is in large mixed functions (70-80%) — partial JIT has limited benefit
