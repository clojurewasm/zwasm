# Relaxed SIMD

Status: Wasm 3.0 | Repo: relaxed-simd | Complexity: high
zwasm: todo | Est. LOC: ~600 | Opcodes: 20 new

## What It Adds

20 SIMD instructions with implementation-defined (non-deterministic) behavior.
These map directly to hardware SIMD instructions, trading determinism for
performance. Results may vary across platforms but are consistent within a
single execution environment.

## New Opcodes

All use the 0xfd SIMD prefix. Opcodes 0x100-0x113:

| Opcode | Instruction | Signature | Category |
|--------|-------------|-----------|----------|
| 0x100 | i8x16.relaxed_swizzle | (v128, v128) -> v128 | Swizzle |
| 0x101 | i32x4.relaxed_trunc_f32x4_s | (v128) -> v128 | Truncation |
| 0x102 | i32x4.relaxed_trunc_f32x4_u | (v128) -> v128 | Truncation |
| 0x103 | i32x4.relaxed_trunc_f64x2_s_zero | (v128) -> v128 | Truncation |
| 0x104 | i32x4.relaxed_trunc_f64x2_u_zero | (v128) -> v128 | Truncation |
| 0x105 | f32x4.relaxed_madd | (v128, v128, v128) -> v128 | FMA |
| 0x106 | f32x4.relaxed_nmadd | (v128, v128, v128) -> v128 | FMA |
| 0x107 | f64x2.relaxed_madd | (v128, v128, v128) -> v128 | FMA |
| 0x108 | f64x2.relaxed_nmadd | (v128, v128, v128) -> v128 | FMA |
| 0x109 | i8x16.relaxed_laneselect | (v128, v128, v128) -> v128 | Select |
| 0x10a | i16x8.relaxed_laneselect | (v128, v128, v128) -> v128 | Select |
| 0x10b | i32x4.relaxed_laneselect | (v128, v128, v128) -> v128 | Select |
| 0x10c | i64x2.relaxed_laneselect | (v128, v128, v128) -> v128 | Select |
| 0x10d | f32x4.relaxed_min | (v128, v128) -> v128 | Min/Max |
| 0x10e | f32x4.relaxed_max | (v128, v128) -> v128 | Min/Max |
| 0x10f | f64x2.relaxed_min | (v128, v128) -> v128 | Min/Max |
| 0x110 | f64x2.relaxed_max | (v128, v128) -> v128 | Min/Max |
| 0x111 | i16x8.relaxed_q15mulr_s | (v128, v128) -> v128 | Q15 Mul |
| 0x112 | i16x8.relaxed_dot_i8x16_i7x16_s | (v128, v128) -> v128 | Dot |
| 0x113 | i32x4.relaxed_dot_i8x16_i7x16_add_s | (v128, v128, v128) -> v128 | Dot |

Reserved: 0x114-0x12F (14 opcodes for future use)

## New Types

None. All operate on existing v128 type.

## Key Semantic Changes

- **Non-determinism**: Results are implementation-defined for edge cases:
  - Swizzle: out-of-range indices (16-255) produce impl-defined values
  - Trunc: NaN/overflow lanes may saturate or return min/max
  - FMA: single-rounding (fused) or double-rounding (unfused)
  - Laneselect: mixed-bit masks produce impl-defined results
  - Min/Max: NaN and +0/-0 handling is impl-defined
  - Q15: overflow (INT16_MIN * INT16_MIN) returns INT16_MIN or INT16_MAX
  - Dot: high-bit-set second operand interpretation varies

- **Consistency guarantee**: Within one execution environment, the same input
  always produces the same output (environment-global determinism).

## Dependencies

- fixed_width_simd (required — extends SIMD instruction set)

## Implementation Strategy

1. Add 20 opcodes to `opcode.zig` (0xfd prefix, 0x100-0x113)
2. Decode in `module.zig` — no immediates beyond the opcode
3. Validate — all take v128 operands, return v128
4. Implement in `vm.zig`:
   - ARM64 NEON: most map directly to single instructions
   - swizzle -> TBL, trunc -> FCVTZS/FCVTZU, FMA -> FMLA/FMLS
   - laneselect -> BSL, min/max -> FMIN/FMAX, Q15 -> SQRDMULH
   - dot -> SMULL+SADDLP or SDOT
5. JIT: emit NEON instructions directly (ideal for relaxed ops)

## Files to Modify

| File | Changes |
|------|---------|
| opcode.zig | Add 20 relaxed SIMD opcodes |
| module.zig | Decode + validate |
| predecode.zig | IR opcodes |
| vm.zig | Implement 20 operations |
| jit.zig | NEON codegen for relaxed ops |
| spec-support.md | Update opcode count |

## Tests

- Spec: relaxed-simd/test/core/relaxed-simd/ — 7 test files
  (swizzle, trunc, madd, laneselect, min_max, q15mulr, dot_product)
- Assertions: ~200+ (many have impl-defined expected ranges)

## wasmtime Reference

- `cranelift/codegen/src/isa/aarch64/lower/isle/generated_code.rs`
  — relaxed SIMD lowering rules
- `cranelift/wasm/src/code_translator.rs` — `translate_relaxed_simd`
- ARM64 uses NEON directly; x86 uses SSE/AVX equivalents
