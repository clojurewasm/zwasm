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

- **13.0 DONE**: simdStackEffect table, simd_arm64/x86.zig stubs
- **13.1 DONE**: All 252 SIMD opcodes flow through RegIR via stack adapter
  - v128 storage: lo in regs[rd], hi in Vm.simd_hi[rd]
  - OP_MOV/CONST now copy/clear simd_hi (bug: upper 64-bit loss, fixed)
  - Spec: 62,263/62,263. SIMD conformance: 3/3. Real-world samples: 6/6 correct.
- **13.2 DONE (trampoline)**: JIT accepts SIMD functions
  - simd_hi moved from stack-local to Vm struct (JIT accessible via @offsetOf)
  - ARM64 NEON instruction encoders added (ldrQ/strQ, faddV4s, fmulV4s, etc.)
  - SIMD opcodes in JIT: trampoline → jitSimdTrampoline → executeSimdIR
  - SIMD bench: 19-30x slower than scalar (trampoline overhead, was 20-53x)
  - All tests + samples pass. JIT compiles SIMD hot loops.
- **5 real-world SIMD C samples** in test/realworld/c_simd/ (wasi-sdk -msimd128)
- **13.2+ Native NEON** (in progress): **141 opcodes** now native ARM64
  - All comparisons: i8x16/i16x8/i32x4 (eq/ne/lt/gt/le/ge × s/u), i64x2 (signed only)
  - All integer arithmetic: add/sub/mul, abs/neg/min/max (i8x16/i16x8/i32x4), i64x2 add/sub/abs/neg
  - All integer shifts: i8x16/i16x8/i32x4/i64x2 shl/shr_s/shr_u
  - All float arithmetic: f32x4/f64x2 add/sub/mul/div/min/max/abs/neg/sqrt
  - All extract_lane/replace_lane (all 8 types)
  - All extadd_pairwise (4 variants)
  - v128.load/store, v128.const, splat (6 types)
  - v128 bitwise (and/andnot/or/xor/not)
  - i16x8 extend (s/u), i8x16 narrow (s/u), i8x16 avgr_u
  - SIMD bench: image_blend 4.8x faster than scalar, matrix_mul 1.3x
  - Gap source: v128 load-op-store overhead (10 instrs/op, see jit-debugging.md §8)
  - **Next priorities**:
    1. More native opcodes (i32x4.dot, i64x2.mul, bitmask, any_true/all_true, f32x4 compare, convert ops, saturating add/sub)
    2. x86 SSE port (D6: both ISAs per opcode group)
    3. Long-term: NEON register allocator or contiguous v128 storage
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
