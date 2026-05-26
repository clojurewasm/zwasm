//! SysV/Win64 frame-chain read helper (ADR-0114 D6 / D5).
//!
//! Reads the caller's saved RBP + saved RIP out of an x86_64
//! frame prefix planted by the function prologue's
//! `PUSH RBP; MOV RBP, RSP`. Per System V AMD64 ABI §3.2.2 (and
//! the Win64 ABI's equivalent — both ABIs use RBP-chained
//! frames in this layout):
//!
//!   [RBP, #0] = caller's saved RBP
//!   [RBP, #8] = caller's saved RIP (the return address pushed
//!               by the CALL instruction)
//!
//! Mirror of `arm64/frame_chain.zig` (AAPCS64 `[X29, #0]` / `[X29, #8]`);
//! the trampoline (10.E-codegen-3c follow-on) composes both into a
//! `unwind.FrameChainLoader` per host via a PC-normalization callback.
//!
//! Top-of-Wasm-stack sentinel: `fp == 0` returns null. The entry
//! shim plants this sentinel so the unwinder terminates
//! deterministically at the Wasm boundary.
//!
//! INVARIANT (paired with ADR-0114 D5 + ADR-0112 D7): two
//! pointer-relative loads, no allocator calls, no host-call
//! invocations, no signal-check branches.
//!
//! Spec: System V AMD64 ABI §3.2.2.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

/// One x86_64 frame prefix read. The trampoline converts
/// `caller_rip` (= the raw saved RIP, an absolute return address)
/// to a module-relative PC via the active function's code-map
/// lookup before calling `unwind.walk`.
pub const RawFrameLink = struct {
    caller_fp: usize,
    caller_rip: usize,
};

/// Read the x86_64 frame prefix at `[fp, 0]` + `[fp, 8]`.
/// Returns null for the top-of-Wasm-stack sentinel (`fp == 0`).
pub fn loadFrame(fp: usize) ?RawFrameLink {
    if (fp == 0) return null;
    const slots: [*]const usize = @ptrFromInt(fp);
    return .{
        .caller_fp = slots[0],
        .caller_rip = slots[1],
    };
}

/// D-184 — x86_64 prologue-aware sniffed frame read. The zwasm
/// JIT prologue is `PUSH RBP; PUSH R15; MOV RBP, RSP` when the
/// function uses_runtime_ptr (= EH ops, calls, memory ops, …
/// per `usage.usesRuntimePtr`). MOV RBP, RSP captures RBP AFTER
/// the R15 push, so `[RBP, 0] = saved R15`, `[RBP, 8] = saved
/// RBP`, `[RBP, 16] = saved RIP`. For non-uses_runtime_ptr
/// functions the prologue is just `PUSH RBP; MOV RBP, RSP`,
/// giving the standard SysV `[RBP, 0] = saved RBP`, `[RBP, 8] =
/// saved RIP` layout. The unwinder doesn't know per-frame which
/// layout applies, so it sniffs: if `[fp, 8]` resolves through
/// the CodeMap as a JIT body address (i.e., a saved RIP), the
/// function used standard SysV; if `[fp, 16]` resolves but
/// `[fp, 8]` does not, the function pushed R15 between RBP-save
/// and MOV. The check is unambiguous because saved-RBP / saved-
/// R15 are stack / heap addresses (never JIT-body); only the
/// saved-RIP at the correct slot resolves to `.inside`.
pub fn loadFrameSniffed(
    fp: usize,
    code_map: *const @import("../shared/code_map.zig").CodeMap,
) ?RawFrameLink {
    if (fp == 0) return null;
    const slots: [*]const usize = @ptrFromInt(fp);
    // Sniff standard layout first (most caller frames in EH chain
    // do NOT push R15 between RBP-save and MOV; non-throwing
    // intermediate frames are uses_runtime_ptr=false often).
    switch (code_map.lookup(slots[1])) {
        .inside => return .{ .caller_fp = slots[0], .caller_rip = slots[1] },
        .outside => {},
    }
    switch (code_map.lookup(slots[2])) {
        .inside => return .{ .caller_fp = slots[1], .caller_rip = slots[2] },
        .outside => {},
    }
    // Neither slot is a JIT body address — frame chain has
    // escaped the JIT module (entry shim / host stack). Return
    // the slot0/slot1 default; the unwinder will see the
    // non-JIT caller_rip resolve to the `non_jit_pc_sentinel`
    // and either match a sentinel handler or step further into
    // host frames where `loadFrame` may return null (fp == 0)
    // or the heuristic may fail safely on the next iteration.
    return .{ .caller_fp = slots[0], .caller_rip = slots[1] };
}

// ---------------------------------------------------------------------
// Unit tests — pure pointer read; synthetic frame planted in test
// memory. No JIT emit / no actual stack walk required.
// ---------------------------------------------------------------------

const testing = std.testing;

test "loadFrame x86_64: fp == 0 sentinel → null (top-of-stack)" {
    try testing.expectEqual(@as(?RawFrameLink, null), loadFrame(0));
}

test "loadFrame x86_64: reads [fp, 0] as caller_fp and [fp, 8] as caller_rip" {
    var frame: [2]usize = .{ 0xDEADBEEFCAFE, 0xFEEDFACE0001 };
    const fp: usize = @intFromPtr(&frame);

    const link = loadFrame(fp).?;
    try testing.expectEqual(@as(usize, 0xDEADBEEFCAFE), link.caller_fp);
    try testing.expectEqual(@as(usize, 0xFEEDFACE0001), link.caller_rip);
}

test "loadFrame x86_64: caller_fp == 0 propagates (next walk step would terminate)" {
    var frame: [2]usize = .{ 0, 0xAAAA1234 };
    const fp: usize = @intFromPtr(&frame);

    const link = loadFrame(fp).?;
    try testing.expectEqual(@as(usize, 0), link.caller_fp);
    try testing.expectEqual(@as(usize, 0xAAAA1234), link.caller_rip);
}

test "loadFrame x86_64: chained read — outer frame reachable via inner's caller_fp" {
    var outer: [2]usize = .{ 0, 0x1111 };
    var inner: [2]usize = .{ @intFromPtr(&outer), 0x2222 };
    const inner_fp: usize = @intFromPtr(&inner);

    const inner_link = loadFrame(inner_fp).?;
    try testing.expectEqual(@intFromPtr(&outer), inner_link.caller_fp);
    try testing.expectEqual(@as(usize, 0x2222), inner_link.caller_rip);

    const outer_link = loadFrame(inner_link.caller_fp).?;
    try testing.expectEqual(@as(usize, 0), outer_link.caller_fp);
    try testing.expectEqual(@as(usize, 0x1111), outer_link.caller_rip);
}
