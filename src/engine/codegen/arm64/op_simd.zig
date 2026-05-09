//! ARM64 emit pass — SIMD-128 op handlers (§9.9 / 9.5-b-iii
//! per ADR-0041).
//!
//! Wires the foundational NEON encoders (`inst_neon.zig`,
//! §9.5-a) into the ZirOp dispatch path. MVP catalogue
//! covers v128.load / v128.store / i32x4.splat / i32x4.add —
//! the four ops that demonstrate end-to-end the whole
//! SIMD pipeline (validator → lower → liveness → regalloc
//! with shape_tags → emit).
//!
//! Spill-aware integration: 9.5-b-iii MVP uses the existing
//! `gpr.resolveFp` for V-register resolution (works for
//! non-spilling functions where the SIMD vregs all fit in
//! V16-V28). Spilled v128 vregs need a 16-byte-stride
//! analog of `gpr.fpLoadSpilled` / `gpr.fpStoreSpilled`
//! (defers to 9.5-c per ADR-0041 chunk plan; current
//! `fpDefSpilled` uses 8-byte D-form stride). For now,
//! spilled v128 vregs return `UnsupportedOp` matching the
//! `gpr.resolveFp` graceful-degradation pattern.
//!
//! Per ADR-0041 §"Decision" / 2 (FP-class register pool
//! reuse with shape-tag axis): handlers query
//! `ctx.alloc.shapeTag(vreg)` only when the spill path
//! lands in 9.5-c — for non-spilled cases the V-register
//! choice is identical to scalar f32/f64.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// `v128.load`: pop i32 address (Wn), push v128 result (Vd.16B).
/// `LDR Q<vd>, [X<wn>, #imm]`. The memarg's offset payload encodes
/// the byte offset (must be 16-byte aligned for the imm12 form;
/// for non-aligned offsets we'd need to materialise a base + ADD,
/// which is a 9.5-c extension).
///
/// 9.5-b-iii MVP: only handles the in-V-register path. Spilled
/// v128 vregs (slot id >= max_reg_slots_fp = 13) return
/// `UnsupportedOp` via `resolveFp` — 9.5-c lifts this restriction
/// alongside 16-byte spill helpers.
pub fn emitV128Load(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const addr_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: i32 addr; GPR spill-aware path is its own follow-on (mirrors 9.5-c-i's v128-only scope).
    const addr_reg = try gpr.resolveGpr(ctx.alloc, addr_vreg);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // §9.5-c-ii: v128 result via Q-form def helper. If spilled,
    // returns V29 stage; otherwise the vreg's V-reg home.
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    const offset = ins.payload;
    if (offset > 65535 or (offset & 0xF) != 0) {
        // 9.5-b-iii MVP: only 16-byte-aligned imm12 offsets.
        // Larger or unaligned offsets need a base+ADD sequence
        // (9.5-c lift).
        std.debug.print(
            "arm64/op_simd: v128.load unsupported offset {d} (must be 16-byte-aligned & <= 65520)\n",
            .{offset},
        );
        return Error.UnsupportedOp;
    }

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encLdrQImm(result_v, addr_reg, @intCast(offset)));
    // §9.5-c-ii: flush v128 result to spill slot if spilled.
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `v128.store`: pop v128 value (Vt.16B), pop i32 address (Wn).
/// `STR Q<vt>, [X<wn>, #imm]`. Same alignment + offset
/// constraints as `v128.load`.
pub fn emitV128Store(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const value_vreg = ctx.pushed_vregs.pop().?;
    // §9.5-c-ii: v128 operand via Q-form load helper.
    const value_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);

    const addr_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: i32 addr; GPR spill-aware path is its own follow-on.
    const addr_reg = try gpr.resolveGpr(ctx.alloc, addr_vreg);

    const offset = ins.payload;
    if (offset > 65535 or (offset & 0xF) != 0) {
        std.debug.print(
            "arm64/op_simd: v128.store unsupported offset {d} (must be 16-byte-aligned & <= 65520)\n",
            .{offset},
        );
        return Error.UnsupportedOp;
    }

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encStrQImm(value_v, addr_reg, @intCast(offset)));
}

/// `i32x4.splat`: pop scalar i32 (Wn), push v128 result (Vd.4S).
/// `DUP V<vd>.4S, W<wn>` broadcasts the i32 to all four 32-bit
/// lanes.
pub fn emitI32x4Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: i32 src; GPR spill-aware path is its own follow-on.
    const src_reg = try gpr.resolveGpr(ctx.alloc, src_vreg);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // §9.5-c-ii: v128 result via Q-form def + store helpers.
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encDup4S(result_v, src_reg));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `i32x4.add`: pop two v128 (Vn.4S, Vm.4S), push v128 sum
/// (Vd.4S). `ADD V<vd>.4S, V<vn>.4S, V<vm>.4S` does element-wise
/// 32-bit add across the four lanes.
/// Shared v128 binop emit helper (§9.5-c-iv): pop 2 v128, emit
/// `encoder(rd, rn, rm)`, push 1 v128. Spill-aware via the q*
/// trio at stage_idx 0/1 (same convention as gpr/fp binops —
/// lhs at 0, rhs at 1; result reuses 0 since lhs is consumed).
fn emitV128Binop(
    ctx: *EmitCtx,
    encoder: *const fn (rd: u5, rn: u5, rm: u5) u32,
) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, lhs_v, rhs_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI8x16Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAdd16B);
}
pub fn emitI8x16Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encSub16B);
}
pub fn emitI16x8Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAdd8H);
}
pub fn emitI16x8Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encSub8H);
}
pub fn emitI32x4Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAdd4S);
}
pub fn emitI32x4Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encSub4S);
}
pub fn emitI64x2Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAdd2D);
}
pub fn emitI64x2Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encSub2D);
}
// Note: Wasm SIMD has no `i8x16.mul` (only i16x8/i32x4/i64x2). The
// underlying NEON `MUL Vd.16B` encoding (encMul16B) is preserved
// in inst_neon.zig for completeness but no ZirOp dispatches to it.
pub fn emitI16x8Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encMul8H);
}
pub fn emitI32x4Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encMul4S);
}

/// `i32x4.extract_lane`: pop v128 (Vn.4S), push i32 result (Wd).
/// `UMOV W<wd>, V<vn>.S[lane]` extracts the 32-bit lane (zero-
/// extended into Wd). Lane immediate is in `ins.payload`
/// (per `lower.emitLaneByte`'s 1-byte encoding from §9.4).
pub fn emitI32x4ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: i32 result (GPR); spill-aware path is its own follow-on alongside other GPR sites.
    const result_w = try gpr.resolveGpr(ctx.alloc, result_vreg);

    const lane: u2 = @intCast(ins.payload & 3);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovWFromS(result_w, src_v, lane));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `i32x4.replace_lane`: pop scalar i32 (Wn), pop v128 (Vd.4S),
/// push v128 result (Vd' = Vd with lane[ins.payload] replaced).
/// `INS V<vd>.S[lane], W<wn>`. Note: INS modifies the destination
/// in place; for our pipeline (where the result is a fresh vreg
/// distinct from the input v128 vreg), the handler first MOVs
/// the input v128 into the result V-reg, then INS the lane.
/// When the input v128 is the same V-reg as the result (slot
/// reuse), the MOV is a no-op (encMovV16B Vd, Vd is harmless).
pub fn emitI32x4ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const new_lane_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: i32 new-lane scalar (GPR); spill-aware path is its own follow-on.
    const new_lane_w = try gpr.resolveGpr(ctx.alloc, new_lane_vreg);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 1);

    // Copy source v128 to result reg (skip if same V-reg).
    if (src_v != result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, src_v));
    }
    const lane: u2 = @intCast(ins.payload & 3);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encInsSFromW(result_v, new_lane_w, lane));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// §9.9 / 9.5-c-vi — i8x16 / i16x8 / i64x2 lane access
// ============================================================
//
// Wasm SIMD spec — extract_lane (signed/unsigned) + replace_lane
// for the remaining int element widths. i32x4 is already wired
// in 9.5-c-iii above. f32x4 / f64x2 + i64x2.mul defer to
// 9.5-c-vii.
//
// All extract handlers return an i32 GPR result (i64 for i64x2).
// replace handlers consume an i32 GPR new-lane (i64 for i64x2).
// Per ADR-0041, the GPR side stays on the SPILL-EXEMPT escape
// hatch alongside the rest of 9.5-c (D-034 BASELINE=0; spill-
// aware GPR machinery lands in a later sub-row alongside the
// remaining bare-resolveGpr sites).

/// Helper: emit an `extract_lane` shape that reads a v128 lane via
/// a UMOV/SMOV-family encoder. The encoder builds the 32-bit
/// instruction word from (rd:Xn, rn:Vn, lane). `lane_mask` clamps
/// `ins.payload`'s lane field to the element-form's valid range.
fn emitV128ExtractLane(
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
    // SPILL-EXEMPT: scalar lane result (GPR); spill-aware path is its own follow-on alongside other GPR sites.
    const result_x = try gpr.resolveGpr(ctx.alloc, result_vreg);

    const lane = ins.payload & lane_mask;
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_x, src_v, lane));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit a `replace_lane` shape that writes a v128 lane via
/// an INS-family encoder.
fn emitV128ReplaceLane(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    encoder: *const fn (rd: u5, rn: u5, lane: u32) u32,
    lane_mask: u32,
) Error!void {
    const new_lane_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: scalar new-lane (GPR); spill-aware path is its own follow-on alongside other GPR sites.
    const new_lane_x = try gpr.resolveGpr(ctx.alloc, new_lane_vreg);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 1);

    if (src_v != result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, src_v));
    }
    const lane = ins.payload & lane_mask;
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, new_lane_x, lane));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// Encoder thunks — adapt the per-element-form encoder signatures to
// the helper's `(u5, u5, u32) -> u32` shape. The helpers want a
// uniform lane type so both u4 (B) and u3 (H) and u1 (D) encoders
// can share one code path; the cast is safe because `lane_mask`
// constrains the value first.

fn encUmovB(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encUmovWFromB(rd, rn, @intCast(lane));
}
fn encSmovB(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encSmovWFromB(rd, rn, @intCast(lane));
}
fn encInsB(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encInsBFromW(rd, rn, @intCast(lane));
}
fn encUmovH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encUmovWFromH(rd, rn, @intCast(lane));
}
fn encSmovH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encSmovWFromH(rd, rn, @intCast(lane));
}
fn encInsH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encInsHFromW(rd, rn, @intCast(lane));
}
fn encUmovD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encUmovXFromD(rd, rn, @intCast(lane));
}
fn encInsD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encInsDFromX(rd, rn, @intCast(lane));
}

/// Wasm spec (SIMD) — `i8x16.extract_lane_s`: lane ∈ 0..15;
/// sign-extend the byte into i32. Lowers to `SMOV W<rd>, V<rn>.B[lane]`.
pub fn emitI8x16ExtractLaneS(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encSmovB, 0xF);
}

/// Wasm spec (SIMD) — `i8x16.extract_lane_u`: zero-extend the byte
/// into i32. Lowers to `UMOV W<rd>, V<rn>.B[lane]`.
pub fn emitI8x16ExtractLaneU(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encUmovB, 0xF);
}

/// Wasm spec (SIMD) — `i8x16.replace_lane`: replace the lane with the
/// low 8 bits of an i32 input. Lowers to `INS V<vd>.B[lane], W<wn>`.
pub fn emitI8x16ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLane(ctx, ins, encInsB, 0xF);
}

/// Wasm spec (SIMD) — `i16x8.extract_lane_s`: sign-extend the halfword
/// into i32. Lowers to `SMOV W<rd>, V<rn>.H[lane]`.
pub fn emitI16x8ExtractLaneS(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encSmovH, 0x7);
}

/// Wasm spec (SIMD) — `i16x8.extract_lane_u`: zero-extend the halfword
/// into i32. Lowers to `UMOV W<rd>, V<rn>.H[lane]`.
pub fn emitI16x8ExtractLaneU(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encUmovH, 0x7);
}

/// Wasm spec (SIMD) — `i16x8.replace_lane`: replace the lane with the
/// low 16 bits of an i32 input. Lowers to `INS V<vd>.H[lane], W<wn>`.
pub fn emitI16x8ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLane(ctx, ins, encInsH, 0x7);
}

/// Wasm spec (SIMD) — `i64x2.extract_lane`: lane ∈ 0..1; copy the
/// 64-bit lane into an i64 GPR. Lowers to `UMOV X<rd>, V<rn>.D[lane]`.
/// (No signed/unsigned variant — i64 has no narrower width to extend
/// from.)
pub fn emitI64x2ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encUmovD, 0x1);
}

/// Wasm spec (SIMD) — `i64x2.replace_lane`: replace the lane with an
/// i64 input. Lowers to `INS V<vd>.D[lane], X<rn>`.
pub fn emitI64x2ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLane(ctx, ins, encInsD, 0x1);
}

// ============================================================
// §9.9 / 9.5-c-vii — f32x4 / f64x2 lane access
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
/// `emitV128ExtractLane` but resolves the result vreg to a V
/// register via `gpr.resolveFp` instead of a GPR via `resolveGpr`.
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
    // SPILL-EXEMPT: FP scalar result; fpDefSpilled (D-form, 8-byte stride) is its own follow-on alongside other FP-side sites.
    const result_v = try gpr.resolveFp(ctx.alloc, result_vreg);

    const lane = ins.payload & lane_mask;
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_v, lane));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit `replace_lane` for FP-input variants. The new-lane
/// scalar comes from a V register (S/D form low bits), not a GPR.
fn emitV128ReplaceLaneFp(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    encoder: *const fn (rd: u5, dst_lane: u32, rn: u5) u32,
    lane_mask: u32,
) Error!void {
    const new_lane_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: FP scalar new-lane; fpLoadSpilled is its own follow-on alongside other FP-side sites.
    const new_lane_v = try gpr.resolveFp(ctx.alloc, new_lane_vreg);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 1);

    if (src_v != result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, src_v));
    }
    const lane = ins.payload & lane_mask;
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, lane, new_lane_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// Encoder thunks for the FP forms (parallel to the int thunks above).
fn encDupScalarS(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encMovScalarSFromVlane(rd, rn, @intCast(lane));
}
fn encDupScalarD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encMovScalarDFromVlane(rd, rn, @intCast(lane));
}
fn encInsElemS(rd: u5, dst_lane: u32, rn: u5) u32 {
    return inst_neon.encMovVSlaneFromVS0(rd, @intCast(dst_lane), rn);
}
fn encInsElemD(rd: u5, dst_lane: u32, rn: u5) u32 {
    return inst_neon.encMovVDlaneFromVD0(rd, @intCast(dst_lane), rn);
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
// §9.9 / 9.5-c-vii-mul — i64x2.mul multi-instr synthesis
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
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovXFromD(i64x2_mul_scratch_a, lhs_v, k));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovXFromD(i64x2_mul_scratch_b, rhs_v, k));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMulReg(i64x2_mul_scratch_a, i64x2_mul_scratch_a, i64x2_mul_scratch_b));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encInsDFromX(result_v, i64x2_mul_scratch_a, k));
    }

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// §9.6 / 9.6-a — f32x4 / f64x2 binary FP arithmetic
// ============================================================
//
// Wasm spec (SIMD) — `f32x4.add/sub/mul/div`, `f64x2.add/sub/mul/div`.
// Lowers to NEON FADD/FSUB/FMUL/FDIV with 4S (S = single) or 2D
// (D = double) arrangement. NEON FP arith follows IEEE-754
// round-to-nearest-even with NaN-propagation matching Wasm
// semantics (per ADR-0041 §"4. NEON IEEE-754 spec-fidelity").
//
// All 8 handlers share the existing `emitV128Binop` shape — pop
// 2 v128, push 1 v128 — so they're thin adapters around the
// per-shape encoder.

pub fn emitF32x4Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFAdd4S);
}
pub fn emitF32x4Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFSub4S);
}
pub fn emitF32x4Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMul4S);
}
pub fn emitF32x4Div(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFDiv4S);
}
pub fn emitF64x2Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFAdd2D);
}
pub fn emitF64x2Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFSub2D);
}
pub fn emitF64x2Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMul2D);
}
pub fn emitF64x2Div(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFDiv2D);
}

// ============================================================
// §9.6 / 9.6-b — f32x4 / f64x2 unary FP arithmetic
// ============================================================
//
// Wasm spec (SIMD) — `f32x4.{abs,neg,sqrt,ceil,floor,trunc,nearest}`
// and the f64x2 counterparts. Lowers to NEON FABS / FNEG / FSQRT /
// FRINTN / FRINTM / FRINTP / FRINTZ with 4S or 2D shape.

/// Helper: emit a v128 unary op via the given encoder (rd, rn) → u32.
/// Pop 1 v128 vreg, push 1 v128 result. Mirrors `emitV128Binop` but
/// with one source operand.
fn emitV128Unop(ctx: *EmitCtx, encoder: *const fn (rd: u5, rn: u5) u32) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitF32x4Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFAbs4S);
}
pub fn emitF32x4Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFNeg4S);
}
pub fn emitF32x4Sqrt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFSqrt4S);
}
pub fn emitF32x4Ceil(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintP4S);
}
pub fn emitF32x4Floor(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintM4S);
}
pub fn emitF32x4Trunc(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintZ4S);
}
pub fn emitF32x4Nearest(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintN4S);
}
pub fn emitF64x2Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFAbs2D);
}
pub fn emitF64x2Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFNeg2D);
}
pub fn emitF64x2Sqrt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFSqrt2D);
}
pub fn emitF64x2Ceil(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintP2D);
}
pub fn emitF64x2Floor(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintM2D);
}
pub fn emitF64x2Trunc(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintZ2D);
}
pub fn emitF64x2Nearest(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintN2D);
}

// ============================================================
// §9.6 / 9.6-c-i — f32x4 / f64x2 min / max (NaN-propagating)
// ============================================================
//
// Wasm spec (SIMD) — IEEE-754-2008 min/max with NaN propagation.
// NEON FMAX/FMIN match exactly. `pmin`/`pmax` (pseudo-min/max
// with zero-on-equal-magnitude semantics) defer to 9.6-c-ii.

pub fn emitF32x4Min(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMin4S);
}
pub fn emitF32x4Max(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMax4S);
}
pub fn emitF64x2Min(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMin2D);
}
pub fn emitF64x2Max(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMax2D);
}

// ============================================================
// §9.6 / 9.6-c-ii — f32x4/f64x2 pmin/pmax synthesis
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

const simd_scratch_v: u5 = 31; // V31 / reserved scratch per ADR-0041 + regalloc.zig

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
    try gpr.writeU32(ctx.allocator, ctx.buf, cmp_encoder(simd_scratch_v, cmp_a, cmp_b));

    // Step 2: BSL V31, V<rhs>.16B, V<lhs>.16B — mask ? rhs : lhs (same
    // for both pmin and pmax since the mask sense already encodes which).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encBsl16B(simd_scratch_v, rhs_v, lhs_v));

    // Step 3: MOV V<result>.16B, V31.16B (alias of ORR Vd, Vn, Vn).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, simd_scratch_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitF32x4Pmin(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon.encFCmGt4S, false);
}
pub fn emitF32x4Pmax(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon.encFCmGt4S, true);
}
pub fn emitF64x2Pmin(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon.encFCmGt2D, false);
}
pub fn emitF64x2Pmax(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon.encFCmGt2D, true);
}

// ============================================================
// §9.6 / 9.6-d — Int per-lane compares
// ============================================================
//
// Wasm spec (SIMD) — `i*x*.{eq,ne,lt_s,lt_u,gt_s,gt_u,le_s,le_u,ge_s,ge_u}`.
// i64x2 omits the unsigned variants per Wasm 2.0 SIMD.
//
// Strategy:
// - eq: emitV128Binop with CMEQ encoder
// - ne: CMEQ + NOT V16B (3-instr synthesis using V31 scratch)
// - gt_s: emitV128Binop with CMGT encoder
// - gt_u: emitV128Binop with CMHI encoder
// - ge_s: emitV128Binop with CMGE encoder
// - ge_u: emitV128Binop with CMHS encoder
// - lt_*: same encoder as gt_*, but operands swapped at handler level
// - le_*: same encoder as ge_*, but operands swapped

/// Helper: emit a binop with operands swapped (calls encoder(rd, rhs, lhs)
/// instead of the default encoder(rd, lhs, rhs)). Used for lt/le → gt/ge
/// rewrites.
fn emitV128BinopSwapped(ctx: *EmitCtx, encoder: *const fn (rd: u5, rn: u5, rm: u5) u32) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Operand swap — for lt(a,b) we emit gt(b,a).
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, rhs_v, lhs_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit `ne` synthesis. CMEQ → NOT V16B → MOV result, V31.
fn emitV128Ne(ctx: *EmitCtx, eq_encoder: *const fn (rd: u5, rn: u5, rm: u5) u32) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Step 1: CMEQ V31, V<lhs>, V<rhs>
    try gpr.writeU32(ctx.allocator, ctx.buf, eq_encoder(simd_scratch_v, lhs_v, rhs_v));
    // Step 2: NOT V31.16B, V31.16B
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encNotV16B(simd_scratch_v, simd_scratch_v));
    // Step 3: MOV V<result>.16B, V31.16B
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, simd_scratch_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// i8x16 compares
pub fn emitI8x16Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmEq16B); }
pub fn emitI8x16Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encCmEq16B); }
pub fn emitI8x16GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGt16B); }
pub fn emitI8x16GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHi16B); }
pub fn emitI8x16GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGe16B); }
pub fn emitI8x16GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHs16B); }
pub fn emitI8x16LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGt16B); }
pub fn emitI8x16LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHi16B); }
pub fn emitI8x16LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGe16B); }
pub fn emitI8x16LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHs16B); }

// i16x8 compares
pub fn emitI16x8Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmEq8H); }
pub fn emitI16x8Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encCmEq8H); }
pub fn emitI16x8GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGt8H); }
pub fn emitI16x8GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHi8H); }
pub fn emitI16x8GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGe8H); }
pub fn emitI16x8GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHs8H); }
pub fn emitI16x8LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGt8H); }
pub fn emitI16x8LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHi8H); }
pub fn emitI16x8LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGe8H); }
pub fn emitI16x8LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHs8H); }

// i32x4 compares
pub fn emitI32x4Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmEq4S); }
pub fn emitI32x4Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encCmEq4S); }
pub fn emitI32x4GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGt4S); }
pub fn emitI32x4GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHi4S); }
pub fn emitI32x4GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGe4S); }
pub fn emitI32x4GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHs4S); }
pub fn emitI32x4LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGt4S); }
pub fn emitI32x4LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHi4S); }
pub fn emitI32x4LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGe4S); }
pub fn emitI32x4LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHs4S); }

// i64x2 compares — signed only per Wasm 2.0 SIMD.
pub fn emitI64x2Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmEq2D); }
pub fn emitI64x2Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encCmEq2D); }
pub fn emitI64x2GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGt2D); }
pub fn emitI64x2GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGe2D); }
pub fn emitI64x2LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGt2D); }
pub fn emitI64x2LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGe2D); }

// ============================================================
// §9.6 / 9.6-e — FP per-lane compares
// ============================================================
//
// Wasm spec (SIMD) — `f*x*.{eq,ne,lt,gt,le,ge}` (12 ops total).
// Reuse 9.6-d's helpers: `emitV128Binop` for direct, `emitV128Ne`
// for ne synthesis, `emitV128BinopSwapped` for lt/le rewrites.
// FCMGT was added in 9.6-c-ii; FCMEQ + FCMGE land here.

pub fn emitF32x4Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmEq4S); }
pub fn emitF32x4Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encFCmEq4S); }
pub fn emitF32x4Gt(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmGt4S); }
pub fn emitF32x4Ge(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmGe4S); }
pub fn emitF32x4Lt(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encFCmGt4S); }
pub fn emitF32x4Le(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encFCmGe4S); }

pub fn emitF64x2Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmEq2D); }
pub fn emitF64x2Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encFCmEq2D); }
pub fn emitF64x2Gt(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmGt2D); }
pub fn emitF64x2Ge(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmGe2D); }
pub fn emitF64x2Lt(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encFCmGt2D); }
pub fn emitF64x2Le(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encFCmGe2D); }
