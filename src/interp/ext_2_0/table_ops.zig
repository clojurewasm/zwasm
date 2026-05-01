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
    table.interp[op(.@"table.copy")] = tableCopy;
    table.interp[op(.@"table.init")] = tableInit;
    table.interp[op(.@"elem.drop")] = elemDrop;
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

/// table.copy x y: pop n:i32, src:i32, dst:i32. Copy n refs from
/// tables[y] to tables[x]. memmove semantics on overlap when
/// tables[x] == tables[y]. Encoding: payload = dst-tableidx,
/// extra = src-tableidx.
fn tableCopy(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const dst_tbl_idx = instr.payload;
    const src_tbl_idx = instr.extra;
    if (dst_tbl_idx >= rt.tables.len or src_tbl_idx >= rt.tables.len) return Trap.Unreachable;
    const dst_tbl = rt.tables[dst_tbl_idx];
    const src_tbl = rt.tables[src_tbl_idx];

    const n_i = rt.popOperand().i32;
    const src_i = rt.popOperand().i32;
    const dst_i = rt.popOperand().i32;
    const n: u64 = @as(u32, @bitCast(n_i));
    const src: u64 = @as(u32, @bitCast(src_i));
    const dst: u64 = @as(u32, @bitCast(dst_i));
    if (src + n > src_tbl.refs.len or dst + n > dst_tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    if (n == 0) return;
    const src_lo: usize = @intCast(src);
    const dst_lo: usize = @intCast(dst);
    const n_lo: usize = @intCast(n);

    const same = dst_tbl_idx == src_tbl_idx;
    if (same and dst_lo > src_lo and dst_lo < src_lo + n_lo) {
        // Self-overlap with dst > src — copy backwards.
        var i: usize = n_lo;
        while (i > 0) {
            i -= 1;
            dst_tbl.refs[dst_lo + i] = src_tbl.refs[src_lo + i];
        }
    } else {
        var i: usize = 0;
        while (i < n_lo) : (i += 1) {
            dst_tbl.refs[dst_lo + i] = src_tbl.refs[src_lo + i];
        }
    }
}

/// table.init x y: payload = elemidx, extra = tableidx. Pop n,
/// src, dst. Copy n refs from elems[x] to tables[y]. Trap if
/// src+n > elem.len OR dst+n > table.len. Treat dropped segments
/// as zero-length.
fn tableInit(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const elemidx = instr.payload;
    const tableidx = instr.extra;
    if (elemidx >= rt.elems.len or tableidx >= rt.tables.len) return Trap.Unreachable;
    const dropped = if (elemidx < rt.elem_dropped.len) rt.elem_dropped[elemidx] else false;
    const seg = rt.elems[elemidx];
    const seg_len: u64 = if (dropped) 0 else seg.len;
    const tbl = rt.tables[tableidx];

    const n_i = rt.popOperand().i32;
    const src_i = rt.popOperand().i32;
    const dst_i = rt.popOperand().i32;
    const n: u64 = @as(u32, @bitCast(n_i));
    const src: u64 = @as(u32, @bitCast(src_i));
    const dst: u64 = @as(u32, @bitCast(dst_i));
    if (src + n > seg_len or dst + n > tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    if (n == 0) return;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        tbl.refs[@as(usize, @intCast(dst)) + i] = seg[@as(usize, @intCast(src)) + i];
    }
}

/// elem.drop x: mark element segment x as dropped. Subsequent
/// table.init x calls treat its length as 0.
fn elemDrop(c: *@import("../../ir/dispatch_table.zig").InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const elemidx = instr.payload;
    if (elemidx >= rt.elem_dropped.len) return Trap.Unreachable;
    rt.elem_dropped[elemidx] = true;
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

test "register: all eight table ops populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"table.get")] != null);
    try testing.expect(t.interp[op(.@"table.set")] != null);
    try testing.expect(t.interp[op(.@"table.size")] != null);
    try testing.expect(t.interp[op(.@"table.grow")] != null);
    try testing.expect(t.interp[op(.@"table.fill")] != null);
    try testing.expect(t.interp[op(.@"table.copy")] != null);
    try testing.expect(t.interp[op(.@"table.init")] != null);
    try testing.expect(t.interp[op(.@"elem.drop")] != null);
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

test "table.copy: cross-table copy moves refs" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs0 = [_]Value{
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
        .{ .ref = Value.null_ref },
    };
    var refs1 = [_]Value{ .{ .ref = 7 }, .{ .ref = 8 }, .{ .ref = 9 } };
    var tbls = [_]TableInstance{
        .{ .refs = &refs0, .elem_type = .funcref },
        .{ .refs = &refs1, .elem_type = .funcref },
    };
    rt.tables = &tbls;

    // table.copy 0 1: dst=0, src=1, n=2 → tables[0][0..2] = tables[1][0..2]
    // payload=0 (dst), extra=1 (src)
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 2 }); // n
    try driveOne(&rt, &t, .@"table.copy", 0, 1);
    try testing.expectEqual(@as(u64, 7), refs0[0].ref);
    try testing.expectEqual(@as(u64, 8), refs0[1].ref);
    try testing.expectEqual(Value.null_ref, refs0[2].ref);
}

test "table.copy: same-table overlap with dst > src copies backwards" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var refs = [_]Value{
        .{ .ref = 1 }, .{ .ref = 2 }, .{ .ref = 3 }, .{ .ref = 4 }, .{ .ref = 5 },
    };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;

    // table.copy 0 0: dst=2, src=0, n=3 → backwards copy.
    // After: refs = [1, 2, 1, 2, 3]
    try rt.pushOperand(.{ .i32 = 2 });
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 3 });
    try driveOne(&rt, &t, .@"table.copy", 0, 0);
    try testing.expectEqual(@as(u64, 1), refs[0].ref);
    try testing.expectEqual(@as(u64, 2), refs[1].ref);
    try testing.expectEqual(@as(u64, 1), refs[2].ref);
    try testing.expectEqual(@as(u64, 2), refs[3].ref);
    try testing.expectEqual(@as(u64, 3), refs[4].ref);
}

test "table.copy: src+n > src_len traps" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs0 = [_]Value{ .{ .ref = 0 }, .{ .ref = 0 }, .{ .ref = 0 } };
    var refs1 = [_]Value{ .{ .ref = 0 }, .{ .ref = 0 } };
    var tbls = [_]TableInstance{
        .{ .refs = &refs0, .elem_type = .funcref },
        .{ .refs = &refs1, .elem_type = .funcref },
    };
    rt.tables = &tbls;
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 1 }); // src
    try rt.pushOperand(.{ .i32 = 3 }); // n (1+3=4 > src_len=2)
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.copy", 0, 1));
}

fn setupElems(rt: *Runtime, segs: []const []const Value) !void {
    rt.elems = segs;
    rt.elem_dropped = try rt.alloc.alloc(bool, segs.len);
    @memset(rt.elem_dropped, false);
}

test "table.init: copies refs from element segment to table" {
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

    const seg0 = [_]Value{ .{ .ref = 11 }, .{ .ref = 22 }, .{ .ref = 33 } };
    const segs = [_][]const Value{&seg0};
    try setupElems(&rt, &segs);

    // table.init 0 0: dst=1, src=0, n=2. Encoding: payload=0 (elemidx), extra=0 (tableidx)
    try rt.pushOperand(.{ .i32 = 1 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 2 }); // n
    try driveOne(&rt, &t, .@"table.init", 0, 0);
    try testing.expectEqual(Value.null_ref, refs[0].ref);
    try testing.expectEqual(@as(u64, 11), refs[1].ref);
    try testing.expectEqual(@as(u64, 22), refs[2].ref);
    try testing.expectEqual(Value.null_ref, refs[3].ref);
}

test "table.init: src+n > seg_len traps" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{ .{ .ref = Value.null_ref }, .{ .ref = Value.null_ref } };
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const seg0 = [_]Value{.{ .ref = 0 }};
    const segs = [_][]const Value{&seg0};
    try setupElems(&rt, &segs);

    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 5 }); // n=5 > seg_len=1
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.init", 0, 0));
}

test "table.init after elem.drop: any n>0 traps; n=0 succeeds" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]Value{.{ .ref = Value.null_ref }};
    var tbls = [_]TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const seg0 = [_]Value{ .{ .ref = 1 }, .{ .ref = 2 } };
    const segs = [_][]const Value{&seg0};
    try setupElems(&rt, &segs);

    // elem.drop 0
    try driveOne(&rt, &t, .@"elem.drop", 0, 0);
    try testing.expectEqual(true, rt.elem_dropped[0]);

    // n=1 → trap.
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 1 });
    try testing.expectError(Trap.OutOfBoundsTableAccess, driveOne(&rt, &t, .@"table.init", 0, 0));

    // n=0 → no-op.
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 0 });
    try rt.pushOperand(.{ .i32 = 0 });
    try driveOne(&rt, &t, .@"table.init", 0, 0);
}

test "elem.drop: elemidx out of range traps Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"elem.drop", 0, 0));
}
