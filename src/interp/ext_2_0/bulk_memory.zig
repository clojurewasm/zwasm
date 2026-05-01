//! Wasm 2.0 bulk-memory interp handlers (§9.2 / 2.3 chunk 4).
//!
//! Prefix opcode 0xFC + sub-opcode 10 / 11. Both pop three i32
//! operands (n, src/val, dst) and trap OutOfBoundsStore on
//! overflow. memory.init / data.drop / table.* land in later
//! sub-chunks (data + element section decoders required first).
//!
//! Sub-opcode → ZirOp:
//!   10 → memory.copy: pop n, src, dst; copy n bytes (memmove
//!        semantics for overlap); trap if (dst+n > len) or
//!        (src+n > len).
//!   11 → memory.fill: pop n, val, dst; fill n bytes at dst with
//!        val&0xFF; trap if (dst+n > len).
//!
//! Zone 2 (`src/interp/ext_2_0/`) — imports Zone 0 (`util/`) +
//! Zone 1 (`ir/`) + sibling Zone 2 (`../mod.zig`,
//! `../dispatch.zig`).

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
    table.interp[op(.@"memory.copy")] = memoryCopy;
    table.interp[op(.@"memory.fill")] = memoryFill;
    table.interp[op(.@"memory.init")] = memoryInit;
    table.interp[op(.@"data.drop")] = dataDrop;
}

fn memoryCopy(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const n_i = rt.popOperand().i32;
    const src_i = rt.popOperand().i32;
    const dst_i = rt.popOperand().i32;
    const n: u64 = @as(u32, @bitCast(n_i));
    const src: u64 = @as(u32, @bitCast(src_i));
    const dst: u64 = @as(u32, @bitCast(dst_i));
    const mem_len: u64 = rt.memory.len;
    if (src + n > mem_len or dst + n > mem_len) return Trap.OutOfBoundsStore;
    if (n == 0) return;
    const src_lo: usize = @intCast(src);
    const dst_lo: usize = @intCast(dst);
    const n_lo: usize = @intCast(n);
    // memmove semantics: if regions overlap with dst > src, copy
    // backwards; otherwise forwards.
    if (dst_lo > src_lo and dst_lo < src_lo + n_lo) {
        std.mem.copyBackwards(u8, rt.memory[dst_lo .. dst_lo + n_lo], rt.memory[src_lo .. src_lo + n_lo]);
    } else {
        std.mem.copyForwards(u8, rt.memory[dst_lo .. dst_lo + n_lo], rt.memory[src_lo .. src_lo + n_lo]);
    }
}

fn memoryFill(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const n_i = rt.popOperand().i32;
    const val_i = rt.popOperand().i32;
    const dst_i = rt.popOperand().i32;
    const n: u64 = @as(u32, @bitCast(n_i));
    const dst: u64 = @as(u32, @bitCast(dst_i));
    const mem_len: u64 = rt.memory.len;
    if (dst + n > mem_len) return Trap.OutOfBoundsStore;
    if (n == 0) return;
    const dst_lo: usize = @intCast(dst);
    const n_lo: usize = @intCast(n);
    const byte: u8 = @truncate(@as(u32, @bitCast(val_i)));
    @memset(rt.memory[dst_lo .. dst_lo + n_lo], byte);
}

/// memory.init x: pop n, src, dst. Copy n bytes from data segment
/// rt.datas[x] starting at offset src into rt.memory at offset
/// dst. Trap OutOfBoundsStore if src+n > data.len OR dst+n >
/// mem.len. If the segment was previously dropped, treat its data
/// length as 0 (any n>0 → trap).
fn memoryInit(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const dataidx = instr.payload;
    if (dataidx >= rt.datas.len) return Trap.Unreachable;
    const dropped = if (dataidx < rt.data_dropped.len) rt.data_dropped[dataidx] else false;
    const seg_len: u64 = if (dropped) 0 else rt.datas[dataidx].len;

    const n_i = rt.popOperand().i32;
    const src_i = rt.popOperand().i32;
    const dst_i = rt.popOperand().i32;
    const n: u64 = @as(u32, @bitCast(n_i));
    const src: u64 = @as(u32, @bitCast(src_i));
    const dst: u64 = @as(u32, @bitCast(dst_i));
    if (src + n > seg_len or dst + n > rt.memory.len) return Trap.OutOfBoundsStore;
    if (n == 0) return;
    const src_lo: usize = @intCast(src);
    const dst_lo: usize = @intCast(dst);
    const n_lo: usize = @intCast(n);
    @memcpy(rt.memory[dst_lo .. dst_lo + n_lo], rt.datas[dataidx][src_lo .. src_lo + n_lo]);
}

/// data.drop x: mark data segment x as dropped. Subsequent
/// memory.init x calls treat its length as 0.
fn dataDrop(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const dataidx = instr.payload;
    if (dataidx >= rt.data_dropped.len) return Trap.Unreachable;
    rt.data_dropped[dataidx] = true;
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

fn allocMem(rt: *Runtime, len: usize) !void {
    rt.memory = try rt.alloc.alloc(u8, len);
    @memset(rt.memory, 0);
}

test "register: bulk-memory slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"memory.copy")] != null);
    try testing.expect(t.interp[op(.@"memory.fill")] != null);
    try testing.expect(t.interp[op(.@"memory.init")] != null);
    try testing.expect(t.interp[op(.@"data.drop")] != null);
}

fn setupDatas(rt: *Runtime, segs: []const []const u8) !void {
    rt.datas = segs;
    rt.data_dropped = try rt.alloc.alloc(bool, segs.len);
    @memset(rt.data_dropped, false);
}

test "memory.init: copy bytes from data segment to memory" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    const seg0 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    const segs = [_][]const u8{&seg0};
    try setupDatas(&rt, &segs);
    try rt.pushOperand(.{ .i32 = 4 }); // dst
    try rt.pushOperand(.{ .i32 = 1 }); // src (offset within seg)
    try rt.pushOperand(.{ .i32 = 3 }); // n
    try driveOne(&rt, &t, .@"memory.init", 0, 0);
    try testing.expectEqual(@as(u8, 0xBB), rt.memory[4]);
    try testing.expectEqual(@as(u8, 0xCC), rt.memory[5]);
    try testing.expectEqual(@as(u8, 0xDD), rt.memory[6]);
}

test "memory.init: src+n > seg_len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    const seg0 = [_]u8{ 0xAA, 0xBB, 0xCC };
    const segs = [_][]const u8{&seg0};
    try setupDatas(&rt, &segs);
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 1 }); // src
    try rt.pushOperand(.{ .i32 = 5 }); // n (1+5=6 > 3)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.init", 0, 0));
}

test "memory.init: dst+n > mem_len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 4);
    const seg0 = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const segs = [_][]const u8{&seg0};
    try setupDatas(&rt, &segs);
    try rt.pushOperand(.{ .i32 = 2 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 3 }); // n (2+3=5 > 4)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.init", 0, 0));
}

test "memory.init after data.drop: any n>0 traps; n=0 succeeds" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    const seg0 = [_]u8{ 0x11, 0x22, 0x33 };
    const segs = [_][]const u8{&seg0};
    try setupDatas(&rt, &segs);

    // data.drop 0
    try driveOne(&rt, &t, .@"data.drop", 0, 0);
    try testing.expectEqual(true, rt.data_dropped[0]);

    // memory.init 0 with n=1 → trap (segment effectively empty).
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 1 }); // n
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.init", 0, 0));

    // memory.init 0 with n=0 succeeds (no-op).
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 0 }); // n
    try driveOne(&rt, &t, .@"memory.init", 0, 0);
}

test "data.drop: dataidx out of range traps Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // No datas set up.
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"data.drop", 0, 0));
}

test "memory.copy: non-overlapping forward copy" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    rt.memory[0] = 0xAA;
    rt.memory[1] = 0xBB;
    rt.memory[2] = 0xCC;
    // memory.copy: pop n, src, dst. Push order: dst, src, n.
    try rt.pushOperand(.{ .i32 = 8 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 3 }); // n
    try driveOne(&rt, &t, .@"memory.copy", 0, 0);
    try testing.expectEqual(@as(u8, 0xAA), rt.memory[8]);
    try testing.expectEqual(@as(u8, 0xBB), rt.memory[9]);
    try testing.expectEqual(@as(u8, 0xCC), rt.memory[10]);
}

test "memory.copy: zero-length is a no-op even at boundary" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    try rt.pushOperand(.{ .i32 = 16 }); // dst (one past end)
    try rt.pushOperand(.{ .i32 = 16 }); // src
    try rt.pushOperand(.{ .i32 = 0 }); // n
    try driveOne(&rt, &t, .@"memory.copy", 0, 0);
}

test "memory.copy: overlap dst > src → backward copy preserves data" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    // 0x01 0x02 0x03 0x04 0x05 ...
    var i: u8 = 0;
    while (i < 8) : (i += 1) rt.memory[i] = i + 1;
    // Copy [0..4] to [2..6] — overlap, dst > src.
    try rt.pushOperand(.{ .i32 = 2 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 4 }); // n
    try driveOne(&rt, &t, .@"memory.copy", 0, 0);
    // After: memory[0..6] = 1 2 1 2 3 4
    try testing.expectEqual(@as(u8, 1), rt.memory[0]);
    try testing.expectEqual(@as(u8, 2), rt.memory[1]);
    try testing.expectEqual(@as(u8, 1), rt.memory[2]);
    try testing.expectEqual(@as(u8, 2), rt.memory[3]);
    try testing.expectEqual(@as(u8, 3), rt.memory[4]);
    try testing.expectEqual(@as(u8, 4), rt.memory[5]);
}

test "memory.copy: overlap src > dst → forward copy preserves data" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    var i: u8 = 0;
    while (i < 8) : (i += 1) rt.memory[i] = i + 1;
    // Copy [2..6] to [0..4] — overlap, src > dst.
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 2 }); // src
    try rt.pushOperand(.{ .i32 = 4 }); // n
    try driveOne(&rt, &t, .@"memory.copy", 0, 0);
    // After: memory[0..6] = 3 4 5 6 5 6
    try testing.expectEqual(@as(u8, 3), rt.memory[0]);
    try testing.expectEqual(@as(u8, 4), rt.memory[1]);
    try testing.expectEqual(@as(u8, 5), rt.memory[2]);
    try testing.expectEqual(@as(u8, 6), rt.memory[3]);
    try testing.expectEqual(@as(u8, 5), rt.memory[4]);
    try testing.expectEqual(@as(u8, 6), rt.memory[5]);
}

test "memory.copy: src+n > len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    try rt.pushOperand(.{ .i32 = 0 }); // dst
    try rt.pushOperand(.{ .i32 = 5 }); // src
    try rt.pushOperand(.{ .i32 = 4 }); // n (5+4 = 9 > 8)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.copy", 0, 0));
}

test "memory.copy: dst+n > len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    try rt.pushOperand(.{ .i32 = 5 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // src
    try rt.pushOperand(.{ .i32 = 4 }); // n (5+4 = 9 > 8)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.copy", 0, 0));
}

test "memory.fill: writes byte-low-8 of value" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    try rt.pushOperand(.{ .i32 = 4 }); // dst
    try rt.pushOperand(.{ .i32 = @bitCast(@as(u32, 0xAABBCCEE)) }); // val (low 8 → 0xEE)
    try rt.pushOperand(.{ .i32 = 6 }); // n
    try driveOne(&rt, &t, .@"memory.fill", 0, 0);
    var i: usize = 4;
    while (i < 10) : (i += 1) {
        try testing.expectEqual(@as(u8, 0xEE), rt.memory[i]);
    }
    // Untouched bytes still zero.
    try testing.expectEqual(@as(u8, 0), rt.memory[3]);
    try testing.expectEqual(@as(u8, 0), rt.memory[10]);
}

test "memory.fill: zero-length is a no-op even at boundary" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 16);
    try rt.pushOperand(.{ .i32 = 16 }); // dst at boundary
    try rt.pushOperand(.{ .i32 = 0xAA }); // val
    try rt.pushOperand(.{ .i32 = 0 }); // n
    try driveOne(&rt, &t, .@"memory.fill", 0, 0);
}

test "memory.fill: dst+n > len → OutOfBoundsStore" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try allocMem(&rt, 8);
    try rt.pushOperand(.{ .i32 = 5 }); // dst
    try rt.pushOperand(.{ .i32 = 0 }); // val
    try rt.pushOperand(.{ .i32 = 4 }); // n (5+4 = 9 > 8)
    try testing.expectError(Trap.OutOfBoundsStore, driveOne(&rt, &t, .@"memory.fill", 0, 0));
}
