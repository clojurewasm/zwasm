//! Wasm 3.0 GC `ref.test` / `ref.test_null` interp handlers
//! (10.G op_gc cycle 7 per `.dev/phase10_g_op_bundle_plan.md`).
//!
//! Encoding (Wasm 3.0 GC §3.3.5.3):
//!   - `ref.test heap_type` (0xFB 0x14): pop reftype; push i32
//!     (1 if value is a non-null instance of heap_type, else 0).
//!   - `ref.test_null heap_type` (0xFB 0x15): pop reftype; push
//!     i32 (1 if value is a (ref null heap_type), else 0). Null
//!     always matches the `_null` variant.
//!
//! Cycle-7 semantics (no RTT yet):
//!   - The validator already type-checked the heap_type → the
//!     operand statically matches the heap_type's parent class.
//!   - Without RTT (ADR-0116 type_hierarchy.zig lands later),
//!     we can't refine cast-to-subtype. The runtime trusts the
//!     validator's static narrowing and only distinguishes null
//!     from non-null at the value level:
//!       * `ref.test`: 1 if non-null, 0 if null.
//!       * `ref.test_null`: 1 always (null + non-null both match).
//!   - This matches simple corpus fixtures where heap_type ==
//!     declared reftype; cast-to-subtype refinement lands with
//!     RTT TypeInfo at sub-chunk 7's later cycles.
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
const AbstractHeapType = zir.AbstractHeapType;
const ObjectHeader = type_info_mod.ObjectHeader;
const ObjectKind = type_info_mod.ObjectKind;

inline fn op(o: ZirOp) usize {
    return @intFromEnum(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"ref.test")] = refTest;
    table.interp[op(.@"ref.test_null")] = refTestNull;
    table.interp[op(.@"ref.cast")] = refCast;
    table.interp[op(.@"ref.cast_null")] = refCastNull;
}

/// Map a heap-type wire byte to its abstract head, or null for a
/// concrete typeidx byte (single-byte indices 0x00..0x3F don't collide
/// with the 0x69..0x74 abstract set; multi-byte indices aren't yet
/// reachable here — lower.zig stores one byte). Mirrors
/// `init_expr.readTypedRef`'s abstract switch.
fn decodeAbstract(b: u8) ?AbstractHeapType {
    return switch (b) {
        0x70 => .func,
        0x6F => .extern_,
        0x6E => .any,
        0x6D => .eq,
        0x6C => .i31,
        0x6B => .struct_,
        0x6A => .array,
        0x69 => .exn,
        0x71 => .none,
        0x72 => .noextern,
        0x73 => .nofunc,
        0x74 => .noexn,
        else => null,
    };
}

/// Read a non-null heap GC object's `ObjectHeader.kind` (struct_ / array)
/// from the slot the GcRef offset points at. Null on a malformed heap.
fn readObjKind(rt: *Runtime, v: Value) ?ObjectKind {
    const heap = rt.gc_heap orelse return null;
    const hdr_size = @sizeOf(ObjectHeader);
    // `v.ref` may NOT be a GC-heap offset — `ref.test (ref struct)` can be
    // reached with an anyref holding a host pointer (an `any.convert_extern`
    // result). Reject anything at/beyond the heap (as u64) BEFORE the u32
    // cast — the cast panics on a > u32 pointer. Such a value is simply not
    // a struct/array → no match.
    if (v.ref >= heap.bytes.len) return null;
    const ref: u32 = @intCast(v.ref);
    if (@as(usize, ref) + hdr_size > heap.bytes.len) return null;
    var hdr: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&hdr)[0..hdr_size], heap.bytes[ref .. ref + hdr_size]);
    return hdr.kind;
}

/// Runtime type-test of a NON-NULL ref `v` against heap-type byte `ht`
/// (Wasm 3.0 GC §3.3.5.3 / §4.4). The validator statically narrows the
/// operand to `ht`'s hierarchy, so the top of each hierarchy (any / eq /
/// func / extern / exn) matches any non-null operand; the bottoms (none /
/// nofunc / noextern / noexn) match nothing; i31 / struct / array test
/// the concrete runtime shape. Concrete-typeidx targets fall back to a
/// coarse non-null match (precise supertype walk lands with
/// `TypeInfo.supertype_chain` threading, next cycle).
fn gcRefMatchesNonNull(rt: *Runtime, v: Value, ht: u8) bool {
    const is_i31 = Value.isI31Ref(v);
    const obj_kind: ?ObjectKind = if (is_i31) null else readObjKind(rt, v);
    return gcAbstractMatch(ht, is_i31, obj_kind);
}

/// Pure core of the non-null runtime type-test (testable without a
/// Runtime/heap): given the heap-type byte + the operand's extracted
/// runtime facts (`is_i31`, heap `obj_kind` when not i31), decide the
/// match. See `gcRefMatchesNonNull` for the spec rationale.
fn gcAbstractMatch(ht: u8, is_i31: bool, obj_kind: ?ObjectKind) bool {
    const a = decodeAbstract(ht) orelse return true; // concrete: coarse pre-supertype
    return switch (a) {
        .any, .eq, .func, .extern_, .exn => true,
        .none, .nofunc, .noextern, .noexn => false,
        .i31 => is_i31,
        .struct_ => !is_i31 and obj_kind == .struct_,
        .array => !is_i31 and obj_kind == .array,
    };
}

fn refTest(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const ht: u8 = @truncate(instr.payload);
    const matches: i32 = if (v.ref == Value.null_ref) 0 else @intFromBool(gcRefMatchesNonNull(rt, v, ht));
    try rt.pushOperand(.{ .i32 = matches });
}

fn refTestNull(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    const ht: u8 = @truncate(instr.payload);
    // `_null` variant: null matches; otherwise same runtime test.
    const matches: i32 = if (v.ref == Value.null_ref) 1 else @intFromBool(gcRefMatchesNonNull(rt, v, ht));
    try rt.pushOperand(.{ .i32 = matches });
}

/// Wasm 3.0 GC §3.3.5.4 — `ref.cast heap_type`: pop reftype;
/// trap if value is null OR type doesn't match heap_type;
/// otherwise push the value back narrowed to heap_type.
///
/// Cycle-8 stub semantics (pre-RTT): the validator already
/// type-checked the heap_type → operand statically matches.
/// Runtime distinguishes only null from non-null:
///   - null operand → Trap.NullReference (matches Wasm 3.0 spec
///     "ref.cast traps on null").
///   - non-null → push the value back unchanged.
/// Real subtype-mismatch trap lands with RTT TypeInfo at the
/// type_hierarchy.zig integration cycle.
fn refCast(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    if (v.ref == Value.null_ref) return runtime.Trap.NullReference;
    try rt.pushOperand(v);
}

/// Wasm 3.0 GC §3.3.5.4 — `ref.cast_null heap_type`: like
/// ref.cast but accepts null (null + non-null both pass the
/// cast pre-RTT). Real subtype-mismatch trap lands with RTT.
fn refCastNull(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    // Push the same reftype back; null OK with `_null` variant.
    try rt.pushOperand(v);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("../../interp/dispatch.zig");

test "gcAbstractMatch: abstract heap-type runtime test (10.G cycle 149, ADR-0116 RTT)" {
    // i31 (0x6C): matches an i31 value, not a struct.
    try testing.expect(gcAbstractMatch(0x6C, true, null));
    try testing.expect(!gcAbstractMatch(0x6C, false, .struct_));
    // struct (0x6B) / array (0x6A): match by ObjectHeader.kind, reject i31.
    try testing.expect(gcAbstractMatch(0x6B, false, .struct_));
    try testing.expect(!gcAbstractMatch(0x6B, false, .array));
    try testing.expect(!gcAbstractMatch(0x6B, true, null)); // i31 ⊄ struct
    try testing.expect(gcAbstractMatch(0x6A, false, .array));
    // any (0x6E) / eq (0x6D): any non-null operand of the hierarchy matches.
    try testing.expect(gcAbstractMatch(0x6E, true, null));
    try testing.expect(gcAbstractMatch(0x6D, false, .struct_));
    // bottoms none (0x71) / nofunc (0x73) / noextern (0x72): match nothing.
    try testing.expect(!gcAbstractMatch(0x71, false, .struct_));
    try testing.expect(!gcAbstractMatch(0x73, true, null));
    // func (0x70) / extern (0x6F): top of their hierarchy → non-null matches.
    try testing.expect(gcAbstractMatch(0x70, false, null));
    // concrete typeidx byte (e.g. 0x01): coarse non-null match (pre-supertype).
    try testing.expect(gcAbstractMatch(0x01, false, .struct_));
}

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "ref.test: null ref returns 0 (10.G op_gc cycle 7)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"ref.test", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "ref.test: non-null ref returns 1 (10.G op_gc cycle 7)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xDEADBEEF });
    try driveOne(&rt, &t, .@"ref.test", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "ref.test_null: null ref returns 1 (10.G op_gc cycle 7; null matches _null variant)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"ref.test_null", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "ref.test_null: non-null ref returns 1 (10.G op_gc cycle 7)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xCAFEBABE });
    try driveOne(&rt, &t, .@"ref.test_null", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "ref.cast: null ref traps NullReference (10.G op_gc cycle 8)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try testing.expectError(runtime.Trap.NullReference, driveOne(&rt, &t, .@"ref.cast", 0, 0));
}

test "ref.cast: non-null ref round-trips unchanged (10.G op_gc cycle 8)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xDEADBEEF });
    try driveOne(&rt, &t, .@"ref.cast", 0, 0);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), rt.popOperand().ref);
}

test "ref.cast_null: null ref round-trips unchanged (10.G op_gc cycle 8)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try driveOne(&rt, &t, .@"ref.cast_null", 0, 0);
    try testing.expectEqual(Value.null_ref, rt.popOperand().ref);
}

test "ref.cast_null: non-null ref round-trips unchanged (10.G op_gc cycle 8)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 0xCAFEBABE });
    try driveOne(&rt, &t, .@"ref.cast_null", 0, 0);
    try testing.expectEqual(@as(u64, 0xCAFEBABE), rt.popOperand().ref);
}
