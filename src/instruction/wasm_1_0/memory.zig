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

/// 10.M cycle 64 — return the byte slice of the memory targeted by
/// `instr.extra`'s `MemArgExtra.memidx` field (Wasm 3.0 §5.4.6
/// memarg encoding). For memidx=0 this is `rt.memories[0].bytes`
/// which aliases the legacy `rt.memory` per
/// `setMemory0Bytes` (ADR-0111 D2); for memidx > 0 this routes to
/// the corresponding entry in the `rt.memories` array.
///
/// Returns an empty slice when `rt.memories` is uninitialised (test
/// scaffolds that bypass the full instantiate path leave it empty
/// + rt.memory non-empty); falls back to `rt.memory` in that case
/// so MVP single-memory tests stay green.
inline fn memorySlice(rt: *Runtime, extra: u32) []u8 {
    const memidx: u8 = zir.MemArgExtra.unpack(extra).memidx;
    if (rt.memories.len == 0) return rt.memory;
    if (memidx >= rt.memories.len) return &[_]u8{};
    return rt.memories[memidx].bytes;
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"i32.load")] = i32Load;
    table.interp[op(.@"i32.atomic.load")] = i32AtomicLoad;
    table.interp[op(.@"i64.atomic.load")] = i64AtomicLoad;
    table.interp[op(.@"i32.atomic.load8_u")] = i32AtomicLoad8U;
    table.interp[op(.@"i32.atomic.load16_u")] = i32AtomicLoad16U;
    table.interp[op(.@"i64.atomic.load8_u")] = i64AtomicLoad8U;
    table.interp[op(.@"i64.atomic.load16_u")] = i64AtomicLoad16U;
    table.interp[op(.@"i64.atomic.load32_u")] = i64AtomicLoad32U;
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

fn effectiveAddrStore(mem: []u8, popped_addr: u32, offset: u64, width: usize) Trap!usize {
    const ea: u64 = @as(u64, popped_addr) + offset;
    if (ea + width > mem.len) return Trap.OutOfBoundsStore;
    return @intCast(ea);
}

// --- Loads ---

fn i32Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 4 > mem.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u32, mem[@intCast(ea)..][0..4], .little);
    try rt.pushOperand(.{ .u32 = v });
}

/// Wasm threads §exec — `i32.atomic.load` (ADR-0168): naturally
/// aligned 4-byte load. On the single-threaded substrate every atomic
/// access is trivially seq-cst, so this is a plain little-endian load.
/// Per spec step 8 the alignment trap (`ea mod 4 ≠ 0`) is checked
/// BEFORE the bounds test (step 14a). Validation already pinned the
/// static memarg align to exactly 2 (natural).
fn i32AtomicLoad(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea & 3 != 0) return Trap.UnalignedAtomic;
    if (ea + 4 > mem.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u32, mem[@intCast(ea)..][0..4], .little);
    try rt.pushOperand(.{ .u32 = v });
}

/// Wasm threads §exec — `i64.atomic.load` (ADR-0168): naturally
/// aligned 8-byte seq-cst load. Mirrors `i32AtomicLoad` (alignment
/// trap `ea mod 8 ≠ 0` BEFORE bounds, spec step 8 < 14a); natural
/// align pinned to 3 by validation.
fn i64AtomicLoad(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea & 7 != 0) return Trap.UnalignedAtomic;
    if (ea + 8 > mem.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u64, mem[@intCast(ea)..][0..8], .little);
    try rt.pushOperand(.{ .u64 = v });
}

/// Wasm threads §exec — narrow atomic loads (`*.atomic.load{8,16,32}_u`,
/// ADR-0168): naturally aligned zero-extending load. Alignment trap
/// (`ea mod width ≠ 0`) BEFORE bounds (spec step 8 < 14a); 1-byte loads
/// are always aligned. All atomic narrow loads are UNSIGNED (no _s).
fn atomicLoadU(mem: []const u8, popped_addr: u32, comptime W: type, offset: u64) Trap!u64 {
    const width = @sizeOf(W);
    const ea: u64 = @as(u64, popped_addr) + offset;
    if (ea & (width - 1) != 0) return Trap.UnalignedAtomic;
    if (ea + width > mem.len) return Trap.OutOfBoundsLoad;
    return @as(u64, std.mem.readInt(W, mem[@intCast(ea)..][0..width], .little));
}
fn i32AtomicLoad8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u8, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i32AtomicLoad16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u16, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i64AtomicLoad8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u8, instr.payload);
    try rt.pushOperand(.{ .u64 = v });
}
fn i64AtomicLoad16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u16, instr.payload);
    try rt.pushOperand(.{ .u64 = v });
}
fn i64AtomicLoad32U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = try atomicLoadU(memorySlice(rt, instr.extra), rt.popOperand().u32, u32, instr.payload);
    try rt.pushOperand(.{ .u64 = v });
}

fn i64Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 8 > mem.len) return Trap.OutOfBoundsLoad;
    const v = std.mem.readInt(u64, mem[@intCast(ea)..][0..8], .little);
    try rt.pushOperand(.{ .u64 = v });
}

fn f32Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 4 > mem.len) return Trap.OutOfBoundsLoad;
    const bits = std.mem.readInt(u32, mem[@intCast(ea)..][0..4], .little);
    try rt.pushOperand(.{ .bits64 = bits });
}

fn f64Load(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const mem = memorySlice(rt, instr.extra);
    const ea: u64 = @as(u64, rt.popOperand().u32) + @as(u64, instr.payload);
    if (ea + 8 > mem.len) return Trap.OutOfBoundsLoad;
    const bits = std.mem.readInt(u64, mem[@intCast(ea)..][0..8], .little);
    try rt.pushOperand(.{ .bits64 = bits });
}

fn loadInt(mem: []const u8, popped_addr: u32, comptime W: type, comptime sign_extend: bool, offset: u64) Trap!i64 {
    const width = @sizeOf(W);
    const ea: u64 = @as(u64, popped_addr) + offset;
    if (ea + width > mem.len) return Trap.OutOfBoundsLoad;
    const raw = std.mem.readInt(W, mem[@intCast(ea)..][0..width], .little);
    if (sign_extend) {
        const SignedW = @Int(.signed, @bitSizeOf(W));
        const sw: SignedW = @bitCast(raw);
        return @as(i64, sw);
    }
    return @as(i64, @as(i64, @bitCast(@as(u64, raw))));
}

fn i32Load8S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u8, true, instr.payload);
    try rt.pushOperand(.{ .i32 = @intCast(@as(i32, @truncate(v))) });
}
fn i32Load8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u8, false, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i32Load16S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u16, true, instr.payload);
    try rt.pushOperand(.{ .i32 = @intCast(@as(i32, @truncate(v))) });
}
fn i32Load16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u16, false, instr.payload);
    try rt.pushOperand(.{ .u32 = @intCast(v) });
}
fn i64Load8S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u8, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load8U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u8, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}
fn i64Load16S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u16, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load16U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u16, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}
fn i64Load32S(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u32, true, instr.payload);
    try rt.pushOperand(.{ .i64 = v });
}
fn i64Load32U(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const addr = rt.popOperand().u32;
    const v = try loadInt(memorySlice(rt, instr.extra), addr, u32, false, instr.payload);
    try rt.pushOperand(.{ .u64 = @intCast(v) });
}

// --- Stores ---

fn i32Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand().u32;
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 4);
    std.mem.writeInt(u32, mem[ea..][0..4], v, .little);
}
fn i64Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand().u64;
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 8);
    std.mem.writeInt(u64, mem[ea..][0..8], v, .little);
}
fn f32Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const bits: u32 = @truncate(v.bits64);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 4);
    std.mem.writeInt(u32, mem[ea..][0..4], bits, .little);
}
fn f64Store(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 8);
    std.mem.writeInt(u64, mem[ea..][0..8], v.bits64, .little);
}
fn i32Store8(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u8 = @truncate(rt.popOperand().u32);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 1);
    mem[ea] = v;
}
fn i32Store16(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u16 = @truncate(rt.popOperand().u32);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 2);
    std.mem.writeInt(u16, mem[ea..][0..2], v, .little);
}
fn i64Store8(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u8 = @truncate(rt.popOperand().u64);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 1);
    mem[ea] = v;
}
fn i64Store16(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u16 = @truncate(rt.popOperand().u64);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 2);
    std.mem.writeInt(u16, mem[ea..][0..2], v, .little);
}
fn i64Store32(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v: u32 = @truncate(rt.popOperand().u64);
    const addr = rt.popOperand().u32;
    const mem = memorySlice(rt, instr.extra);
    const ea = try effectiveAddrStore(mem, addr, instr.payload, 4);
    std.mem.writeInt(u32, mem[ea..][0..4], v, .little);
}

// --- memory.size / memory.grow ---

/// True when the memory at `memidx` is declared with `(memory i64 …)`
/// (Wasm 3.0 memory64). Falls back to i32 when `rt.memories[memidx]`
/// is not present (test scaffolds that bypass instantiate leave
/// memories empty + rt.memory non-empty for memidx=0).
inline fn memoryIsI64(rt: *const Runtime, memidx: usize) bool {
    return memidx < rt.memories.len and rt.memories[memidx].idx_type == .i64;
}

fn memorySize(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    // 10.M cycle 66 — memidx in instr.payload (was reserved 0x00
    // pre-multi-memory). Route through rt.memories[memidx]; fall
    // back to rt.memory for the legacy memidx=0 / pre-instantiate
    // case so the existing in-source unit tests stay green.
    const memidx: usize = @intCast(instr.payload);
    const mem: []const u8 = if (memidx < rt.memories.len)
        rt.memories[memidx].bytes
    else if (memidx == 0)
        rt.memory
    else
        return Trap.OutOfBoundsLoad;
    const pages: u64 = mem.len / wasm_page_size;
    // Wasm spec §4.4.7 — result type matches the memory's idx_type.
    if (memoryIsI64(rt, memidx)) {
        try rt.pushOperand(.{ .i64 = @bitCast(pages) });
    } else {
        try rt.pushOperand(.{ .u32 = @intCast(pages) });
    }
}

fn memoryGrow(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const memidx: usize = @intCast(instr.payload);
    const is_i64 = memoryIsI64(rt, memidx);
    // Pop delta in the memory's idx-type-width: writer pushed i64
    // for memory64 modules; reading .u32 there would mask off the
    // high half and silently miscompute.
    const delta: u64 = if (is_i64) @bitCast(rt.popOperand().i64) else rt.popOperand().u32;
    // Core grow (cap + realloc + zero-fill + memory0 alias) lives on
    // `Runtime.growMemory` so the interp handler + the Zig facade
    // `Memory.grow` share one implementation. `null` = grow refused
    // (cap exceeded / overflow / OOM) → push the -1 sentinel; the
    // result width follows the memory's idx-type.
    const old_pages = rt.growMemory(memidx, delta) orelse {
        if (is_i64) try rt.pushOperand(.{ .i64 = -1 }) else try rt.pushOperand(.{ .i32 = -1 });
        return;
    };
    if (is_i64) {
        try rt.pushOperand(.{ .i64 = @bitCast(old_pages) });
    } else {
        try rt.pushOperand(.{ .u32 = @intCast(old_pages) });
    }
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

test "i32.atomic.load reads an aligned word" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);

    // Plain store 0xCAFEBABE at aligned addr=8, then atomic-load it.
    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u32 = 0xCAFEBABE });
    try driveOne(&rt, &t, .@"i32.store", 0, 0);

    try rt.pushOperand(.{ .u32 = 8 });
    try driveOne(&rt, &t, .@"i32.atomic.load", 0, 0);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), rt.popOperand().u32);
}

test "i32.atomic.load unaligned address traps UnalignedAtomic (before bounds)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);

    // addr=2 is in-bounds but not 4-aligned → alignment trap, not OOB.
    try rt.pushOperand(.{ .u32 = 2 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"i32.atomic.load", 0, 0));
}

test "i64.atomic.load reads an aligned doubleword + traps unaligned (4 not 8-aligned)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);

    try rt.pushOperand(.{ .u32 = 8 });
    try rt.pushOperand(.{ .u64 = 0x0123456789ABCDEF });
    try driveOne(&rt, &t, .@"i64.store", 0, 0);
    try rt.pushOperand(.{ .u32 = 8 });
    try driveOne(&rt, &t, .@"i64.atomic.load", 0, 0);
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), rt.popOperand().u64);

    // addr=4 is 4-aligned but NOT 8-aligned → UnalignedAtomic.
    try rt.pushOperand(.{ .u32 = 4 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"i64.atomic.load", 0, 0));
}

test "narrow atomic loads zero-extend + trap unaligned" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 64);
    @memset(rt.memory, 0);
    rt.memory[5] = 0xAB; // byte at 5
    std.mem.writeInt(u32, rt.memory[8..][0..4], 0xDEADBEEF, .little); // word at 8

    // i32.atomic.load8_u @5 → 0xAB (byte access always aligned).
    try rt.pushOperand(.{ .u32 = 5 });
    try driveOne(&rt, &t, .@"i32.atomic.load8_u", 0, 0);
    try testing.expectEqual(@as(u32, 0xAB), rt.popOperand().u32);
    // i64.atomic.load32_u @8 → 0xDEADBEEF zero-extended to u64.
    try rt.pushOperand(.{ .u32 = 8 });
    try driveOne(&rt, &t, .@"i64.atomic.load32_u", 0, 0);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), rt.popOperand().u64);
    // i32.atomic.load16_u @1 (odd) → UnalignedAtomic.
    try rt.pushOperand(.{ .u32 = 1 });
    try testing.expectError(Trap.UnalignedAtomic, driveOne(&rt, &t, .@"i32.atomic.load16_u", 0, 0));
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

test "memory.size on memory64 returns i64 result (ADR-0111 D2 runtime)" {
    // Wasm spec §4.4.7 — memory.size returns i32 for i32-indexed
    // memory and i64 for i64-indexed (memory64). The interp's
    // current i32-only path returned the low 32 bits with the
    // high bits undefined; the wasm-3.0-assert memory64 corpus
    // surfaced this as ~22 size/grow mismatches.
    const sections_mod = @import("../../parse/sections.zig");
    const memory_instance = @import("../../runtime/instance/memory_instance.zig");

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    rt.memory = try testing.allocator.alloc(u8, 2 * 65536); // 2 pages
    var mi_val: memory_instance.MemoryInstance = .{
        .bytes = rt.memory,
        .idx_type = sections_mod.MemoryEntry.IdxType.i64,
        .pages_min = 2,
        .pages_max = null,
    };
    var mi = [_]*memory_instance.MemoryInstance{&mi_val};
    rt.memories = mi[0..];
    defer rt.memories = &.{};

    try driveOne(&rt, &t, .@"memory.size", 0, 0);
    try testing.expectEqual(@as(i64, 2), rt.popOperand().i64);
}

test "memory.grow on memory64 pops i64 delta, pushes i64 old_size (ADR-0111 D2 runtime)" {
    const sections_mod = @import("../../parse/sections.zig");
    const memory_instance = @import("../../runtime/instance/memory_instance.zig");

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var mi_val: memory_instance.MemoryInstance = .{
        .bytes = &.{},
        .idx_type = sections_mod.MemoryEntry.IdxType.i64,
        .pages_min = 0,
        .pages_max = null,
    };
    var mi = [_]*memory_instance.MemoryInstance{&mi_val};
    rt.memories = mi[0..];
    defer rt.memories = &.{};

    try rt.pushOperand(.{ .i64 = 1 });
    try driveOne(&rt, &t, .@"memory.grow", 0, 0);
    try testing.expectEqual(@as(i64, 0), rt.popOperand().i64); // old size = 0
    try testing.expectEqual(@as(usize, 65536), rt.memory.len);
}
