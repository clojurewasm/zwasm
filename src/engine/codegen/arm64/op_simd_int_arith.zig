//! ARM64 emit pass — SIMD-128 integer arithmetic op handlers
//! (split from `op_simd.zig`).
//!
//! Houses int ALU (add/sub/mul/neg/abs/popcnt), shift (shl /
//! shr_s / shr_u), min/max (signed + unsigned), avgr_u, and the
//! i64x2.mul multi-instr synthesis. Uses `op_simd.emitV128Binop`
//! / `op_simd.emitV128Unop` for the canonical 2-op and 1-op
//! shapes; shift / i64x2.mul recipes live here because they own
//! their own scratch-register reservations.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
const inst_neon_arith = @import("inst_neon_arith.zig");
const inst_neon_lane_cmp = @import("inst_neon_lane_cmp.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const op_simd = @import("op_simd.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

pub fn emitI8x16Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encAdd16B);
}
pub fn emitI8x16Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSub16B);
}
pub fn emitI16x8Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encAdd8H);
}
pub fn emitI16x8Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSub8H);
}
pub fn emitI32x4Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encAdd4S);
}
pub fn emitI32x4Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSub4S);
}
pub fn emitI64x2Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encAdd2D);
}
pub fn emitI64x2Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSub2D);
}

// Int unops (abs / neg / popcnt). Wasm SIMD
// spec §4.4 (vector arith). NEON ABS/NEG share the
// two-register-misc encoding with size selecting lane shape;
// CNT is byte-only (16B) and exists only for `i8x16.popcnt`.
pub fn emitI8x16Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encAbs16B);
}
pub fn emitI8x16Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encNeg16B);
}
pub fn emitI8x16Popcnt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encCnt16B);
}
pub fn emitI16x8Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encAbs8H);
}
pub fn emitI16x8Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encNeg8H);
}
pub fn emitI32x4Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encAbs4S);
}
pub fn emitI32x4Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encNeg4S);
}
pub fn emitI64x2Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encAbs2D);
}
pub fn emitI64x2Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encNeg2D);
}
// Note: Wasm SIMD has no `i8x16.mul` (only i16x8/i32x4/i64x2). The
// underlying NEON `MUL Vd.16B` encoding (encMul16B) is preserved
// in inst_neon.zig for completeness but no ZirOp dispatches to it.
pub fn emitI16x8Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encMul8H);
}
pub fn emitI32x4Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encMul4S);
}

// ============================================================
// saturating add/sub + Q15 mulr + extadd_pairwise (13 ops)
// ============================================================
//
// Wasm SIMD spec — `i8x16/i16x8.{add,sub}_sat_{s,u}`: lane-wise add/sub
// with signed/unsigned saturation. A64 SQADD/UQADD/SQSUB/UQSUB (.16B / .8H)
// map exactly. `i16x8.q15mulr_sat_s` = NEON SQRDMULH.8H (signed rounding
// doubling multiply, returning the high half — the Q15 fixed-point form).
// `i{16x8,32x4}.extadd_pairwise_*` = SADDLP/UADDLP (add-long-pairwise,
// .8H←.16B / .4S←.8H), a 1-source two-reg-misc op → emitV128Unop.

pub fn emitI8x16AddSatS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSqadd16B);
}
pub fn emitI8x16AddSatU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUqadd16B);
}
pub fn emitI8x16SubSatS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSqsub16B);
}
pub fn emitI8x16SubSatU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUqsub16B);
}
pub fn emitI16x8AddSatS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSqadd8H);
}
pub fn emitI16x8AddSatU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUqadd8H);
}
pub fn emitI16x8SubSatS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSqsub8H);
}
pub fn emitI16x8SubSatU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUqsub8H);
}
pub fn emitI16x8Q15mulrSatS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSqrdmulh8H);
}
pub fn emitI16x8ExtaddPairwiseI8x16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encSaddlp8H);
}
pub fn emitI16x8ExtaddPairwiseI8x16U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUaddlp8H);
}
pub fn emitI32x4ExtaddPairwiseI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encSaddlp4S);
}
pub fn emitI32x4ExtaddPairwiseI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUaddlp4S);
}

// ============================================================
// extended (widening) multiply (12 ops)
// ============================================================
//
// Wasm SIMD spec — `i{16x8,32x4,64x2}.extmul_{low,high}_*_{s,u}`:
// multiply corresponding low (or high) halves of two narrower
// inputs, producing wide products in the destination shape.
// A64 NEON SMULL/UMULL (low-half) and SMULL2/UMULL2 (high-half)
// map exactly: source low/high half selection matches Wasm's
// extmul_low/extmul_high, and signed/unsigned select SMULL/UMULL.

pub fn emitI16x8ExtmulLowI8x16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmull8H);
}
pub fn emitI16x8ExtmulHighI8x16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmull2_8H);
}
pub fn emitI16x8ExtmulLowI8x16U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmull8H);
}
pub fn emitI16x8ExtmulHighI8x16U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmull2_8H);
}
pub fn emitI32x4ExtmulLowI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmull4S);
}
pub fn emitI32x4ExtmulHighI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmull2_4S);
}
pub fn emitI32x4ExtmulLowI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmull4S);
}
pub fn emitI32x4ExtmulHighI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmull2_4S);
}
pub fn emitI64x2ExtmulLowI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmull2D);
}
pub fn emitI64x2ExtmulHighI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmull2_2D);
}
pub fn emitI64x2ExtmulLowI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmull2D);
}
pub fn emitI64x2ExtmulHighI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmull2_2D);
}

// ============================================================
// i32x4.dot_i16x8_s (pairwise multiply-add)
// ============================================================
//
// Wasm SIMD spec — `i32x4.dot_i16x8_s`: result[i] = a[2i]*b[2i] +
// a[2i+1]*b[2i+1] for i=0..3 (signed i16×i16→i32 products, pairwise
// summed). 3-instr synthesis (not a single NEON instruction):
//   SMULL  V31      = lhs.4h * rhs.4h    → [p0,p1,p2,p3]
//   SMULL2 result_v = lhs.8h * rhs.8h    → [p4,p5,p6,p7]
//   ADDP   result_v = ADDP(V31, result_v)= [p0+p1,p2+p3,p4+p5,p6+p7]
// V31 (op_simd.simd_scratch_v) is the always-reserved SIMD scratch.
// Choreography reads each source before any write, so it is alias-safe
// even if result_v coincides with lhs_v or rhs_v.

/// Wasm spec (SIMD) — `i32x4.dot_i16x8_s`. 3-word emission per call.
pub fn emitI32x4DotI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSmull4S(op_simd.simd_scratch_v, lhs_v, rhs_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSmull2_4S(result_v, lhs_v, rhs_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encAddp4S(result_v, op_simd.simd_scratch_v, result_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// Relaxed-SIMD `i16x8.relaxed_dot_i8x16_i7x16_s` — signed i8×i8 → i16
// pairwise dot: result[i] = a[2i]*b[2i] + a[2i+1]*b[2i+1]. Mirrors the strict
// i32x4.dot_i16x8_s recipe one element-size down (SMULL/SMULL2/ADDP at .8H).
// arm64 does signed×signed; x86 PMADDUBSW does a-unsigned (ADR-0169 latitude).
pub fn emitI16x8RelaxedDot(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);
    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);
    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSmull8H(op_simd.simd_scratch_v, lhs_v, rhs_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSmull2_8H(result_v, lhs_v, rhs_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encAddp8H(result_v, op_simd.simd_scratch_v, result_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// `i32x4.relaxed_dot_i8x16_i7x16_add_s` — 4-way i8 dot + accumulate:
// result[j] = Σ_{k=0..3} a[4j+k]*b[4j+k] + c[j]. = (i16x8 dot) → signed
// pairwise widen-add to i32x4 (SADDLP) → + c. 3-pop ternop. Spill-everything
// regalloc routes a/b/c/result through stage regs V29/V30 + V31 scratch, so
// (like strict dot) result reuses a's stage-0 reg with no alias hazard.
pub fn emitI32x4RelaxedDotAdd(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const c_vreg = ctx.pushed_vregs.pop().?;
    const b_vreg = ctx.pushed_vregs.pop().?;
    const a_vreg = ctx.pushed_vregs.pop().?;
    const b_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, b_vreg, 1);
    const a_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, a_vreg, 0);
    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // i16x8 dot: low→V31, high→result, ADDP→result (a consumed at SMULL2).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSmull8H(op_simd.simd_scratch_v, a_v, b_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSmull2_8H(result_v, a_v, b_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encAddp8H(result_v, op_simd.simd_scratch_v, result_v));
    // i16x8 → i32x4 signed pairwise widen-add.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSaddlp4S(result_v, result_v));
    // + c (load into stage 1; b is dead).
    const c_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, c_vreg, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encAdd4S(result_v, result_v, c_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// int min/max + avgr_u (14 ops)
// ============================================================
//
// Wasm SIMD spec — i*x*.{min_s, min_u, max_s, max_u} for B/H/S
// shapes (no .2D form on NEON). i*x*.avgr_u for B/H only (Wasm
// has no i32x4.avgr_u). Each op compiles to a single Advanced
// SIMD three-same instruction (SMIN / UMIN / SMAX / UMAX /
// URHADD); all share the existing `op_simd.emitV128Binop` helper.

pub fn emitI8x16MinS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmin16B);
}
pub fn emitI8x16MinU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmin16B);
}
pub fn emitI8x16MaxS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmax16B);
}
pub fn emitI8x16MaxU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmax16B);
}
pub fn emitI8x16AvgrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUrhadd16B);
}
pub fn emitI16x8MinS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmin8H);
}
pub fn emitI16x8MinU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmin8H);
}
pub fn emitI16x8MaxS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmax8H);
}
pub fn emitI16x8MaxU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmax8H);
}
pub fn emitI16x8AvgrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUrhadd8H);
}
pub fn emitI32x4MinS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmin4S);
}
pub fn emitI32x4MinU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmin4S);
}
pub fn emitI32x4MaxS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encSmax4S);
}
pub fn emitI32x4MaxU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encUmax4S);
}

// ============================================================
// i64x2.mul multi-instr synthesis
// ============================================================
//
// Wasm spec (SIMD) — `i64x2.mul`: lane-wise 64-bit multiply.
// A64 NEON has no `MUL Vd.2D` instruction (the size encoding
// for MUL Vd.<T>, Vn.<T>, Vm.<T> stops at 4S — bits[23:22]=11
// is reserved for D form). We synthesise via per-lane GPR
// transit:
//   for k in 0..2:
//     UMOV X16, V<lhs>.D[k]   ; encUmovXFromD
//     UMOV X17, V<rhs>.D[k]   ; encUmovXFromD
//     MUL  X16, X16, X17      ; encMulReg (X-form)
//     INS  V<result>.D[k], X16 ; encInsDFromX
//
// X16 (IP0) / X17 (IP1) are AAPCS64 intra-procedure scratch —
// already used by `op_alu_int.emitI*Rotl` (rotate-left synthesis)
// and `op_alu_float.emitF*Copysign` (signed-zero bit-mask). No
// new reservation needed.
//
// Aliasing safety: result V can equal lhs V or rhs V (regalloc
// may reuse a slot whose liveness ended at this op). The
// per-lane sequence is alias-safe — INS V<result>.D[k] only
// touches lane k, leaving the other lane intact for the next
// iteration's UMOV reads.

const i64x2_mul_scratch_a: inst.Xn = 16; // X16 / IP0
const i64x2_mul_scratch_b: inst.Xn = 17; // X17 / IP1

/// Wasm spec (SIMD) — `i64x2.mul`: 8-word emission per call.
/// See block comment above for the synthesis rationale.
pub fn emitI64x2Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    inline for (.{ 0, 1 }) |k| {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovXFromD(i64x2_mul_scratch_a, lhs_v, k));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovXFromD(i64x2_mul_scratch_b, rhs_v, k));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMulReg(i64x2_mul_scratch_a, i64x2_mul_scratch_a, i64x2_mul_scratch_b));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encInsDFromX(result_v, i64x2_mul_scratch_a, k));
    }

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// int shift left (i*x*.shl)
// ============================================================
//
// Wasm SIMD spec §3.3.6 (vector shift): `i*x*.shl` pops i32
// amount + v128 value, pushes v128. Recipe: DUP V<tmp>.<T>,
// W<amt> (broadcast scalar amount to all lanes), then USHL
// V<d>.<T>, V<src>.<T>, V<tmp>.<T>. NEON USHL automatically
// masks the shift to lane-element bitwidth (per Arm IHI 0055
// §C7.2.412), matching Wasm's "amount mod lane_width" semantic.
// shr_s / shr_u use the same shape but require NEG W<amt> first
// (NEON treats negative amount as right-shift) — deferred to a
// follow-up chunk.
//
// V29 = fp_spill_stage[0] reused as DUP destination scratch.
// W<dup_tmp_w> via spill stage 0 GPR (X14 per abi.zig).

/// Wasm shift semantic: amount is taken `mod element_width` (per
/// spec §3.3.6). NEON USHL/SSHL semantic: when `|shift| >=
/// element_width`, all result bits are zeroed (per Arm IHI 0055
/// §C7.2.412). The two semantics diverge for shift amounts at
/// or beyond element_width — Wasm wraps to a small mod, NEON
/// zeroes. We bridge with an explicit `AND W<amt>, #(lane-1)`
/// before DUP / NEG. Lane mask: 7 / 15 / 31 / 63 for i8x16 /
/// i16x8 / i32x4 / i64x2.
const shift_scratch_mask_x: u5 = 16; // X16 / IP0
const shift_scratch_amt_x: u5 = 17; // X17 / IP1 (post-mask + post-NEG)

fn emitV128IntShift(
    ctx: *EmitCtx,
    lane_mask: u16, // 7 / 15 / 31 / 63
    is_64bit: bool, // true for i64x2 (use X-form NEG)
    is_shr: bool, // true for shr_s/shr_u (NEG amount before DUP)
    dup_encoder: *const fn (rd: u5, rn: u5) u32,
    shift_encoder: *const fn (rd: u5, rn: u5, rm: u5) u32,
) Error!void {
    const amt_vreg = ctx.pushed_vregs.pop().?;
    // D-034 (f): spill-aware GPR shift-amount (was resolveGpr-EXEMPT).
    // gprLoadSpilled stage0/X14 (X-file, disjoint from the X16/X17 mask/amt
    // scratch and the V-file dup/src/result stages); consumed via AND below
    // before any further GPR-stage use.
    const amt_w = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, amt_vreg, 0);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // D-034 (f): the DUP scratch MUST avoid the FP spill-stage regs. When src
    // spills it lands in qLoadSpilled stage0 (V29); a dup_v of V29 would clobber
    // src before USHL/SSHL reads it (→ shifts the count by itself). simd_scratch_v
    // (V31) is outside both the stage pool {V29,V30} and the allocatable V-regs,
    // so it never collides with src/result.
    const dup_v: u5 = op_simd.simd_scratch_v;

    // MOVZ X16, #lane_mask ; AND W17, W<amt>, W16  (masks the amount mod lane_width).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(shift_scratch_mask_x, lane_mask));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAndRegW(shift_scratch_amt_x, amt_w, shift_scratch_mask_x));
    if (is_shr) {
        if (is_64bit) {
            // SUB X17, XZR, X17 — full 64-bit NEG (mask cleared upper bits, so X17's high half is 0 pre-NEG).
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubReg(shift_scratch_amt_x, 31, shift_scratch_amt_x));
        } else {
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubRegW(shift_scratch_amt_x, 31, shift_scratch_amt_x));
        }
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, dup_encoder(dup_v, shift_scratch_amt_x));
    try gpr.writeU32(ctx.allocator, ctx.buf, shift_encoder(result_v, src_v, dup_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI8x16Shl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 7, false, false, inst_neon.encDup16B, inst_neon_arith.encUshl16B);
}
pub fn emitI16x8Shl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 15, false, false, inst_neon.encDup8H, inst_neon_arith.encUshl8H);
}
pub fn emitI32x4Shl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 31, false, false, inst_neon.encDup4S, inst_neon_arith.encUshl4S);
}
pub fn emitI64x2Shl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 63, true, false, inst_neon.encDupGen2D, inst_neon_arith.encUshl2D);
}

// ============================================================
// int shift right (i*x*.shr_s, i*x*.shr_u)
// ============================================================
//
// NEON's USHL/SSHL with **negative** shift amount in V<m>'s
// per-lane element performs a right shift (logical for U,
// arithmetic for S). The recipe extends `emitV128IntShl` with a
// preceding NEG of the W<amt> (or X<amt> for i64x2) before DUP:
//
//   SUB W<tmp>, WZR, W<amt>        ; 32-bit NEG (i8x16/i16x8/i32x4)
//   DUP V<dup>.<T>, W<tmp>
//   (U|S)SHL Vd.<T>, Vsrc.<T>, V<dup>.<T>
//
// For i64x2: SUB X<tmp>, XZR, X<amt> — full 64-bit NEG, since the
// W amount has been zero-extended into X<amt>'s low 32 bits and
// the high 32 bits are 0 (Wasm shift amount mod 64 is always
// non-negative, so the zero-extended X<amt> already represents
// the correct positive value pre-NEG).

// shr_u — USHL with negative (masked) amount.
pub fn emitI8x16ShrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 7, false, true, inst_neon.encDup16B, inst_neon_arith.encUshl16B);
}
pub fn emitI16x8ShrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 15, false, true, inst_neon.encDup8H, inst_neon_arith.encUshl8H);
}
pub fn emitI32x4ShrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 31, false, true, inst_neon.encDup4S, inst_neon_arith.encUshl4S);
}
pub fn emitI64x2ShrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 63, true, true, inst_neon.encDupGen2D, inst_neon_arith.encUshl2D);
}

// shr_s — SSHL with negative (masked) amount (arithmetic sign extension).
pub fn emitI8x16ShrS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 7, false, true, inst_neon.encDup16B, inst_neon_arith.encSshl16B);
}
pub fn emitI16x8ShrS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 15, false, true, inst_neon.encDup8H, inst_neon_arith.encSshl8H);
}
pub fn emitI32x4ShrS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 31, false, true, inst_neon.encDup4S, inst_neon_arith.encSshl4S);
}
pub fn emitI64x2ShrS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 63, true, true, inst_neon.encDupGen2D, inst_neon_arith.encSshl2D);
}
