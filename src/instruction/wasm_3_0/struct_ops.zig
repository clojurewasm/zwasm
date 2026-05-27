//! Wasm 3.0 GC struct allocation + field access interp handlers
//! (10.G op_gc cycle 22+ per `.dev/phase10_g_op_bundle_plan.md`).
//!
//! Wires the no-RTT validator+lower surface landed at cycles 15
//! (`06a8dff5` struct.new family) and 17 (`94e5e3fe` struct.get
//! + struct.set) to the runtime — consuming the StructInfo /
//! ObjectHeader extern layout per ADR-0116 §3a (cycles 19-21
//! substrate) and the per-Store Heap slab per ADR-0115 §1
//! (10.G-foundation cycle 3).
//!
//! Encoding:
//!   - `struct.new typeidx` (0xFB 0x00): pop one Value per field
//!     (reverse declared order), allocate StructInfo.payload_size
//!     + ObjectHeader bytes, write fields at FieldInfo.offset,
//!     push GcRef.
//!   - `struct.new_default typeidx` (0xFB 0x01): allocate; zero-
//!     init payload (Heap.allocate returns zeroed bytes when
//!     newly-grown; otherwise we explicitly zero); push GcRef.
//!
//! Push shape: GcRef as `.ref = @as(u64, ref_u32)` — the low 32
//! bits of the Value.ref union slot. High bits zero; the low-bit-0
//! invariant per ADR-0116 §5 is preserved because Heap.allocate
//! returns 2-byte-aligned offsets.
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
const StructInfo = type_info_mod.StructInfo;
const header_size: u32 = @sizeOf(ObjectHeader);

inline fn op(o: ZirOp) usize {
    return @intFromEnum(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"struct.new")] = structNew;
    table.interp[op(.@"struct.new_default")] = structNewDefault;
}

/// Resolve `inst.gc_type_infos.?.struct_infos[typeidx].?` —
/// returns Trap.NullReference if the GC substrate hasn't been
/// materialised (defensive; the validator+ADR-0116 §1 gate
/// ensure this only fires for malformed callers).
fn resolveStructInfo(inst: *const Instance, typeidx: u32) anyerror!StructInfo {
    const gti = inst.gc_type_infos orelse return runtime.Trap.NullReference;
    if (typeidx >= gti.struct_infos.len) return runtime.Trap.NullReference;
    return gti.struct_infos[typeidx] orelse runtime.Trap.NullReference;
}

/// Allocate the struct object on the GC heap. Returns the
/// 32-bit GcRef offset; writes the ObjectHeader at offset 0.
fn allocateStruct(rt: *Runtime, typeidx: u32, payload_size: u32) anyerror!u32 {
    const heap = rt.gc_heap orelse return runtime.Trap.NullReference;
    const total_size: u32 = header_size + payload_size;
    const ref = try heap.allocate(total_size);
    // Write ObjectHeader at offset 0 of the allocation.
    const header_bytes = heap.bytes[ref .. ref + header_size];
    const header: ObjectHeader = .{
        .kind = .struct_,
        .info = typeidx,
    };
    @memcpy(header_bytes, std.mem.asBytes(&header));
    return ref;
}

fn structNew(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const si = try resolveStructInfo(inst, typeidx);
    const ref = try allocateStruct(rt, typeidx, si.payload_size);
    // Pop fields in reverse declared order: stack top = last field.
    // Write each field's Value into the payload at fields[i].offset.
    const heap = rt.gc_heap.?;
    var i: usize = si.type_info.field_count;
    while (i > 0) {
        i -= 1;
        const field = si.fields[i];
        const v = rt.popOperand();
        const dst_off = ref + header_size + field.offset;
        // All slots are 8 bytes this cut (ADR-0116 §3a) — write
        // the low 8 bytes of the Value's u64-equivalent storage.
        // Value is an extern union so reinterpret as u64 bytes is
        // safe; the validator-driven valtype tells the field which
        // arm was active.
        const dst = heap.bytes[dst_off .. dst_off + 8];
        const as_u64 = std.mem.asBytes(&v)[0..8];
        @memcpy(dst, as_u64);
    }
    try rt.pushOperand(.{ .ref = @as(u64, ref) });
}

fn structNewDefault(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const inst = @as(*const Instance, @ptrCast(@alignCast(rt.instance orelse return runtime.Trap.NullReference)));
    const typeidx: u32 = @intCast(instr.payload);
    const si = try resolveStructInfo(inst, typeidx);
    const ref = try allocateStruct(rt, typeidx, si.payload_size);
    // Zero-init the payload. Heap.allocate may return bytes that
    // were previously used (after a future GC sweep frees + reuses
    // the slot) so we explicitly zero rather than relying on
    // freshly-grown pages being zeroed.
    const heap = rt.gc_heap.?;
    const payload_start = ref + header_size;
    const payload_end = payload_start + si.payload_size;
    @memset(heap.bytes[payload_start..payload_end], 0);
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
    // Decode types + materialise gc_type_infos (mirrors cycle-21
    // instantiate wire without going through the full instantiate
    // path).
    var types = try sections.decodeTypes(testing.allocator, body);
    defer types.deinit();
    const gti = try type_info_mod.materialiseGcTypes(a, types);

    // Allocate Runtime + Instance + Heap on the test arena.
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

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = 0 };
    try dispatch_loop.step(rt, table, &instr);
}

test "struct.new_default: allocates + pushes non-null GcRef (10.G op_gc cycle 22)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // struct { i32 var }
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try driveOne(env.rt, &t, .@"struct.new_default", 0);

    const v = env.rt.popOperand();
    try testing.expect(v.ref != Value.null_ref);
    // GcRef returned is 2-byte-aligned ≥ 2 per Heap.allocate contract.
    try testing.expect(v.ref >= 2);
    try testing.expectEqual(@as(u64, 0), v.ref % 2);
}

test "struct.new_default: ObjectHeader stamped with typeidx + struct_ kind (10.G op_gc cycle 22)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    try driveOne(env.rt, &t, .@"struct.new_default", 0);

    const ref: u32 = @intCast(env.rt.popOperand().ref);
    const heap = env.rt.gc_heap.?;
    var header: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&header)[0..header_size], heap.bytes[ref .. ref + header_size]);
    try testing.expectEqual(ObjectKind.struct_, header.kind);
    try testing.expectEqual(@as(u32, 0), header.info);
}

test "struct.new: pops 2 fields + writes them at offsets 0, 8 (10.G op_gc cycle 22)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // struct { i32 var, i64 var }
    const body = [_]u8{ 0x01, 0x5F, 0x02, 0x7F, 0x01, 0x7E, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    var t = DispatchTable.init();
    register(&t);
    // Push fields in declared order: i32 first, i64 second.
    // struct.new pops in reverse, so top-of-stack = last field.
    try env.rt.pushOperand(.{ .i32 = 42 });
    try env.rt.pushOperand(.{ .i64 = 0xDEAD_BEEF_CAFE });
    try driveOne(env.rt, &t, .@"struct.new", 0);

    const ref: u32 = @intCast(env.rt.popOperand().ref);
    const heap = env.rt.gc_heap.?;
    // field[0] at offset header_size + 0
    const f0_off = ref + header_size + 0;
    var f0_val: Value = undefined;
    @memcpy(std.mem.asBytes(&f0_val)[0..8], heap.bytes[f0_off .. f0_off + 8]);
    try testing.expectEqual(@as(i32, 42), f0_val.i32);
    // field[1] at offset header_size + 8
    const f1_off = ref + header_size + 8;
    var f1_val: Value = undefined;
    @memcpy(std.mem.asBytes(&f1_val)[0..8], heap.bytes[f1_off .. f1_off + 8]);
    try testing.expectEqual(@as(i64, 0xDEAD_BEEF_CAFE), f1_val.i64);
}

test "struct.new_default: payload zero-init (10.G op_gc cycle 22)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // struct { i64 var }
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7E, 0x01 };
    const env = try buildInstanceForTypes(&arena, &body);

    // Pre-write garbage into the heap region the next allocate
    // will return, then verify struct.new_default zeroes it.
    const heap = env.rt.gc_heap.?;
    _ = try heap.allocate(16); // bump cursor past 0; garbage stays
    @memset(heap.bytes[0..16], 0xAA); // poison the region BEFORE next alloc

    var t = DispatchTable.init();
    register(&t);
    try driveOne(env.rt, &t, .@"struct.new_default", 0);
    const ref: u32 = @intCast(env.rt.popOperand().ref);

    const payload_start = ref + header_size;
    var f0: Value = undefined;
    @memcpy(std.mem.asBytes(&f0)[0..8], heap.bytes[payload_start .. payload_start + 8]);
    try testing.expectEqual(@as(i64, 0), f0.i64);
}
