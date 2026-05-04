//! Per-vreg liveness analysis pass (§9.5 / 5.4).
//!
//! Walks a lowered `ZirFunc`'s instr stream simulating the
//! operand stack as a stack of vreg ids. Each push assigns a
//! fresh vreg id (sequential, 0-based) and opens a live range
//! `(def_pc, def_pc)`. Each pop closes the topmost vreg's range
//! by setting `last_use_pc = pc`. The function-level `end`
//! consumes any vreg still on the stack so its range closes at
//! that instr index too.
//!
//! Phase-5 scope is the **straight-line MVP arithmetic + locals
//! + globals + select + conversions** subset (the ops covered by
//! `src/interp/mvp_int.zig`, `mvp_float.zig`, and
//! `mvp_conversions.zig` minus control flow). Encountering any
//! control-flow op (`block` / `loop` / `if` / `else` / `br` /
//! `br_if` / `br_table` / `return` / `call` / `call_indirect`)
//! returns `error.UnsupportedControlFlow` — the Phase-7 regalloc
//! consumer will refine the analysis to handle CFG splits when
//! it lands. Calls into `memory_ops.*` (loads / stores) are not
//! covered by this iteration either; their stack effects land
//! alongside the regalloc consumer.
//!
//! Lifetime: `compute` allocates the result slice via the
//! caller-supplied allocator. The caller owns it; pair with
//! `deinit` to free.
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("../zir.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const Liveness = zir.Liveness;
const LiveRange = zir.LiveRange;

pub const Error = error{
    UnsupportedControlFlow,
    UnsupportedOp,
    OperandStackUnderflow,
    OutOfMemory,
};

/// Bounded VM operand-stack simulation. 1024 mirrors the
/// validator's `max_operand_stack` so a function the validator
/// accepts cannot exceed this depth at runtime.
const max_simulated_stack: usize = 1024;

const StackEffect = struct { pops: u8, pushes: u8 };

/// Stack effect of an MVP op for liveness purposes. Returns
/// `null` for ops the analysis does not yet model (control flow,
/// memory ops, pseudo opcodes); callers translate that into the
/// appropriate error.
fn stackEffect(op: ZirOp) ?StackEffect {
    return switch (op) {
        // 0 → 0
        .nop => .{ .pops = 0, .pushes = 0 },
        // 0 → 1
        .@"i32.const",
        .@"i64.const",
        .@"f32.const",
        .@"f64.const",
        .@"local.get",
        .@"global.get",
        => .{ .pops = 0, .pushes = 1 },
        // 1 → 0
        .drop,
        .@"local.set",
        .@"global.set",
        => .{ .pops = 1, .pushes = 0 },
        // 1 → 1 (pop-and-push of same logical value: tee)
        .@"local.tee" => .{ .pops = 1, .pushes = 1 },
        // 1 → 1 testop / unop (i32 / i64 / f32 / f64)
        .@"i32.eqz", .@"i32.clz", .@"i32.ctz", .@"i32.popcnt",
        .@"i64.eqz", .@"i64.clz", .@"i64.ctz", .@"i64.popcnt",
        .@"f32.abs", .@"f32.neg", .@"f32.ceil", .@"f32.floor",
        .@"f32.trunc", .@"f32.nearest", .@"f32.sqrt",
        .@"f64.abs", .@"f64.neg", .@"f64.ceil", .@"f64.floor",
        .@"f64.trunc", .@"f64.nearest", .@"f64.sqrt",
        // conversions 1 → 1
        .@"i32.wrap_i64",
        .@"i32.trunc_f32_s", .@"i32.trunc_f32_u",
        .@"i32.trunc_f64_s", .@"i32.trunc_f64_u",
        .@"i64.extend_i32_s", .@"i64.extend_i32_u",
        .@"i64.trunc_f32_s", .@"i64.trunc_f32_u",
        .@"i64.trunc_f64_s", .@"i64.trunc_f64_u",
        .@"f32.convert_i32_s", .@"f32.convert_i32_u",
        .@"f32.convert_i64_s", .@"f32.convert_i64_u",
        .@"f32.demote_f64",
        .@"f64.convert_i32_s", .@"f64.convert_i32_u",
        .@"f64.convert_i64_s", .@"f64.convert_i64_u",
        .@"f64.promote_f32",
        .@"i32.reinterpret_f32", .@"i64.reinterpret_f64",
        .@"f32.reinterpret_i32", .@"f64.reinterpret_i64",
        // Wasm 2.0 sat_trunc (sub-h5).
        .@"i32.trunc_sat_f32_s", .@"i32.trunc_sat_f32_u",
        .@"i32.trunc_sat_f64_s", .@"i32.trunc_sat_f64_u",
        .@"i64.trunc_sat_f32_s", .@"i64.trunc_sat_f32_u",
        .@"i64.trunc_sat_f64_s", .@"i64.trunc_sat_f64_u",
        => .{ .pops = 1, .pushes = 1 },
        // 2 → 1 binop
        .@"i32.add", .@"i32.sub", .@"i32.mul",
        .@"i32.div_s", .@"i32.div_u", .@"i32.rem_s", .@"i32.rem_u",
        .@"i32.and", .@"i32.or", .@"i32.xor",
        .@"i32.shl", .@"i32.shr_s", .@"i32.shr_u", .@"i32.rotl", .@"i32.rotr",
        .@"i64.add", .@"i64.sub", .@"i64.mul",
        .@"i64.div_s", .@"i64.div_u", .@"i64.rem_s", .@"i64.rem_u",
        .@"i64.and", .@"i64.or", .@"i64.xor",
        .@"i64.shl", .@"i64.shr_s", .@"i64.shr_u", .@"i64.rotl", .@"i64.rotr",
        .@"f32.add", .@"f32.sub", .@"f32.mul", .@"f32.div",
        .@"f32.min", .@"f32.max", .@"f32.copysign",
        .@"f64.add", .@"f64.sub", .@"f64.mul", .@"f64.div",
        .@"f64.min", .@"f64.max", .@"f64.copysign",
        // 2 → 1 relop
        .@"i32.eq", .@"i32.ne",
        .@"i32.lt_s", .@"i32.lt_u", .@"i32.gt_s", .@"i32.gt_u",
        .@"i32.le_s", .@"i32.le_u", .@"i32.ge_s", .@"i32.ge_u",
        .@"i64.eq", .@"i64.ne",
        .@"i64.lt_s", .@"i64.lt_u", .@"i64.gt_s", .@"i64.gt_u",
        .@"i64.le_s", .@"i64.le_u", .@"i64.ge_s", .@"i64.ge_u",
        .@"f32.eq", .@"f32.ne", .@"f32.lt", .@"f32.gt", .@"f32.le", .@"f32.ge",
        .@"f64.eq", .@"f64.ne", .@"f64.lt", .@"f64.gt", .@"f64.le", .@"f64.ge",
        => .{ .pops = 2, .pushes = 1 },
        // 3 → 1 select
        .@"select", .@"select_typed" => .{ .pops = 3, .pushes = 1 },
        else => null,
    };
}

fn isControlFlow(op: ZirOp) bool {
    // After sub-7.5c-iv, every Wasm 1.0 control-flow op is
    // handled explicitly in `compute`. The function exists
    // only as documentation of the categories; nothing in the
    // analysis branches on it now.
    return switch (op) {
        .@"unreachable",
        .@"br", .@"br_if", .@"br_table", .@"return",
        .@"block", .@"loop", .@"if", .@"else", .@"end",
        .@"call", .@"call_indirect",
        => true,
        else => false,
    };
}

/// Compute per-vreg live ranges. Returns a `Liveness` whose
/// `ranges` slice the caller owns.
///
/// `func_sigs` indexes function signatures by func_idx; consulted
/// by `call N` to determine the pop/push count. `module_types`
/// indexes type signatures by typeidx; consulted by
/// `call_indirect type_idx`. Pass empty slices when the function
/// has no calls (the existing straight-line tests).
///
/// **Phase 7.5 scope**: extends Phase-5's straight-line MVP +
/// conversions + sat_trunc (sub-h5) with `call` + `call_indirect`.
/// Block-level control flow (block / loop / if / else / br / etc.)
/// still rejects; sub-7.5c-future widens this to structured-CFG-
/// aware analysis.
pub fn compute(
    allocator: Allocator,
    func: *const ZirFunc,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
) Error!Liveness {
    var ranges: std.ArrayList(LiveRange) = .empty;
    errdefer ranges.deinit(allocator);

    var sim_stack: [max_simulated_stack]u32 = undefined;
    var sim_len: usize = 0;

    // Sub-7.5c-iv: after an unconditional branch (br / return /
    // unreachable) the rest of the block body is dead code per
    // Wasm's polymorphic-stack rule. Dead-code liveness does
    // nothing structurally — vregs that the dead region produces
    // would never reach a real consumer; their ranges stay
    // collapsed to a single pc by virtue of no later instr
    // popping them. So we don't track a separate dead flag
    // explicitly; the conservative pop-on-branch handling below
    // is enough.

    for (func.instrs.items, 0..) |instr, idx| {
        const pc: u32 = @intCast(idx);

        // The function-level `end` closes every still-live vreg.
        if (instr.op == .@"end") {
            const is_function_end = (idx + 1 == func.instrs.items.len);
            if (is_function_end) {
                while (sim_len > 0) {
                    sim_len -= 1;
                    const vreg = sim_stack[sim_len];
                    ranges.items[vreg].last_use_pc = pc;
                }
            }
            // Mid-function `end` (block/loop/if frame closer) is
            // transparent at the liveness level — values produced
            // inside the block stay on the operand stack and flow
            // naturally to the next consumer. The Wasm validator
            // already enforces stack-shape consistency at block
            // boundaries.
            continue;
        }

        // block / loop / else: structural markers, transparent.
        if (instr.op == .@"block" or instr.op == .@"loop" or instr.op == .@"else") {
            continue;
        }

        // if: pops the condition (1 operand), no push.
        if (instr.op == .@"if") {
            if (sim_len == 0) return Error.OperandStackUnderflow;
            sim_len -= 1;
            const cond_vreg = sim_stack[sim_len];
            ranges.items[cond_vreg].last_use_pc = pc;
            continue;
        }

        // Branches: conservative single-pass liveness.
        //   br N           — unconditional. Result values for
        //                     label N stay on the operand stack
        //                     at the target. For us: close every
        //                     vreg currently live (pessimistic;
        //                     forces spill if reused after target).
        //   br_if N        — pop 1 (condition); operand stack
        //                     otherwise unchanged (the K result
        //                     values for label N stay on stack
        //                     for both branch paths).
        //   br_table       — pop 1 (table index); same as br_if.
        //   return         — close all live vregs (function exits).
        //   unreachable    — trap; subsequent code dead.
        //
        // After unconditional branches the rest of the body is
        // dead per Wasm's polymorphic-stack rule. The Wasm
        // validator already accepts dead-code stack
        // arbitrariness; for liveness we just don't touch ranges
        // in that region. Implementation: continue iterating
        // until the matching `end` (the lowerer guarantees one
        // exists per Wasm validator rules); subsequent ops may
        // re-push fresh vregs they themselves define, which we
        // treat conservatively.
        if (instr.op == .@"br" or instr.op == .@"return" or instr.op == .@"unreachable") {
            while (sim_len > 0) {
                sim_len -= 1;
                const vreg = sim_stack[sim_len];
                ranges.items[vreg].last_use_pc = pc;
            }
            continue;
        }
        if (instr.op == .@"br_if" or instr.op == .@"br_table") {
            if (sim_len == 0) return Error.OperandStackUnderflow;
            sim_len -= 1;
            const cond_vreg = sim_stack[sim_len];
            ranges.items[cond_vreg].last_use_pc = pc;
            continue;
        }

        // call / call_indirect: pop callee-sig.params, push callee-sig.results.
        if (instr.op == .@"call" or instr.op == .@"call_indirect") {
            const callee_sig: zir.FuncType = blk: {
                if (instr.op == .@"call") {
                    if (instr.payload >= func_sigs.len) return Error.UnsupportedOp;
                    break :blk func_sigs[instr.payload];
                } else {
                    if (instr.payload >= module_types.len) return Error.UnsupportedOp;
                    break :blk module_types[instr.payload];
                }
            };
            // call_indirect's stack at entry is [args..., idx]; pop idx first.
            if (instr.op == .@"call_indirect") {
                if (sim_len == 0) return Error.OperandStackUnderflow;
                sim_len -= 1;
                const idx_vreg = sim_stack[sim_len];
                ranges.items[idx_vreg].last_use_pc = pc;
            }
            // Pop N args (in reverse stack order).
            const n_args: usize = callee_sig.params.len;
            if (sim_len < n_args) return Error.OperandStackUnderflow;
            var ai: usize = 0;
            while (ai < n_args) : (ai += 1) {
                sim_len -= 1;
                const arg_vreg = sim_stack[sim_len];
                ranges.items[arg_vreg].last_use_pc = pc;
            }
            // Push results.
            for (callee_sig.results) |_| {
                const vreg: u32 = @intCast(ranges.items.len);
                try ranges.append(allocator, .{ .def_pc = pc, .last_use_pc = pc });
                if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
                sim_stack[sim_len] = vreg;
                sim_len += 1;
            }
            continue;
        }

        if (isControlFlow(instr.op)) return Error.UnsupportedControlFlow;

        const eff = stackEffect(instr.op) orelse return Error.UnsupportedOp;

        // Pop side first — record last_use for each vreg consumed.
        var i: u8 = 0;
        while (i < eff.pops) : (i += 1) {
            if (sim_len == 0) return Error.OperandStackUnderflow;
            sim_len -= 1;
            const vreg = sim_stack[sim_len];
            ranges.items[vreg].last_use_pc = pc;
        }

        // Push side — open a fresh vreg per produced value.
        i = 0;
        while (i < eff.pushes) : (i += 1) {
            const vreg: u32 = @intCast(ranges.items.len);
            try ranges.append(allocator, .{ .def_pc = pc, .last_use_pc = pc });
            if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
            sim_stack[sim_len] = vreg;
            sim_len += 1;
        }
    }

    return .{ .ranges = try ranges.toOwnedSlice(allocator) };
}

pub fn deinit(allocator: Allocator, info: Liveness) void {
    if (info.ranges.len != 0) allocator.free(info.ranges);
}

const testing = std.testing;

fn buildFunc(allocator: Allocator, ops: []const ZirInstr) !ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    errdefer f.deinit(allocator);
    for (ops) |o| try f.instrs.append(allocator, o);
    return f;
}

test "compute: straight-line i32.const + i32.const + i32.add + drop + end" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.add" },
        .{ .op = .drop },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 3), live.ranges.len);
    // vreg 0: pushed at pc 0, consumed by add at pc 2.
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[0].last_use_pc);
    // vreg 1: pushed at pc 1, consumed by add at pc 2.
    try testing.expectEqual(@as(u32, 1), live.ranges[1].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[1].last_use_pc);
    // vreg 2: produced by add at pc 2, consumed by drop at pc 3.
    try testing.expectEqual(@as(u32, 2), live.ranges[2].def_pc);
    try testing.expectEqual(@as(u32, 3), live.ranges[2].last_use_pc);
}

test "compute: function-level end closes the still-live vreg" {
    // i32.const 7 ; end -> vreg 0 def=0 last_use=1 (closed by end)
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 7 },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 1), live.ranges.len);
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 1), live.ranges[0].last_use_pc);
}

test "compute: local.tee bridges def at the tee instr" {
    // local.get 0 ; local.tee 1 ; drop ; end
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"local.get", .payload = 0 },
        .{ .op = .@"local.tee", .payload = 1 },
        .{ .op = .drop },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 2), live.ranges.len);
    // vreg 0 (from local.get): def=0, last_use=1 (popped by tee).
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 1), live.ranges[0].last_use_pc);
    // vreg 1 (pushed by tee): def=1, last_use=2 (drop).
    try testing.expectEqual(@as(u32, 1), live.ranges[1].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[1].last_use_pc);
}

test "compute: br closes all live vregs at branch site (sub-7.5c-iv)" {
    // (i32.const 1) (br) (end) — `br` is now handled, not rejected.
    // The const's vreg should have last_use_pc == br's pc.
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"br" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer testing.allocator.free(live.ranges);
    try testing.expectEqual(@as(usize, 1), live.ranges.len);
    try testing.expectEqual(@as(u32, 1), live.ranges[0].last_use_pc); // br at pc=1
}

test "compute: stack underflow when pop with empty stack" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .drop },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    try testing.expectError(Error.OperandStackUnderflow, compute(testing.allocator, &f, &.{}, &.{}));
}

test "compute: select consumes 3 vregs and produces 1" {
    // i32.const 1 ; i32.const 2 ; i32.const 0 ; select ; drop ; end
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.const", .payload = 0 },
        .{ .op = .@"select" },
        .{ .op = .drop },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 4), live.ranges.len);
    // The three operands all close at pc 3 (select), and select's
    // result vreg lives until drop at pc 4.
    for (live.ranges[0..3]) |r| {
        try testing.expectEqual(@as(u32, 3), r.last_use_pc);
    }
    try testing.expectEqual(@as(u32, 3), live.ranges[3].def_pc);
    try testing.expectEqual(@as(u32, 4), live.ranges[3].last_use_pc);
}

test "compute: install onto ZirFunc.liveness slot round-trips" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 5 },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);

    f.liveness = try compute(testing.allocator, &f, &.{}, &.{});
    defer if (f.liveness) |li| deinit(testing.allocator, li);

    try testing.expect(f.liveness != null);
    try testing.expectEqual(@as(usize, 1), f.liveness.?.ranges.len);
}
