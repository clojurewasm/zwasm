//! ARM64 emit pass — SIMD-128 floating-point op handlers (split
//! from `op_simd.zig`).
//!
//! Houses all `emitF*` handlers: f32x4 / f64x2 splat,
//! extract_lane / replace_lane, arithmetic (add/sub/mul/div),
//! unary (abs/neg/sqrt/ceil/floor/trunc/nearest), min/max
//! (NaN-propagating), pmin/pmax (pseudo, FCMGT+BSL synthesis),
//! per-lane compares (eq/ne/lt/gt/le/ge), i↔f conversions,
//! promote/demote, and trunc_sat. Uses
//! `op_simd.emitV128Binop` / `op_simd.emitV128Unop` /
//! `op_simd.emitV128BinopSwapped` / `op_simd.emitV128Ne` /
//! `op_simd.simd_scratch_v` for the canonical shapes and V31
//! scratch reservation.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const zir = @import("../../../ir/zir.zig");
const inst_neon = @import("inst_neon.zig");
const inst_neon_arith = @import("inst_neon_arith.zig");
const inst_neon_lane_cmp = @import("inst_neon_lane_cmp.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const op_simd = @import("op_simd.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// FP-source splat helper. Takes an f32/f64 scalar in V-class
/// register's lane 0 and broadcasts via DUP element form.
fn emitV128SplatFromV(
    ctx: *EmitCtx,
    encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    // f32/f64 scalar lives in a V-class reg's lane 0; loadSpilled
    // here uses the FP D-form spill stride (8 bytes) — fpLoadSpilled
    // returns the V index that DUP element can read from.
    const src_v = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `f32x4.splat`: pop f32 scalar (S<vn>), broadcast to all 4 32-bit
/// lanes via DUP element form (V<vn>.S[0] → V<vd>.4S).
pub fn emitF32x4Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromV(ctx, inst_neon.encDup4SFromS0);
}

/// `f64x2.splat`: pop f64 scalar (D<vn>), broadcast to both lanes.
pub fn emitF64x2Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromV(ctx, inst_neon.encDup2DFromD0);
}

// ============================================================
// f32x4 / f64x2 lane access
// ============================================================
//
// Wasm spec (SIMD) — `f32x4.extract_lane` / `f64x2.extract_lane`
// produce a scalar f32 / f64 result held in an FP register.
// `_replace_lane` consumes a scalar FP at S[0] / D[0] of an FP
// register. Encoders: DUP-scalar (extract; zeros upper V bits) +
// INS-element (replace; copies V<n>.S[0] / V<n>.D[0] into a V<rd>
// lane). FP-side scalar resolves stay on the SPILL-EXEMPT escape
// hatch alongside the int-side resolveGpr sites — fpLoadSpilled /
// fpDefSpilled migration is its own follow-on. The v128 spill
// path remains via `qLoadSpilled` / `qDefSpilled` / `qStoreSpilled`.

/// Helper: emit `extract_lane` for FP-result variants. Mirrors
/// `op_simd_int_cmp_lane.emitV128ExtractLane` but resolves the
/// result vreg to a V register via `gpr.resolveFp` instead of a
/// GPR via `resolveGpr`.
fn emitV128ExtractLaneFp(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    encoder: *const fn (rd: u5, rn: u5, lane: u32) u32,
    lane_mask: u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // D-461: spill-aware FP-scalar result (was resolveFp-reject). The v128 src
    // uses qLoadSpilled stage 0 (V29); the FP result uses stage 1 (V30) — both
    // draw from fp_spill_stage_vregs {V29,V30}, so distinct stages avoid a
    // same-V-file collision (unlike the GPR narrow-extract's disjoint X-file).
    const result_v = try gpr.fpDefSpilled(ctx.alloc, result_vreg, 1);

    const lane: u32 = @intCast(ins.payload & lane_mask);
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_v, lane));
    try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit `replace_lane` for FP-input variants. The new-lane
/// scalar comes from a V register (S/D form low bits), not a GPR.
///
/// Aliasing safety (D-066 close): the regalloc's LIFO slot-reuse
/// can assign `result_vreg` the same physical V-reg as
/// `new_lane_vreg` (e.g. simd_lane.137's
/// `extract_lane → replace_lane` chain on `(v128, v128) → v128`
/// — at the replace_lane site, the extracted-lane vreg dies and
/// its V-reg is the LIFO-top free slot, which is then handed back
/// to the new result vreg). The naive sequence MOV result_v ←
/// src_v then INS would clobber `new_lane_v` before INS reads it.
/// Stash `new_lane_v` through V31 (popcnt scratch — outside any
/// popcnt sequence here) when the alias condition holds.
fn emitV128ReplaceLaneFp(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    encoder: *const fn (rd: u5, dst_lane: u32, rn: u5) u32,
    lane_mask: u32,
) Error!void {
    const new_lane_vreg = ctx.pushed_vregs.pop().?;
    // D-034 (c): spill-aware FP new-lane (was resolveFp-EXEMPT). The 2-stage
    // FP pool {V29,V30} is fully consumed by src (stage0) + result (stage1);
    // the new-lane outlives both, so a spilled new-lane loads into stage1
    // (V30) — deliberately the result's stage. The existing D-066
    // aliasing-stash below (new_lane_v == result_v → MOV V31 ← new_lane)
    // already preserves it across the result MOV, so no extra scratch needed.
    const new_lane_v = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, new_lane_vreg, 1);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 1);

    var ins_src: u5 = new_lane_v;
    if (src_v != result_v and new_lane_v == result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(op_simd.simd_scratch_v, new_lane_v));
        ins_src = op_simd.simd_scratch_v;
    }
    if (src_v != result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, src_v));
    }
    const lane: u32 = @intCast(ins.payload & lane_mask);
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, lane, ins_src));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// Encoder thunks for the FP forms (parallel to the int thunks in
// `op_simd_int_cmp_lane.zig`).
fn encDupScalarS(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encMovScalarSFromVlane(rd, rn, @intCast(lane));
}
fn encDupScalarD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encMovScalarDFromVlane(rd, rn, @intCast(lane));
}
fn encInsElemS(rd: u5, dst_lane: u32, rn: u5) u32 {
    return inst_neon_lane_cmp.encMovVSlaneFromVS0(rd, @intCast(dst_lane), rn);
}
fn encInsElemD(rd: u5, dst_lane: u32, rn: u5) u32 {
    return inst_neon_lane_cmp.encMovVDlaneFromVD0(rd, @intCast(dst_lane), rn);
}

/// Wasm spec (SIMD) — `f32x4.extract_lane`: lane ∈ 0..3; produce a
/// scalar f32. Lowers to `MOV S<rd>, V<rn>.S[lane]` (DUP scalar S).
pub fn emitF32x4ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLaneFp(ctx, ins, encDupScalarS, 0x3);
}

/// Wasm spec (SIMD) — `f32x4.replace_lane`: replace a lane with an
/// f32 scalar. Lowers to `MOV V<vd>.S[lane], V<vn>.S[0]` (INS
/// element S form, src lane 0).
pub fn emitF32x4ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLaneFp(ctx, ins, encInsElemS, 0x3);
}

/// Wasm spec (SIMD) — `f64x2.extract_lane`: lane ∈ 0..1; produce a
/// scalar f64. Lowers to `MOV D<rd>, V<rn>.D[lane]` (DUP scalar D).
pub fn emitF64x2ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLaneFp(ctx, ins, encDupScalarD, 0x1);
}

/// Wasm spec (SIMD) — `f64x2.replace_lane`: replace a lane with an
/// f64 scalar. Lowers to `MOV V<vd>.D[lane], V<vn>.D[0]` (INS
/// element D form, src lane 0).
pub fn emitF64x2ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLaneFp(ctx, ins, encInsElemD, 0x1);
}

// ============================================================
// f32x4 / f64x2 binary FP arithmetic
// ============================================================
//
// Wasm spec (SIMD) — `f32x4.add/sub/mul/div`, `f64x2.add/sub/mul/div`.
// Lowers to NEON FADD/FSUB/FMUL/FDIV with 4S (S = single) or 2D
// (D = double) arrangement. NEON FP arith follows IEEE-754
// round-to-nearest-even with NaN-propagation matching Wasm
// semantics (per ADR-0041 §"4. NEON IEEE-754 spec-fidelity").
//
// All 8 handlers share the existing `op_simd.emitV128Binop` shape — pop
// 2 v128, push 1 v128 — so they're thin adapters around the
// per-shape encoder.

pub fn emitF32x4Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFAdd4S);
}
pub fn emitF32x4Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFSub4S);
}
pub fn emitF32x4Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFMul4S);
}
pub fn emitF32x4Div(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFDiv4S);
}
pub fn emitF64x2Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFAdd2D);
}
pub fn emitF64x2Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFSub2D);
}
pub fn emitF64x2Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFMul2D);
}
pub fn emitF64x2Div(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFDiv2D);
}

// ============================================================
// f32x4 / f64x2 unary FP arithmetic
// ============================================================
//
// Wasm spec (SIMD) — `f32x4.{abs,neg,sqrt,ceil,floor,trunc,nearest}`
// and the f64x2 counterparts. Lowers to NEON FABS / FNEG / FSQRT /
// FRINTN / FRINTM / FRINTP / FRINTZ with 4S or 2D shape.

pub fn emitF32x4Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFAbs4S);
}
pub fn emitF32x4Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFNeg4S);
}
pub fn emitF32x4Sqrt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFSqrt4S);
}
pub fn emitF32x4Ceil(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFRintP4S);
}
pub fn emitF32x4Floor(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFRintM4S);
}
pub fn emitF32x4Trunc(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFRintZ4S);
}
pub fn emitF32x4Nearest(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFRintN4S);
}
pub fn emitF64x2Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFAbs2D);
}
pub fn emitF64x2Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFNeg2D);
}
pub fn emitF64x2Sqrt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFSqrt2D);
}
pub fn emitF64x2Ceil(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFRintP2D);
}
pub fn emitF64x2Floor(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFRintM2D);
}
pub fn emitF64x2Trunc(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFRintZ2D);
}
pub fn emitF64x2Nearest(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFRintN2D);
}

// ============================================================
// f32x4 / f64x2 min / max (NaN-propagating)
// ============================================================
//
// Wasm spec (SIMD) — IEEE-754-2008 min/max with NaN propagation.
// NEON FMAX/FMIN match exactly. `pmin`/`pmax` (pseudo-min/max
// with zero-on-equal-magnitude semantics) are synthesised below.

pub fn emitF32x4Min(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFMin4S);
}
pub fn emitF32x4Max(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFMax4S);
}
pub fn emitF64x2Min(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFMin2D);
}
pub fn emitF64x2Max(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_arith.encFMax2D);
}

// Relaxed-SIMD madd/nmadd — fused FMLA/FMLS (ADR-0169: uniform fused
// on arm64). madd = a*b+c (FMLA); nmadd = -(a*b)+c (FMLS). 3-operand ternop.
pub fn emitF32x4RelaxedMadd(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128FpFma(ctx, inst_neon_arith.encFmla4S);
}
pub fn emitF32x4RelaxedNmadd(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128FpFma(ctx, inst_neon_arith.encFmls4S);
}
pub fn emitF64x2RelaxedMadd(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128FpFma(ctx, inst_neon_arith.encFmla2D);
}
pub fn emitF64x2RelaxedNmadd(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128FpFma(ctx, inst_neon_arith.encFmls2D);
}

// ============================================================
// f32x4/f64x2 pmin/pmax synthesis
// ============================================================
//
// Wasm spec (SIMD) — pseudo-min/max with zero-on-equal-magnitude:
//   pmin(x, y) ≡ if y < x then y else x   (returns y on ties / NaN)
//   pmax(x, y) ≡ if x < y then y else x   (returns y on ties / NaN)
//
// A64 NEON has no direct instruction; synthesis via FCMGT + BSL
// per Arm IHI 0055. Sequence (3 instructions):
//   1. FCMGT V31, V<a>, V<b>            ; mask = (a > b)
//   2. BSL   V31.16B, V<true>.16B, V<false>.16B ; V31 = mask ? true : false
//   3. MOV   V<result>.16B, V31.16B     ; copy to result V
//
// V31 reservation: per `regalloc.zig:126` ("V31 reserved for popcnt's
// V-register pipeline"); reused here as a SIMD scratch since no live
// SIMD vreg can land there.
//
// pmin operand choice: a=lhs, b=rhs, true=rhs, false=lhs.
//   mask = (lhs > rhs); true case = rhs, false case = lhs.
// pmax operand choice: a=rhs, b=lhs, true=rhs, false=lhs.
//   mask = (rhs > lhs); true case = rhs, false case = lhs.

fn emitPminPmaxSynthesis(
    ctx: *EmitCtx,
    cmp_encoder: *const fn (rd: u5, rn: u5, rm: u5) u32,
    is_pmax: bool,
) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Step 1: FCMGT V31, V<a>, V<b>. For pmin, a=lhs, b=rhs (mask = lhs > rhs).
    // For pmax, a=rhs, b=lhs (mask = rhs > lhs).
    const cmp_a = if (is_pmax) rhs_v else lhs_v;
    const cmp_b = if (is_pmax) lhs_v else rhs_v;
    try gpr.writeU32(ctx.allocator, ctx.buf, cmp_encoder(op_simd.simd_scratch_v, cmp_a, cmp_b));

    // Step 2: BSL V31, V<rhs>.16B, V<lhs>.16B — mask ? rhs : lhs (same
    // for both pmin and pmax since the mask sense already encodes which).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encBsl16B(op_simd.simd_scratch_v, rhs_v, lhs_v));

    // Step 3: MOV V<result>.16B, V31.16B (alias of ORR Vd, Vn, Vn).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, op_simd.simd_scratch_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitF32x4Pmin(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon_lane_cmp.encFCmGt4S, false);
}
pub fn emitF32x4Pmax(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon_lane_cmp.encFCmGt4S, true);
}
pub fn emitF64x2Pmin(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon_lane_cmp.encFCmGt2D, false);
}
pub fn emitF64x2Pmax(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon_lane_cmp.encFCmGt2D, true);
}

// ============================================================
// FP per-lane compares
// ============================================================
//
// Wasm spec (SIMD) — `f*x*.{eq,ne,lt,gt,le,ge}` (12 ops total).
// Reuse the shared helpers: `op_simd.emitV128Binop` for direct,
// `op_simd.emitV128Ne` for ne synthesis,
// `op_simd.emitV128BinopSwapped` for lt/le rewrites (FCMEQ /
// FCMGT / FCMGE encoders).

pub fn emitF32x4Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encFCmEq4S);
}
pub fn emitF32x4Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Ne(ctx, inst_neon_lane_cmp.encFCmEq4S);
}
pub fn emitF32x4Gt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encFCmGt4S);
}
pub fn emitF32x4Ge(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encFCmGe4S);
}
pub fn emitF32x4Lt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encFCmGt4S);
}
pub fn emitF32x4Le(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encFCmGe4S);
}

pub fn emitF64x2Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encFCmEq2D);
}
pub fn emitF64x2Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Ne(ctx, inst_neon_lane_cmp.encFCmEq2D);
}
pub fn emitF64x2Gt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encFCmGt2D);
}
pub fn emitF64x2Ge(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encFCmGe2D);
}
pub fn emitF64x2Lt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encFCmGt2D);
}
pub fn emitF64x2Le(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encFCmGe2D);
}

// ============================================================
// i→f FP convert (4 ops)
// ============================================================
//
// Wasm spec — `f32x4.convert_i32x4_{s,u}` (single SCVTF/UCVTF .4S
// instruction) + `f64x2.convert_low_i32x4_{s,u}` (2-instruction
// synthesis: SXTL/UXTL .2D extends lower 2 i32 lanes to 2 i64,
// then SCVTF/UCVTF .2D converts in place). FPCR RMode=00 default
// gives IEEE-754 round-to-nearest-even, matching Wasm spec
// §4.3.2.11-13.

pub fn emitF32x4ConvertI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encScvtf4S);
}
pub fn emitF32x4ConvertI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUcvtf4S);
}

/// Helper: emit `f64x2.convert_low_i32x4_{s,u}` synthesis. Sequence:
///   1. SXTL/UXTL result.2D, src.2S — extend lower 2 i32 lanes to 2 i64.
///   2. SCVTF/UCVTF result.2D, result.2D — convert in place.
fn emitV128ConvertLowI32ToF64(
    ctx: *EmitCtx,
    extend_encoder: *const fn (rd: u5, rn: u5) u32,
    convert_encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, extend_encoder(result_v, src_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, convert_encoder(result_v, result_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitF64x2ConvertLowI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ConvertLowI32ToF64(ctx, inst_neon_arith.encSxtl2D, inst_neon_arith.encScvtf2D);
}
pub fn emitF64x2ConvertLowI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ConvertLowI32ToF64(ctx, inst_neon_arith.encUxtl2D, inst_neon_arith.encUcvtf2D);
}

// ============================================================
// FCVTL / FCVTN (FP narrow / widen)
// ============================================================
//
// Wasm spec — `f64x2.promote_low_f32x4` (widens lower 2 f32 →
// 2 f64) + `f32x4.demote_f64x2_zero` (narrows 2 f64 → lower 2
// f32 lanes; upper 2 zeroed by Q=0 form).

pub fn emitF64x2PromoteLowF32x4(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFCvtl_2D_2S);
}
pub fn emitF32x4DemoteF64x2Zero(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFCvtn_2S_2D);
}

// ============================================================
// trunc_sat (4 ops)
// ============================================================
//
// Wasm spec — `i32x4.trunc_sat_f32x4_{s,u}` (single-instruction
// FCVTZS/U .4S; NaN→0 + saturation match NEON default per Arm
// IHI 0055 §C7.2.131-133) + `i32x4.trunc_sat_f64x2_{s,u}_zero`
// (2-instruction synthesis: FCVTZS/U .2D narrows f64→i64 with
// sat, then SQXTN/UQXTN .2S narrows i64→i32 with sat; Q=0 form
// of the narrow instruction zeros upper 64 bits of the result,
// matching Wasm `_zero` semantic).

pub fn emitI32x4TruncSatF32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFcvtzs4S);
}
pub fn emitI32x4TruncSatF32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encFcvtzu4S);
}

/// Helper: emit `i32x4.trunc_sat_f64x2_*_zero` synthesis. Sequence:
///   1. FCVTZS/U result.2D, src.2D — f64x2 → i64x2 with sat.
///   2. SQXTN/UQXTN result.2S, result.2D — i64x2 → i32x2 with sat;
///      Q=0 form clears upper 64 bits of result.
/// For signed: convert_encoder=encFcvtzs2D, narrow_encoder=encSqxtn2S
/// For unsigned: convert_encoder=encFcvtzu2D, narrow_encoder=encUqxtn2S
fn emitV128TruncSatF64Zero(
    ctx: *EmitCtx,
    convert_encoder: *const fn (rd: u5, rn: u5) u32,
    narrow_encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, convert_encoder(result_v, src_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, narrow_encoder(result_v, result_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI32x4TruncSatF64x2SZero(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128TruncSatF64Zero(ctx, inst_neon_arith.encFcvtzs2D, inst_neon_arith.encSqxtn2S);
}
pub fn emitI32x4TruncSatF64x2UZero(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128TruncSatF64Zero(ctx, inst_neon_arith.encFcvtzu2D, inst_neon_arith.encUqxtn2S);
}
