//! Wasm 2.0 table interp handlers (§9.2 / 2.3 chunks 5c / 5c-2).
//!
//! Five table ops:
//!   0x25     table.get x  — pop i32 idx, push tables[x][idx].
//!   0x26     table.set x  — pop reftype, pop i32 idx, write.
//!   0xFC 15  table.grow x — pop n:i32, init:reftype; realloc
//!                           refs[..len+n], fill new slots with
//!                           init; push prev_size or -1.
//!   0xFC 16  table.size x — push i32 (current length).
//!   0xFC 17  table.fill x — pop n:i32, val:reftype, dst:i32;
//!                           write n cells; trap on OOB.
//!
//! table.copy / table.init / elem.drop defer to chunk 5d (need
//! the element section decoder).
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
    table.interp[op(.@"table.grow")] = tableGrow;
    table.interp[op(.@"table.fill")] = tableFill;
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

/// table.grow x: pop n:i32, init:reftype. Realloc refs to
/// len+n and fill new slots with init. Push prev_size on
/// success or -1 on max-cap violation / alloc failure.
fn tableGrow(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = &rt.tables[tableidx];

    const n_i = rt.popOperand().i32;
    const init_v = rt.popOperand();
    const prev: u64 = tbl.refs.len;
    const n: u64 = @as(u32, @bitCast(n_i));
    const new_len = prev + n;

    // Max-cap or u32-range violation → push -1, no mutation.
    if (new_len > std.math.maxInt(u32)) {
        try rt.pushOperand(.{ .i32 = -1 });
        return;
    }
    if (tbl.max) |m| if (new_len > m) {
        try rt.pushOperand(.{ .i32 = -1 });
        return;
    };

    const new_refs = rt.alloc.realloc(tbl.refs, @intCast(new_len)) catch {
        try rt.pushOperand(.{ .i32 = -1 });
        return;
    };
    var i: usize = @intCast(prev);
    while (i < new_refs.len) : (i += 1) new_refs[i] = init_v;
    tbl.refs = new_refs;

    const prev_i: i32 = @intCast(prev);
    try rt.pushOperand(.{ .i32 = prev_i });
}

/// table.fill x: pop n:i32, val:reftype, dst:i32. Set n cells
/// at dst to val. Trap OutOfBoundsTableAccess if dst+n > len.
fn tableFill(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.payload;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];

    const n_i = rt.popOperand().i32;
    const v = rt.popOperand();
    const dst_i = rt.popOperand().i32;
    const n: u64 = @as(u32, @bitCast(n_i));
    const dst: u64 = @as(u32, @bitCast(dst_i));
    if (dst + n > tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    if (n == 0) return;
    var i: usize = @intCast(dst);
    const end: usize = @intCast(dst + n);
    while (i < end) : (i += 1) tbl.refs[i] = v;
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

test "register: all five table ops populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"table.get")] != null);
    try testing.expect(t.interp[op(.@"table.set")] != null);
    try testing.expect(t.interp[op(.@"table.size")] != null);
    try testing.expect(t.interp[op(.@"table.grow")] != null);
    try testing.expect(t.interp[op(.@"table.fill")] != null);
}

test "table.size: returns refs.len" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{ .{ .ref = Value.null_ref }, .{ .ref = 7 }, .{ .ref = 9 } };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
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
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
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
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
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
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
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

test "table.fill: writes n cells with val; trap on dst+n > len" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
    };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    // table.fill 0: dst=1, val=ref(7), n=2 → cells 1..3 = 7
    try rt.pushOperand(.{ .i32 = 1 });
    try rt.pushOperand(.{ .ref = 7 });
    try rt.pushOperand(.{ .i32 = 2 });
    try driveOne(&rt, &t, .@"table.fill", 0, 0);
    try testing.expectEqual(Value.null_ref, refs[0].ref);
    try testing.expectEqual(@as(u64, 7), refs[1].ref);
    try testing.expectEqual(@as(u64, 7), refs[2].ref);
    try testing.expectEqual(Value.null_ref, refs[3].ref);

    // OOB: dst=3, n=2 (3+2=5 > 4) → trap.
    try rt.pushOperand(.{ .i32 = 3 });
    try rt.pushOperand(.{ .ref = 9 });
    try rt.pushOperand(.{ .i32 = 2 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.fill", 0, 0));
}

test "table.grow: extends refs and pushes prev_size" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    // Initial table of length 2; allocate via testing.allocator so realloc works.
    const initial = try testing.allocator.alloc(Value, 2);
    initial[0] = .{ .ref = 1 };
    initial[1] = .{ .ref = 2 };
    var tbls = [_]TableInstance{.{ .refs = initial, .elem_type = .funcref }};
    rt.tables = &tbls;
    defer testing.allocator.free(rt.tables[0].refs);

    // table.grow 0: init=ref(99), n=3 → prev_size=2; new len=5 with cells 2..5 = 99
    try rt.pushOperand(.{ .ref = 99 });
    try rt.pushOperand(.{ .i32 = 3 });
    try driveOne(&rt, &t, .@"table.grow", 0, 0);
    try testing.expectEqual(@as(i32, 2), rt.popOperand().i32);
    try testing.expectEqual(@as(usize, 5), rt.tables[0].refs.len);
    try testing.expectEqual(@as(u64, 1), rt.tables[0].refs[0].ref);
    try testing.expectEqual(@as(u64, 99), rt.tables[0].refs[2].ref);
    try testing.expectEqual(@as(u64, 99), rt.tables[0].refs[4].ref);
}

test "table.grow: max-cap violation pushes -1" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    const initial = try testing.allocator.alloc(Value, 2);
    initial[0] = .{ .ref = 0 };
    initial[1] = .{ .ref = 0 };
    var tbls = [_]TableInstance{.{ .refs = initial, .elem_type = .funcref, .max = 3 }};
    rt.tables = &tbls;
    defer testing.allocator.free(rt.tables[0].refs);

    // n=5 → would overflow max=3 → push -1, no mutation.
    try rt.pushOperand(.{ .ref = 0 });
    try rt.pushOperand(.{ .i32 = 5 });
    try driveOne(&rt, &t, .@"table.grow", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
    try testing.expectEqual(@as(usize, 2), rt.tables[0].refs.len);
}
