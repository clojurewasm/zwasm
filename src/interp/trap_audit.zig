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
const runtime = @import("../runtime/runtime.zig");
const mvp = @import("mvp.zig");
const dispatch_loop = @import("dispatch.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const Runtime = runtime.Runtime;
const Trap = runtime.Trap;

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
    var refs = [_]runtime.Value{.{ .ref = runtime.Value.null_ref }};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
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
    var refs = [_]runtime.Value{.{ .ref = runtime.Value.null_ref }};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
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
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0 }};
    rt.func_entities = &entities;
    var refs = [_]runtime.Value{runtime.Value.fromFuncRef(&entities[0])};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
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
    var entities = [_]runtime.FuncEntity{.{ .runtime = &rt, .func_idx = 0 }};
    rt.func_entities = &entities;
    var refs = [_]runtime.Value{runtime.Value.fromFuncRef(&entities[0])};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &i32_arr }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 42), rt.popOperand().u32);
}

test "6.K.1: null funcref round-trip — ref.is_null + call_indirect" {
    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var refs = [_]runtime.Value{.{ .ref = runtime.Value.null_ref }};
    // Encoding contract per ADR-0014 §2.1 / 6.K.1: null is literal 0.
    try testing.expectEqual(@as(u64, 0), refs[0].ref);

    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &.{} }};
    rt.module_types = &types;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try testing.expectError(Trap.UninitializedElement, dispatch_loop.run(&rt, &t, caller.instrs.items));
}

test "6.K.1: two runtimes share a table; FuncEntity routes to source" {
    // Source runtime A owns callee_a (returns 42); importer rt_b
    // calls A's func 0 via call_indirect. The FuncEntity pointer
    // stored in rt_b's table cell carries A's identity, so dispatch
    // resolves rt_a.funcs[0] even though rt_b.funcs is empty.
    const i32_arr = [_]zir.ValType{.i32};
    var callee_a = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer callee_a.deinit(testing.allocator);
    try callee_a.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42, .extra = 0 });
    try callee_a.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var rt_a = Runtime.init(testing.allocator);
    defer rt_a.deinit();
    const funcs_a = [_]*const zir.ZirFunc{&callee_a};
    rt_a.funcs = &funcs_a;
    var entities_a = [_]runtime.FuncEntity{.{ .runtime = &rt_a, .func_idx = 0 }};
    rt_a.func_entities = &entities_a;

    var caller = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    mvp.register(&t);
    var rt_b = Runtime.init(testing.allocator);
    defer rt_b.deinit();
    // rt_b has no funcs of its own — proves dispatch routes to rt_a.
    var refs = [_]runtime.Value{runtime.Value.fromFuncRef(&entities_a[0])};
    var tbls = [_]runtime.TableInstance{.{ .refs = &refs, .elem_type = .funcref }};
    rt_b.tables = &tbls;
    const types = [_]zir.FuncType{.{ .params = &.{}, .results = &i32_arr }};
    rt_b.module_types = &types;

    try rt_b.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt_b.popFrame();
    try dispatch_loop.run(&rt_b, &t, caller.instrs.items);
    try testing.expectEqual(@as(u32, 42), rt_b.popOperand().u32);
}
