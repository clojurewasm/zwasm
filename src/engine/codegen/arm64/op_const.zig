//! ARM64 emit pass — constant-materialisation handlers.
//!
//! Per ADR-0023 §3 + ADR-0021 sub-deliverable b (§9.7 / 7.5d
//! sub-b emit.zig 9-module split): houses the `i32.const` /
//! `i64.const` ZirOp handlers plus the `emitConstU32` /
//! `emitConstU64` micro-helpers used by trapping-trunc bounds
//! materialisation in emit.zig and (eventually) by the float
//! `*.const` handlers.
//!
//! - `i32.const` — MOVZ Wd #lo16 (+ optional MOVK at hw=1).
//!   Spill-aware via `gpr.gprDefSpilled` + `gpr.gprStoreSpilled`
//!   (sub-1c migration; first handler converted).
//! - `i64.const` — MOVZ Xd #hw0 plus up to 3 MOVK lanes for
//!   non-zero halfwords. Inline-only (no helper indirection)
//!   because the upper-32-bit packing across `(payload, extra)`
//!   is op-shape specific.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;
const Xn = inst.Xn;
const Allocator = std.mem.Allocator;

/// Emit a 32-bit constant into Xd via MOVZ (lo16) + optional
/// MOVK (hi16, hw=1). Used by `i32.const` and by the
/// trapping-trunc f32 bounds-materialisation in emit.zig.
pub fn emitConstU32(allocator: Allocator, buf: *std.ArrayList(u8), xd: Xn, value: u32) !void {
    const lo16: u16 = @truncate(value & 0xFFFF);
    const hi16: u16 = @truncate(value >> 16);
    try gpr.writeU32(allocator, buf, inst.encMovzImm16(xd, lo16));
    if (hi16 != 0) {
        try gpr.writeU32(allocator, buf, inst.encMovkImm16(xd, hi16, 1));
    }
}

/// Emit a 64-bit constant into Xd via MOVZ (hw=0) + up to 3
/// MOVKs at hw=1,2,3. Halfwords that are zero are skipped after
/// the initial MOVZ. Used by sub-h3b's f64 trapping-trunc
/// bounds (8-byte hex constants like 0xC3E0000000000000 for
/// -2^63), staged through X16 then FMOV D31, X16.
pub fn emitConstU64(allocator: Allocator, buf: *std.ArrayList(u8), xd: Xn, value: u64) !void {
    const hw0: u16 = @truncate(value & 0xFFFF);
    const hw1: u16 = @truncate((value >> 16) & 0xFFFF);
    const hw2: u16 = @truncate((value >> 32) & 0xFFFF);
    const hw3: u16 = @truncate((value >> 48) & 0xFFFF);
    try gpr.writeU32(allocator, buf, inst.encMovzImm16(xd, hw0));
    if (hw1 != 0) try gpr.writeU32(allocator, buf, inst.encMovkImm16(xd, hw1, 1));
    if (hw2 != 0) try gpr.writeU32(allocator, buf, inst.encMovkImm16(xd, hw2, 2));
    if (hw3 != 0) try gpr.writeU32(allocator, buf, inst.encMovkImm16(xd, hw3, 3));
}

/// `i32.const` handler. Allocates the next vreg (sub-1c
/// spill-aware), materialises the immediate via `emitConstU32`,
/// flushes the result to its spill slot if applicable, and
/// pushes the vreg id onto the operand stack.
pub fn emitI32Const(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const xd = try gpr.gprDefSpilled(ctx.alloc, vreg, 0);
    try emitConstU32(ctx.allocator, ctx.buf, xd, ins.payload);
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}

/// `i64.const` handler. ZirInstr packs u64 across (payload,
/// extra): low_32 = payload, high_32 = extra. Emits MOVZ for
/// the low 16 bits and MOVK for any non-zero upper lane.
pub fn emitI64Const(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const xd = try gpr.resolveGpr(ctx.alloc, vreg);
    const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
    const lane0: u16 = @truncate(value & 0xFFFF);
    const lane1: u16 = @truncate((value >> 16) & 0xFFFF);
    const lane2: u16 = @truncate((value >> 32) & 0xFFFF);
    const lane3: u16 = @truncate((value >> 48) & 0xFFFF);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(xd, lane0));
    if (lane1 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(xd, lane1, 1));
    if (lane2 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(xd, lane2, 2));
    if (lane3 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(xd, lane3, 3));
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}
