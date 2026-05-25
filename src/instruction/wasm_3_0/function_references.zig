//! Wasm 3.0 function-references proposal interp handlers
//! (`phase10_design_plan_ja.md` §3.2). Mirror of
//! `src/instruction/wasm_2_0/reference_types.zig` shape — the
//! 5 typed-function-references ops (ref.as_non_null / br_on_null
//! / br_on_non_null / call_ref / return_call_ref) register their
//! interp handlers via the same DispatchTable.interp slot pattern
//! as the Wasm 2.0 reftype family.
//!
//! 10.R-1 lands ref.as_non_null only; the other 4 ops register at
//! 10.R-2..10.R-5 (sub-chunks per the design plan).
//!
//! Wasm spec 3.0 §3.3.8.5 (`ref.as_non_null`): pop reftype; if
//! null, trap (.NullReference per ADR-0111 / runtime/trap.zig);
//! else push the same reftype value back. Statically the type
//! narrows `(ref null T)` → `(ref T)` (nullability axis); v2.0
//! reftype catalogue doesn't model this yet, so the runtime
//! handler is a simple null-check (per `phase10_design_plan_ja.md`
//! §3.2 (1)). Per-op file placeholder
//! `src/instruction/wasm_3_0/ref_as_non_null.zig` returns
//! NotMigrated → legacy dispatch table (this file) handles it.
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
    table.interp[op(.@"ref.as_non_null")] = refAsNonNull;
}

fn refAsNonNull(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const r = rt.popOperand().ref;
    if (r == Value.null_ref) return runtime.Trap.NullReference;
    try rt.pushOperand(.{ .ref = r });
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

test "register: ref.as_non_null slot populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"ref.as_non_null")] != null);
}

test "ref.as_non_null: non-null funcref → passes through" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // Push a non-null sentinel (any non-zero value).
    try rt.pushOperand(.{ .ref = 0x1000 });
    try driveOne(&rt, &t, .@"ref.as_non_null", 0, 0);
    try testing.expectEqual(@as(u64, 0x1000), rt.popOperand().ref);
}

test "ref.as_non_null: null → Trap.NullReference" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = Value.null_ref });
    try testing.expectError(runtime.Trap.NullReference, driveOne(&rt, &t, .@"ref.as_non_null", 0, 0));
}
