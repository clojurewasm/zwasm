//! Wasm 2.0 reference-type interp handlers (§9.2 / 2.3 chunk 5).
//!
//! Three opcodes:
//!   0xD0 ref.null  t      — push null reference of type t.
//!   0xD1 ref.is_null      — pop ref, push i32 (1 if null else 0).
//!   0xD2 ref.func  funcidx — push funcref to function funcidx.
//!
//! References share storage with other Value fields via the
//! `Value.ref: u64` view. Null references use the sentinel
//! `Value.null_ref` (= u64::MAX); valid funcrefs encode a u32
//! funcidx in the low 32 bits.
//!
//! select_typed (0x1C), table.get/set/grow/size/fill, and
//! table.init / table.copy / elem.drop land in chunks 5b/5c.
//!
//! Zone 2 (`src/interp/ext_2_0/`).

const std = @import("std");

const dispatch = @import("../../ir/dispatch_table.zig");
const zir = @import("../../ir/zir.zig");
const interp = @import("../mod.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = interp.Runtime;
const Value = interp.Value;

inline fn op(o: ZirOp) usize {
    return @intFromEnum(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"ref.null")] = refNull;
    table.interp[op(.@"ref.is_null")] = refIsNull;
    table.interp[op(.@"ref.func")] = refFunc;
}

fn refNull(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .ref = Value.null_ref });
}

fn refIsNull(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const r = rt.popOperand().ref;
    try rt.pushOperand(.{ .i32 = if (r == Value.null_ref) 1 else 0 });
}

fn refFunc(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .ref = @as(u64, instr.payload) });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../dispatch.zig");

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "register: ref.null / is_null / func slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"ref.null")] != null);
    try testing.expect(t.interp[op(.@"ref.is_null")] != null);
    try testing.expect(t.interp[op(.@"ref.func")] != null);
}

test "ref.null: pushes the null sentinel" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"ref.null", 0, 0);
    try testing.expectEqual(Value.null_ref, rt.popOperand().ref);
}

test "ref.is_null: null → 1; non-null → 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"ref.is_null", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);

    try rt.pushOperand(.{ .ref = 7 });
    try driveOne(&rt, &t, .@"ref.is_null", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "ref.func: payload is pushed as the ref value" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"ref.func", 42, 0);
    try testing.expectEqual(@as(u64, 42), rt.popOperand().ref);
}

test "ref round-trip: ref.func 7 ; ref.is_null → 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"ref.func", 7, 0);
    try driveOne(&rt, &t, .@"ref.is_null", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "ref round-trip: ref.null ; ref.is_null → 1" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"ref.null", 0, 0);
    try driveOne(&rt, &t, .@"ref.is_null", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}
