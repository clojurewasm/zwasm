//! JIT greedy-local register allocator (§9.7 / 7.1).
//!
//! Walks the per-vreg live ranges in `ZirFunc.liveness.?.ranges`
//! in def_pc order; for each vreg, assigns the smallest physical
//! slot id that is not already held by a vreg whose live range
//! overlaps. Output is an `Allocation { slots: []u8, n_slots }`
//! the §9.7 / 7.3 jit_arm64 emit pass consumes (later commits
//! map slot id → physical register via the per-arch ABI table
//! from §9.7 / 7.2).
//!
//! Phase-7 / 7.1 scope: the slot-only allocator + verify
//! post-condition. All vregs are treated as GPR class for now;
//! per-class slot pools land alongside §9.7 / 7.2's ABI work
//! (the `RegClassInfo` table from §9.7 / 7.0 will drive the
//! refinement). Spilling is also out-of-scope here — the
//! greedy-local allocator may grow `n_slots` unboundedly; a
//! production allocator caps n_slots at the per-arch register
//! file size and spills the rest, which is a §9.7 / 7.3 follow-
//! up once the emit pass surfaces concrete pressure.
//!
//! The W54-class lesson (per `textbook_survey.md` Guard 4):
//! liveness drives regalloc, NOT the other way around. The
//! `Liveness` slot is populated upstream by §9.5 / 5.4
//! (`ir/liveness.zig`); regalloc reads it as a const input.
//! The verifier checks the regalloc didn't violate liveness
//! before downstream emit ever sees the allocation. v1's W54
//! bug came from regalloc-stage IR shape implicitly assuming
//! liveness invariants that weren't checked; the post-condition
//! here makes that check explicit.
//!
//! Lifetime: caller-allocated; pair with `deinit` to free.
//!
//! Zone 2 (`src/jit/`).

const std = @import("std");

const zir = @import("../ir/zir.zig");
const reg_class = @import("reg_class.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const LiveRange = zir.LiveRange;

pub const Error = error{
    LivenessMissing,
    OutOfMemory,
    SlotOverflow,
};

pub const VerifyError = error{
    SlotsLengthMismatch,
    OverlappingVregsShareSlot,
    SlotIndexExceedsCount,
};

/// Maximum distinct slots the §9.7 / 7.1 allocator emits before
/// erroring with `SlotOverflow`. Mirrors the validator's
/// max_operand_stack so any function the validator accepts can
/// in principle be allocated. Production refinement (spilling)
/// lands per §9.7 / 7.3.
pub const max_slots: u8 = 255;

pub const Allocation = struct {
    /// `slots[v]` is the physical slot id assigned to vreg `v`.
    /// Length matches `func.liveness.?.ranges.len`. Slot ids are
    /// dense from 0 (the first vreg's slot) up to `n_slots - 1`.
    slots: []const u8,
    /// Distinct slots used. Equal to `max(slots) + 1` (or 0 for
    /// the empty function). Drives the per-arch emit's stack-
    /// frame sizing.
    n_slots: u8,
};

/// Compute a greedy-local allocation for `func`. Requires
/// `func.liveness` to be populated (call
/// `liveness.compute(allocator, func)` and assign first).
pub fn compute(allocator: Allocator, func: *const ZirFunc) Error!Allocation {
    const live = func.liveness orelse return Error.LivenessMissing;
    if (live.ranges.len == 0) {
        return .{ .slots = &.{}, .n_slots = 0 };
    }

    var slots = try allocator.alloc(u8, live.ranges.len);
    errdefer allocator.free(slots);
    var n_slots: u8 = 0;

    // For each vreg in def_pc order (which `liveness.compute`
    // already produces — vreg ids are def-order), find the
    // smallest slot id not currently held by any earlier vreg
    // whose live range overlaps. "Overlaps" means the earlier
    // vreg's `last_use_pc` >= the current vreg's `def_pc`.
    for (live.ranges, 0..) |r, vreg| {
        const my_def = r.def_pc;
        // Build a one-bit-per-slot busy mask by walking earlier
        // vregs. max_slots = 255 fits in a u256 bit set; for
        // simplicity use a fixed-size [256]bool. The overlap
        // test is strict at the use edge: a vreg dying at pc=N
        // (last_use_pc=N) and a vreg born at pc=N (def_pc=N) do
        // NOT overlap — the use happens before the def at that
        // instr (e.g. `i32.add` pops two vregs and pushes one;
        // the result can reuse a popped slot). Standard LSRA
        // convention.
        var busy = [_]bool{false} ** (@as(usize, max_slots) + 1);
        for (live.ranges[0..vreg], 0..) |earlier, ev| {
            if (earlier.last_use_pc > my_def) {
                // earlier is still live past this def — its slot is busy.
                busy[slots[ev]] = true;
            }
        }
        // Find the smallest free slot.
        var assigned: u8 = max_slots;
        var s: u8 = 0;
        while (s < max_slots) : (s += 1) {
            if (!busy[s]) {
                assigned = s;
                break;
            }
        }
        if (assigned == max_slots) return Error.SlotOverflow;
        slots[vreg] = assigned;
        if (assigned + 1 > n_slots) n_slots = assigned + 1;
    }

    return .{ .slots = slots, .n_slots = n_slots };
}

/// Post-condition verifier (the §9.7 / 7.1 promise). Checks
/// that the allocation didn't violate liveness — every pair of
/// overlapping live ranges has distinct slot assignments.
pub fn verify(func: *const ZirFunc, alloc: Allocation) VerifyError!void {
    const live = func.liveness orelse return; // Nothing to verify
    if (alloc.slots.len != live.ranges.len) return VerifyError.SlotsLengthMismatch;
    for (alloc.slots) |s| {
        if (s >= alloc.n_slots) return VerifyError.SlotIndexExceedsCount;
    }
    // Pairwise overlap check. O(n²); for Phase-7 / 7.1 the
    // function sizes the regalloc sees are bounded by validator
    // limits (max_operand_stack = 1024 → at most ~1024 vregs in
    // straight-line code), so the quadratic cost is acceptable.
    // Production refinement (interval-tree-based check) is a
    // §9.7 / 7.3 follow-up if profiling demands it.
    for (live.ranges, 0..) |a, ai| {
        for (live.ranges[ai + 1 ..], ai + 1..) |b, bi| {
            // Strict overlap (use-before-def at shared pc is OK):
            // [a_def, a_use] overlaps [b_def, b_use] iff
            //   a_def < b_use AND b_def < a_use.
            const overlaps = (a.def_pc < b.last_use_pc) and (b.def_pc < a.last_use_pc);
            if (overlaps and alloc.slots[ai] == alloc.slots[bi]) {
                return VerifyError.OverlappingVregsShareSlot;
            }
        }
    }
}

pub fn deinit(allocator: Allocator, alloc: Allocation) void {
    if (alloc.slots.len != 0) allocator.free(alloc.slots);
}

// Suppress the unused-public-decl finding; reg_class is the
// upstream consumer hook for the next iteration.
comptime {
    _ = reg_class;
}

const testing = std.testing;
const liveness_mod = @import("../ir/liveness.zig");

fn buildFunc(allocator: Allocator, ops: []const zir.ZirInstr) !ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    errdefer f.deinit(allocator);
    for (ops) |o| try f.instrs.append(allocator, o);
    return f;
}

test "compute: empty function yields empty allocation" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };

    const a = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, a);
    try testing.expectEqual(@as(usize, 0), a.slots.len);
    try testing.expectEqual(@as(u8, 0), a.n_slots);
    try verify(&f, a);
}

test "compute: liveness missing returns LivenessMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // f.liveness intentionally null
    try testing.expectError(Error.LivenessMissing, compute(testing.allocator, &f));
}

test "compute: 3 sequential vregs share the same slot (no overlap)" {
    // i32.const 1 ; drop ; i32.const 2 ; drop ; i32.const 3 ; drop ; end
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .drop },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .drop },
        .{ .op = .@"i32.const", .payload = 3 },
        .{ .op = .drop },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);
    f.liveness = try liveness_mod.compute(testing.allocator, &f);
    defer if (f.liveness) |l| liveness_mod.deinit(testing.allocator, l);

    const a = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, a);

    try testing.expectEqual(@as(usize, 3), a.slots.len);
    try testing.expectEqual(@as(u8, 1), a.n_slots);
    try testing.expectEqual(@as(u8, 0), a.slots[0]);
    try testing.expectEqual(@as(u8, 0), a.slots[1]);
    try testing.expectEqual(@as(u8, 0), a.slots[2]);
    try verify(&f, a);
}

test "compute: 2 simultaneously-live vregs use distinct slots (binop pre-pop)" {
    // i32.const 1 ; i32.const 2 ; i32.add ; end
    // vreg 0 (def 0, last_use 2) overlaps vreg 1 (def 1, last_use 2);
    // result vreg 2 (def 2, last_use 3 = end) does not overlap
    // either of them (they died at pc 2).
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.add" },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);
    f.liveness = try liveness_mod.compute(testing.allocator, &f);
    defer if (f.liveness) |l| liveness_mod.deinit(testing.allocator, l);

    const a = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, a);

    try testing.expectEqual(@as(usize, 3), a.slots.len);
    // vregs 0 + 1 overlap → distinct slots 0, 1.
    try testing.expectEqual(@as(u8, 0), a.slots[0]);
    try testing.expectEqual(@as(u8, 1), a.slots[1]);
    // vreg 2 reuses slot 0 (vreg 0 died at pc 2).
    try testing.expectEqual(@as(u8, 0), a.slots[2]);
    try testing.expectEqual(@as(u8, 2), a.n_slots);
    try verify(&f, a);
}

test "compute: 4-deep stack uses 4 slots" {
    // i32.const 1 ; i32.const 2 ; i32.const 3 ; i32.const 4 ;
    // drop ; drop ; drop ; drop ; end
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.const", .payload = 3 },
        .{ .op = .@"i32.const", .payload = 4 },
        .{ .op = .drop },
        .{ .op = .drop },
        .{ .op = .drop },
        .{ .op = .drop },
        .{ .op = .@"end" },
    });
    defer f.deinit(testing.allocator);
    f.liveness = try liveness_mod.compute(testing.allocator, &f);
    defer if (f.liveness) |l| liveness_mod.deinit(testing.allocator, l);

    const a = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, a);

    try testing.expectEqual(@as(usize, 4), a.slots.len);
    try testing.expectEqual(@as(u8, 4), a.n_slots);
    try verify(&f, a);
}

test "verify: rejects overlapping vregs forced to share a slot" {
    // Manually construct a liveness with two overlapping ranges
    // and an allocation that puts both in slot 0 (a bug the
    // greedy allocator wouldn't produce, but the verifier must
    // catch it for downstream consumers that build allocations
    // by other means).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &[_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 5 },
        .{ .def_pc = 2, .last_use_pc = 4 }, // overlaps with vreg 0
    } };
    const bad: Allocation = .{ .slots = &[_]u8{ 0, 0 }, .n_slots = 1 };
    try testing.expectError(VerifyError.OverlappingVregsShareSlot, verify(&f, bad));
}

test "verify: slot index exceeding n_slots fails" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &[_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const bad: Allocation = .{ .slots = &[_]u8{5}, .n_slots = 1 };
    try testing.expectError(VerifyError.SlotIndexExceedsCount, verify(&f, bad));
}

test "verify: slots length mismatch fails" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &[_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const bad: Allocation = .{ .slots = &[_]u8{0}, .n_slots = 1 };
    try testing.expectError(VerifyError.SlotsLengthMismatch, verify(&f, bad));
}
