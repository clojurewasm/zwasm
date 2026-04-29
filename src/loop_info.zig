//! Shared loop / branch / liveness analysis for the JIT pipeline.
//!
//! Owns the data structures that describe a function's control-flow
//! shape (where the branch targets are, which PCs are loop headers,
//! how long each loop body extends) and — in later phases — vreg
//! liveness and loop-invariant-constant classification.
//!
//! Both JIT backends consume the same `LoopInfo` instead of running
//! their own pre-scans. Cost: one forward sweep over the RegInstr
//! stream per compile.

const std = @import("std");
const regalloc = @import("regalloc.zig");

const RegInstr = regalloc.RegInstr;

pub const LoopInfo = struct {
    /// branch_targets[pc] = true iff some control-flow op (BR, BR_IF,
    /// BR_IF_NOT, BR_TABLE, BLOCK_END) targets this PC. Drives JIT
    /// cache eviction and the known_consts wipe.
    branch_targets: []bool = &.{},

    /// loop_headers[pc] = true iff `pc` is the target of a backward
    /// branch (i.e. a loop entry).
    loop_headers: []bool = &.{},

    /// loop_end[header_pc] = max source PC of any back-edge into
    /// header_pc. Defines the inclusive range `[header_pc, loop_end]`
    /// that the loop body covers. 0 for non-headers.
    loop_end: []u32 = &.{},

    /// Free all owned slices. Safe to call on a default-initialized
    /// (empty) LoopInfo.
    pub fn deinit(self: *LoopInfo, alloc: std.mem.Allocator) void {
        if (self.branch_targets.len > 0) alloc.free(self.branch_targets);
        if (self.loop_headers.len > 0) alloc.free(self.loop_headers);
        if (self.loop_end.len > 0) alloc.free(self.loop_end);
        self.* = .{};
    }

    /// Single forward sweep populating branch_targets / loop_headers /
    /// loop_end. Returns false on allocation failure (caller treats
    /// the JIT compile as a bail).
    pub fn analyse(
        self: *LoopInfo,
        alloc: std.mem.Allocator,
        ir: []const RegInstr,
    ) bool {
        const targets = alloc.alloc(bool, ir.len) catch return false;
        @memset(targets, false);
        const loop_headers = alloc.alloc(bool, ir.len) catch {
            alloc.free(targets);
            return false;
        };
        @memset(loop_headers, false);
        const loop_end = alloc.alloc(u32, ir.len) catch {
            alloc.free(loop_headers);
            alloc.free(targets);
            return false;
        };
        @memset(loop_end, 0);

        var scan_pc: u32 = 0;
        while (scan_pc < ir.len) {
            const instr = ir[scan_pc];
            const source_pc = scan_pc;
            scan_pc += 1;
            switch (instr.op) {
                regalloc.OP_BR => recordTarget(targets, loop_headers, loop_end, instr.operand, source_pc, ir.len),
                regalloc.OP_BR_IF, regalloc.OP_BR_IF_NOT => recordTarget(
                    targets,
                    loop_headers,
                    loop_end,
                    instr.operand,
                    source_pc,
                    ir.len,
                ),
                regalloc.OP_BR_TABLE => {
                    const count = instr.operand;
                    var i: u32 = 0;
                    while (i < count + 1 and scan_pc < ir.len) : (i += 1) {
                        const entry = ir[scan_pc];
                        scan_pc += 1;
                        recordTarget(targets, loop_headers, loop_end, entry.operand, source_pc, ir.len);
                    }
                },
                regalloc.OP_BLOCK_END => {
                    targets[scan_pc - 1] = true;
                },
                else => {},
            }
        }

        self.* = .{
            .branch_targets = targets,
            .loop_headers = loop_headers,
            .loop_end = loop_end,
        };
        return true;
    }
};

fn recordTarget(
    targets: []bool,
    loop_headers: []bool,
    loop_end: []u32,
    target_pc: u32,
    source_pc: u32,
    ir_len: usize,
) void {
    if (target_pc >= ir_len) return;
    targets[target_pc] = true;
    if (target_pc <= source_pc) {
        loop_headers[target_pc] = true;
        if (source_pc > loop_end[target_pc]) {
            loop_end[target_pc] = source_pc;
        }
    }
}

const testing = std.testing;

test "LoopInfo: empty IR yields empty slices" {
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &.{}));
    try testing.expectEqual(@as(usize, 0), info.branch_targets.len);
    try testing.expectEqual(@as(usize, 0), info.loop_headers.len);
    try testing.expectEqual(@as(usize, 0), info.loop_end.len);
}

test "LoopInfo: forward branch flagged, no loop header" {
    // pc=0: NOP
    // pc=1: BR -> pc=3   (forward branch)
    // pc=2: NOP
    // pc=3: NOP (target)
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BR, .rd = 0, .rs1 = 0, .operand = 3 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir));
    try testing.expect(info.branch_targets[3]);
    try testing.expect(!info.loop_headers[3]);
    try testing.expectEqual(@as(u32, 0), info.loop_end[3]);
}

test "LoopInfo: backward branch is a loop header with end_pc" {
    // pc=0: NOP (header)
    // pc=1: NOP
    // pc=2: BR_IF -> pc=0 (back-edge)
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BR_IF, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir));
    try testing.expect(info.branch_targets[0]);
    try testing.expect(info.loop_headers[0]);
    try testing.expectEqual(@as(u32, 2), info.loop_end[0]);
}

test "LoopInfo: nested back-edges keep max end_pc" {
    // pc=0: header (target of two back-edges)
    // pc=1: NOP
    // pc=2: BR -> pc=0
    // pc=3: NOP
    // pc=4: BR -> pc=0
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BR, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BR, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir));
    try testing.expectEqual(@as(u32, 4), info.loop_end[0]);
}

test "LoopInfo: BLOCK_END marks the END pc itself as a target" {
    const ir = [_]RegInstr{
        .{ .op = regalloc.OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc.OP_BLOCK_END, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var info: LoopInfo = .{};
    defer info.deinit(testing.allocator);
    try testing.expect(info.analyse(testing.allocator, &ir));
    try testing.expect(info.branch_targets[1]);
    try testing.expect(!info.loop_headers[1]);
}
