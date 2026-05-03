//! Loop-info analysis pass (§9.5 / 5.3).
//!
//! Walks a lowered `ZirFunc`'s `blocks` slice and surfaces every
//! `loop` frame's header + matching `end` as parallel `[]u32`
//! slices. The result populates `ZirFunc.loop_info` (a Phase-5+
//! reserved slot per ROADMAP §4.2 / P13 / W54 lesson) so later
//! passes — §9.5 / 5.4 liveness + Phase-7 regalloc — can iterate
//! per-loop without re-walking the block table.
//!
//! The lowerer (`src/frontend/lowerer.zig`) already records every
//! frame in `func.blocks` with its `kind` set to `.loop` /
//! `.block` / `.if_then` / `.else_open`. The analysis is therefore
//! a single linear filter: O(blocks.len), zero per-instruction
//! work.
//!
//! Lifetime: `compute` allocates the two result slices via the
//! caller-supplied allocator. The caller owns them; if they are
//! installed onto a `ZirFunc.loop_info`, they should be freed
//! before the owning `ZirFunc` is dropped (or stored in an arena
//! whose lifetime exceeds the func).
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("zir.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const LoopInfo = zir.LoopInfo;

/// Compute `LoopInfo` for a lowered function. Returns a struct
/// whose two `[]u32` fields the caller owns.
pub fn compute(allocator: Allocator, func: *const ZirFunc) !LoopInfo {
    var headers: std.ArrayList(u32) = .empty;
    errdefer headers.deinit(allocator);
    var ends: std.ArrayList(u32) = .empty;
    errdefer ends.deinit(allocator);

    for (func.blocks.items) |blk| {
        if (blk.kind != .loop) continue;
        try headers.append(allocator, blk.start_inst);
        try ends.append(allocator, blk.end_inst);
    }

    return .{
        .loop_headers = try headers.toOwnedSlice(allocator),
        .loop_end = try ends.toOwnedSlice(allocator),
    };
}

/// Free the two slices held by a `LoopInfo`. Safe on the
/// default-initialised (empty-slice) value too.
pub fn deinit(allocator: Allocator, info: LoopInfo) void {
    if (info.loop_headers.len != 0) allocator.free(info.loop_headers);
    if (info.loop_end.len != 0) allocator.free(info.loop_end);
}

const testing = std.testing;

test "compute: function with no loops yields empty slices" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    const info = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, info);
    try testing.expectEqual(@as(usize, 0), info.loop_headers.len);
    try testing.expectEqual(@as(usize, 0), info.loop_end.len);
}

test "compute: skips block / if frames, collects loop frames" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    try f.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 5 });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 6, .end_inst = 12 });
    try f.blocks.append(testing.allocator, .{ .kind = .if_then, .start_inst = 13, .end_inst = 20 });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 21, .end_inst = 30 });

    const info = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, info);
    try testing.expectEqual(@as(usize, 2), info.loop_headers.len);
    try testing.expectEqual(@as(u32, 6), info.loop_headers[0]);
    try testing.expectEqual(@as(u32, 12), info.loop_end[0]);
    try testing.expectEqual(@as(u32, 21), info.loop_headers[1]);
    try testing.expectEqual(@as(u32, 30), info.loop_end[1]);
}

test "compute: single nested loop preserves enclosing-block ordering" {
    // Mirrors the lowerer's emission order for:
    //   block { loop { ... } }  →  blocks[0] = block, blocks[1] = loop
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    try f.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 10 });
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 1, .end_inst = 9 });

    const info = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, info);
    try testing.expectEqual(@as(usize, 1), info.loop_headers.len);
    try testing.expectEqual(@as(u32, 1), info.loop_headers[0]);
    try testing.expectEqual(@as(u32, 9), info.loop_end[0]);
}

test "compute: result installs cleanly onto ZirFunc.loop_info slot" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.blocks.append(testing.allocator, .{ .kind = .loop, .start_inst = 0, .end_inst = 4 });

    f.loop_info = try compute(testing.allocator, &f);
    defer if (f.loop_info) |li| deinit(testing.allocator, li);

    try testing.expect(f.loop_info != null);
    try testing.expectEqual(@as(usize, 1), f.loop_info.?.loop_headers.len);
    try testing.expectEqual(@as(u32, 0), f.loop_info.?.loop_headers[0]);
    try testing.expectEqual(@as(u32, 4), f.loop_info.?.loop_end[0]);
}
