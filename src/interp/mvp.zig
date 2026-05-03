//! MVP interp handler shell (Phase 2 / §9.2 / 2.2).
//!
//! Per ROADMAP §4.5 / §A12, each handler is registered into the
//! central `DispatchTable.interp` via `register(*DispatchTable)`.
//! The dispatcher (`src/interp/dispatch.zig`) calls them with an
//! opaque `*InterpCtx` cast back to the concrete `*Runtime` from
//! `src/interp/mod.zig`.
//!
//! After §9.5 / 5.1 (ADR-0007 follow-on for `mvp.zig` discoverability)
//! the handler set is split across siblings:
//!
//! - `mvp_int.zig`         — i32 / i64 constants + numeric (unops,
//!                           binops, relops, testops)
//! - `mvp_float.zig`       — f32 / f64 constants + numeric
//! - `mvp_conversions.zig` — wrap / extend / trunc / convert /
//!                           promote / demote / reinterpret
//! - `memory_ops.zig`      — loads / stores / memory.size / .grow
//! - this file (residual)  — control flow (block / loop / if /
//!                           else / end / br / br_if / br_table /
//!                           call / call_indirect / return),
//!                           parametric (drop, select, select_typed),
//!                           variable (locals / globals),
//!                           unreachable / nop, plus the `register()`
//!                           shell that calls each split's `register()`
//!                           in sequence.
//!
//! Wraparound / NaN / trap semantics are documented at each split
//! module's header.
//!
//! Zone 2 (`src/interp/`) — feature-MVP handlers live alongside
//! the engine they wire into so the Zone-1 / Zone-2 boundary is
//! clean: `src/feature/mvp/mod.zig` (Zone 1) covers parser-side
//! handlers, this file + siblings (Zone 2) cover interp-side
//! handlers, and Phase-6+ `src/jit_*/mvp.zig` (Zone 2) will
//! mirror the pattern for JIT emitters.
//!
//! Imports Zone 0 (`util/`) + Zone 1 (`ir/`) + sibling Zone 2
//! (`mod.zig`, `dispatch.zig`, `memory_ops.zig`, `mvp_int.zig`,
//! `mvp_float.zig`, `mvp_conversions.zig`).

const std = @import("std");

const dispatch = @import("../ir/dispatch_table.zig");
const zir = @import("../ir/zir.zig");
const interp = @import("mod.zig");
const memory_ops = @import("memory_ops.zig");
const mvp_int = @import("mvp_int.zig");
const mvp_float = @import("mvp_float.zig");
const mvp_conversions = @import("mvp_conversions.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = interp.Runtime;
const Value = interp.Value;
const Trap = interp.Trap;

// ============================================================
// Public registration
// ============================================================

pub fn register(table: *DispatchTable) void {
    // Trap-only / no-op control
    table.interp[op(.@"unreachable")] = unreachableOp;
    table.interp[op(.nop)] = nopOp;
    table.interp[op(.select)] = selectOp;
    table.interp[op(.@"select_typed")] = selectOp;

    // Control flow
    table.interp[op(.@"block")] = blockOp;
    table.interp[op(.@"loop")] = loopOp;
    table.interp[op(.@"if")] = ifOp;
    table.interp[op(.@"else")] = elseOp;
    table.interp[op(.@"end")] = endOp;
    table.interp[op(.@"br")] = brOp;
    table.interp[op(.@"br_if")] = brIfOp;
    table.interp[op(.@"br_table")] = brTableOp;
    table.interp[op(.@"return")] = returnOp;
    table.interp[op(.@"call")] = callOp;
    table.interp[op(.@"call_indirect")] = callIndirectOp;

    // Parametric
    table.interp[op(.drop)] = drop;

    // Locals + globals
    table.interp[op(.@"local.get")] = localGet;
    table.interp[op(.@"local.set")] = localSet;
    table.interp[op(.@"local.tee")] = localTee;
    table.interp[op(.@"global.get")] = globalGet;
    table.interp[op(.@"global.set")] = globalSet;

    // Numeric / conversions / loads-stores live in sibling modules.
    mvp_int.register(table);
    mvp_float.register(table);
    mvp_conversions.register(table);
    memory_ops.register(table);
}

inline fn op(t: ZirOp) usize {
    return @intFromEnum(t);
}

// ============================================================
// Handlers — control flow + parametric + variable
// ============================================================

fn unreachableOp(_: *InterpCtx, _: *const ZirInstr) anyerror!void {
    return Trap.Unreachable;
}

fn nopOp(_: *InterpCtx, _: *const ZirInstr) anyerror!void {
    // Wasm `nop` — intentionally empty.
}

fn selectOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const cond = rt.popOperand().i32;
    const b = rt.popOperand();
    const a = rt.popOperand();
    try rt.pushOperand(if (cond != 0) a else b);
}

// --- Control flow ---
//
// Block instr encoding (post §9.2 / 2.3 chunk 3):
//   payload = block index into func.blocks
//   extra   = arity (count of result values the block leaves on
//             the operand stack; 0/1 for Wasm 1.0, ≥1 for Wasm
//             2.0 multivalue typeidx blocks).

fn blockOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    try frame.pushLabel(.{
        .height = rt.operand_len,
        .arity = instr.extra,
        // br to a block targets its end, transferring the
        // block's results; same value as `arity`.
        .branch_arity = instr.extra,
        .target_pc = blk.end_inst + 1,
    });
}

fn loopOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    try frame.pushLabel(.{
        .height = rt.operand_len,
        // `end` of a loop transfers the loop's result arity to the
        // operand stack (Wasm 2.0 multivalue: zero or more results).
        // §9.2 / 2.3 chunk 3b's missing piece — without this, falling
        // through a `loop (result T)` end drops the result and
        // unbalances the caller's stack (cf. tinygo_fib's
        // `loop (result i32)` recursion).
        .arity = instr.extra,
        // br to a loop targets the loop's start and transfers its
        // *params*. Wasm 1.0 has no loop-params; multivalue loop-
        // with-params lands alongside the rest of multivalue
        // (Phase 2 chunk 3b carry-over).
        .branch_arity = 0,
        // Branching to a loop pops the label (see doBranch) and jumps
        // back to the loop opcode itself, which re-runs loopOp and
        // re-pushes the label. Pointing target_pc past the opcode
        // would skip that re-push and corrupt the label stack on the
        // second iteration.
        .target_pc = blk.start_inst,
    });
}

fn ifOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const cond = rt.popOperand().i32;
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    try frame.pushLabel(.{
        .height = rt.operand_len,
        .arity = instr.extra,
        .branch_arity = instr.extra,
        .target_pc = blk.end_inst + 1,
    });
    if (cond == 0) {
        // Skip to else (if any) or directly past end.
        frame.pc = if (blk.else_inst) |e| e + 1 else blk.end_inst;
    }
}

fn elseOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    // Reaching else from the then-branch — jump to the matching `end`.
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    frame.pc = fnz.blocks.items[instr.payload].end_inst;
}

fn endOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    if (frame.label_len == 0) {
        // Function-level end: the run loop terminates after this step.
        frame.done = true;
        return;
    }
    const label = frame.popLabel();
    try restoreToLabel(rt, label);
}

/// Maximum arity supported by control-flow handlers. Bounded so
/// `restoreToLabel` and `returnOp` can save the topmost values to
/// a stack-local buffer without heap. Wasm 2.0 multivalue blocks
/// rarely return more than a handful of values; 16 is a generous
/// ceiling.
const max_block_arity: u32 = 16;

inline fn restoreToLabel(rt: *Runtime, label: interp.Label) Trap!void {
    // Save `arity` topmost values, drop down to label.height, push back.
    if (label.arity == 0) {
        rt.operand_len = label.height;
        return;
    }
    if (label.arity > max_block_arity) return Trap.Unreachable;
    var saved: [max_block_arity]Value = undefined;
    var i: u32 = label.arity;
    while (i > 0) {
        i -= 1;
        saved[i] = rt.popOperand();
    }
    rt.operand_len = label.height;
    i = 0;
    while (i < label.arity) : (i += 1) {
        try rt.pushOperand(saved[i]);
    }
}

inline fn doBranch(rt: *Runtime, frame: *interp.Frame, depth: u32) Trap!void {
    if (depth >= frame.label_len) return Trap.Unreachable;
    const target = frame.labelAt(depth);
    // Pop (depth + 1) labels off the control stack — except for loop
    // labels, br re-enters them (the loop opcode at target_pc will
    // re-push the label). Easier: pop all (depth+1), let the loop
    // opcode re-push if needed.
    var i: u32 = 0;
    while (i <= depth) : (i += 1) _ = frame.popLabel();
    // `restoreToLabel` uses `arity` — for branches we need
    // branch_arity (= results for block/if; = 0 for loops in
    // Wasm 1.0). Synthesise a label with the branch-time arity.
    const branch_label: interp.Label = .{
        .height = target.height,
        .arity = target.branch_arity,
        .branch_arity = target.branch_arity,
        .target_pc = target.target_pc,
    };
    try restoreToLabel(rt, branch_label);
    frame.pc = target.target_pc;
}

fn brOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try doBranch(rt, rt.currentFrame(), instr.payload);
}

fn brIfOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const cond = rt.popOperand().i32;
    if (cond != 0) {
        try doBranch(rt, rt.currentFrame(), instr.payload);
    }
}

fn brTableOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const idx = rt.popOperand().u32;
    const count = instr.payload;
    const start = instr.extra;
    const fnz = frame.func orelse return Trap.Unreachable;
    const targets = fnz.branch_targets.items;
    const end_idx = start + count;
    if (end_idx >= targets.len) return Trap.Unreachable;
    const depth = if (idx < count) targets[start + idx] else targets[end_idx];
    try doBranch(rt, frame, depth);
}

/// Recursive call. Pops args, allocates locals (params + zero-init
/// declared locals), pushes a frame, recursively runs the callee
/// body, then pops the frame on return.
fn callOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    // Host-call short-circuit (§9.4 / 4.7 chunk c). For imports
    // wired by the C-API binding, `host_calls[idx]` carries the
    // thunk + host context; defined-function indices have null
    // and fall through to ordinary ZirFunc dispatch.
    if (idx < rt.host_calls.len) {
        if (rt.host_calls[idx]) |hc| {
            try hc.fn_ptr(rt, hc.ctx);
            return;
        }
    }
    if (idx >= rt.funcs.len) return Trap.Unreachable;
    const callee = rt.funcs[idx];
    const tbl = rt.table orelse return Trap.Unreachable;
    try invoke(rt, tbl, callee);
}

/// `call_indirect type_idx table_idx`: pops i32 selector, indexes
/// `rt.tables[table_idx]`, resolves the table cell's funcref by
/// dereferencing `*const FuncEntity` (ADR-0014 §2.1 / 6.K.1), and
/// invokes the callee body found at `fe.runtime.funcs[fe.func_idx]`
/// after a runtime sig-equality check against
/// `rt.module_types[type_idx]`. Encoding: `instr.payload` =
/// type_idx, `instr.extra` = table_idx.
///
/// The FuncEntity-pointer encoding makes cross-module dispatch
/// addressable in 6.K.3: `fe.runtime` may differ from `rt`, in
/// which case the callee body comes from the source runtime even
/// though the caller frame stays on `rt`. (Cross-module memory /
/// global access is 6.K.3's full wiring.)
///
/// Spec traps:
///   - selector >= table.len               → OutOfBoundsTableAccess
///   - table[selector] == null_ref         → UninitializedElement
///   - resolved sig != expected sig        → IndirectCallTypeMismatch
fn callIndirectOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const tableidx = instr.extra;
    if (tableidx >= rt.tables.len) return Trap.Unreachable;
    const tbl = rt.tables[tableidx];

    const sel = rt.popOperand().u32;
    if (sel >= tbl.refs.len) return Trap.OutOfBoundsTableAccess;
    const ref_v = tbl.refs[sel];
    const fe = interp.Value.refAsFuncEntity(ref_v) orelse return Trap.UninitializedElement;
    const callee_rt = fe.runtime;
    if (fe.func_idx >= callee_rt.funcs.len) return Trap.UninitializedElement;
    const callee = callee_rt.funcs[fe.func_idx];

    if (instr.payload >= rt.module_types.len) return Trap.IndirectCallTypeMismatch;
    const expected = rt.module_types[instr.payload];
    if (!sigEq(callee.sig, expected)) return Trap.IndirectCallTypeMismatch;

    const dispatch_tbl = rt.table orelse return Trap.Unreachable;
    try invoke(rt, dispatch_tbl, callee);
}

inline fn sigEq(a: zir.FuncType, b: zir.FuncType) bool {
    if (a.params.len != b.params.len) return false;
    if (a.results.len != b.results.len) return false;
    for (a.params, b.params) |x, y| if (x != y) return false;
    for (a.results, b.results) |x, y| if (x != y) return false;
    return true;
}

/// Invoke a callee on the given runtime. Made public per
/// ADR-0014 §2.1 / 6.K.3 so the cross-module call thunk in
/// `c_api/instance.zig` can dispatch source-instance bodies on
/// the source instance's runtime.
pub fn invoke(rt: *Runtime, table: *const DispatchTable, callee: *const zir.ZirFunc) anyerror!void {
    const params_len = callee.sig.params.len;
    const total = params_len + callee.locals.len;
    const locals = try rt.alloc.alloc(interp.Value, total);
    defer rt.alloc.free(locals);

    // Pop args in reverse (last param popped first lands at locals[params_len-1]).
    var i: usize = params_len;
    while (i > 0) {
        i -= 1;
        if (rt.operand_len == 0) return Trap.StackOverflow;
        locals[i] = rt.popOperand();
    }
    // Zero-init declared locals.
    var j: usize = params_len;
    while (j < total) : (j += 1) locals[j] = interp.Value.zero;

    try rt.pushFrame(.{
        .sig = callee.sig,
        .locals = locals,
        .operand_base = rt.operand_len,
        .pc = 0,
        .func = callee,
    });

    const dispatch_loop_local = @import("dispatch.zig");
    const run_err = dispatch_loop_local.run(rt, table, callee.instrs.items);
    _ = rt.popFrame();
    try run_err;
}

fn returnOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const arity: u32 = @intCast(frame.sig.results.len);
    if (arity > max_block_arity) return Trap.Unreachable;
    var saved: [max_block_arity]Value = undefined;
    var i: u32 = arity;
    while (i > 0) {
        i -= 1;
        saved[i] = rt.popOperand();
    }
    rt.operand_len = frame.operand_base;
    i = 0;
    while (i < arity) : (i += 1) {
        try rt.pushOperand(saved[i]);
    }
    frame.label_len = 0;
    frame.done = true;
}

fn drop(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    _ = rt.popOperand();
}

fn localGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    try rt.pushOperand(frame.locals[idx]);
}

fn localSet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    frame.locals[idx] = rt.popOperand();
}

fn localTee(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    frame.locals[idx] = rt.topOperand();
}

fn globalGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    if (idx >= rt.globals.len) return Trap.Unreachable;
    try rt.pushOperand(rt.globals[idx].*);
}

fn globalSet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    if (idx >= rt.globals.len) return Trap.Unreachable;
    rt.globals[idx].* = rt.popOperand();
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("dispatch.zig");

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "register: const + drop slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"i32.const")] != null);
    try testing.expect(t.interp[op(.@"i64.const")] != null);
    try testing.expect(t.interp[op(.drop)] != null);
}
test "locals: get/set/tee round-trip via current frame" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var locals = [_]Value{ Value.fromI32(0), Value.fromI32(0) };
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    try rt.pushFrame(.{ .sig = sig, .locals = &locals, .operand_base = 0, .pc = 0 });

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 42)), 0);
    try driveOne(&rt, &t, .@"local.set", 0, 0);
    try testing.expectEqual(@as(i32, 42), locals[0].i32);

    try driveOne(&rt, &t, .@"local.get", 0, 0);
    try testing.expectEqual(@as(i32, 42), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 99)), 0);
    try driveOne(&rt, &t, .@"local.tee", 1, 0);
    try testing.expectEqual(@as(i32, 99), locals[1].i32);
    try testing.expectEqual(@as(i32, 99), rt.popOperand().i32);
}
test "call: invokes callee, args pop and result push round-trip" {
    // callee: fn (i32, i32) -> i32 { local.get 0 ; local.get 1 ; i32.add ; end }
    const param_arr = [_]zir.ValType{ .i32, .i32 };
    const result_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &param_arr, .results = &result_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 1, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.add", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    // caller: fn () -> i32 { i32.const 5 ; i32.const 7 ; call 0 ; end }
    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &result_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 12), rt.popOperand().u32);
}

test "block + end: arity=0, operand stack restored" {
    // ZirFunc with 1 block (start=0, end=2). instrs: [block, i32.const 7, end, i32.const 99, end]
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 2 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"block", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 7)), .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 99)), .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    // After block (arity=0): operand stack popped back to 0, then i32.const 99
    // pushed, then function-level end fires.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 99), rt.popOperand().i32);
}

test "br 0 from inside block: jumps past end" {
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 4 });
    // block; i32.const 1; br 0; i32.const 2 (skipped); end; i32.const 3; end
    try fnz.instrs.append(testing.allocator, .{ .op = .@"block", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 3, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    // br 0 (arity=0) discarded the i32.const 1 result. Then i32.const 3 pushed.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 3), rt.popOperand().u32);
}

test "if cond=0 skips to end; cond=1 runs then-branch" {
    // (if (then i32.const 1) (else i32.const 2)) — sig: () -> i32
    // instrs: i32.const cond ; if ; i32.const 1 ; else ; i32.const 2 ; end ; end
    const i32_arr = [_]zir.ValType{.i32};
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .else_open, .start_inst = 1, .end_inst = 5, .else_inst = 3 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1, .extra = 0 }); // cond
    try fnz.instrs.append(testing.allocator, .{ .op = .@"if", .payload = 0, .extra = 1 }); // if (result i32) → arity 1
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 11, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"else", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 22, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);
    try testing.expectEqual(@as(u32, 11), rt.popOperand().u32);
}

test "return: ends function execution and produces sig.results" {
    const i32_arr = [_]zir.ValType{.i32};
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer fnz.deinit(testing.allocator);
    // i32.const 7 ; return ; i32.const 99 ; end
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"return", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 7), rt.popOperand().u32);
}

test "block + end: arity=2 multivalue — both results survive" {
    // Wasm 2.0 multivalue: block (result i32 i32) { i32.const 11 ; i32.const 22 }
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 3 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"block", .payload = 0, .extra = 2 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 11, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 22, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    // Both 11 and 22 should remain (arity=2 saved + restored).
    try testing.expectEqual(@as(u32, 2), rt.operand_len);
    try testing.expectEqual(@as(u32, 22), rt.popOperand().u32);
    try testing.expectEqual(@as(u32, 11), rt.popOperand().u32);
}
test "unreachable: traps Trap.Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"unreachable", 0, 0));
}

test "nop: leaves stack untouched" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 7 });
    try driveOne(&rt, &t, .nop, 0, 0);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
}

test "select: cond != 0 picks first operand" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 11 }); // a
    try rt.pushOperand(.{ .i32 = 22 }); // b
    try rt.pushOperand(.{ .i32 = 1 }); // cond
    try driveOne(&rt, &t, .select, 0, 0);
    try testing.expectEqual(@as(i32, 11), rt.popOperand().i32);
}

test "select: cond == 0 picks second operand" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 11 });
    try rt.pushOperand(.{ .i32 = 22 });
    try rt.pushOperand(.{ .i32 = 0 });
    try driveOne(&rt, &t, .select, 0, 0);
    try testing.expectEqual(@as(i32, 22), rt.popOperand().i32);
}

test "select_typed: same runtime semantics as select" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .ref = 7 });
    try rt.pushOperand(.{ .ref = interp.Value.null_ref });
    try rt.pushOperand(.{ .i32 = 1 }); // cond=true → pick first
    try driveOne(&rt, &t, .@"select_typed", 0, 0x70);
    try testing.expectEqual(@as(u64, 7), rt.popOperand().ref);
}

test "globals: get/set round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    // Per ADR-0014 §2.1 / 6.K.3: Runtime.globals is `[]*Value`
    // (one pointer per slot, so cross-module imports can alias
    // source storage). Tests build the slot array on the stack.
    var storage = [_]Value{Value.fromI32(0)};
    var slots = [_]*Value{&storage[0]};
    rt.globals = &slots;
    defer rt.globals = &.{}; // prevent deinit from freeing the stack slice

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 17)), 0);
    try driveOne(&rt, &t, .@"global.set", 0, 0);
    try testing.expectEqual(@as(i32, 17), storage[0].i32);

    try driveOne(&rt, &t, .@"global.get", 0, 0);
    try testing.expectEqual(@as(i32, 17), rt.popOperand().i32);
}
