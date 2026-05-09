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
    // SPILL-EXEMPT: 9.5-b-iii MVP non-spilling path (16-byte v128 Q-form spill defers to 9.5-c per ADR-0041).
    const addr_reg = try gpr.resolveGpr(ctx.alloc, addr_vreg);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: 9.5-b-iii MVP (see addr_reg above).
    const result_v = try gpr.resolveFp(ctx.alloc, result_vreg);

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
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `v128.store`: pop v128 value (Vt.16B), pop i32 address (Wn).
/// `STR Q<vt>, [X<wn>, #imm]`. Same alignment + offset
/// constraints as `v128.load`.
pub fn emitV128Store(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const value_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: 9.5-b-iii MVP (16-byte v128 spill defer to 9.5-c).
    const value_v = try gpr.resolveFp(ctx.alloc, value_vreg);

    const addr_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: 9.5-b-iii MVP (i32 addr; spill-aware path lands in 9.5-c).
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
    // SPILL-EXEMPT: 9.5-b-iii MVP (scalar src; spill defer to 9.5-c).
    const src_reg = try gpr.resolveGpr(ctx.alloc, src_vreg);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: 9.5-b-iii MVP (16-byte v128 spill defer to 9.5-c).
    const result_v = try gpr.resolveFp(ctx.alloc, result_vreg);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encDup4S(result_v, src_reg));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `i32x4.add`: pop two v128 (Vn.4S, Vm.4S), push v128 sum
/// (Vd.4S). `ADD V<vd>.4S, V<vn>.4S, V<vm>.4S` does element-wise
/// 32-bit add across the four lanes.
pub fn emitI32x4Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: 9.5-b-iii MVP (16-byte v128 spill defer to 9.5-c).
    const rhs_v = try gpr.resolveFp(ctx.alloc, rhs_vreg);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: 9.5-b-iii MVP (16-byte v128 spill defer to 9.5-c).
    const lhs_v = try gpr.resolveFp(ctx.alloc, lhs_vreg);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: 9.5-b-iii MVP (16-byte v128 spill defer to 9.5-c).
    const result_v = try gpr.resolveFp(ctx.alloc, result_vreg);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encAdd4S(result_v, lhs_v, rhs_v));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}
