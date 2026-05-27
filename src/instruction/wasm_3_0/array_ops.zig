//! Wasm 3.0 GC array allocation + element access interp handlers
//! (10.G op_gc cycle 24+ per `.dev/phase10_g_op_bundle_plan.md`).
//!
//! Mirrors `struct_ops.zig` (cycle 22-23) for the array catalogue:
//! consumes the cycle-21 Instance.gc_type_infos.array_infos[typeidx]
//! + the cycle-3 GC Heap slab, writes ArrayHeader (ObjectHeader +
//! length slot per ADR-0116 §3a) at offset 0, then N * element.size
//! bytes of payload.
//!
//! Encoding:
//!   - `array.new typeidx`         (0xFB 0x06): pop init + i32 size,
//!                                              allocate, fill N copies.
//!   - `array.new_default typeidx` (0xFB 0x07): pop i32 size, alloc,
//!                                              zero-init payload.
//!   - `array.new_fixed typeidx N` (0xFB 0x08): pop N values (reverse),
//!                                              alloc, fill.
//!
//! Push shape: GcRef as `.ref = @as(u64, ref_u32)` (same as struct_ops).
//!
//! Zone 1 (`src/instruction/`).

const std = @import("std");

const dispatch = @import("../../ir/dispatch_table.zig");
const zir = @import("../../ir/zir.zig");
const runtime = @import("../../runtime/runtime.zig");
const type_info_mod = @import("../../feature/gc/type_info.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = runtime.Runtime;
const Value = runtime.Value;
const Instance = runtime.Instance;

const ObjectHeader = type_info_mod.ObjectHeader;
const ObjectKind = type_info_mod.ObjectKind;
const ArrayHeader = type_info_mod.ArrayHeader;
const ArrayInfo = type_info_mod.ArrayInfo;
const array_header_size: u32 = @sizeOf(ArrayHeader);

inline fn op(o: ZirOp) usize {
    return @intFromEnum(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"array.new")] = arrayNew;
    table.interp[op(.@"array.new_default")] = arrayNewDefault;
    table.interp[op(.@"array.new_fixed")] = arrayNewFixed;
}

fn resolveArrayInfo(inst: *const Instance, typeidx: u32) anyerror!ArrayInfo {
    const gti = inst.gc_type_infos orelse return runtime.Trap.NullReference;
    if (typeidx >= gti.array_infos.len) return runtime.Trap.NullReference;
    return gti.array_infos[typeidx] orelse runtime.Trap.NullReference;
}

/// Allocate an array of `length` elements on the GC heap; write
/// ArrayHeader at offset 0. Returns the 32-bit GcRef.
fn allocateArray(rt: *Runtime, typeidx: u32, length: u32, element_size: u8) anyerror!u32 {
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const payload_bytes: u32 = length * @as(u32, element_size);
    const total: u32 = array_header_size + payload_bytes;
    const ref = try heap.allocate(total);
    const header: ArrayHeader = .{
        .header = .{ .kind = .array, .info = typeidx },
        .length = length,
    };
    @memcpy(heap.bytes[ref .. ref + array_header_size], std.mem.asBytes(&header)[0..array_header_size]);
    return ref;
}

fn arrayNew(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    // Stack top: size:i32; under it: init value.
    const size_val = rt.popOperand();
    const size_i32 = size_val.i32;
    if (size_i32 < 0) return runtime.Trap.OutOfBoundsStore;
    const length: u32 = @intCast(size_i32);
    const init_val = rt.popOperand();
    const ref = try allocateArray(rt, typeidx, length, ai.element.size);
    const heap = rt.gc_heap.?;
    var i: u32 = 0;
    while (i < length) : (i += 1) {
        const dst_off = ref + array_header_size + i * ai.element.size;
        const dst = heap.bytes[dst_off .. dst_off + ai.element.size];
        @memcpy(dst, std.mem.asBytes(&init_val)[0..ai.element.size]);
    }
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

fn arrayNewDefault(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    const size_val = rt.popOperand();
    const size_i32 = size_val.i32;
    if (size_i32 < 0) return runtime.Trap.OutOfBoundsStore;
    const length: u32 = @intCast(size_i32);
    const ref = try allocateArray(rt, typeidx, length, ai.element.size);
    const heap = rt.gc_heap.?;
    const payload_start = ref + array_header_size;
    const payload_end = payload_start + length * @as(u32, ai.element.size);
    @memset(heap.bytes[payload_start..payload_end], 0);
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

fn arrayNewFixed(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const ai = try resolveArrayInfo(inst, typeidx);
    const length: u32 = instr.extra;
    const ref = try allocateArray(rt, typeidx, length, ai.element.size);
    const heap = rt.gc_heap.?;
    // Pop N values in reverse: stack top = last element.
    var i: u32 = length;
    while (i > 0) {
        i -= 1;
        const v = rt.popOperand();
        const dst_off = ref + array_header_size + i * ai.element.size;
        const dst = heap.bytes[dst_off .. dst_off + ai.element.size];
        @memcpy(dst, std.mem.asBytes(&v)[0..ai.element.size]);
    }
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");
const sections = @import("../../parse/sections.zig");

fn buildInstanceForTypes(arena: *std.heap.ArenaAllocator, body: []const u8) !struct { rt: *Runtime, inst: *Instance } {
    const a = arena.allocator();
    var types = try sections.decodeTypes(testing.allocator, body);
    defer types.deinit();
    const gti = try type_info_mod.materialiseGcTypes(a, types);
    const rt = try a.create(Runtime);
    rt.* = Runtime.init(a);
    const heap = try a.create(@import("../../feature/gc/heap.zig").Heap);
    heap.* = @import("../../feature/gc/heap.zig").Heap.init(a);
    rt.gc_heap = heap;
    const inst = try a.create(Instance);
    inst.* = .{ .store = null, .module = null, .runtime = rt };
    inst.gc_type_infos = gti;
    rt.instance = @ptrCast(inst);
    return .{ .rt = rt, .inst = inst };
}

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "array.new_default: allocates ArrayHeader + zero-init payload (10.G op_gc cycle 24)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // array<i32 var>
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try env.rt.pushOperand(.{ .i32 = 3 });
    try driveOne(env.rt, &t, .@"array.new_default", 0, 0);
    const ref: u32 = @intCast(env.rt.popOperand().ref);
    const heap = env.rt.gc_heap.?;
    var header: ArrayHeader = undefined;
    @memcpy(std.mem.asBytes(&header)[0..array_header_size], heap.bytes[ref .. ref + array_header_size]);
    try testing.expectEqual(ObjectKind.array, header.header.kind);
    try testing.expectEqual(@as(u32, 0), header.header.info);
    try testing.expectEqual(@as(u32, 3), header.length);
    // Payload zero-init (3 * 8 = 24 bytes).
    var i: u32 = 0;
    while (i < 24) : (i += 1) {
        try testing.expectEqual(@as(u8, 0), heap.bytes[ref + array_header_size + i]);
    }
}

test "array.new: fills N copies of init value (10.G op_gc cycle 24)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    // Push init value then size; stack top = size.
    try env.rt.pushOperand(.{ .i32 = 42 });
    try env.rt.pushOperand(.{ .i32 = 4 });
    try driveOne(env.rt, &t, .@"array.new", 0, 0);
    const ref: u32 = @intCast(env.rt.popOperand().ref);
    const heap = env.rt.gc_heap.?;
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const off = ref + array_header_size + i * 8;
        var v: Value = undefined;
        @memcpy(std.mem.asBytes(&v)[0..8], heap.bytes[off .. off + 8]);
        try testing.expectEqual(@as(i32, 42), v.i32);
    }
}

test "array.new_fixed N=3: writes 3 values in declared order (10.G op_gc cycle 24)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    // Push 3 i32 values in declared order: 11, 22, 33. Stack top = 33 (last).
    try env.rt.pushOperand(.{ .i32 = 11 });
    try env.rt.pushOperand(.{ .i32 = 22 });
    try env.rt.pushOperand(.{ .i32 = 33 });
    try driveOne(env.rt, &t, .@"array.new_fixed", 0, 3);
    const ref: u32 = @intCast(env.rt.popOperand().ref);
    const heap = env.rt.gc_heap.?;
    const expected = [_]i32{ 11, 22, 33 };
    for (expected, 0..) |want, idx| {
        const off = ref + array_header_size + @as(u32, @intCast(idx)) * 8;
        var v: Value = undefined;
        @memcpy(std.mem.asBytes(&v)[0..8], heap.bytes[off .. off + 8]);
        try testing.expectEqual(want, v.i32);
    }
}
