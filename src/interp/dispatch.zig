//! Threaded-code dispatch loop (Phase 2 / §9.2 / 2.1).
//!
//! Looks up the handler for each `ZirInstr.op` in
//! `DispatchTable.interp` and invokes it. Per ROADMAP §A12 the
//! dispatcher does not branch on feature flags; an unbound slot
//! is `Trap.Unreachable`. The full MVP handler set lands in
//! §9.2 / 2.2 (feature/mvp/interp.zig); 2.1 only delivers the
//! dispatch primitive plus a smoke-shaped `run` outer loop.
//!
//! The Zig 0.16 toolchain does not guarantee tail-call elimination
//! per the wasm3 idiom (`m3_exec.c` macro tower). zwasm v2's
//! divergence: a plain `while` loop over `[]const ZirInstr` indexed
//! by `pc`. The cost vs. wasm3-style threaded code is measurable
//! and gets revisited in Phase 15 (§4.3 — "interpreter / JIT / AOT
//! share one path"); for the Phase-2 spec gate, correctness is the
//! priority over μs/op throughput.
//!
//! Zone 2 (`src/interp/`) — may import Zone 0 + 1 + sibling
//! `src/interp/mod.zig`.

const std = @import("std");

pub const zir = @import("../ir/zir.zig");
const dispatch_table = @import("../ir/dispatch_table.zig");
const interp = @import("mod.zig");

const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const DispatchTable = dispatch_table.DispatchTable;
const Runtime = interp.Runtime;
const Trap = interp.Trap;

/// Run a single instruction by looking up its handler in `table` and
/// invoking it. An unbound slot returns `Trap.Unreachable` per
/// ROADMAP §A12 — the alternative would be silent passthrough.
pub fn step(
    rt: *Runtime,
    table: *const DispatchTable,
    instr: *const ZirInstr,
) anyerror!void {
    const idx = @intFromEnum(instr.op);
    if (idx >= dispatch_table.N_OPS) return Trap.Unreachable;
    const handler = table.interp[idx] orelse return Trap.Unreachable;
    try handler(rt.toOpaque(), instr);
}

/// Walk an instruction sequence linearly. The loop tracks `pc`
/// on the **current frame** (`rt.currentFrame().pc`) so control-
/// flow handlers (`br` / `br_if` / `br_table` / `return` / `if`
/// / `else` / `end`) can mutate it directly. If a handler does
/// not change `pc`, the loop advances by 1.
///
/// If no frame is active when `run` is called, an ephemeral frame
/// (empty sig + empty locals) is pushed for the duration. This
/// keeps small handler tests green without forcing every test to
/// stage a full frame.
pub fn run(
    rt: *Runtime,
    table: *const DispatchTable,
    instrs: []const ZirInstr,
) anyerror!void {
    const saved_table = rt.table;
    rt.table = table;
    defer rt.table = saved_table;

    const ephemeral = rt.frame_len == 0;
    if (ephemeral) {
        const empty_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
        try rt.pushFrame(.{
            .sig = empty_sig,
            .locals = &.{},
            .operand_base = rt.operand_len,
            .pc = 0,
        });
    }
    defer if (ephemeral) {
        _ = rt.popFrame();
    };

    const f = rt.currentFrame();
    f.pc = 0;
    f.done = false;
    while (f.pc < instrs.len and !f.done) {
        const cur = f.pc;
        try step(rt, table, &instrs[cur]);
        if (f.pc == cur) f.pc += 1;
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const StubHandlers = struct {
    fn nop(_: *dispatch_table.InterpCtx, _: *const ZirInstr) anyerror!void {}

    fn pushI32Const(opaque_ctx: *dispatch_table.InterpCtx, instr: *const ZirInstr) anyerror!void {
        const rt = Runtime.fromOpaque(opaque_ctx);
        const v: i32 = @bitCast(instr.payload);
        try rt.pushOperand(.{ .i32 = v });
    }
};

fn buildSmokeTable() DispatchTable {
    var t = DispatchTable.init();
    t.interp[@intFromEnum(ZirOp.@"nop")] = StubHandlers.nop;
    t.interp[@intFromEnum(ZirOp.@"i32.const")] = StubHandlers.pushI32Const;
    return t;
}

test "step: unbound op slot returns Trap.Unreachable" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = DispatchTable.init();
    const instr: ZirInstr = .{ .op = .@"i32.const", .payload = 0, .extra = 0 };
    try testing.expectError(Trap.Unreachable, step(&rt, &table, &instr));
}

test "step: bound i32.const handler pushes the payload" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = buildSmokeTable();

    const instr: ZirInstr = .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 42)), .extra = 0 };
    try step(&rt, &table, &instr);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 42), rt.popOperand().i32);
}

test "run: walks sequence, leaves operand stack with the const sequence" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const table = buildSmokeTable();

    const instrs = [_]ZirInstr{
        .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 1)), .extra = 0 },
        .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 2)), .extra = 0 },
        .{ .op = .@"nop", .payload = 0, .extra = 0 },
        .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 3)), .extra = 0 },
    };
    try run(&rt, &table, &instrs);

    try testing.expectEqual(@as(u32, 3), rt.operand_len);
    try testing.expectEqual(@as(i32, 3), rt.popOperand().i32);
    try testing.expectEqual(@as(i32, 2), rt.popOperand().i32);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "run: bubbles handler trap and stops iteration" {
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    var t = DispatchTable.init();
    t.interp[@intFromEnum(ZirOp.@"i32.const")] = StubHandlers.pushI32Const;
    // .nop slot left null → step returns Trap.Unreachable on the second instr.

    const instrs = [_]ZirInstr{
        .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 7)), .extra = 0 },
        .{ .op = .@"nop", .payload = 0, .extra = 0 },
        .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 99)), .extra = 0 },
    };
    try testing.expectError(Trap.Unreachable, run(&rt, &t, &instrs));

    // 7 was pushed before the trap; 99 was not reached.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 7), rt.popOperand().i32);
}
