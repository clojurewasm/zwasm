//! Per-Instance exception-handler table (ADR-0114 D3).
//!
//! Consumed at unwind time by `shared/unwind.zig` (10.E-codegen-2
//! follow-on) which walks the frame chain calling `lookup(pc,
//! throw_tag_idx)` at each frame's throw site. Built at JIT-emit
//! time by the per-arch `op_exception_handling.zig` (ADR-0114 D2 /
//! 10.E-codegen-4 follow-on) as it encounters `try_table` bodies.
//!
//! Storage shape (per ADR-0114 D3): a sequence of `HandlerEntry`
//! records, each capturing one catch clause within a try_table
//! body. The table is consulted by the FP-walk unwinder using the
//! `(throw_pc, throw_tag_idx)` pair as the key; the first matching
//! entry (innermost-try_table-first by insertion order) wins.
//!
//! ADR-0114 D3 cites the eventual `*TagInstance` pointer-equality
//! key (D7), but the interp already keys on `tag_idx` (the
//! module's tag-section index) per `feature/exception_handling/
//! exception.zig` until cross-module tag identity lands. The
//! codegen-side table follows the interp's keying for now —
//! migrating both sides together when `*TagInstance` resolution
//! ships.
//!
//! For Wasm 3.0 / 10.E milestones this storage is per-Instance
//! and immutable after JIT compile (no run-time mutation); the
//! linear-scan lookup is acceptable until the per-function
//! sorted-by-PC binary-search optimisation lands at Phase 11+.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

/// Catch clause flavor — mirrors `ir/zir.zig::CatchKind` so the
/// per-arch emit path can copy through without re-encoding. The
/// `_ref` variants additionally push the caught `exnref` onto the
/// landing-pad's operand stack.
pub const CatchKind = enum(u8) {
    catch_ = 0,
    catch_ref = 1,
    catch_all = 2,
    catch_all_ref = 3,
};

/// One entry in the exception table: a single catch clause within
/// a try_table body. The PC range `[pc_start, pc_end)` matches
/// any throw site whose PC lies within it; this lets the FP-walk
/// unwinder identify the active try_table by PC alone.
///
/// `tag_idx == null` is required for `catch_all` / `catch_all_ref`
/// flavors and forbidden for the `catch_` / `catch_ref` flavors.
/// The constructor enforces the invariant.
pub const HandlerEntry = struct {
    pc_start: u32,
    pc_end: u32,
    tag_idx: ?u32,
    landing_pad_pc: u32,
    kind: CatchKind,
};

/// Result of a successful `lookup`: the landing-pad PC plus the
/// catch flavor (so the unwinder knows whether to push the
/// exnref).
pub const HandlerMatch = struct {
    landing_pad_pc: u32,
    kind: CatchKind,
};

/// Per-Instance exception table. Immutable after JIT emit.
pub const ExceptionTable = struct {
    entries: []const HandlerEntry,

    /// Lookup the handler for a `(throw_pc, throw_tag_idx)` pair.
    /// Returns the first matching entry per the
    /// innermost-try_table-first insertion order; null if no
    /// catch clause matches (= unwind continues to caller frame
    /// per ADR-0114 D5).
    ///
    /// Matching rule (ADR-0114 D3 + Wasm 3.0 §4.5.10 try_table):
    ///   - PC must lie in `[pc_start, pc_end)`.
    ///   - `catch_all` / `catch_all_ref`: matches any tag.
    ///   - `catch_` / `catch_ref`: matches iff
    ///     `entry.tag_idx.? == throw_tag_idx`.
    pub fn lookup(self: ExceptionTable, pc: u32, throw_tag_idx: u32) ?HandlerMatch {
        for (self.entries) |e| {
            if (pc < e.pc_start or pc >= e.pc_end) continue;
            const matches = switch (e.kind) {
                .catch_all, .catch_all_ref => true,
                .catch_, .catch_ref => e.tag_idx != null and e.tag_idx.? == throw_tag_idx,
            };
            if (matches) return .{
                .landing_pad_pc = e.landing_pad_pc,
                .kind = e.kind,
            };
        }
        return null;
    }
};

/// Per-arch emit-time bookkeeping for an open `try_table` block.
/// One entry pushed at `try_table.emit`, popped + patched at the
/// matching `end` op (the `pc_end` placeholder originally written
/// by `try_table.emit` becomes the real post-inner-block PC).
///
/// `labels_depth` is the depth of the per-arch label stack at the
/// time this try_table pushed its inner-block label (= the index of
/// the pushed label, 1-indexed; equivalently `labels.items.len`
/// immediately after the push). The matching `end` identifies the
/// closing try_table by comparing the popped label's stack position
/// to this field.
pub const OpenTryTable = struct {
    labels_depth: u32,
    entry_start: u32,
    entry_count: u32,
};

/// Build-time accumulator for the exception table. The per-arch
/// `op_exception_handling.zig` instantiates one per function being
/// compiled, calls `add(...)` as it lowers each catch clause, and
/// calls `finalize()` to produce the per-Instance `ExceptionTable`.
pub const Builder = struct {
    entries: std.ArrayList(HandlerEntry),

    pub const empty: Builder = .{ .entries = .empty };

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Append a handler entry. Enforces the
    /// `kind ↔ tag_idx-presence` invariant (`catch_*` requires a
    /// `tag_idx`; `catch_all*` forbids one).
    pub fn add(
        self: *Builder,
        allocator: std.mem.Allocator,
        entry: HandlerEntry,
    ) !void {
        switch (entry.kind) {
            .catch_, .catch_ref => std.debug.assert(entry.tag_idx != null),
            .catch_all, .catch_all_ref => std.debug.assert(entry.tag_idx == null),
        }
        std.debug.assert(entry.pc_start < entry.pc_end);
        try self.entries.append(allocator, entry);
    }

    /// Freeze the builder into an `ExceptionTable`. The returned
    /// table aliases the builder's allocation; the caller owns
    /// the lifetime via `deinit`.
    pub fn finalize(self: *const Builder) ExceptionTable {
        return .{ .entries = self.entries.items };
    }
};

// ---------------------------------------------------------------------
// Unit tests — pure-data lookup; no per-arch dependency.
// ---------------------------------------------------------------------

const testing = std.testing;

test "exception_table: empty table — lookup always returns null" {
    const t: ExceptionTable = .{ .entries = &.{} };
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(0, 0));
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(100, 42));
}

test "exception_table: catch_ matches exact tag_idx, misses on mismatch" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 5,
        .landing_pad_pc = 200,
        .kind = .catch_,
    });
    const t = b.finalize();

    // Matching tag → hit.
    const hit = t.lookup(50, 5).?;
    try testing.expectEqual(@as(u32, 200), hit.landing_pad_pc);
    try testing.expectEqual(CatchKind.catch_, hit.kind);

    // Wrong tag → miss.
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(50, 6));
}

test "exception_table: catch_all matches any tag in PC range" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 10,
        .pc_end = 50,
        .tag_idx = null,
        .landing_pad_pc = 300,
        .kind = .catch_all,
    });
    const t = b.finalize();

    // Any tag in range → hit.
    try testing.expectEqual(@as(u32, 300), t.lookup(20, 0).?.landing_pad_pc);
    try testing.expectEqual(@as(u32, 300), t.lookup(20, 999).?.landing_pad_pc);

    // Out of range → miss.
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(5, 0));
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(50, 0));
}

test "exception_table: catch_ref / catch_all_ref propagate through HandlerMatch.kind" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 7,
        .landing_pad_pc = 400,
        .kind = .catch_ref,
    });
    try b.add(testing.allocator, .{
        .pc_start = 100,
        .pc_end = 200,
        .tag_idx = null,
        .landing_pad_pc = 500,
        .kind = .catch_all_ref,
    });
    const t = b.finalize();

    try testing.expectEqual(CatchKind.catch_ref, t.lookup(50, 7).?.kind);
    try testing.expectEqual(CatchKind.catch_all_ref, t.lookup(150, 99).?.kind);
}

test "exception_table: insertion-order wins (innermost try_table first)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    // Outer try_table: PC range [0, 1000), catch_all → landing 999.
    // Inner try_table: PC range [100, 200), catch_ tag=3 → landing 150.
    // The INNER entry is added FIRST per the
    // innermost-try_table-first insertion discipline (the per-arch
    // emit walks try_table bodies depth-first).
    try b.add(testing.allocator, .{
        .pc_start = 100,
        .pc_end = 200,
        .tag_idx = 3,
        .landing_pad_pc = 150,
        .kind = .catch_,
    });
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 1000,
        .tag_idx = null,
        .landing_pad_pc = 999,
        .kind = .catch_all,
    });
    const t = b.finalize();

    // PC inside inner range + matching tag → inner wins.
    try testing.expectEqual(@as(u32, 150), t.lookup(150, 3).?.landing_pad_pc);

    // PC inside inner range + non-matching tag → falls through to outer catch_all.
    try testing.expectEqual(@as(u32, 999), t.lookup(150, 4).?.landing_pad_pc);

    // PC outside inner range → only outer can match.
    try testing.expectEqual(@as(u32, 999), t.lookup(50, 3).?.landing_pad_pc);
}

test "exception_table: PC at pc_end is exclusive (matches the contract)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 10,
        .pc_end = 20,
        .tag_idx = null,
        .landing_pad_pc = 100,
        .kind = .catch_all,
    });
    const t = b.finalize();

    try testing.expectEqual(@as(u32, 100), t.lookup(10, 0).?.landing_pad_pc);
    try testing.expectEqual(@as(u32, 100), t.lookup(19, 0).?.landing_pad_pc);
    try testing.expectEqual(@as(?HandlerMatch, null), t.lookup(20, 0));
}

test "exception_table: Builder.finalize aliases the appended entries (no copy)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);

    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 1,
        .landing_pad_pc = 50,
        .kind = .catch_,
    });
    const t = b.finalize();
    try testing.expectEqual(@as(usize, 1), t.entries.len);
    try testing.expectEqual(@as(u32, 50), t.entries[0].landing_pad_pc);
}
