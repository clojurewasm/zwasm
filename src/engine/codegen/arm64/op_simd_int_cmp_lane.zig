//! ARM64 emit pass — SIMD-128 integer compare / lane access /
//! extend / narrow / bitmask / all_true / shuffle / swizzle op
//! handlers (split from `op_simd.zig`).
//!
//! Houses i*x*.{eq,ne,lt_*,gt_*,le_*,ge_*}, lane access
//! (extract_lane / replace_lane / splat for int shapes), extend
//! (low/high signed/unsigned), narrow (saturating), bitmask,
//! all_true (reductions), and the const-pool-driven shuffle +
//! swizzle handlers. Uses `op_simd.emitV128Binop` /
//! `op_simd.emitV128BinopSwapped` / `op_simd.emitV128Ne` /
//! `op_simd.emitV128Unop` for the canonical shapes;
//! bitmask + all_true own their own scratch reservations.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

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

/// Wasm spec §4.4.5 (`<shape>.splat`) — broadcast a scalar to
/// every lane of a v128. Shared GPR-source helper (i8x16 / i16x8
/// / i32x4 / i64x2 splat); FP-source variants (f32x4 / f64x2)
/// live in `op_simd_float.zig`.
fn emitV128SplatFromGpr(
    ctx: *EmitCtx,
    encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    // D-034 (b): spill-aware GPR splat-source (was resolveGpr-EXEMPT). gprLoadSpilled
    // stage0/X14 (X-file) — disjoint from the V-file qDef stage (V29); DUP reads the
    // GPR and writes the V-reg, distinct register files, no collision.
    const src_reg = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_reg));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `i8x16.splat`: pop i32 scalar (low byte), broadcast to 16 bytes.
pub fn emitI8x16Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromGpr(ctx, inst_neon.encDup16B);
}

/// `i16x8.splat`: pop i32 scalar (low half), broadcast to 8 halves.
pub fn emitI16x8Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromGpr(ctx, inst_neon.encDup8H);
}

/// `i32x4.splat`: pop scalar i32 (Wn), push v128 result (Vd.4S).
/// `DUP V<vd>.4S, W<wn>` broadcasts the i32 to all four 32-bit
/// lanes.
pub fn emitI32x4Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromGpr(ctx, inst_neon.encDup4S);
}

/// `i64x2.splat`: pop i64 scalar (Xn), broadcast to both 64-bit lanes.
pub fn emitI64x2Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromGpr(ctx, inst_neon.encDupGen2D);
}

/// `i32x4.extract_lane`: pop v128 (Vn.4S), push i32 result (Wd).
/// `UMOV W<wd>, V<vn>.S[lane]` extracts the 32-bit lane (zero-
/// extended into Wd). Lane immediate is in `ins.payload`
/// (per `lower.emitLaneByte`'s 1-byte encoding).
pub fn emitI32x4ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // D-461: spill-aware i32 result (was resolveGpr-reject). The v128 source
    // uses qLoadSpilled stage 0 (V-file); the GPR result uses gprDef/Store stage
    // 0 (X-file) — disjoint reg files, so stage 0 is safe for both.
    const result_w = try gpr.gprDefSpilled(ctx.alloc, result_vreg, 0);
    const lane: u2 = @intCast(ins.payload & 3);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovWFromS(result_w, src_v, lane));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
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
    // D-034 (a): spill-aware GPR new-lane (was resolveGpr-EXEMPT). gprLoadSpilled
    // stage0 → X14 if spilled (X-file, disjoint from the V-file qLoad/qDef stages
    // used by src/result; consumed by INS before any further GPR-stage use).
    const new_lane_w = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, new_lane_vreg, 0);

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
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encInsSFromW(result_v, new_lane_w, lane));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// i8x16 / i16x8 / i64x2 lane access
// ============================================================
//
// Wasm SIMD spec — extract_lane (signed/unsigned) + replace_lane
// for the remaining int element widths. i32x4 is already wired
// above; f32x4 / f64x2 live in `op_simd_float.zig` and i64x2.mul
// in `op_simd_int_arith.zig`.
//
// All extract handlers return an i32 GPR result (i64 for i64x2).
// replace handlers consume an i32 GPR new-lane (i64 for i64x2).
// Per ADR-0041, the GPR side stays on the SPILL-EXEMPT escape
// hatch alongside the rest of the lane ops (D-034 BASELINE=0;
// spill-aware GPR machinery lands in a later sub-row alongside the
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
    // D-461: spill-aware GPR lane result (was resolveGpr-reject). Mirrors
    // emitI32x4ExtractLane: src_v uses qLoadSpilled stage 0 (V-file), the GPR
    // result uses gprDef/Store stage 0 (X-file) — disjoint reg files, stage 0
    // safe for both. Covers i8x16/i16x8 (_s/_u) + i64x2 extract_lane.
    const result_x = try gpr.gprDefSpilled(ctx.alloc, result_vreg, 0);

    const lane: u32 = @intCast(ins.payload & lane_mask);
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_x, src_v, lane));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
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
    // D-034 (a): spill-aware GPR new-lane (was resolveGpr-EXEMPT). gprLoadSpilled
    // stage0/X14 (X-file, disjoint from V-file qLoad/qDef); covers i8x16/i16x8/i64x2.
    const new_lane_x = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, new_lane_vreg, 0);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 1);

    if (src_v != result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, src_v));
    }
    const lane: u32 = @intCast(ins.payload & lane_mask);
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
    return inst_neon_lane_cmp.encUmovWFromB(rd, rn, @intCast(lane));
}
fn encSmovB(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encSmovWFromB(rd, rn, @intCast(lane));
}
fn encInsB(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encInsBFromW(rd, rn, @intCast(lane));
}
fn encUmovH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encUmovWFromH(rd, rn, @intCast(lane));
}
fn encSmovH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encSmovWFromH(rd, rn, @intCast(lane));
}
fn encInsH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encInsHFromW(rd, rn, @intCast(lane));
}
fn encUmovD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encUmovXFromD(rd, rn, @intCast(lane));
}
fn encInsD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon_lane_cmp.encInsDFromX(rd, rn, @intCast(lane));
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
// v128 reductions (all_true)
// ============================================================
//
// Wasm SIMD spec — `i*x*.all_true` returns 1 iff every lane of
// the input v128 is non-zero. Pops v128, pushes i32. (The
// matching `v128.any_true` reduction stays in op_simd.zig
// alongside the V128 bitwise family.)
//
// ARM64 strategy:
//
//   i8x16/i16x8/i32x4.all_true: UMINV {B,H,S}<v>, V<src>.{16B,8H,
//             4S} (min lane is non-zero iff every lane was).
//             Then UMOV → CMP → CSET NE. Same shape; the encoder
//             differs by lane-width.
//
//   i64x2.all_true: NEON has no UMINV.2D form — synthesise via
//             two D-lane extracts + CMP + CSET + AND. Per Arm
//             IHI 0055 §C7.2.394 (UMINV is byte/halfword/word
//             only; doubleword reduction requires GPR detour).
//
// Result vreg is GPR-class (i32). The shared helper
// `emitV128ReduceWithEncoder` handles the common path; i64x2 has
// its own dedicated handler.

const reduce_scratch_v: u5 = 29; // V29: fp_spill_stage[0]; safe inside this op.
const reduce_scratch_x_a: u5 = 16; // X16 / IP0
const reduce_scratch_x_b: u5 = 17; // X17 / IP1

fn emitV128ReduceWithEncoder(
    ctx: *EmitCtx,
    encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // D-034 (e): spill-aware GPR result (was resolveGpr-reject). gprDefSpilled
    // stage 0 → X14 if spilled, disjoint from the X16/X17 reduce scratch + V29;
    // the result is written once (CSET) at the end, then flushed via
    // gprStoreSpilled. Mirrors emitV128ExtractLane's GPR-result @a534d1c45.
    const result_w = try gpr.gprDefSpilled(ctx.alloc, result_vreg, 0);

    // Reduce into V29 (lane 0 holds the max/min byte/half/word).
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(reduce_scratch_v, src_v));
    // Extract lane 0 (B form) into W16 — width 8 / 16 / 32 of the
    // reduced scalar all zero-extend cleanly into W via UMOV B
    // since "value != 0" is what we actually compare; the upper
    // bits are immaterial.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovWFromB(reduce_scratch_x_a, reduce_scratch_v, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(reduce_scratch_x_a, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(result_w, .ne));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI8x16AllTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ReduceWithEncoder(ctx, inst_neon_arith.encUminv16B);
}

pub fn emitI16x8AllTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ReduceWithEncoder(ctx, inst_neon_arith.encUminv8H);
}

pub fn emitI32x4AllTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ReduceWithEncoder(ctx, inst_neon_arith.encUminv4S);
}

/// `i64x2.all_true`: NEON UMINV has no 2D form. Synthesise via
/// extracting both 64-bit lanes to GPRs, comparing each to 0,
/// and ANDing the cset results. 6 instructions.
pub fn emitI64x2AllTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // D-034 (e): spill-aware GPR result (was resolveGpr-reject). gprDefSpilled
    // stage 0 → X14 if spilled (disjoint from X16/X17 + V29); result written
    // once (AND) at the end, then flushed. Mirrors emitV128ReduceWithEncoder.
    const result_w = try gpr.gprDefSpilled(ctx.alloc, result_vreg, 0);

    // X16 ← src.D[0]; X17 ← src.D[1].
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovXFromD(reduce_scratch_x_a, src_v, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovXFromD(reduce_scratch_x_b, src_v, 1));
    // CMP X16, #0 ; CSET W16, NE
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(reduce_scratch_x_a, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(reduce_scratch_x_a, .ne));
    // CMP X17, #0 ; CSET W17, NE
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(reduce_scratch_x_b, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(reduce_scratch_x_b, .ne));
    // AND W<result>, W16, W17
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAndRegW(result_w, reduce_scratch_x_a, reduce_scratch_x_b));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// i*x*.bitmask (per ADR-0051 + ADR-0042)
//
// Wasm spec §4.4.4: pop v128, push i32 where bit i = sign bit
// (high bit) of lane i. The recipe (per cranelift `aarch64/
// lower.isle:2883-2943`) for vector shapes:
//
//   SSHR Vt, V<src>, #(lane_width-1)   ; broadcast sign bit
//   LDR  Q<mask>, <pool>                ; per-shape 1<<lane mask
//   AND  Vt, Vt, V<mask>
//   <reduce> Vt → low byte/halfword/word
//   UMOV W<dst>, V<t>.<elem>[0]
//
// i8x16 needs an extra fold (NEON ADDV.16B reduces to byte 0 but
// the byte cap is 255 — 16 mask values up to 128 each would
// overflow into byte arithmetic that ADDV does NOT widen). The
// recipe rearranges via EXT (swap halves) + ZIP1 (interleave
// pairs into halfwords) then ADDV.8H, so each halfword sees only
// 2 mask values summed (max 0xFF + 0x80) which the H-form
// accumulates without overflow.
//
// i64x2 has no NEON 2D-form ADDV — synthesise via scalar UMOV +
// LSR #63 per lane + ADD.
// ============================================================

/// Per-shape position-mask literals for the bitmask recipe. Each
/// lane holds `1 << (lane_index % bits_per_byte_group)`; ADDV
/// across the AND'd vector then packs all marked bits into a
/// single low byte/halfword/word.
const I8X16_BITMASK_MASK: [16]u8 = [_]u8{
    1, 2, 4, 8, 16, 32, 64, 128,
    1, 2, 4, 8, 16, 32, 64, 128,
};
/// i16x8: little-endian halfwords [1, 2, 4, 8, 16, 32, 64, 128].
const I16X8_BITMASK_MASK: [16]u8 = [_]u8{
    1,  0, 2,  0, 4,  0, 8,   0,
    16, 0, 32, 0, 64, 0, 128, 0,
};
/// i32x4: little-endian words [1, 2, 4, 8].
const I32X4_BITMASK_MASK: [16]u8 = [_]u8{
    1, 0, 0, 0, 2, 0, 0, 0,
    4, 0, 0, 0, 8, 0, 0, 0,
};

/// Append `value` to `ctx.extra_consts` if not already present
/// (linear scan dedup), returning the global const_idx (i.e.
/// `simd_consts_base + position-in-extra_consts`). Mirrors x86_64's
/// `op_simd.lookupOrAppendExtraConst` per ADR-0051.
fn lookupOrAppendExtraConst(ctx: *EmitCtx, value: [16]u8) Error!u32 {
    for (ctx.extra_consts.items, 0..) |c, i| {
        if (std.mem.eql(u8, &c, &value)) {
            return ctx.simd_consts_base + @as(u32, @intCast(i));
        }
    }
    const idx: u32 = ctx.simd_consts_base +
        @as(u32, @intCast(ctx.extra_consts.items.len));
    try ctx.extra_consts.append(ctx.allocator, value);
    return idx;
}

/// Emit an `LDR Q<rt>, <const-pool entry>` placeholder for the
/// given global const_idx, recording a SimdConstFixup. Matches
/// the shape used by emitV128Const / emitI8x16Shuffle.
fn emitLdrLiteralQForConst(ctx: *EmitCtx, rt: u5, const_idx: u32) Error!void {
    const fixup_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encLdrLiteralQ(rt, 0));
    try ctx.simd_const_fixups.append(ctx.allocator, .{
        .byte_offset = fixup_byte,
        .const_idx = const_idx,
    });
}

// Scratch V registers usable inside a unary v128 → i32 handler.
// `qLoadSpilled(..., 0)` returns V29 (fp_spill_stage[0]) when the
// source is spilled. V30 / V31 are free in a unary op (V30 is
// fp_spill_stage[1] which only fires on qLoadSpilled(..., 1);
// V31 is popcnt-pipeline-reserved but this handler is not part
// of a popcnt sequence).
const bitmask_scratch_v_t: u5 = 30;
const bitmask_scratch_v_mask: u5 = 31;

pub fn emitI8x16Bitmask(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_w = try gpr.resolveGpr(ctx.alloc, result_vreg);

    const mask_idx = try lookupOrAppendExtraConst(ctx, I8X16_BITMASK_MASK);
    // V<t> = SSHR src.16B, #7  — broadcast sign bit (0x00 or 0xFF per lane).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSshrV16B(bitmask_scratch_v_t, src_v, 7));
    // V<mask> ← LDR Q literal — per-shape 1<<(lane%8) mask.
    try emitLdrLiteralQForConst(ctx, bitmask_scratch_v_mask, mask_idx);
    // V<t> = V<t> AND V<mask>  — each lane: 0 or 1<<(lane%8).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encAnd16B(bitmask_scratch_v_t, bitmask_scratch_v_t, bitmask_scratch_v_mask));
    // V<mask> = EXT V<t>, V<t>, #8  — swap halves of V<t> into V<mask>.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encExtV16B(bitmask_scratch_v_mask, bitmask_scratch_v_t, bitmask_scratch_v_t, 8));
    // V<t> = ZIP1 V<t>, V<mask>  — viewed as .8H, each halfword
    // packs lane[k] (low byte) + lane[k+8] (high byte).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encZip1V16B(bitmask_scratch_v_t, bitmask_scratch_v_t, bitmask_scratch_v_mask));
    // ADDV H<t>, V<t>.8H — sum 8 halfwords into halfword 0.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encAddvH8H(bitmask_scratch_v_t, bitmask_scratch_v_t));
    // UMOV W<result>, V<t>.H[0]  — extract 16-bit result.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovWFromH(result_w, bitmask_scratch_v_t, 0));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI16x8Bitmask(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // D-461: spill-aware i32 result (was resolveGpr-reject under high v128 pressure).
    const result_w = try gpr.gprDefSpilled(ctx.alloc, result_vreg, 0);

    const mask_idx = try lookupOrAppendExtraConst(ctx, I16X8_BITMASK_MASK);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSshrV8H(bitmask_scratch_v_t, src_v, 15));
    try emitLdrLiteralQForConst(ctx, bitmask_scratch_v_mask, mask_idx);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encAnd16B(bitmask_scratch_v_t, bitmask_scratch_v_t, bitmask_scratch_v_mask));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encAddvH8H(bitmask_scratch_v_t, bitmask_scratch_v_t));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovWFromH(result_w, bitmask_scratch_v_t, 0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI32x4Bitmask(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_w = try gpr.resolveGpr(ctx.alloc, result_vreg);

    const mask_idx = try lookupOrAppendExtraConst(ctx, I32X4_BITMASK_MASK);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encSshrV4S(bitmask_scratch_v_t, src_v, 31));
    try emitLdrLiteralQForConst(ctx, bitmask_scratch_v_mask, mask_idx);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encAnd16B(bitmask_scratch_v_t, bitmask_scratch_v_t, bitmask_scratch_v_mask));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encAddvS4S(bitmask_scratch_v_t, bitmask_scratch_v_t));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovWFromS(result_w, bitmask_scratch_v_t, 0));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `i64x2.bitmask`: NEON has no .2D form for ADDV / SSHR-followed-
/// by-reduce, so synthesise via two D-lane scalar extracts + LSR
/// #63 + combine. 6 instructions, no const-pool entry needed.
pub fn emitI64x2Bitmask(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_w = try gpr.resolveGpr(ctx.alloc, result_vreg);

    // X16 = src.D[0]; X17 = src.D[1].
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovXFromD(reduce_scratch_x_a, src_v, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_lane_cmp.encUmovXFromD(reduce_scratch_x_b, src_v, 1));
    // X16 >>= 63; X17 >>= 63  — each becomes 0 or 1 (sign bit).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLsrImmX(reduce_scratch_x_a, reduce_scratch_x_a, 63));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLsrImmX(reduce_scratch_x_b, reduce_scratch_x_b, 63));
    // X17 += X17  — X17 = lane1_sign << 1.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(reduce_scratch_x_b, reduce_scratch_x_b, reduce_scratch_x_b));
    // W<result> = W16 | W17  — combine into result's low 2 bits.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(result_w, reduce_scratch_x_a, reduce_scratch_x_b));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// Int per-lane compares
// ============================================================
//
// Wasm spec (SIMD) — `i*x*.{eq,ne,lt_s,lt_u,gt_s,gt_u,le_s,le_u,ge_s,ge_u}`.
// i64x2 omits the unsigned variants per Wasm 2.0 SIMD.
//
// Strategy:
// - eq: op_simd.emitV128Binop with CMEQ encoder
// - ne: CMEQ + NOT V16B (3-instr synthesis using V31 scratch) via op_simd.emitV128Ne
// - gt_s: op_simd.emitV128Binop with CMGT encoder
// - gt_u: op_simd.emitV128Binop with CMHI encoder
// - ge_s: op_simd.emitV128Binop with CMGE encoder
// - ge_u: op_simd.emitV128Binop with CMHS encoder
// - lt_*: same encoder as gt_*, but operands swapped at handler level (op_simd.emitV128BinopSwapped)
// - le_*: same encoder as ge_*, but operands swapped

// i8x16 compares
pub fn emitI8x16Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmEq16B);
}
pub fn emitI8x16Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Ne(ctx, inst_neon_lane_cmp.encCmEq16B);
}
pub fn emitI8x16GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmGt16B);
}
pub fn emitI8x16GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmHi16B);
}
pub fn emitI8x16GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmGe16B);
}
pub fn emitI8x16GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmHs16B);
}
pub fn emitI8x16LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmGt16B);
}
pub fn emitI8x16LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmHi16B);
}
pub fn emitI8x16LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmGe16B);
}
pub fn emitI8x16LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmHs16B);
}

// i16x8 compares
pub fn emitI16x8Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmEq8H);
}
pub fn emitI16x8Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Ne(ctx, inst_neon_lane_cmp.encCmEq8H);
}
pub fn emitI16x8GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmGt8H);
}
pub fn emitI16x8GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmHi8H);
}
pub fn emitI16x8GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmGe8H);
}
pub fn emitI16x8GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmHs8H);
}
pub fn emitI16x8LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmGt8H);
}
pub fn emitI16x8LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmHi8H);
}
pub fn emitI16x8LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmGe8H);
}
pub fn emitI16x8LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmHs8H);
}

// i32x4 compares
pub fn emitI32x4Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmEq4S);
}
pub fn emitI32x4Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Ne(ctx, inst_neon_lane_cmp.encCmEq4S);
}
pub fn emitI32x4GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmGt4S);
}
pub fn emitI32x4GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmHi4S);
}
pub fn emitI32x4GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmGe4S);
}
pub fn emitI32x4GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmHs4S);
}
pub fn emitI32x4LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmGt4S);
}
pub fn emitI32x4LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmHi4S);
}
pub fn emitI32x4LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmGe4S);
}
pub fn emitI32x4LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmHs4S);
}

// i64x2 compares — signed only per Wasm 2.0 SIMD.
pub fn emitI64x2Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmEq2D);
}
pub fn emitI64x2Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Ne(ctx, inst_neon_lane_cmp.encCmEq2D);
}
pub fn emitI64x2GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmGt2D);
}
pub fn emitI64x2GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Binop(ctx, inst_neon_lane_cmp.encCmGe2D);
}
pub fn emitI64x2LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmGt2D);
}
pub fn emitI64x2LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128BinopSwapped(ctx, inst_neon_lane_cmp.encCmGe2D);
}

// ============================================================
// i*x*.extend_{low,high}_i*x*_{s,u} (12 ops)
// ============================================================
//
// Wasm spec — bitwise sign/zero extension to double-width lanes.
// Single-instruction NEON lowering (SXTL/SXTL2/UXTL/UXTL2 — aliases
// of SSHLL/USHLL with shift=0). Each handler is a thin
// `op_simd.emitV128Unop` adapter with the appropriate per-shape encoder.

pub fn emitI16x8ExtendLowI8x16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encSxtl8H);
}
pub fn emitI16x8ExtendHighI8x16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encSxtl2_8H);
}
pub fn emitI16x8ExtendLowI8x16U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUxtl8H);
}
pub fn emitI16x8ExtendHighI8x16U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUxtl2_8H);
}

pub fn emitI32x4ExtendLowI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encSxtl4S);
}
pub fn emitI32x4ExtendHighI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encSxtl2_4S);
}
pub fn emitI32x4ExtendLowI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUxtl4S);
}
pub fn emitI32x4ExtendHighI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUxtl2_4S);
}

pub fn emitI64x2ExtendLowI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encSxtl2D);
}
pub fn emitI64x2ExtendHighI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encSxtl2_2D);
}
pub fn emitI64x2ExtendLowI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUxtl2D);
}
pub fn emitI64x2ExtendHighI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try op_simd.emitV128Unop(ctx, inst_neon_arith.encUxtl2_2D);
}

// ============================================================
// saturating narrow (4 ops)
// ============================================================
//
// Wasm spec — `*.narrow_*_{s,u}`. Two-instruction synthesis:
//   1. <low_enc>  result.<half>, lhs.<full>   ; writes lower, zeros upper
//   2. <high_enc> result.<full>, rhs.<full>   ; writes upper, preserves lower
// SQXTN's Q=0 form clears upper half + Q=1 form preserves lower half
// → no scratch register needed (cranelift uses same pattern).

fn emitV128NarrowSaturating(
    ctx: *EmitCtx,
    low_encoder: *const fn (rd: u5, rn: u5) u32,
    high_encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Step 1: low-half narrow into result_v (zeros upper half).
    try gpr.writeU32(ctx.allocator, ctx.buf, low_encoder(result_v, lhs_v));
    // Step 2: high-half narrow merges into upper of result_v.
    try gpr.writeU32(ctx.allocator, ctx.buf, high_encoder(result_v, rhs_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI8x16NarrowI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128NarrowSaturating(ctx, inst_neon_arith.encSqxtn8B, inst_neon_arith.encSqxtn2_16B);
}
pub fn emitI8x16NarrowI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128NarrowSaturating(ctx, inst_neon_arith.encSqxtun8B, inst_neon_arith.encSqxtun2_16B);
}
pub fn emitI16x8NarrowI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128NarrowSaturating(ctx, inst_neon_arith.encSqxtn4H, inst_neon_arith.encSqxtn2_8H);
}
pub fn emitI16x8NarrowI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128NarrowSaturating(ctx, inst_neon_arith.encSqxtun4H, inst_neon_arith.encSqxtun2_8H);
}

// ============================================================
// i8x16.swizzle / i8x16.shuffle
// ============================================================
//
// Wasm spec (SIMD) — `i8x16.swizzle(operand, indices)`:
//   for each lane k: output[k] = (indices[k] < 16) ? operand[indices[k]] : 0
//
// Lowers to NEON TBL (1-register table form):
//   TBL V<result>.16B, { V<operand>.16B }, V<indices>.16B
// Stack order: operand pushed first, indices pushed second; popped
// in reverse → indices first, operand second.

/// Wasm spec (SIMD) — `i8x16.shuffle`: pop 2 v128 (lhs, rhs), push
/// v128 result. The 16-byte shuffle mask is materialised from the
/// const-pool. NEON TBL 2-register form requires a consecutive
/// V-register pair; we copy lhs → V30 and rhs → V31, then run TBL
/// with the mask read from the result V register (which receives
/// the const-pool load + the TBL output in sequence — TBL's
/// register-level atomic semantics permit Vd == Vm).
///
/// Sequence:
///   MOV V31.16B, V<rhs>.16B
///   MOV V30.16B, V<lhs>.16B    (after lhs load, before mask load)
///   LDR Q<result>, <const-pool>  (placeholder; fixup-resolved)
///   TBL V<result>.16B, { V30.16B, V31.16B }, V<result>.16B
pub fn emitI8x16Shuffle(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);
    // Save rhs to V31 IMMEDIATELY after qLoadSpilled — if rhs was
    // spilled, rhs_v == V30 (spill stage 1) and we must copy to V31
    // before V30 is overwritten by the lhs load stage.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(31, rhs_v));

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);
    // Save lhs to V30. If lhs was spilled, lhs_v == V29, distinct
    // from V30 (rhs spill stage which is now overwritten with lhs;
    // this is fine since rhs is already in V31).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(30, lhs_v));

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Materialise mask into result_v via LDR-Q-literal placeholder.
    const fixup_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encLdrLiteralQ(result_v, 0));
    try ctx.simd_const_fixups.append(ctx.allocator, .{
        .byte_offset = fixup_byte,
        .const_idx = @intCast(ins.payload),
    });

    // TBL V<result>.16B, { V30.16B, V31.16B }, V<result>.16B.
    // result_v serves both as Vd (output) and Vm (mask) — atomic
    // register read-then-write is well-defined per Arm IHI 0055.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encTbl2Reg(result_v, 30, result_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI8x16Swizzle(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const indices_vreg = ctx.pushed_vregs.pop().?;
    const indices_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, indices_vreg, 1);

    const operand_vreg = ctx.pushed_vregs.pop().?;
    const operand_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, operand_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon_arith.encTbl1Reg(result_v, operand_v, indices_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}
