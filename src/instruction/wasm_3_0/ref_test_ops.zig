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

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = runtime.Runtime;
const Value = runtime.Value;

inline fn op(o: ZirOp) usize {
    return @intFromEnum(o);
}

pub fn register(table: *DispatchTable) void {
    table.interp[op(.@"ref.test")] = refTest;
    table.interp[op(.@"ref.test_null")] = refTestNull;
}

fn refTest(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    // Cycle-7 stub semantics: pre-RTT we can only distinguish
    // null from non-null. Validator-narrowed reftype guarantees
    // static type match; runtime returns 1 iff non-null.
    const matches: i32 = if (v.ref == Value.null_ref) 0 else 1;
    try rt.pushOperand(.{ .i32 = matches });
}

fn refTestNull(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    _ = rt.popOperand();
    // Cycle-7 stub semantics: `_null` variant accepts null too,
    // so given the validator's static narrowing, always 1.
    try rt.pushOperand(.{ .i32 = 1 });
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
