//! FP-walk unwind algorithm (ADR-0114 D5).
//!
//! Cross-platform: Mac aarch64 / Linux x86_64 / Win64 use the
//! SAME frame-chain walker — FP register conventions are
//! ABI-pinned per platform (AAPCS64: X29; SysV / Win64: RBP)
//! but the walk shape is platform-agnostic. The arch-specific
//! glue (which FP register to read, how to materialise the
//! frame chain from registers + memory) lives in the
//! `zwasm_throw` trampoline (10.E-codegen-3 follow-on); this
//! file owns the platform-agnostic algorithm.
//!
//! Algorithm (per ADR-0114 D5):
//!
//!   pc = current_throw_site
//!   fp = current_frame_pointer
//!   loop:
//!       handler = table.lookup(pc, throw_tag_idx)
//!       if handler != null:
//!           return .{ landing_pad_pc, kind, handler_fp = fp }
//!       (caller_fp, caller_pc) = load_frame_chain(fp)
//!       if caller_fp == 0:  // top of stack
//!           return .uncaught
//!       fp = caller_fp
//!       pc = caller_pc
//!
//! For Phase 10 the table is per-Runtime; cross-instance frames
//! resolve to the same table (single-instance throws). Phase 11+
//! cross-instance EH adds per-frame instance dispatch (each
//! frame's load_frame_chain return includes the callee's
//! Instance pointer → that Instance's exception_table). Until
//! then, the single-table call shape suffices.
//!
//! INVARIANT: the walker has NO allocator calls / NO host-call
//! invocations / NO signal-check branches between
//! initial entry and the .uncaught or .handler return —
//! aligning with the safepoint-free unwind invariant cited
//! by ADR-0114 D5 (the unwinder shares the
//! "no allocator between teardown and landing" property with
//! tail-call per ADR-0112 D7).
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const exception_table = @import("exception_table.zig");

pub const ExceptionTable = exception_table.ExceptionTable;
pub const CatchKind = exception_table.CatchKind;

/// One frame-chain link as observed by the unwinder. Materialised
/// per-arch by the trampoline (AAPCS64 reads `[X29, #0]` for
/// caller's saved FP + `[X29, #8]` for caller's saved LR; SysV
/// reads `[RBP]` for caller's saved RBP + `[RBP + 8]` for the
/// return address).
///
/// `caller_fp == 0` signals top-of-stack (= no caller frame; the
/// throw escapes the Wasm execution boundary → uncaught exception
/// per ADR-0114 D5).
pub const FrameLink = struct {
    caller_fp: usize,
    caller_pc: u32,
    /// Absolute return address (= raw saved LR / RIP, pre-normalize).
    /// The walker carries this so a handler match in this frame can
    /// return the absolute PC, letting the trampoline look up the
    /// catching function's `code_map.Entry` for `start_addr` +
    /// `frame_bytes` (needed to compute the absolute landing-pad
    /// JMP target and the SP-restore amount).
    caller_abs_pc: usize,
};

/// Function pointer that materialises one frame-chain step.
/// Caller (the trampoline) constructs this once per unwind and
/// passes it to `walk`. The synthetic-test driver supplies an
/// in-memory implementation; the production trampoline supplies
/// the load-from-frame-prefix implementation.
pub const LoadFrameChainFn = *const fn (fp: usize, ctx: ?*anyopaque) ?FrameLink;

pub const FrameChainLoader = struct {
    load: LoadFrameChainFn,
    ctx: ?*anyopaque = null,
};

/// Successful catch outcome.
pub const HandlerLanding = struct {
    landing_pad_pc: u32,
    kind: CatchKind,
    /// FP at the catching frame — the trampoline restores SP to
    /// this frame's prologue boundary before jumping to
    /// `landing_pad_pc`.
    handler_fp: usize,
    /// Absolute PC inside the catching function at the moment the
    /// handler matched (= the throw-site call's saved-LR for the
    /// catching frame, OR `throw_site_addr` if the handler hit in
    /// the throwing function itself). The trampoline does
    /// `code_map.lookup(handler_abs_pc)` to recover the catching
    /// function's `start_addr` + `frame_bytes` for the SP-restore
    /// and absolute landing-pad JMP target.
    handler_abs_pc: usize,
};

/// Unwind walk result. `.uncaught` propagates to the
/// outermost Wasm boundary and triggers the host's uncaught-
/// exception trap (per ADR-0114 D5 + Wasm 3.0 §4.5.10).
pub const UnwindResult = union(enum) {
    handler: HandlerLanding,
    uncaught,
};

/// Walk the frame chain from `(initial_pc, initial_fp)` looking
/// for a handler matching `throw_tag_idx`. Stops at the first
/// matching handler (= innermost-try_table-wins per ADR-0114 D5
/// + Wasm 3.0 §4.5.10).
///
/// `max_depth` bounds the walk to detect corrupted frame chains
/// (a cycle would otherwise loop forever). The trampoline sets
/// it to the Runtime's configured Wasm call-stack cap.
pub fn walk(
    table: ExceptionTable,
    throw_tag_idx: u32,
    initial_pc: u32,
    initial_abs_pc: usize,
    initial_fp: usize,
    loader: FrameChainLoader,
    max_depth: u32,
) UnwindResult {
    var pc = initial_pc;
    var abs_pc = initial_abs_pc;
    var fp = initial_fp;
    var depth: u32 = 0;
    while (depth < max_depth) : (depth += 1) {
        if (table.lookup(pc, throw_tag_idx)) |hit| {
            return .{ .handler = .{
                .landing_pad_pc = hit.landing_pad_pc,
                .kind = hit.kind,
                .handler_fp = fp,
                .handler_abs_pc = abs_pc,
            } };
        }
        const link = loader.load(fp, loader.ctx) orelse return .uncaught;
        if (link.caller_fp == 0) return .uncaught;
        fp = link.caller_fp;
        pc = link.caller_pc;
        abs_pc = link.caller_abs_pc;
    }
    // Depth exhausted — treat as uncaught. The trampoline
    // distinguishes this from a clean top-of-stack via the
    // depth counter (Phase 11+ if diagnostic granularity warrants).
    return .uncaught;
}

// ---------------------------------------------------------------------
// Unit tests — pure-algorithm; synthetic frame chains constructed
// inline. No JIT emit / no actual stack walk required.
// ---------------------------------------------------------------------

const testing = std.testing;
const Builder = exception_table.Builder;

/// Synthetic frame-chain backing for tests. Maps `fp → FrameLink`
/// via an array lookup keyed on FP-as-index.
const SyntheticFrames = struct {
    links: []const ?FrameLink,

    fn loadFn(fp: usize, ctx: ?*anyopaque) ?FrameLink {
        const self: *const SyntheticFrames = @ptrCast(@alignCast(ctx.?));
        if (fp >= self.links.len) return null;
        return self.links[fp];
    }

    fn loader(self: *const SyntheticFrames) FrameChainLoader {
        return .{ .load = SyntheticFrames.loadFn, .ctx = @constCast(self) };
    }
};

test "unwind: matching handler in current frame → returns handler immediately" {
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

    // No frame chain needed — handler hits at the initial frame.
    const frames: SyntheticFrames = .{ .links = &.{} };
    const result = walk(t, 5, 50, 0, 1, frames.loader(), 16);

    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 200), h.landing_pad_pc);
            try testing.expectEqual(CatchKind.catch_, h.kind);
            try testing.expectEqual(@as(usize, 1), h.handler_fp);
        },
        .uncaught => try testing.expect(false),
    }
}

test "unwind: no handler in any frame → uncaught (caller_fp == 0 terminates)" {
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

    // 2-frame chain; throw tag is 99 (no match at any pc).
    // fp=2 → caller fp=1 ; fp=1 → caller fp=0 (top).
    const frames: SyntheticFrames = .{ .links = &.{
        null,
        .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 },
        .{ .caller_fp = 1, .caller_pc = 50, .caller_abs_pc = 50 },
    } };
    const result = walk(t, 99, 50, 0, 2, frames.loader(), 16);
    try testing.expectEqual(UnwindResult.uncaught, result);
}

test "unwind: walks to caller frame and finds handler there" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    // Inner frame's PC range = [0, 100), tag=99 (won't match throw of tag=5).
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = 99,
        .landing_pad_pc = 100,
        .kind = .catch_,
    });
    // Caller's PC range = [500, 600), tag=5 → matches throw.
    try b.add(testing.allocator, .{
        .pc_start = 500,
        .pc_end = 600,
        .tag_idx = 5,
        .landing_pad_pc = 555,
        .kind = .catch_,
    });
    const t = b.finalize();

    // Inner frame at fp=2 throws at pc=50 (no match);
    // caller frame at fp=1, call site pc=550.
    const frames: SyntheticFrames = .{ .links = &.{
        null,
        .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 },
        .{ .caller_fp = 1, .caller_pc = 550, .caller_abs_pc = 0x10550 },
    } };
    const result = walk(t, 5, 50, 0x10050, 2, frames.loader(), 16);

    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 555), h.landing_pad_pc);
            try testing.expectEqual(@as(usize, 1), h.handler_fp);
        },
        .uncaught => try testing.expect(false),
    }
}

test "unwind: catch_all in inner frame catches everything (no walk needed)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{
        .pc_start = 0,
        .pc_end = 100,
        .tag_idx = null,
        .landing_pad_pc = 77,
        .kind = .catch_all,
    });
    const t = b.finalize();

    const frames: SyntheticFrames = .{ .links = &.{} };
    const result = walk(t, 12345, 50, 0, 0, frames.loader(), 16);
    switch (result) {
        .handler => |h| {
            try testing.expectEqual(@as(u32, 77), h.landing_pad_pc);
            try testing.expectEqual(CatchKind.catch_all, h.kind);
        },
        .uncaught => try testing.expect(false),
    }
}

test "unwind: max_depth bound prevents runaway on corrupted chain" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    // Table has no entries — every frame falls through.
    const t = b.finalize();

    // Pathological frame chain: every frame points back to itself
    // (a cycle). Without max_depth this would loop forever.
    const frames: SyntheticFrames = .{
        .links = &.{
            .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 }, // fp=0 → fp=0 (self-cycle)
        },
    };
    const result = walk(t, 1, 0, 0, 0, frames.loader(), 4);
    try testing.expectEqual(UnwindResult.uncaught, result);
}

test "unwind: loader returning null (invalid fp) → uncaught" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    const t = b.finalize();

    // Empty frame chain — loader returns null at any fp.
    const frames: SyntheticFrames = .{ .links = &.{} };
    const result = walk(t, 5, 50, 0, 99, frames.loader(), 16);
    try testing.expectEqual(UnwindResult.uncaught, result);
}

test "unwind: handler_fp reports the catching frame (NOT the throwing frame)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    // No handler at inner; handler at depth-2 frame.
    try b.add(testing.allocator, .{
        .pc_start = 1000,
        .pc_end = 2000,
        .tag_idx = null,
        .landing_pad_pc = 1500,
        .kind = .catch_all,
    });
    const t = b.finalize();

    // 3-frame chain: throw at fp=3 → walks to fp=2 → walks to fp=1
    // (pc=1500 hits the handler). handler_fp should be 1.
    const frames: SyntheticFrames = .{ .links = &.{
        null,
        .{ .caller_fp = 0, .caller_pc = 0, .caller_abs_pc = 0 },
        .{ .caller_fp = 1, .caller_pc = 1500, .caller_abs_pc = 0x21500 },
        .{ .caller_fp = 2, .caller_pc = 50, .caller_abs_pc = 0x20050 },
    } };
    const result = walk(t, 7, 10, 0x30010, 3, frames.loader(), 16);
    switch (result) {
        .handler => |h| try testing.expectEqual(@as(usize, 1), h.handler_fp),
        .uncaught => try testing.expect(false),
    }
}
