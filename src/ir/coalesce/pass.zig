//! Post-regalloc slot-aliasing coalescer (§9.8b / 8b.1 per
//! ADR-0035).
//!
//! Side-table metadata pass: walks the ZIR instr stream after
//! regalloc has assigned slots and records `CoalesceRecord`
//! entries for MOV-shaped emit sites where `slots[src_vreg]
//! == slots[dst_vreg]` and the alias is safe to elide. The
//! emit pass queries `func.coalesced_movs` before each MOV
//! emission and skips redundant slots.
//!
//! **Scaffolding scope (8b.1-c, this commit)**:
//! framework only — populates `func.coalesced_movs` with an
//! empty slice. Real detection logic + emit-side query
//! mechanism lands incrementally in 8b.1-d alongside
//! bench-delta evidence per ADR-0032's bench-driven
//! discipline. The 8b.1-a survey at
//! `private/notes/p8-8b1-coalescer-survey.md` identified the
//! candidate ZirOp catalogue (`local.tee` post-regalloc,
//! end-of-block multi-value merges, return-value marshalling
//! from `end`, call-arg setup); this MVP intentionally ships
//! ZERO detected records to keep the pass-frame change
//! surgical. Subsequent chunks layer in detection per-op.
//!
//! Caller-owned: `func.coalesced_movs` slice must be freed
//! via `deinitArtifacts` before `func.deinit` (mirror of
//! `src/ir/hoist/pass.zig:deinitArtifacts`).
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("../zir.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const CoalesceRecord = zir.CoalesceRecord;

pub const Error = error{OutOfMemory};

/// Run the coalescer pass. Pre-conditions: regalloc has assigned
/// per-vreg slots; the caller passes the resulting `slots[]`
/// slice directly (Zone 2 → Zone 1 boundary preserved per
/// `.claude/rules/zone_deps.md`; this pass is Zone 1, the
/// `regalloc.Allocation` type lives in Zone 2). Post-condition:
/// `func.coalesced_movs` slot installed (may be empty —
/// scaffolding scope per `pass.zig` module doc).
pub fn run(allocator: Allocator, func: *ZirFunc, slots: []const u16) Error!void {
    _ = slots; // reserved for Phase 15 detection lift per ADR-0036

    // §9.8b / 8b.1 (closed per ADR-0036): scaffolding-only.
    // Phase 15 layers the operand-stack vreg-numbering
    // simulation (def-order matching liveness's) + same-slot
    // check against `slots[]` once 8b.2's allocator reshape
    // exposes natural same-slot sites.
    _ = isCoalesceCandidate; // keep referenced; unused this commit

    var records: std.ArrayList(CoalesceRecord) = .empty;
    errdefer records.deinit(allocator);

    func.coalesced_movs = try records.toOwnedSlice(allocator);
}

/// §9.8b / 8b.1 candidate-op predicate (per ADR-0035 +
/// 8b.1-d design exploration). Selects ZirOps that EMIT a
/// MOV-shaped instruction sequence at emit time when the
/// op's src and dst vregs happen to share a slot
/// post-regalloc. Conservative MVP catalogue:
///
/// - `local.tee`: redundant store-then-keep when input vreg
///   and output vreg share slot (the per-iteration store is
///   wasted work).
/// - `local.get` (post-hoist synthetic local): pairs with a
///   prologue `local.set` per ADR-0031; coalescer detects
///   the pair via `func.hoisted_constants` inspection.
/// - `local.set` (post-hoist prologue): the inverse pair.
/// - `select`: post-regalloc the cmov often coalesces both
///   arms onto the same slot.
///
/// Catalogue grows incrementally as bench-delta surfaces
/// wins (per ADR-0035 Consequence "Catalogue maintenance").
/// Per `single_slot_dual_meaning.md` the candidate set lives
/// in one place (this function), not split per arch.
pub fn isCoalesceCandidate(op: zir.ZirOp) bool {
    return switch (op) {
        .@"local.tee", .@"local.get", .@"local.set", .@"select" => true,
        else => false,
    };
}

/// Free `func.coalesced_movs`. No-op when slot is null or
/// empty. Called by `compile.zig:deinitFuncResult` symmetric
/// to `hoist.deinitArtifacts`.
pub fn deinitArtifacts(allocator: Allocator, func: *ZirFunc) void {
    if (func.coalesced_movs) |records| {
        if (records.len != 0) allocator.free(records);
        func.coalesced_movs = null;
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "coalesce.run: scaffolding installs empty records on a tiny ZirFunc" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    defer deinitArtifacts(testing.allocator, &f);

    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .end });

    const slots = [_]u16{0};

    try testing.expect(f.coalesced_movs == null);
    try run(testing.allocator, &f, &slots);
    try testing.expect(f.coalesced_movs != null);
    try testing.expectEqual(@as(usize, 0), f.coalesced_movs.?.len);
}

test "coalesce.deinitArtifacts: no-op on null slot" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    try testing.expect(f.coalesced_movs == null);
    deinitArtifacts(testing.allocator, &f);
    try testing.expect(f.coalesced_movs == null);
}

test "isCoalesceCandidate: MVP catalogue accepts local.tee/get/set + select" {
    try testing.expect(isCoalesceCandidate(.@"local.tee"));
    try testing.expect(isCoalesceCandidate(.@"local.get"));
    try testing.expect(isCoalesceCandidate(.@"local.set"));
    try testing.expect(isCoalesceCandidate(.@"select"));
    try testing.expect(!isCoalesceCandidate(.@"i32.const"));
    try testing.expect(!isCoalesceCandidate(.end));
    try testing.expect(!isCoalesceCandidate(.@"i32.add"));
    try testing.expect(!isCoalesceCandidate(.@"call"));
    try testing.expect(!isCoalesceCandidate(.@"br_table"));
}

test "coalesce.deinitArtifacts: frees populated records" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    const records = try testing.allocator.alloc(CoalesceRecord, 2);
    records[0] = .{ .instr_pc = 5, .slot = 3, .reason = .same_slot_alias };
    records[1] = .{ .instr_pc = 12, .slot = 7, .reason = .same_slot_alias };
    f.coalesced_movs = records;

    deinitArtifacts(testing.allocator, &f);
    try testing.expect(f.coalesced_movs == null);
}
