//! Wasm 2.0 table interp handlers (§9.2 / 2.3 chunk 5c).
//!
//! Three foundational ops:
//!   0x25 table.get x  — pop i32 idx, push tables[x][idx].
//!   0x26 table.set x  — pop reftype, pop i32 idx, write.
//!   0xFC 16 table.size x — push i32 (current length).
//!
//! table.grow / table.fill / table.copy / table.init / elem.drop
//! defer to chunk 5c-2 / 5d (need a mutable owning table model
//! and the element section decoder).
//!
//! Zone 2.

const std = @import("std");

const dispatch = @import("../../ir/dispatch_table.zig");
const zir = @import("../../ir/zir.zig");
const interp = @import("../mod.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = interp.Runtime;
const Trap = interp.Trap;

inline fn op(o: ZirOp) usize {
    return @intFromEnum(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"table.get")] = tableGet;
    table.interp[op(.@"table.set")] = tableSet;
    table.interp[op(.@"table.size")] = tableSize;
}

fn tableGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];
    const idx_i = rt.popOperand().i32;
    const idx: u64 = @as(u32, @bitCast(idx_i));
    if (idx >= tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    try rt.pushOperand(tbl.refs[@intCast(idx)]);
}

fn tableSet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];
    const v = rt.popOperand();
    const idx_i = rt.popOperand().i32;
    const idx: u64 = @as(u32, @bitCast(idx_i));
    if (idx >= tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    tbl.refs[@intCast(idx)] = v;
}

fn tableSize(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];
    const sz: i32 = @intCast(tbl.refs.len);
    try rt.pushOperand(.{ .i32 = sz });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../dispatch.zig");
const Value = interp.Value;
const TableInstance = interp.TableInstance;

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "register: table.get / table.set / table.size populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"table.get")] != null);
    try testing.expect(t.interp[op(.@"table.set")] != null);
    try testing.expect(t.interp[op(.@"table.size")] != null);
}

test "table.size: returns refs.len" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{ .{ .ref = Value.null_ref }, .{ .ref = 7 }, .{ .ref = 9 } };
    const tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    try driveOne(&rt, &t, .@"table.size", 0, 0);
    try testing.expectEqual(@as(i32, 3), rt.popOperand().i32);
}

test "table.get / set round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
    };
    const tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    // table.set: idx=1, val=ref(42)
    try rt.pushOperand(.{ .i32 = 1 });
    try rt.pushOperand(.{ .ref = 42 });
    try driveOne(&rt, &t, .@"table.set", 0, 0);

    // table.get: idx=1
    try rt.pushOperand(.{ .i32 = 1 });
    try driveOne(&rt, &t, .@"table.get", 0, 0);
    try testing.expectEqual(@as(u64, 42), rt.popOperand().ref);

    // Other slots untouched.
    try testing.expectEqual(Value.null_ref, refs[0].ref);
    try testing.expectEqual(Value.null_ref, refs[2].ref);
}

test "table.get: idx out of range traps OutOfBoundsTableAccess" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{.{ .ref = Value.null_ref }};
    const tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    try rt.pushOperand(.{ .i32 = 5 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.get", 0, 0));
}

test "table.set: idx out of range traps OutOfBoundsTableAccess" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{.{ .ref = Value.null_ref }};
    const tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    try rt.pushOperand(.{ .i32 = 1 });
    try rt.pushOperand(.{ .ref = 7 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.set", 0, 0));
}

test "table.get: tableidx out of range traps Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // No tables wired.
    try rt.pushOperand(.{ .i32 = 0 });
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"table.get", 0, 0));
}
