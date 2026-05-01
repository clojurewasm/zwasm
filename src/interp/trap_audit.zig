//! Trap-semantics audit tests (Phase 2 / §9.2 / 2.4).
//!
//! Concentrates the spec-conformant trap-condition tests that
//! cross multiple opcodes. Per-opcode trap behaviour is unit-
//! tested next to the handler in `mvp.zig` / `memory_ops.zig` /
//! `ext_2_0/*`; this file holds the call_indirect path tests
//! that need a full ZirFunc + Runtime + table + module_types
//! setup, and any other spec traps whose verification spans
//! multiple subsystems.
//!
//! Zone 2.

const std = @import("std");

const dispatch = @import("../ir/dispatch_table.zig");
const zir = @import("../ir/zir.zig");
const interp = @import("mod.zig");
const mvp = @import("mvp.zig");
const dispatch_loop = @import("dispatch.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const Runtime = interp.Runtime;
const Trap = interp.Trap;

const testing = std.testing;

test "call_indirect: selector OOB → OutOfBoundsTableAccess" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]interp.Value{.{ .ref = interp.Value.null_ref }};
    var tbls = [_]interp.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.OutOfBoundsTableAccess, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "call_indirect: null table cell → UninitializedElement" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]interp.Value{.{ .ref = interp.Value.null_ref }};
    var tbls = [_]interp.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.UninitializedElement, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "call_indirect: sig mismatch → IndirectCallTypeMismatch" {
    const i32_arr = [_]zir.ValType{.i32};
    // callee () -> i32; expected (per type_idx=0): () -> ()
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var refs = [_]interp.Value{.{ .ref = 0 }};
    var tbls = [_]interp.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.IndirectCallTypeMismatch, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "call_indirect: matching sig invokes callee through table" {
    const i32_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;
    var refs = [_]interp.Value{.{ .ref = 0 }};
    var tbls = [_]interp.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &i32_arr }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 42), rt.popOperand().u32);
}
