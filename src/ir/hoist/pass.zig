//! ZIR-stage hoist pass — constant-hoist MVP (§9.8 / 8.4 per
//! ADR-0031).
//!
//! Moves loop-invariant `*.const` opcodes (`i32.const` /
//! `i64.const` / `f32.const` / `f64.const`) out of `loop` frames
//! to a synthetic preheader region immediately before the loop
//! header instruction. Pre-regalloc; runs between `lower` and
//! `liveness` in `src/engine/codegen/shared/compile.zig`.
//!
//! Wasm ZIR semantics (per ADR-0014 §6.K): vreg IDs are stored
//! on `ZirInstr` payload/extra fields, NOT recomputed from
//! position. Moving a `*.const` instruction backward in the
//! instr stream therefore preserves vreg identity — downstream
//! `i32.add` / `drop` etc. continue to reference the same vreg
//! IDs they did pre-hoist. The vreg's liveness range simply
//! extends across the loop boundary; `liveness.compute()` (run
//! AFTER hoist) computes the new range.
//!
//! MVP scope: only `*.const` opcodes are hoisted. Transitive
//! hoisting (e.g. an `i32.add` whose operands are both
//! loop-invariant) is deferred to Phase 15 per ADR-0031
//! Alternative A.
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("../zir.zig");
const loop_info_mod = @import("../analysis/loop_info.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const HoistedConst = zir.HoistedConst;
const LoopInfo = zir.LoopInfo;

pub const Error = error{OutOfMemory};

/// Run the hoist pass. Mutates `func.instrs` in place; updates
/// `func.blocks[]` start/end PCs + `func.branch_targets[]`
/// entries to track the shift; allocates and installs
/// `func.hoisted_constants` recording each successful hoist.
///
/// Caller-owned: `func.hoisted_constants` lives until
/// `func.deinit` (caller must free, mirroring `LoopInfo`'s
/// lifecycle convention).
///
/// No-op when `func.loop_info` is null (caller must compute
/// loop_info first; deliberately *not* computed-on-demand to
/// keep ownership boundaries explicit per ROADMAP §A12).
pub fn run(allocator: Allocator, func: *ZirFunc) Error!void {
    const li = func.loop_info orelse return;
    if (li.loop_headers.len == 0) return;

    // Collect, per loop, the PCs of `*.const` instrs inside its
    // body that should be hoisted. Use a single scan: for each
    // instr PC, find its innermost containing loop (if any). MVP
    // hoists to the **outermost** loop containing the const —
    // maximum-benefit placement, matches ADR-0031 §"Boundary
    // cases".
    var hoist_per_loop = try std.ArrayList(std.ArrayList(u32)).initCapacity(allocator, li.loop_headers.len);
    defer {
        for (hoist_per_loop.items) |*list| list.deinit(allocator);
        hoist_per_loop.deinit(allocator);
    }
    for (0..li.loop_headers.len) |_| {
        try hoist_per_loop.append(allocator, .empty);
    }

    var hoist_count: u32 = 0;
    for (func.instrs.items, 0..) |instr, pc_usize| {
        const pc: u32 = @intCast(pc_usize);
        if (!isConstOp(instr.op)) continue;
        // Find the outermost loop containing pc (smallest loop_header).
        const loop_idx = outermostLoopContaining(li, pc) orelse continue;
        try hoist_per_loop.items[loop_idx].append(allocator, pc);
        hoist_count += 1;
    }

    if (hoist_count == 0) return;

    // Build the new instrs list. Walk original PCs, emitting
    // hoisted constants at each loop header before the header
    // itself, and skipping the original (now-moved) const
    // instructions inside loops.
    var new_instrs = try std.ArrayList(ZirInstr).initCapacity(allocator, func.instrs.items.len);
    errdefer new_instrs.deinit(allocator);
    var hoisted_records = try std.ArrayList(HoistedConst).initCapacity(allocator, hoist_count);
    errdefer hoisted_records.deinit(allocator);

    // Build a flat set of original PCs that are being hoisted
    // (so the walk can skip them).
    var hoisted_pcs = try allocator.alloc(bool, func.instrs.items.len);
    defer allocator.free(hoisted_pcs);
    @memset(hoisted_pcs, false);
    for (hoist_per_loop.items) |loop_list| {
        for (loop_list.items) |pc| hoisted_pcs[pc] = true;
    }

    // Map original PC → list of (loop_idx) whose hoists land at
    // this PC's position. Since hoists land *before* the loop
    // header, "PC == loop_headers[i]" means loop i's hoists go
    // here. Use a parallel flat lookup.
    for (func.instrs.items, 0..) |instr, pc_usize| {
        const pc: u32 = @intCast(pc_usize);
        // If this PC is a loop header, prepend its hoisted
        // constants from `hoist_per_loop`.
        for (li.loop_headers, 0..) |header, loop_idx| {
            if (header != pc) continue;
            for (hoist_per_loop.items[loop_idx].items) |orig_pc| {
                const orig_instr = func.instrs.items[orig_pc];
                const new_pc: u32 = @intCast(new_instrs.items.len);
                try new_instrs.append(allocator, orig_instr);
                try hoisted_records.append(allocator, .{
                    .original_pc = orig_pc,
                    .new_pc = new_pc,
                    .op = orig_instr.op,
                    .payload = orig_instr.payload,
                    .extra = orig_instr.extra,
                });
            }
        }
        // Skip if this PC is itself being hoisted (already
        // emitted via the header check above for its loop).
        if (hoisted_pcs[pc]) continue;
        try new_instrs.append(allocator, instr);
    }

    // Compute pc_shift: original_pc → new_pc map. For every
    // original PC, count how many hoisted constants from any
    // loop header at-or-before this PC have been inserted, MINUS
    // any constants extracted from at-or-before this PC. The net
    // delta is what shifts blocks/branch_targets.
    //
    // Practically: for each loop header H at original pc, all
    // PCs >= H gain `hoist_per_loop[loop].len` shift; for each
    // hoisted const at original pc P, all PCs >= P+1 lose 1
    // shift (because P's instr was moved earlier). The net effect
    // is captured by walking original PCs and accumulating.
    var pc_shift = try allocator.alloc(i32, func.instrs.items.len + 1);
    defer allocator.free(pc_shift);
    var cur_shift: i32 = 0;
    for (0..func.instrs.items.len + 1) |orig_pc_usize| {
        const orig_pc: u32 = @intCast(orig_pc_usize);
        // Apply per-loop hoist insertion if this PC is a loop header.
        for (li.loop_headers, 0..) |header, loop_idx| {
            if (header == orig_pc) {
                cur_shift += @as(i32, @intCast(hoist_per_loop.items[loop_idx].items.len));
            }
        }
        pc_shift[orig_pc_usize] = cur_shift;
        // If this PC was extracted (hoisted), the next PC
        // contracts by 1 (the gap left by the extracted instr).
        if (orig_pc < func.instrs.items.len and hoisted_pcs[orig_pc]) {
            cur_shift -= 1;
        }
    }

    // Update blocks: each block's start_inst and end_inst shift
    // by pc_shift[that_pc].
    for (func.blocks.items) |*blk| {
        blk.start_inst = @intCast(@as(i32, @intCast(blk.start_inst)) + pc_shift[blk.start_inst]);
        blk.end_inst = @intCast(@as(i32, @intCast(blk.end_inst)) + pc_shift[blk.end_inst]);
    }

    // Update branch_targets: each target PC shifts.
    for (func.branch_targets.items) |*tgt| {
        tgt.* = @intCast(@as(i32, @intCast(tgt.*)) + pc_shift[tgt.*]);
    }

    // Swap in the new instrs.
    func.instrs.deinit(allocator);
    func.instrs = new_instrs;

    // Install the hoisted-constants record.
    func.hoisted_constants = try hoisted_records.toOwnedSlice(allocator);
}

/// Free the slice held by `func.hoisted_constants`. Safe on
/// null. Caller must call this before `func.deinit` if the slice
/// was installed by `run` with the same allocator.
pub fn deinitHoistedConstants(allocator: Allocator, func: *ZirFunc) void {
    if (func.hoisted_constants) |slice| {
        if (slice.len > 0) allocator.free(slice);
        func.hoisted_constants = null;
    }
}

fn isConstOp(op: ZirOp) bool {
    return switch (op) {
        .@"i32.const", .@"i64.const", .@"f32.const", .@"f64.const" => true,
        else => false,
    };
}

/// Find the outermost loop whose body contains `pc`. Returns
/// the index into `li.loop_headers` (= same index in
/// `li.loop_end`) of the innermost containing loop, OR null if
/// `pc` is not inside any loop body.
///
/// "Outermost" here means the loop whose `[loop_header,
/// loop_end]` range contains `pc` AND has the smallest header
/// (= the most enclosing). For non-overlapping nested loops
/// (Wasm spec §3.5.1's structured control flow), the smallest
/// header guarantees outermost containment.
fn outermostLoopContaining(li: LoopInfo, pc: u32) ?usize {
    var best: ?usize = null;
    var best_header: u32 = 0;
    for (li.loop_headers, li.loop_end, 0..) |header, end, idx| {
        // pc strictly inside the loop body (between header and end).
        if (pc <= header or pc >= end) continue;
        if (best == null or header < best_header) {
            best = idx;
            best_header = header;
        }
    }
    return best;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "run: no-op on function with no loop_info" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    try run(testing.allocator, &f);
    try testing.expect(f.hoisted_constants == null);
}

test "run: no-op on function with empty loop_info" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.loop_info = .{ .loop_headers = &.{}, .loop_end = &.{} };

    try run(testing.allocator, &f);
    try testing.expect(f.hoisted_constants == null);
}

test "run: hoists single i32.const out of loop body" {
    // Function shape:
    //   PC 0: loop  (block.start=0, block.end=3)
    //   PC 1: i32.const 42
    //   PC 2: drop
    //   PC 3: end
    //
    // Expected post-hoist:
    //   PC 0: i32.const 42 (hoisted, original_pc=1, new_pc=0)
    //   PC 1: loop  (block.start=1, block.end=3)
    //   PC 2: drop
    //   PC 3: end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitHoistedConstants(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 0, .end_inst = 3 });

    const loop_info_value = try loop_info_mod.compute(testing.allocator, &f);
    defer loop_info_mod.deinit(testing.allocator, loop_info_value);
    f.loop_info = loop_info_value;

    try run(testing.allocator, &f);

    try testing.expectEqual(@as(usize, 4), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 42), f.instrs.items[0].payload);
    try testing.expectEqual(ZirOp.@"loop", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"drop", f.instrs.items[2].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[3].op);

    try testing.expectEqual(@as(u32, 1), f.blocks.items[0].start_inst);
    try testing.expectEqual(@as(u32, 3), f.blocks.items[0].end_inst);

    try testing.expect(f.hoisted_constants != null);
    try testing.expectEqual(@as(usize, 1), f.hoisted_constants.?.len);
    try testing.expectEqual(@as(u32, 1), f.hoisted_constants.?[0].original_pc);
    try testing.expectEqual(@as(u32, 0), f.hoisted_constants.?[0].new_pc);
    try testing.expectEqual(ZirOp.@"i32.const", f.hoisted_constants.?[0].op);
    try testing.expectEqual(@as(u32, 42), f.hoisted_constants.?[0].payload);
}

test "run: leaves a const that's outside any loop alone" {
    // PC 0: i32.const 99 (outside any loop)
    // PC 1: drop
    // PC 2: end
    // No loops.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitHoistedConstants(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .end });

    const loop_info_value = try loop_info_mod.compute(testing.allocator, &f);
    defer loop_info_mod.deinit(testing.allocator, loop_info_value);
    f.loop_info = loop_info_value;

    try run(testing.allocator, &f);

    // No hoist; instrs unchanged.
    try testing.expectEqual(@as(usize, 3), f.instrs.items.len);
    try testing.expect(f.hoisted_constants == null);
}

test "run: hoists multiple consts from same loop, preserves order" {
    // PC 0: loop
    // PC 1: i32.const 10
    // PC 2: i32.const 20
    // PC 3: i32.add
    // PC 4: drop
    // PC 5: end
    //
    // Expected:
    // PC 0: i32.const 10 (hoisted, original_pc=1)
    // PC 1: i32.const 20 (hoisted, original_pc=2)
    // PC 2: loop (block.start=2, block.end=5)
    // PC 3: i32.add
    // PC 4: drop
    // PC 5: end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitHoistedConstants(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 10 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 20 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 0, .end_inst = 5 });

    const loop_info_value = try loop_info_mod.compute(testing.allocator, &f);
    defer loop_info_mod.deinit(testing.allocator, loop_info_value);
    f.loop_info = loop_info_value;

    try run(testing.allocator, &f);

    try testing.expectEqual(@as(usize, 6), f.instrs.items.len);
    try testing.expectEqual(@as(u32, 10), f.instrs.items[0].payload);
    try testing.expectEqual(@as(u32, 20), f.instrs.items[1].payload);
    try testing.expectEqual(ZirOp.@"loop", f.instrs.items[2].op);
    try testing.expectEqual(ZirOp.@"i32.add", f.instrs.items[3].op);

    try testing.expectEqual(@as(u32, 2), f.blocks.items[0].start_inst);
    try testing.expectEqual(@as(u32, 5), f.blocks.items[0].end_inst);

    try testing.expectEqual(@as(usize, 2), f.hoisted_constants.?.len);
}

test "run: shifts branch_targets entries past hoisted const" {
    // Mirror of the multi-const test above plus one branch_target
    // at PC 5 (the end). Expected post-hoist target = PC 5
    // (unchanged in this case because the targets don't sit
    // before the hoisted PCs, they're past them — the shift is
    // still correct because pc_shift[5] == +2 - 2 = 0 for PCs
    // that come AFTER all hoists complete).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitHoistedConstants(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 10 });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 0, .end_inst = 3 });
    try f.branch_targets.append(testing.allocator, 0); // target = loop header (= pc 0)

    const loop_info_value = try loop_info_mod.compute(testing.allocator, &f);
    defer loop_info_mod.deinit(testing.allocator, loop_info_value);
    f.loop_info = loop_info_value;

    try run(testing.allocator, &f);

    // Target was 0 (loop header); after hoist, loop is at pc 1.
    try testing.expectEqual(@as(u32, 1), f.branch_targets.items[0]);
}
