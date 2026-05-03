//! MVP float ops carve-out (§9.5 / 5.1 split from `mvp.zig`).
//!
//! Holds f32 / f64 constants + numeric ops (unary, binary,
//! relational). `register()` installs only this module's slots;
//! the residual `mvp.zig` shell calls each split's `register()`.
//!
//! Wasm 1.0 §6.2.3 specifies "canonical NaN" semantics for
//! arithmetic outputs: the implementation may return any NaN.
//! Strict canonicalisation is post-MVP.
//!
//! Zone 2 (`src/interp/`).

const std = @import("std");

const dispatch = @import("../ir/dispatch_table.zig");
const zir = @import("../ir/zir.zig");
const interp = @import("mod.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = interp.Runtime;
const Value = interp.Value;
const Trap = interp.Trap;

inline fn op(t: ZirOp) usize {
    return @intFromEnum(t);
}

inline fn pushBool(rt: *Runtime, b: bool) anyerror!void {
    try rt.pushOperand(.{ .i32 = if (b) 1 else 0 });
}

pub fn register(table: *DispatchTable) void {
    // Constants
    table.interp[op(.@"f32.const")] = f32Const;
    table.interp[op(.@"f64.const")] = f64Const;

    // f32 relops
    table.interp[op(.@"f32.eq")] = f32Eq;
    table.interp[op(.@"f32.ne")] = f32Ne;
    table.interp[op(.@"f32.lt")] = f32Lt;
    table.interp[op(.@"f32.gt")] = f32Gt;
    table.interp[op(.@"f32.le")] = f32Le;
    table.interp[op(.@"f32.ge")] = f32Ge;

    // f32 unops
    table.interp[op(.@"f32.abs")] = f32Abs;
    table.interp[op(.@"f32.neg")] = f32Neg;
    table.interp[op(.@"f32.ceil")] = f32Ceil;
    table.interp[op(.@"f32.floor")] = f32Floor;
    table.interp[op(.@"f32.trunc")] = f32Trunc;
    table.interp[op(.@"f32.nearest")] = f32Nearest;
    table.interp[op(.@"f32.sqrt")] = f32Sqrt;

    // f32 binops
    table.interp[op(.@"f32.add")] = f32Add;
    table.interp[op(.@"f32.sub")] = f32Sub;
    table.interp[op(.@"f32.mul")] = f32Mul;
    table.interp[op(.@"f32.div")] = f32Div;
    table.interp[op(.@"f32.min")] = f32Min;
    table.interp[op(.@"f32.max")] = f32Max;
    table.interp[op(.@"f32.copysign")] = f32Copysign;

    // f64 relops
    table.interp[op(.@"f64.eq")] = f64Eq;
    table.interp[op(.@"f64.ne")] = f64Ne;
    table.interp[op(.@"f64.lt")] = f64Lt;
    table.interp[op(.@"f64.gt")] = f64Gt;
    table.interp[op(.@"f64.le")] = f64Le;
    table.interp[op(.@"f64.ge")] = f64Ge;

    // f64 unops
    table.interp[op(.@"f64.abs")] = f64Abs;
    table.interp[op(.@"f64.neg")] = f64Neg;
    table.interp[op(.@"f64.ceil")] = f64Ceil;
    table.interp[op(.@"f64.floor")] = f64Floor;
    table.interp[op(.@"f64.trunc")] = f64Trunc;
    table.interp[op(.@"f64.nearest")] = f64Nearest;
    table.interp[op(.@"f64.sqrt")] = f64Sqrt;

    // f64 binops
    table.interp[op(.@"f64.add")] = f64Add;
    table.interp[op(.@"f64.sub")] = f64Sub;
    table.interp[op(.@"f64.mul")] = f64Mul;
    table.interp[op(.@"f64.div")] = f64Div;
    table.interp[op(.@"f64.min")] = f64Min;
    table.interp[op(.@"f64.max")] = f64Max;
    table.interp[op(.@"f64.copysign")] = f64Copysign;
}

// ============================================================
// Handlers — f32 / f64 constants
// ============================================================

fn f32Const(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .bits64 = instr.payload });
}

fn f64Const(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const lo: u64 = instr.payload;
    const hi: u64 = instr.extra;
    try rt.pushOperand(.{ .bits64 = lo | (hi << 32) });
}

// ============================================================
// Handlers — f32 / f64 numeric (relops, unops, binops)
// ============================================================

fn popF32Pair(rt: *Runtime) struct { a: f32, b: f32 } {
    const b = rt.popOperand().f32;
    const a = rt.popOperand().f32;
    return .{ .a = a, .b = b };
}
fn popF64Pair(rt: *Runtime) struct { a: f64, b: f64 } {
    const b = rt.popOperand().f64;
    const a = rt.popOperand().f64;
    return .{ .a = a, .b = b };
}

// --- f32 relops ---
fn f32Eq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a == p.b);
}
fn f32Ne(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a != p.b);
}
fn f32Lt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn f32Gt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn f32Le(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn f32Ge(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a >= p.b);
}

// --- f32 unops ---
fn f32Abs(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @abs(rt.popOperand().f32) });
}
fn f32Neg(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = -rt.popOperand().f32 });
}
fn f32Ceil(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @ceil(rt.popOperand().f32) });
}
fn f32Floor(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floor(rt.popOperand().f32) });
}
fn f32Trunc(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @trunc(rt.popOperand().f32) });
}
fn f32Nearest(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @round(rt.popOperand().f32) });
}
fn f32Sqrt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @sqrt(rt.popOperand().f32) });
}

// --- f32 binops ---
fn f32Add(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = p.a + p.b });
}
fn f32Sub(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = p.a - p.b });
}
fn f32Mul(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = p.a * p.b });
}
fn f32Div(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = p.a / p.b });
}
fn f32Min(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    if (std.math.isNan(p.a) or std.math.isNan(p.b)) {
        try rt.pushOperand(.{ .f32 = std.math.nan(f32) });
    } else {
        try rt.pushOperand(.{ .f32 = @min(p.a, p.b) });
    }
}
fn f32Max(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    if (std.math.isNan(p.a) or std.math.isNan(p.b)) {
        try rt.pushOperand(.{ .f32 = std.math.nan(f32) });
    } else {
        try rt.pushOperand(.{ .f32 = @max(p.a, p.b) });
    }
}
fn f32Copysign(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = std.math.copysign(p.a, p.b) });
}

// --- f64 relops ---
fn f64Eq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a == p.b);
}
fn f64Ne(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a != p.b);
}
fn f64Lt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn f64Gt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn f64Le(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn f64Ge(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a >= p.b);
}

// --- f64 unops ---
fn f64Abs(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @abs(rt.popOperand().f64) });
}
fn f64Neg(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = -rt.popOperand().f64 });
}
fn f64Ceil(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @ceil(rt.popOperand().f64) });
}
fn f64Floor(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floor(rt.popOperand().f64) });
}
fn f64Trunc(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @trunc(rt.popOperand().f64) });
}
fn f64Nearest(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @round(rt.popOperand().f64) });
}
fn f64Sqrt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @sqrt(rt.popOperand().f64) });
}

// --- f64 binops ---
fn f64Add(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = p.a + p.b });
}
fn f64Sub(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = p.a - p.b });
}
fn f64Mul(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = p.a * p.b });
}
fn f64Div(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = p.a / p.b });
}
fn f64Min(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    if (std.math.isNan(p.a) or std.math.isNan(p.b)) {
        try rt.pushOperand(.{ .f64 = std.math.nan(f64) });
    } else {
        try rt.pushOperand(.{ .f64 = @min(p.a, p.b) });
    }
}
fn f64Max(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    if (std.math.isNan(p.a) or std.math.isNan(p.b)) {
        try rt.pushOperand(.{ .f64 = std.math.nan(f64) });
    } else {
        try rt.pushOperand(.{ .f64 = @max(p.a, p.b) });
    }
}
fn f64Copysign(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = std.math.copysign(p.a, p.b) });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("dispatch.zig");
const mvp = @import("mvp.zig");

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "f32.add: 1.0 + 2.0 = 3.0" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = 1.0 });
    try rt.pushOperand(.{ .f32 = 2.0 });
    try driveOne(&rt, &t, .@"f32.add", 0, 0);
    try testing.expectEqual(@as(f32, 3.0), rt.popOperand().f32);
}

test "f32.div: 1.0 / 0.0 = inf (no trap)" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = 1.0 });
    try rt.pushOperand(.{ .f32 = 0.0 });
    try driveOne(&rt, &t, .@"f32.div", 0, 0);
    try testing.expect(std.math.isInf(rt.popOperand().f32));
}

test "f32.min: NaN propagates" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = std.math.nan(f32) });
    try rt.pushOperand(.{ .f32 = 1.0 });
    try driveOne(&rt, &t, .@"f32.min", 0, 0);
    try testing.expect(std.math.isNan(rt.popOperand().f32));
}

test "f64.sqrt: 4.0 → 2.0" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 4.0 });
    try driveOne(&rt, &t, .@"f64.sqrt", 0, 0);
    try testing.expectEqual(@as(f64, 2.0), rt.popOperand().f64);
}

test "f64.copysign: magnitude from a, sign from b" {
    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 3.0 });
    try rt.pushOperand(.{ .f64 = -1.0 });
    try driveOne(&rt, &t, .@"f64.copysign", 0, 0);
    try testing.expectEqual(@as(f64, -3.0), rt.popOperand().f64);
}
