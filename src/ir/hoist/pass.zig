//! ZIR-stage hoist pass — constant-hoist via local-set/local-get
//! rewrite (§9.8 / 8.4 per ADR-0031, post-revision).
//!
//! For each loop-invariant `*.const` opcode (`i32.const` /
//! `i64.const` / `f32.const` / `f64.const`) inside a `loop`
//! frame, the pass:
//!
//!   1. Allocates a fresh synthetic local index N in
//!      `func.synthetic_locals`.
//!   2. Inserts a prologue pair `*.const K; local.set N`
//!      immediately before the loop header.
//!   3. Replaces the in-loop `*.const K` with `local.get N`
//!      (same PC slot, different op).
//!
//! This decouples the value's lifetime from operand-stack scope:
//! the `local.set N` writes once outside the loop; each
//! iteration's `local.get N` reads from the durable local slot
//! and pushes a fresh vreg onto the in-loop operand stack. The
//! drop / consumer inside the loop sees a normal stack push,
//! preserving Wasm's frame-scoped operand-stack semantics
//! (which the naive instr-move attempt of 8.4-c violated; see
//! lesson `2026-05-08-hoist-vreg-semantic.md`).
//!
//! MVP scope: hoists to the **outermost** containing loop.
//! Multiple identical constants each get their own synthetic
//! local in this MVP (pooling deferred to Phase 15).
//! Transitive hoisting (e.g. `i32.add` of two loop-invariant
//! operands) is also deferred.
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("../zir.zig");
const loop_info_mod = @import("../analysis/loop_info.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const ValType = zir.ValType;
const HoistedConst = zir.HoistedConst;
const LoopInfo = zir.LoopInfo;

pub const Error = error{OutOfMemory};

/// Run the hoist pass. Pre-condition: caller has populated
/// `func.loop_info` (see `loop_info.compute`). Post-condition:
/// `func.instrs` rewritten with hoisted prologues + in-loop
/// `local.get` replacements; `func.blocks[]` and `func.
/// branch_targets[]` updated; `func.synthetic_locals` and
/// `func.hoisted_constants` installed.
///
/// Caller-owned: `func.synthetic_locals` and `func.
/// hoisted_constants` slices must be freed by `deinit*`
/// helpers below before `func.deinit`.
pub fn run(allocator: Allocator, func: *ZirFunc) Error!void {
    const li = func.loop_info orelse return;
    if (li.loop_headers.len == 0) return;

    // Per-loop list of in-loop const PCs to hoist.
    var hoists_per_loop = try std.ArrayList(std.ArrayList(u32)).initCapacity(allocator, li.loop_headers.len);
    defer {
        for (hoists_per_loop.items) |*list| list.deinit(allocator);
        hoists_per_loop.deinit(allocator);
    }
    for (0..li.loop_headers.len) |_| {
        try hoists_per_loop.append(allocator, .empty);
    }

    var total_hoists: u32 = 0;
    for (func.instrs.items, 0..) |instr, pc_usize| {
        const pc: u32 = @intCast(pc_usize);
        if (!isConstOp(instr.op)) continue;
        const loop_idx = outermostLoopContaining(li, pc) orelse continue;
        try hoists_per_loop.items[loop_idx].append(allocator, pc);
        total_hoists += 1;
    }

    if (total_hoists == 0) return;

    // Allocate one synthetic local per hoist. local_idx_at[orig_pc] gives
    // the absolute Wasm-space local index assigned to the const at orig_pc.
    var synthetic_types = try std.ArrayList(ValType).initCapacity(allocator, total_hoists);
    errdefer synthetic_types.deinit(allocator);
    var local_idx_at = try allocator.alloc(u32, func.instrs.items.len);
    defer allocator.free(local_idx_at);
    @memset(local_idx_at, std.math.maxInt(u32));

    const num_params: u32 = @intCast(func.sig.params.len);
    const orig_locals_len: u32 = @intCast(func.locals.len);
    const synthetic_base: u32 = num_params + orig_locals_len;

    for (hoists_per_loop.items) |loop_list| {
        for (loop_list.items) |orig_pc| {
            const instr = func.instrs.items[orig_pc];
            const vtype = valTypeOfConst(instr.op);
            const new_local_idx: u32 = synthetic_base + @as(u32, @intCast(synthetic_types.items.len));
            try synthetic_types.append(allocator, vtype);
            local_idx_at[orig_pc] = new_local_idx;
        }
    }

    // Build the new instrs list. Walk original PCs in order.
    // At each loop_header that has hoists, emit the prologue pair
    // (const + local.set) for each. Then emit the original instr
    // — but if its PC is a hoisted const's orig_pc, replace it
    // with local.get.
    const new_capacity = func.instrs.items.len + 2 * total_hoists;
    var new_instrs = try std.ArrayList(ZirInstr).initCapacity(allocator, new_capacity);
    errdefer new_instrs.deinit(allocator);

    var hoisted_records = try std.ArrayList(HoistedConst).initCapacity(allocator, total_hoists);
    errdefer hoisted_records.deinit(allocator);

    for (func.instrs.items, 0..) |instr, pc_usize| {
        const pc: u32 = @intCast(pc_usize);

        // Prologue pairs for any loop whose header is at this PC.
        for (li.loop_headers, 0..) |header, loop_idx| {
            if (header != pc) continue;
            for (hoists_per_loop.items[loop_idx].items) |orig_pc| {
                const orig_instr = func.instrs.items[orig_pc];
                const local_idx = local_idx_at[orig_pc];
                const prologue_const_pc: u32 = @intCast(new_instrs.items.len);
                try new_instrs.append(allocator, orig_instr);
                const prologue_set_pc: u32 = @intCast(new_instrs.items.len);
                try new_instrs.append(allocator, .{ .op = .@"local.set", .payload = local_idx });
                // The in-loop replacement PC is computed when we emit it
                // below; record the prologue PCs now and patch in_loop_pc
                // when the const's orig_pc is processed.
                try hoisted_records.append(allocator, .{
                    .original_pc = orig_pc,
                    .prologue_const_pc = prologue_const_pc,
                    .prologue_set_pc = prologue_set_pc,
                    .in_loop_pc = std.math.maxInt(u32),
                    .local_idx = local_idx,
                    .op = orig_instr.op,
                    .payload = orig_instr.payload,
                    .extra = orig_instr.extra,
                });
            }
        }

        // Replace if this PC is a hoisted const, else emit unchanged.
        if (local_idx_at[pc] != std.math.maxInt(u32)) {
            const local_idx = local_idx_at[pc];
            const in_loop_pc: u32 = @intCast(new_instrs.items.len);
            try new_instrs.append(allocator, .{ .op = .@"local.get", .payload = local_idx });
            // Patch the matching hoisted_records entry's in_loop_pc.
            for (hoisted_records.items) |*rec| {
                if (rec.original_pc == pc) {
                    rec.in_loop_pc = in_loop_pc;
                    break;
                }
            }
        } else {
            try new_instrs.append(allocator, instr);
        }
    }

    // Compute PC shift for blocks + branch_targets.
    // shift[orig_pc] = 2 * sum(hoists_per_loop[L].len) for all L where loop_headers[L] <= orig_pc.
    var pc_shift = try allocator.alloc(u32, func.instrs.items.len + 1);
    defer allocator.free(pc_shift);
    {
        var cur_shift: u32 = 0;
        for (0..func.instrs.items.len + 1) |orig_pc_usize| {
            const orig_pc: u32 = @intCast(orig_pc_usize);
            for (li.loop_headers, 0..) |header, loop_idx| {
                if (header == orig_pc) {
                    cur_shift += 2 * @as(u32, @intCast(hoists_per_loop.items[loop_idx].items.len));
                }
            }
            pc_shift[orig_pc_usize] = cur_shift;
        }
    }

    // Update blocks[].
    for (func.blocks.items) |*blk| {
        blk.start_inst += pc_shift[blk.start_inst];
        blk.end_inst += pc_shift[blk.end_inst];
    }

    // Update branch_targets[].
    for (func.branch_targets.items) |*tgt| {
        tgt.* += pc_shift[tgt.*];
    }

    // Swap in new instrs.
    func.instrs.deinit(allocator);
    func.instrs = new_instrs;

    // Install the slot data.
    func.synthetic_locals = try synthetic_types.toOwnedSlice(allocator);
    func.hoisted_constants = try hoisted_records.toOwnedSlice(allocator);
}

/// Free the slices held by `func.synthetic_locals` and
/// `func.hoisted_constants`. Caller must call this before
/// `func.deinit` if those slices were installed by `run`.
pub fn deinitArtifacts(allocator: Allocator, func: *ZirFunc) void {
    if (func.synthetic_locals) |slice| {
        if (slice.len > 0) allocator.free(slice);
        func.synthetic_locals = null;
    }
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

fn valTypeOfConst(op: ZirOp) ValType {
    return switch (op) {
        .@"i32.const" => .i32,
        .@"i64.const" => .i64,
        .@"f32.const" => .f32,
        .@"f64.const" => .f64,
        else => unreachable, // caller filters via isConstOp
    };
}

/// Find the outermost loop whose body strictly contains `pc`.
/// Returns null if `pc` is not inside any loop body.
fn outermostLoopContaining(li: LoopInfo, pc: u32) ?usize {
    var best: ?usize = null;
    var best_header: u32 = 0;
    for (li.loop_headers, li.loop_end, 0..) |header, end, idx| {
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

test "run: no-op when loop_info is null" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try run(testing.allocator, &f);
    try testing.expect(f.synthetic_locals == null);
    try testing.expect(f.hoisted_constants == null);
}

test "run: hoists single i32.const via local-rewrite" {
    // Original:
    //   PC 0: loop  (block.start=0, block.end=3)
    //   PC 1: i32.const 42
    //   PC 2: drop
    //   PC 3: end
    //
    // Expected post-hoist:
    //   PC 0: i32.const 42       (prologue)
    //   PC 1: local.set N=0      (prologue; N = num_params(0) + locals(0) + synth_idx(0) = 0)
    //   PC 2: loop               (block.start=2, block.end=5)
    //   PC 3: local.get N=0      (replaces original i32.const at PC 1)
    //   PC 4: drop
    //   PC 5: end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitArtifacts(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 0, .end_inst = 3 });

    const li = try loop_info_mod.compute(testing.allocator, &f);
    defer loop_info_mod.deinit(testing.allocator, li);
    f.loop_info = li;

    try run(testing.allocator, &f);

    // 6 instrs (4 original + 2 prologue inserts).
    try testing.expectEqual(@as(usize, 6), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 42), f.instrs.items[0].payload);
    try testing.expectEqual(ZirOp.@"local.set", f.instrs.items[1].op);
    try testing.expectEqual(@as(u32, 0), f.instrs.items[1].payload);
    try testing.expectEqual(ZirOp.@"loop", f.instrs.items[2].op);
    try testing.expectEqual(ZirOp.@"local.get", f.instrs.items[3].op);
    try testing.expectEqual(@as(u32, 0), f.instrs.items[3].payload);
    try testing.expectEqual(ZirOp.@"drop", f.instrs.items[4].op);
    try testing.expectEqual(ZirOp.end, f.instrs.items[5].op);

    // Block update: loop now at PC 2..5.
    try testing.expectEqual(@as(u32, 2), f.blocks.items[0].start_inst);
    try testing.expectEqual(@as(u32, 5), f.blocks.items[0].end_inst);

    // Synthetic local: one i32.
    try testing.expect(f.synthetic_locals != null);
    try testing.expectEqual(@as(usize, 1), f.synthetic_locals.?.len);
    try testing.expectEqual(ValType.i32, f.synthetic_locals.?[0]);
    try testing.expectEqual(@as(u32, 1), f.totalLocalCount());

    // HoistedConst record.
    try testing.expect(f.hoisted_constants != null);
    try testing.expectEqual(@as(usize, 1), f.hoisted_constants.?.len);
    const rec = f.hoisted_constants.?[0];
    try testing.expectEqual(@as(u32, 1), rec.original_pc);
    try testing.expectEqual(@as(u32, 0), rec.prologue_const_pc);
    try testing.expectEqual(@as(u32, 1), rec.prologue_set_pc);
    try testing.expectEqual(@as(u32, 3), rec.in_loop_pc);
    try testing.expectEqual(@as(u32, 0), rec.local_idx);
    try testing.expectEqual(ZirOp.@"i32.const", rec.op);
    try testing.expectEqual(@as(u32, 42), rec.payload);
}

test "run: const outside any loop is left alone" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitArtifacts(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .end });

    const li = try loop_info_mod.compute(testing.allocator, &f);
    defer loop_info_mod.deinit(testing.allocator, li);
    f.loop_info = li;

    try run(testing.allocator, &f);

    try testing.expectEqual(@as(usize, 3), f.instrs.items.len);
    try testing.expect(f.synthetic_locals == null);
    try testing.expect(f.hoisted_constants == null);
}

test "run: shifts branch_targets across hoist prologue" {
    // PC 0: loop  (block.start=0, block.end=3)
    // PC 1: i32.const 7
    // PC 2: drop
    // PC 3: end
    // branch_targets[0] = 0 (target = loop header)
    //
    // After hoist: loop now at PC 2; target should be 2.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitArtifacts(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 0, .end_inst = 3 });
    try f.branch_targets.append(testing.allocator, 0);

    const li = try loop_info_mod.compute(testing.allocator, &f);
    defer loop_info_mod.deinit(testing.allocator, li);
    f.loop_info = li;

    try run(testing.allocator, &f);

    try testing.expectEqual(@as(u32, 2), f.branch_targets.items[0]);
}

test "run: multiple consts in same loop allocate distinct locals" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitArtifacts(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 10 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 20 });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"drop" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 0, .end_inst = 5 });

    const li = try loop_info_mod.compute(testing.allocator, &f);
    defer loop_info_mod.deinit(testing.allocator, li);
    f.loop_info = li;

    try run(testing.allocator, &f);

    // Expect 10 instrs: 4 prologue (2 hoists × 2) + 6 original
    // (the 2 in-loop consts → 2 local.gets in place; plus loop,
    // drop, drop, end).
    try testing.expectEqual(@as(usize, 10), f.instrs.items.len);
    try testing.expectEqual(@as(usize, 2), f.synthetic_locals.?.len);
    try testing.expectEqual(ValType.i32, f.synthetic_locals.?[0]);
    try testing.expectEqual(ValType.i64, f.synthetic_locals.?[1]);
    try testing.expectEqual(@as(usize, 2), f.hoisted_constants.?.len);
}
