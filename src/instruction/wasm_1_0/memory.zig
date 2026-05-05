//! MVP memory ops — loads / stores / memory.size / memory.grow
//! (Phase 2 / §9.2 / 2.2 chunk 5).
//!
//! Extracted from `src/interp/mvp.zig` for the §A2 file-size cap.
//! Effective address = base (popped i32) + memarg.offset (encoded
//! by the lowerer into `ZirInstr.payload`). Width-bounds check
//! against `Runtime.memory.len` traps `OutOfBoundsLoad` /
//! `OutOfBoundsStore`. f32 / f64 transit through `Value.bits64`
//! to preserve IEEE-754 without canonicalisation.
//!
//! Wasm 1.0 page size = 64 KiB, max 2^16 pages. `memory.grow`
//! returns -1 (i32) on OOM or page-cap overflow per spec.
//!
//! Zone 2 (`src/interp/`) — imports Zone 1 (`ir/`) and sibling
//! Zone 2 (`mod.zig`).

const std = @import("std");

const dispatch = @import("../../ir/dispatch_table.zig");
const zir = @import("../../ir/zir.zig");
const runtime = @import("../../runtime/runtime.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = runtime.Runtime;
const Trap = runtime.Trap;

inline fn op(t: ZirOp) usize {
    return @intFromEnum(t);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"i32.load")] = i32Load;
    table.interp[op(.@"i64.load")] = i64Load;
    table.interp[op(.@"f32.load")] = f32Load;
    table.interp[op(.@"f64.load")] = f64Load;
    table.interp[op(.@"i32.load8_s")] = i32Load8S;
    table.interp[op(.@"i32.load8_u")] = i32Load8U;
    table.interp[op(.@"i32.load16_s")] = i32Load16S;
    table.interp[op(.@"i32.load16_u")] = i32Load16U;
    table.interp[op(.@"i64.load8_s")] = i64Load8S;
    table.interp[op(.@"i64.load8_u")] = i64Load8U;
    table.interp[op(.@"i64.load16_s")] = i64Load16S;
    table.interp[op(.@"i64.load16_u")] = i64Load16U;
    table.interp[op(.@"i64.load32_s")] = i64Load32S;
    table.interp[op(.@"i64.load32_u")] = i64Load32U;

    table.interp[op(.@"i32.store")] = i32Store;
    table.interp[op(.@"i64.store")] = i64Store;
    table.interp[op(.@"f32.store")] = f32Store;
    table.interp[op(.@"f64.store")] = f64Store;
    table.interp[op(.@"i32.store8")] = i32Store8;
    table.interp[op(.@"i32.store16")] = i32Store16;
    table.interp[op(.@"i64.store8")] = i64Store8;
    table.interp[op(.@"i64.store16")] = i64Store16;
    table.interp[op(.@"i64.store32")] = i64Store32;

    table.interp[op(.@"memory.size")] = memorySize;
    table.interp[op(.@"memory.grow")] = memoryGrow;
}

// ============================================================
// Loads / stores / memory
// ============================================================

const wasm_page_size: usize = 65536;

fn effectiveAddrStore(rt: *Runtime, offset: u32, width: usize) Trap!usize {
    // Mirrors the inline addr math in `loadInt`; trap kind is Store here.
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, offset);
    if (ea + width > rt.memory.len) return Trap.OutOfBoundsStore;
    return @intCast(ea);
}

// --- Loads ---

fn i32Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    // Pop addr first; effectiveAddr captures it.
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 4 > rt.memory.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u32, rt.memory[@intCast(ea)..][0..4], .little);
    try rt.pushOperand(.{ .u32 = v });
}

fn i64Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 8 > rt.memory.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u64, rt.memory[@intCast(ea)..][0..8], .little);
    try rt.pushOperand(.{ .u64 = v });
}

fn f32Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 4 > rt.memory.len) return Trap.OutOfBoundsLoad;
    const bits = std.mem.readInt(u32, rt.memory[@intCast(ea)..][0..4], .little);
    try rt.pushOperand(.{ .bits64 = bits });
}

fn f64Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 8 > rt.memory.len) return Trap.OutOfBoundsLoad;
    const bits = std.mem.readInt(u64, rt.memory[@intCast(ea)..][0..8], .little);
    try rt.pushOperand(.{ .bits64 = bits });
}

fn loadInt(rt: *Runtime, comptime W: type, comptime sign_extend: bool, offset: u32) Trap!i64 {
    const width = @sizeOf(W);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, offset);
    if (ea + width > rt.memory.len) return Trap.OutOfBoundsLoad;
    const raw = std.mem.readInt(W, rt.memory[@intCast(ea)..][0..width], .little);
    if (sign_extend) {
        const SignedW = @Int(.signed, @bitSizeOf(W));
        const sw: SignedW = @bitCast(raw);
        return @as(i64, sw);
    }
    return @as(i64, @as(i64, @bitCast(@as(u64, raw))));
}

fn i32Load8S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u8, true, instr.payload);
    try rt.pushOperand(.{ .i32 = @intCast(@as(i32, @truncate(v))) });
}
fn i32Load8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u8, false, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i32Load16S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u16, true, instr.payload);
    try rt.pushOperand(.{ .i32 = @intCast(@as(i32, @truncate(v))) });
}
fn i32Load16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u16, false, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i64Load8S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u8, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u8, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}
fn i64Load16S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u16, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u16, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}
fn i64Load32S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u32, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load32U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try loadInt(rt, u32, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}

// --- Stores ---

fn i32Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand().u32;
    const ea = try effectiveAddrStore(rt, instr.payload, 4);
    std.mem.writeInt(u32, rt.memory[ea..][0..4], v, .little);
}
fn i64Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand().u64;
    const ea = try effectiveAddrStore(rt, instr.payload, 8);
    std.mem.writeInt(u64, rt.memory[ea..][0..8], v, .little);
}
fn f32Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const bits: u32 = @truncate(v.bits64);
    const ea = try effectiveAddrStore(rt, instr.payload, 4);
    std.mem.writeInt(u32, rt.memory[ea..][0..4], bits, .little);
}
fn f64Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const ea = try effectiveAddrStore(rt, instr.payload, 8);
    std.mem.writeInt(u64, rt.memory[ea..][0..8], v.bits64, .little);
}
fn i32Store8(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u8 = @truncate(rt.popOperand().u32);
    const ea = try effectiveAddrStore(rt, instr.payload, 1);
    rt.memory[ea] = v;
}
fn i32Store16(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u16 = @truncate(rt.popOperand().u32);
    const ea = try effectiveAddrStore(rt, instr.payload, 2);
    std.mem.writeInt(u16, rt.memory[ea..][0..2], v, .little);
}
fn i64Store8(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u8 = @truncate(rt.popOperand().u64);
    const ea = try effectiveAddrStore(rt, instr.payload, 1);
    rt.memory[ea] = v;
}
fn i64Store16(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u16 = @truncate(rt.popOperand().u64);
    const ea = try effectiveAddrStore(rt, instr.payload, 2);
    std.mem.writeInt(u16, rt.memory[ea..][0..2], v, .little);
}
fn i64Store32(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u32 = @truncate(rt.popOperand().u64);
    const ea = try effectiveAddrStore(rt, instr.payload, 4);
    std.mem.writeInt(u32, rt.memory[ea..][0..4], v, .little);
}

// --- memory.size / memory.grow ---

fn memorySize(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const pages: u32 = @intCast(rt.memory.len / wasm_page_size);
    try rt.pushOperand(.{ .u32 = pages });
}

fn memoryGrow(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const delta = rt.popOperand().u32;
    const old_pages: u32 = @intCast(rt.memory.len / wasm_page_size);
    // Wasm 1.0 max: 2^16 pages = 4 GiB. Fail returns -1 (i32).
    const new_pages: u64 = @as(u64, old_pages) + @as(u64, delta);
    if (new_pages > std.math.maxInt(u16) + 1) {
        try rt.pushOperand(.{ .i32 = -1 });
        return;
    }
    const new_bytes: usize = @intCast(new_pages * wasm_page_size);
    const new_mem = rt.alloc.realloc(rt.memory, new_bytes) catch {
        try rt.pushOperand(.{ .i32 = -1 });
        return;
    };
    @memset(new_mem[rt.memory.len..], 0);
    rt.memory = new_mem;
    try rt.pushOperand(.{ .u32 = old_pages });
}


// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "i32.load / i32.store round-trip with offset" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);

    // Store 0xCAFEBABE at addr=4 + offset=4 = 8.
    try rt.pushOperand(.{ .u32 = 4 }); // base address
    try rt.pushOperand(.{ .u32 = 0xCAFEBABE }); // value
    try driveOne(&rt, &t, .@"i32.store", 4, 0); // payload=offset=4

    // Load it back.
    try rt.pushOperand(.{ .u32 = 4 });
    try driveOne(&rt, &t, .@"i32.load", 4, 0);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), rt.popOperand().u32);
}

test "i32.load OOB traps" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 8);

    try rt.pushOperand(.{ .u32 = 5 }); // 5+4 > 8
    try testing.expectError(Trap.OutOfBoundsLoad, driveOne(&rt, &t, .@"i32.load", 0, 0));
}

test "i32.load8_s sign-extends" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 4);
    rt.memory[0] = 0xFF;

    try rt.pushOperand(.{ .u32 = 0 });
    try driveOne(&rt, &t, .@"i32.load8_s", 0, 0);
    try testing.expectEqual(@as(i32, -1), rt.popOperand().i32);
}

test "memory.size: zero-page memory" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"memory.size", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);
}

test "memory.grow grows by 1 page; size reflects update" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .u32 = 1 });
    try driveOne(&rt, &t, .@"memory.grow", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32); // old size
    try testing.expectEqual(@as(usize, 65536), rt.memory.len);

    try driveOne(&rt, &t, .@"memory.size", 0, 0);
    try testing.expectEqual(@as(u32, 1), rt.popOperand().u32);
}

