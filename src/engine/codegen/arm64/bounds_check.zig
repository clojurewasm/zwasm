//! ARM64 emit pass — Wasm 1.0 trapping float→int trunc handlers
//! and the NaN+range bounds-check sequence they share.
//!
//! Per ADR-0021 sub-deliverable b (§9.7 / 7.5d sub-b emit.zig
//! 9-module split): final chunk. Houses the trapping-trunc op
//! handlers (8 arms: i32/i64.trunc_f32/f64.s/u) plus the
//! emitTrunc{32,64}BoundsCheck helpers they share.
//!
//! The bounds-check sequence (per op): 9 instrs + 3 trap branches.
//!
//!   FCMP src, src                  ; NaN sets V flag
//!   B.VS  trap_stub                ; trap on NaN
//!   <materialise lower bound>      ; via op_const.emitConst*
//!   FMOV  S31/D31, lower bound
//!   FCMP  src, S31/D31             ; src vs lower
//!   B.<lower_cmp> trap_stub        ; trap below lower
//!   <materialise upper bound>
//!   FMOV  S31/D31, upper bound
//!   FCMP  src, S31/D31             ; src vs upper
//!   B.GE  trap_stub                ; trap at-or-above upper
//!
//! All three trap branches append to `ctx.bounds_fixups`, which
//! is patched at the function-final trap stub (shared with
//! memory bounds + call_indirect; single trap reason today).
//!
//! Saturating trunc (Wasm 2.0, `trunc_sat_*`) does NOT live here
//! — ARM64 FCVTZS/FCVTZU natively saturate + return 0 for NaN,
//! matching the Wasm 2.0 spec exactly. Those handlers are in
//! op_convert.zig.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const op_const = @import("op_const.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// f32-source bounds check. Materialises lower / upper bounds
/// into S31 (popcnt scratch — not live across this conversion)
/// via X16, runs FCMP S, S31 against each, and appends one
/// B.<cond> trap fixup per check (NaN, lower, upper).
fn emitTrunc32BoundsCheck(
    ctx: *EmitCtx,
    src_v: inst.Vn,
    lower_bits: u32,
    upper_bits: u32,
    lower_cmp: inst.Cond,
) !void {
    // NaN check: FCMP src, src ; B.VS trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFCmpS(src_v, src_v));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.vs, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    }
    // Lower bound: materialise into S31 via W16, then FCMP + trap.
    try op_const.emitConstU32(ctx.allocator, ctx.buf, 16, lower_bits);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovStoFromW(31, 16));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFCmpS(src_v, 31));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(lower_cmp, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    }
    // Upper bound: materialise + FCMP + B.GE trap.
    try op_const.emitConstU32(ctx.allocator, ctx.buf, 16, upper_bits);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovStoFromW(31, 16));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFCmpS(src_v, 31));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ge, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    }
}

/// f64 counterpart of `emitTrunc32BoundsCheck` — same shape but
/// uses `op_const.emitConstU64` (MOVZ + up to 3 MOVKs) staged
/// through X16 then FMOV D31, X16 + FCMP D-form. Used by f64-
/// source trapping trunc.
fn emitTrunc64BoundsCheck(
    ctx: *EmitCtx,
    src_v: inst.Vn,
    lower_bits: u64,
    upper_bits: u64,
    lower_cmp: inst.Cond,
) !void {
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFCmpD(src_v, src_v));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.vs, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    }
    try op_const.emitConstU64(ctx.allocator, ctx.buf, 16, lower_bits);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovDtoFromX(31, 16));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFCmpD(src_v, 31));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(lower_cmp, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    }
    try op_const.emitConstU64(ctx.allocator, ctx.buf, 16, upper_bits);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovDtoFromX(31, 16));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFCmpD(src_v, 31));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ge, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    }
}

/// Wasm 1.0 trapping trunc, f32 source. Bounds tables encode
/// the per-op boundary (representable f32 hex) and lower-cmp
/// strictness — for u32/u64 destination, lower=-1.0f with .le;
/// for s32, lower is just below INT_MIN with .le; for s64 same
/// shape with the i64 boundary.
pub fn emitTrappingTruncF32(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const vn = try gpr.resolveFp(ctx.alloc, args.src);
    const dest = try gpr.resolveGpr(ctx.alloc, args.result);

    const Bounds = struct { lo: u32, hi: u32, lo_cmp: inst.Cond };
    const b: Bounds = switch (ins.op) {
        .@"i32.trunc_f32_s" => .{ .lo = 0xCF000001, .hi = 0x4F000000, .lo_cmp = .le }, // -2147483904f, 2^31
        .@"i32.trunc_f32_u" => .{ .lo = 0xBF800000, .hi = 0x4F800000, .lo_cmp = .le }, // -1.0f, 2^32
        .@"i64.trunc_f32_s" => .{ .lo = 0xDF000001, .hi = 0x5F000000, .lo_cmp = .le }, // -9223373136366403584f, 2^63
        .@"i64.trunc_f32_u" => .{ .lo = 0xBF800000, .hi = 0x5F800000, .lo_cmp = .le }, // -1.0f, 2^64
        else => unreachable,
    };
    try emitTrunc32BoundsCheck(ctx, vn, b.lo, b.hi, b.lo_cmp);
    const word: u32 = switch (ins.op) {
        .@"i32.trunc_f32_s" => inst.encFcvtzsWFromS(dest, vn),
        .@"i32.trunc_f32_u" => inst.encFcvtzuWFromS(dest, vn),
        .@"i64.trunc_f32_s" => inst.encFcvtzsXFromS(dest, vn),
        .@"i64.trunc_f32_u" => inst.encFcvtzuXFromS(dest, vn),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// Wasm 1.0 trapping trunc, f64 source. Mirror of f32 with f64
/// bounds (8-byte constants staged via op_const.emitConstU64
/// through X16) and FCMP/FCVTZ D-form. The bounds use exact
/// f64 representations (i32 boundary INT_MIN-1 IS representable
/// in f64; i64 boundary -2^63 IS representable so uses .lt
/// strict instead of .le).
pub fn emitTrappingTruncF64(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const vn = try gpr.resolveFp(ctx.alloc, args.src);
    const dest = try gpr.resolveGpr(ctx.alloc, args.result);

    const Bounds = struct { lo: u64, hi: u64, lo_cmp: inst.Cond };
    const b: Bounds = switch (ins.op) {
        .@"i32.trunc_f64_s" => .{ .lo = 0xC1E0000000200000, .hi = 0x41E0000000000000, .lo_cmp = .le }, // -(2^31+1), 2^31
        .@"i32.trunc_f64_u" => .{ .lo = 0xBFF0000000000000, .hi = 0x41F0000000000000, .lo_cmp = .le }, // -1.0, 2^32
        .@"i64.trunc_f64_s" => .{ .lo = 0xC3E0000000000000, .hi = 0x43E0000000000000, .lo_cmp = .lt }, // -2^63 (.lt strict), 2^63
        .@"i64.trunc_f64_u" => .{ .lo = 0xBFF0000000000000, .hi = 0x43F0000000000000, .lo_cmp = .le }, // -1.0, 2^64
        else => unreachable,
    };
    try emitTrunc64BoundsCheck(ctx, vn, b.lo, b.hi, b.lo_cmp);
    const word: u32 = switch (ins.op) {
        .@"i32.trunc_f64_s" => inst.encFcvtzsWFromD(dest, vn),
        .@"i32.trunc_f64_u" => inst.encFcvtzuWFromD(dest, vn),
        .@"i64.trunc_f64_s" => inst.encFcvtzsXFromD(dest, vn),
        .@"i64.trunc_f64_u" => inst.encFcvtzuXFromD(dest, vn),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
