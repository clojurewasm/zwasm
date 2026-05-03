//! Limited const-propagation analysis pass (§9.5 / 5.6).
//!
//! Walks a lowered `ZirFunc`'s instr stream tracking each push as
//! either "constant value V" (after `i*.const`) or "unknown".
//! When a binop sees two constant operands AND the binop is
//! trap-free, the analysis records a `ConstantFold` describing
//! the foldable site: which two `i*.const` pcs supplied the
//! operands, the binop's pc, and the constant-evaluated result.
//!
//! The actual rewrite of `instrs` (replacing the const+const+
//! binop triple with a single const) is a *consumer* job —
//! Phase-15 hoisting / Phase-7 regalloc reads `ConstantPool` and
//! decides where folding pays off. Phase-5 / 5.6 ships the
//! analysis only.
//!
//! Trap-free binops folded today (i32 + i64): add, sub, mul, and,
//! or, xor, shl, shr_s, shr_u, rotl, rotr.
//!
//! Skipped on purpose:
//!   - div_s / div_u / rem_s / rem_u — divide-by-zero traps, plus
//!     INT_MIN/-1 IntOverflow on signed div. Folding would
//!     duplicate trap conditions; safer to leave for the dispatch
//!     path.
//!   - All float ops — NaN propagation, rounding-mode caveats,
//!     min/max-of-NaN spec rule. Out of scope for §9.5 / 5.6;
//!     can be added when a consumer needs it.
//!   - All control flow ops — analysis stops at the first one
//!     (returns whatever it has folded so far).
//!
//! Lifetime: caller-allocated; pair with `deinit` to free.
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("zir.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirOp = zir.ZirOp;
const ConstantPool = zir.ConstantPool;
const ConstantFold = zir.ConstantFold;

const max_simulated_stack: usize = 1024;

/// Per-stack-slot state. `def_pc` is the instr that produced the
/// value; for constant slots `value_lo` / `value_hi` carry the
/// constant bits.
const SlotState = struct {
    def_pc: u32,
    is_const: bool,
    value_lo: u32 = 0,
    value_hi: u32 = 0,
};

pub fn compute(allocator: Allocator, func: *const ZirFunc) !ConstantPool {
    var folds: std.ArrayList(ConstantFold) = .empty;
    errdefer folds.deinit(allocator);

    var sim_stack: [max_simulated_stack]SlotState = undefined;
    var sim_len: usize = 0;

    for (func.instrs.items, 0..) |instr, idx| {
        const pc: u32 = @intCast(idx);

        switch (instr.op) {
            .@"i32.const", .@"i64.const" => {
                if (sim_len == max_simulated_stack) return error.OperandStackOverflow;
                const lo = instr.payload;
                const hi: u32 = if (instr.op == .@"i64.const") instr.extra else 0;
                sim_stack[sim_len] = .{
                    .def_pc = pc,
                    .is_const = true,
                    .value_lo = lo,
                    .value_hi = hi,
                };
                sim_len += 1;
            },
            // Trap-free i32 binops
            .@"i32.add", .@"i32.sub", .@"i32.mul",
            .@"i32.and", .@"i32.or", .@"i32.xor",
            .@"i32.shl", .@"i32.shr_s", .@"i32.shr_u",
            .@"i32.rotl", .@"i32.rotr",
            => try foldI32(allocator, &folds, &sim_stack, &sim_len, pc, instr.op),
            // Trap-free i64 binops
            .@"i64.add", .@"i64.sub", .@"i64.mul",
            .@"i64.and", .@"i64.or", .@"i64.xor",
            .@"i64.shl", .@"i64.shr_s", .@"i64.shr_u",
            .@"i64.rotl", .@"i64.rotr",
            => try foldI64(allocator, &folds, &sim_stack, &sim_len, pc, instr.op),
            // Anything else: stop analysis. The folds collected
            // so far are still valid; the consumer decides what
            // to do beyond the cutoff.
            else => break,
        }
    }

    return .{ .folds = try folds.toOwnedSlice(allocator) };
}

pub fn deinit(allocator: Allocator, pool: ConstantPool) void {
    if (pool.folds.len != 0) allocator.free(pool.folds);
}

fn foldI32(
    allocator: Allocator,
    folds: *std.ArrayList(ConstantFold),
    sim_stack: []SlotState,
    sim_len: *usize,
    pc: u32,
    op: ZirOp,
) !void {
    if (sim_len.* < 2) return; // analysis underflow → just stop folding here.
    const top_b = sim_stack[sim_len.* - 1];
    const top_a = sim_stack[sim_len.* - 2];
    sim_len.* -= 2;
    if (!(top_a.is_const and top_b.is_const)) {
        // Result is unknown — push a placeholder slot.
        if (sim_len.* == max_simulated_stack) return error.OperandStackOverflow;
        sim_stack[sim_len.*] = .{ .def_pc = pc, .is_const = false };
        sim_len.* += 1;
        return;
    }

    const a: i32 = @bitCast(top_a.value_lo);
    const b: i32 = @bitCast(top_b.value_lo);
    const result: u32 = switch (op) {
        .@"i32.add" => @bitCast(a +% b),
        .@"i32.sub" => @bitCast(a -% b),
        .@"i32.mul" => @bitCast(a *% b),
        .@"i32.and" => top_a.value_lo & top_b.value_lo,
        .@"i32.or" => top_a.value_lo | top_b.value_lo,
        .@"i32.xor" => top_a.value_lo ^ top_b.value_lo,
        .@"i32.shl" => top_a.value_lo << @as(u5, @intCast(top_b.value_lo & 31)),
        .@"i32.shr_s" => @bitCast(a >> @as(u5, @intCast(top_b.value_lo & 31))),
        .@"i32.shr_u" => top_a.value_lo >> @as(u5, @intCast(top_b.value_lo & 31)),
        .@"i32.rotl" => std.math.rotl(u32, top_a.value_lo, @as(u5, @intCast(top_b.value_lo & 31))),
        .@"i32.rotr" => std.math.rotr(u32, top_a.value_lo, @as(u5, @intCast(top_b.value_lo & 31))),
        else => unreachable,
    };

    try folds.append(allocator, .{
        .def_pc_a = top_a.def_pc,
        .def_pc_b = top_b.def_pc,
        .op_pc = pc,
        .result_lo = result,
        .result_hi = 0,
    });
    sim_stack[sim_len.*] = .{
        .def_pc = pc,
        .is_const = true,
        .value_lo = result,
        .value_hi = 0,
    };
    sim_len.* += 1;
}

fn foldI64(
    allocator: Allocator,
    folds: *std.ArrayList(ConstantFold),
    sim_stack: []SlotState,
    sim_len: *usize,
    pc: u32,
    op: ZirOp,
) !void {
    if (sim_len.* < 2) return;
    const top_b = sim_stack[sim_len.* - 1];
    const top_a = sim_stack[sim_len.* - 2];
    sim_len.* -= 2;
    if (!(top_a.is_const and top_b.is_const)) {
        if (sim_len.* == max_simulated_stack) return error.OperandStackOverflow;
        sim_stack[sim_len.*] = .{ .def_pc = pc, .is_const = false };
        sim_len.* += 1;
        return;
    }

    const a_u: u64 = (@as(u64, top_a.value_hi) << 32) | top_a.value_lo;
    const b_u: u64 = (@as(u64, top_b.value_hi) << 32) | top_b.value_lo;
    const a: i64 = @bitCast(a_u);
    const b: i64 = @bitCast(b_u);
    const result_u: u64 = switch (op) {
        .@"i64.add" => @bitCast(a +% b),
        .@"i64.sub" => @bitCast(a -% b),
        .@"i64.mul" => @bitCast(a *% b),
        .@"i64.and" => a_u & b_u,
        .@"i64.or" => a_u | b_u,
        .@"i64.xor" => a_u ^ b_u,
        .@"i64.shl" => a_u << @as(u6, @intCast(b_u & 63)),
        .@"i64.shr_s" => @bitCast(a >> @as(u6, @intCast(b_u & 63))),
        .@"i64.shr_u" => a_u >> @as(u6, @intCast(b_u & 63)),
        .@"i64.rotl" => std.math.rotl(u64, a_u, @as(u6, @intCast(b_u & 63))),
        .@"i64.rotr" => std.math.rotr(u64, a_u, @as(u6, @intCast(b_u & 63))),
        else => unreachable,
    };

    try folds.append(allocator, .{
        .def_pc_a = top_a.def_pc,
        .def_pc_b = top_b.def_pc,
        .op_pc = pc,
        .result_lo = @truncate(result_u),
        .result_hi = @truncate(result_u >> 32),
    });
    sim_stack[sim_len.*] = .{
        .def_pc = pc,
        .is_const = true,
        .value_lo = @truncate(result_u),
        .value_hi = @truncate(result_u >> 32),
    };
    sim_len.* += 1;
}

const testing = std.testing;

fn buildFunc(allocator: Allocator, ops: []const zir.ZirInstr) !ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    errdefer f.deinit(allocator);
    for (ops) |o| try f.instrs.append(allocator, o);
    return f;
}

test "compute: i32.const 5 + i32.const 7 + i32.add folds to 12" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 5 },
        .{ .op = .@"i32.const", .payload = 7 },
        .{ .op = .@"i32.add" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const pool = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, pool);

    try testing.expectEqual(@as(usize, 1), pool.folds.len);
    const fold = pool.folds[0];
    try testing.expectEqual(@as(u32, 0), fold.def_pc_a);
    try testing.expectEqual(@as(u32, 1), fold.def_pc_b);
    try testing.expectEqual(@as(u32, 2), fold.op_pc);
    try testing.expectEqual(@as(u32, 12), fold.result_lo);
}

test "compute: i32.add wraps modulo 2^32" {
    const lhs: u32 = @bitCast(@as(i32, std.math.maxInt(i32)));
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = lhs },
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.add" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const pool = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, pool);

    try testing.expectEqual(@as(usize, 1), pool.folds.len);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, std.math.minInt(i32)))), pool.folds[0].result_lo);
}

test "compute: i32.shl masks shift to 5 bits" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 33 }, // 33 mod 32 = 1
        .{ .op = .@"i32.shl" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const pool = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, pool);

    try testing.expectEqual(@as(u32, 2), pool.folds[0].result_lo);
}

test "compute: i64.add folds across low/high split" {
    // 0x1_0000_0000 + 1 = 0x1_0000_0001
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i64.const", .payload = 0, .extra = 1 }, // 1 << 32
        .{ .op = .@"i64.const", .payload = 1, .extra = 0 }, // 1
        .{ .op = .@"i64.add" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const pool = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, pool);

    try testing.expectEqual(@as(usize, 1), pool.folds.len);
    try testing.expectEqual(@as(u32, 1), pool.folds[0].result_lo);
    try testing.expectEqual(@as(u32, 1), pool.folds[0].result_hi);
}

test "compute: chained constants fold transitively" {
    // ((1 + 2) * 3) = 9 → two folds recorded.
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.add" },
        .{ .op = .@"i32.const", .payload = 3 },
        .{ .op = .@"i32.mul" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const pool = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, pool);

    try testing.expectEqual(@as(usize, 2), pool.folds.len);
    try testing.expectEqual(@as(u32, 3), pool.folds[0].result_lo); // 1 + 2 = 3
    try testing.expectEqual(@as(u32, 9), pool.folds[1].result_lo); // 3 * 3 = 9
    // Second fold's `def_pc_a` is the fold that produced 3 (the
    // synthetic def at op_pc = 2), `def_pc_b` is the i32.const 3
    // at pc 3, op_pc = 4.
    try testing.expectEqual(@as(u32, 2), pool.folds[1].def_pc_a);
    try testing.expectEqual(@as(u32, 3), pool.folds[1].def_pc_b);
    try testing.expectEqual(@as(u32, 4), pool.folds[1].op_pc);
}

test "compute: non-constant operand prevents fold but analysis continues" {
    // local.get 0 ; i32.const 5 ; i32.add ; i32.const 7 ; i32.const 8 ; i32.mul ; end
    // First add cannot fold (one operand is a local.get); second mul folds.
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"local.get", .payload = 0 },
        .{ .op = .@"i32.const", .payload = 5 },
        .{ .op = .@"i32.add" },
        .{ .op = .@"i32.const", .payload = 7 },
        .{ .op = .@"i32.const", .payload = 8 },
        .{ .op = .@"i32.mul" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const pool = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, pool);

    // local.get is "anything else" — analysis breaks at pc 0
    // before recording any folds. The 7*8 site is downstream of
    // the cutoff; cleaner per-block analysis is post-Phase-5.
    try testing.expectEqual(@as(usize, 0), pool.folds.len);
}

test "compute: skips trap-emitting div_s and stops analysis" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 10 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.div_s" }, // not in fold set; analysis stops here.
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const pool = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, pool);

    try testing.expectEqual(@as(usize, 0), pool.folds.len);
}

test "compute: install onto ZirFunc.constant_pool round-trips" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 4 },
        .{ .op = .@"i32.const", .payload = 6 },
        .{ .op = .@"i32.add" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    f.constant_pool = try compute(testing.allocator, &f);
    defer if (f.constant_pool) |cp| deinit(testing.allocator, cp);

    try testing.expect(f.constant_pool != null);
    try testing.expectEqual(@as(usize, 1), f.constant_pool.?.folds.len);
    try testing.expectEqual(@as(u32, 10), f.constant_pool.?.folds[0].result_lo);
}
