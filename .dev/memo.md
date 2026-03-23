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
- **13.2+ Native NEON** (in progress): **208 opcodes** now native ARM64 (81% of 256)
  - All comparisons, arithmetic, saturating, shifts, lane ops, extend/narrow, extmul
  - All float ops (arithmetic, compare, rounding, sqrt, min/max, pmin/pmax, convert)
  - bitselect, swizzle, popcnt, extadd_pairwise, q15mulr, avgr_u
  - v128.any_true, all_true (i8x16/i16x8/i32x4/i64x2), i32x4.dot_i16x8_s
  - v128.load/store/const, splat, bitwise, demote/promote, f64x2 convert
  - SIMD bench: image_blend 5.2x faster than scalar, matrix_mul 1.4x
  - **Remaining** (~21 ops): shuffle (1), relaxed ops (20) — all trampoline-safe
- **13.3 x86 SSE port** (in progress, branch `phase13/simd-jit`)
  - Foundation DONE: simd_hi_offset, has_simd, SSE encoders, emitLoadV128/StoreV128
  - SIMD trampoline DONE: all SIMD functions JIT-accepted on x86 (trampoline fallback)
  - OP_MOV/CONST simd_hi handling DONE
  - **~110 native SSE opcodes**: bitwise, all int arithmetic + sat + min/max + abs + avgr,
    all signed int comparisons, f32x4/f64x2 arithmetic + sqrt + min/max,
    v128 load/store/const, all extract/replace_lane, splat (i32x4/i64x2/f32x4/f64x2)
  - Ubuntu x86_64: 62,263/62,263 spec tests pass
  - **Next**: more native SSE (extend/narrow, shift, load variants, unsigned compare, neg)
  - **Long-term**: NEON register allocator or contiguous v128 storage
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
