//! JIT greedy-local register allocator (§9.7 / 7.1).
//!
//! Reads `ZirFunc.liveness.?.ranges` (populated upstream by
//! `src/ir/liveness.zig` per §9.5 / 5.4) and assigns each vreg
//! the smallest physical slot id not held by any earlier vreg
//! whose live range overlaps. Output is a dense
//! `Allocation { slots, n_slots }` consumed by §9.7 / 7.3's
//! emit pass (which maps slot id → physical register via the
//! per-arch ABI table from §9.7 / 7.2).
//!
//! W54-class lesson made structural (per `textbook_survey.md`
//! Guard 4 + ROADMAP §4.2 / P13): liveness drives regalloc, not
//! the other way around. Liveness is a **const input** here;
//! `verify` then asserts the post-condition (no two overlapping
//! live ranges share a slot) before downstream emit ever sees
//! the allocation. v1's W54 root cause was regalloc-stage IR
//! shape implicitly assuming an absent liveness invariant; the
//! split-input + post-condition shape here makes that
//! impossible by construction.
//!
//! Phase 7.1 scope: slot-only assignment + verifier. All vregs
//! treated as a single pool; per-class slot pools land alongside
//! §9.7 / 7.2 ABI work (`reg_class.zig`'s `RegClassInfo` table
//! becomes load-bearing then). Spilling is a §9.7 / 7.3
//! follow-up — the allocator may grow `n_slots` up to
//! `max_slots`; `SlotOverflow` surfaces when the validator's
//! max_operand_stack would otherwise exceed it.
//!
//! Lifetime: caller-allocated; pair `compute` with `deinit`.
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
    SlotIndexExceedsCount,
    OverlappingVregsShareSlot,
};

/// Cap on distinct slots before `compute` returns `SlotOverflow`.
/// Mirrors the validator's `max_operand_stack` (1024) → bounded
/// in straight-line code, but we use a u8 dense slot id so the
/// hard cap is 255 here. Spilling (§9.7 / 7.3+) widens this.
pub const max_slots: u8 = 255;

/// Resolved slot — what physical home a vreg lives in.
/// `reg`'s u8 indexes the per-arch `allocatable_gprs` /
/// `allocatable_v_regs` table (interpreted by per-arch
/// `slotToReg` / `fpSlotToReg`). `spill`'s u32 is a byte
/// offset within the function's spill frame (8-aligned).
pub const Slot = union(enum) {
    reg: u8,
    spill: u32,
};

pub const Allocation = struct {
    /// `slots[v]` is the dense physical slot id assigned to
    /// vreg `v`. Length matches `func.liveness.?.ranges.len`.
    /// Slot ids are 0..n_slots-1 (no holes).
    slots: []const u8,
    /// Distinct slots used. `max(slots) + 1`, or 0 for the
    /// empty-function case. Drives stack-frame sizing in the
    /// per-arch emit pass.
    n_slots: u8,
    /// Per-arch pool size: slot ids `< max_reg_slots` resolve to
    /// `Slot.reg`; ids `>= max_reg_slots` resolve to
    /// `Slot.spill` (per ADR-0018).
    ///
    /// Default = 9 (ARM64 GPR allocatable pool post-ADR-0017
    /// sub-2d-ii: caller-scratch X9..X13 (5) + callee-saved
    /// X20..X23 (4) = 9 regs; X14/X15 reserved as spill stages,
    /// X19 reserved as runtime_ptr save, X24..X28 reserved as
    /// runtime invariants). Per-class regalloc is a Phase 8
    /// follow-up; today FP-class vregs use the same threshold,
    /// which under-utilises the V-register pool but is correct.
    max_reg_slots: u8 = 9,

    /// Resolve a vreg's home: register slot or spill offset.
    pub fn slot(self: Allocation, vreg: usize) Slot {
        const id = self.slots[vreg];
        if (id < self.max_reg_slots) return .{ .reg = id };
        return .{ .spill = (@as(u32, id) - self.max_reg_slots) * 8 };
    }

    /// Total spill-frame bytes required by this allocation.
    /// Adds to the function's stack frame in the prologue.
    pub fn spillBytes(self: Allocation) u32 {
        if (self.n_slots <= self.max_reg_slots) return 0;
        return (@as(u32, self.n_slots) - self.max_reg_slots) * 8;
    }
};

/// Greedy-local allocation. `func.liveness` MUST be populated
/// (call `liveness.compute` and assign first); otherwise returns
/// `LivenessMissing`.
pub fn compute(allocator: Allocator, func: *const ZirFunc) Error!Allocation {
    const live = func.liveness orelse return Error.LivenessMissing;
    if (live.ranges.len == 0) return .{ .slots = &.{}, .n_slots = 0 };

    var slots = try allocator.alloc(u8, live.ranges.len);
    errdefer allocator.free(slots);
    var n_slots: u8 = 0;

    // Scan vregs in def_pc order (vreg ids are def-order by
    // `liveness.compute`'s contract). For each vreg, mark which
    // slots are still busy (held by an earlier vreg whose
    // last_use_pc strictly outlives this vreg's def_pc), then
    // pick the smallest free slot.
    //
    // Edge convention: a vreg dying at pc=N (last_use_pc=N) and
    // a vreg born at pc=N (def_pc=N) do NOT overlap — the use
    // happens before the def at that instr (e.g. `i32.add`
    // pops two and pushes one; result reuses a popped slot).
    // This is standard LSRA practice.
    var busy: [@as(usize, max_slots) + 1]bool = undefined;
    for (live.ranges, 0..) |r, vreg| {
        @memset(&busy, false);
        for (live.ranges[0..vreg], 0..) |earlier, ev| {
            if (earlier.last_use_pc > r.def_pc) busy[slots[ev]] = true;
        }
        var s: u8 = 0;
        const assigned: u8 = while (s < max_slots) : (s += 1) {
            if (!busy[s]) break s;
        } else return Error.SlotOverflow;
        slots[vreg] = assigned;
        if (assigned + 1 > n_slots) n_slots = assigned + 1;
    }

    return .{ .slots = slots, .n_slots = n_slots };
}

/// Post-condition: every pair of overlapping live ranges holds
/// distinct slot assignments AND every slot id is < n_slots AND
/// the slot vector matches the live-range count. Run after every
/// `compute` so a regalloc bug surfaces immediately, not in
/// downstream emit.
///
/// O(n²) pairwise check. Acceptable at Phase 7 sizes (validator
/// caps max_operand_stack at 1024, so at most ~1024 vregs in
/// straight-line code). Interval-tree refinement is a §9.7 / 7.3
/// follow-up if a profile demands it.
pub fn verify(func: *const ZirFunc, alloc: Allocation) VerifyError!void {
    const live = func.liveness orelse return;
    if (alloc.slots.len != live.ranges.len) return VerifyError.SlotsLengthMismatch;
    for (alloc.slots) |s| {
        if (s >= alloc.n_slots) return VerifyError.SlotIndexExceedsCount;
    }
    for (live.ranges, 0..) |a, ai| {
        for (live.ranges[ai + 1 ..], ai + 1..) |b, bi| {
            // Strict half-open overlap: [a.def, a.use) ∩ [b.def, b.use).
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

// reg_class is the upstream-class-aware refinement hook used by
// §9.7 / 7.2's per-arch wiring; reference it so `no_unused`
// linting is happy until the wiring lands.
comptime {
    _ = reg_class;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn freshFunc() ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    return ZirFunc.init(0, sig, &.{});
}

test "compute: empty liveness yields empty allocation" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(usize, 0), alloc.slots.len);
    try testing.expectEqual(@as(u8, 0), alloc.n_slots);
}

test "compute: missing liveness returns LivenessMissing" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try testing.expectError(Error.LivenessMissing, compute(testing.allocator, &f));
}

test "compute: two non-overlapping ranges share slot 0" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u8, 1), alloc.n_slots);
    try testing.expectEqual(@as(u8, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u8, 0), alloc.slots[1]);
    try verify(&f, alloc);
}

test "compute: two overlapping ranges get distinct slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 5 },
        .{ .def_pc = 1, .last_use_pc = 4 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u8, 2), alloc.n_slots);
    try testing.expectEqual(@as(u8, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u8, 1), alloc.slots[1]);
    try verify(&f, alloc);
}

test "compute: shared-edge (use=def at same pc) does not count as overlap" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 5 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    // Second vreg born at pc=2 reuses first's slot since first
    // dies at pc=2.
    try testing.expectEqual(@as(u8, 1), alloc.n_slots);
    try testing.expectEqual(alloc.slots[0], alloc.slots[1]);
    try verify(&f, alloc);
}

test "compute: three overlapping ranges fan out to distinct slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 9 },
        .{ .def_pc = 1, .last_use_pc = 9 },
        .{ .def_pc = 2, .last_use_pc = 9 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u8, 3), alloc.n_slots);
    try testing.expectEqual(@as(u8, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u8, 1), alloc.slots[1]);
    try testing.expectEqual(@as(u8, 2), alloc.slots[2]);
    try verify(&f, alloc);
}

test "verify: rejects allocation with slot index >= n_slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }};
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u8{5};
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 1 };
    try testing.expectError(VerifyError.SlotIndexExceedsCount, verify(&f, bad));
}

test "verify: rejects mismatched slot/range lengths" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }};
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u8{ 0, 1 };
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 2 };
    try testing.expectError(VerifyError.SlotsLengthMismatch, verify(&f, bad));
}

test "verify: rejects overlapping ranges sharing a slot" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 5 },
        .{ .def_pc = 1, .last_use_pc = 4 },
    };
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u8{ 0, 0 };
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 1 };
    try testing.expectError(VerifyError.OverlappingVregsShareSlot, verify(&f, bad));
}

// ========================================================
// ADR-0018: Slot resolution + spill-frame sizing
// ========================================================

test "Allocation.slot: id < max_reg_slots resolves to .reg" {
    const slots = [_]u8{ 0, 5, 9 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 10, .max_reg_slots = 10 };
    try testing.expectEqual(Slot{ .reg = 0 }, alloc.slot(0));
    try testing.expectEqual(Slot{ .reg = 5 }, alloc.slot(1));
    try testing.expectEqual(Slot{ .reg = 9 }, alloc.slot(2));
}

test "Allocation.slot: id >= max_reg_slots resolves to .spill at 8-aligned offset" {
    const slots = [_]u8{ 9, 10, 11, 12 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 13, .max_reg_slots = 10 };
    try testing.expectEqual(Slot{ .reg = 9 }, alloc.slot(0));
    try testing.expectEqual(Slot{ .spill = 0 }, alloc.slot(1));
    try testing.expectEqual(Slot{ .spill = 8 }, alloc.slot(2));
    try testing.expectEqual(Slot{ .spill = 16 }, alloc.slot(3));
}

test "Allocation.spillBytes: 0 when n_slots fits in pool" {
    const slots = [_]u8{ 0, 1 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 2, .max_reg_slots = 10 };
    try testing.expectEqual(@as(u32, 0), alloc.spillBytes());
}

test "Allocation.spillBytes: 8-byte stride past pool size" {
    const slots = [_]u8{ 9, 10, 11, 12 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 13, .max_reg_slots = 10 };
    try testing.expectEqual(@as(u32, 24), alloc.spillBytes()); // (13-10)*8
}
