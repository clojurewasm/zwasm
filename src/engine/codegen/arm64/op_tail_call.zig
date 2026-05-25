//! ARM64 tail-call emit helpers (ADR-0112 D2 + D3).
//!
//! Separate from `op_call.zig` per ADR-0112 D2: regular `call`
//! returns to the caller (LR-restored on RET); tail-call
//! consumes the caller's frame and BR-jumps without LR
//! preserving caller's LR for the callee's eventual RET (which
//! returns to caller's caller). Mixing the two shapes in one
//! file would invite single_slot_dual_meaning drift across
//! Phase 11+ work.
//!
//! Per ADR-0112 D3 the full tail-call emit sequence is:
//!
//!   (1) marshal args → X1..X7 / V0..V7   (caller frame still live)
//!   (2) load callee_rt → X0              (from caller's literal pool)
//!   (3) load callee_entry → X16
//!   (4) frame_teardown.emit(…)           (caller's frame disappears)
//!   (5) BR X16                           (no LR; callee RETs to caller's caller)
//!
//! This file currently lands step (5) — `emitTailJump` — as the
//! observable foundation. Subsequent chunks layer on:
//!   10.TC-3e: callee target load + frame_teardown integration
//!             + per-op-file wire-up into collected_arm64_ops.
//!   10.TC-3f: cross_module_tail_call.zig (ADR-0112 D4).
//!
//! INVARIANT (ADR-0112 D7): the segment from frame_teardown
//! start through the BR X16 contains NO allocator calls, NO
//! host-call dispatches, NO signal-check branches. This file
//! is the natural home for that invariant's audit.
//!
//! Spec: Wasm Core 3.0 §3.3.8.18-20 (tail-call proposal).
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const gpr = @import("gpr.zig");

/// X16 — the AAPCS64 intra-procedure-call scratch (IP0) per
/// Arm IHI 0055 §6.4. ADR-0066 § (bridge thunk) already uses
/// X16 as the callee-target-load register; tail-call reuses
/// the same convention so the regalloc layer's pinned-cohort
/// stays a single set.
pub const tail_target_gpr: inst.Xn = 16;

/// Emit step (5) of the ADR-0112 D3 tail-call sequence: the
/// `BR X16` unconditional branch to the callee entry. Caller
/// MUST have already loaded the callee target into X16 and
/// emitted `frame_teardown.emit(...)` immediately above this
/// (the safepoint-free invariant per ADR-0112 D7).
///
/// `target` is parameterised (default `tail_target_gpr` = 16)
/// so future tests can verify the encoder against alternate
/// targets without polluting the call sites.
pub fn emitTailJump(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    target: inst.Xn,
) !void {
    try gpr.writeU32(allocator, buf, inst.encBr(target));
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots for the BR encoder. These run on
// every host since the arm64 encoders are pure comptime helpers.
// ---------------------------------------------------------------------

const testing = std.testing;

test "op_tail_call arm64: emitTailJump X16 → 0xD61F0200 (canonical AAPCS64 tail-jump)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, tail_target_gpr);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0xD61F0200), word);
}

test "op_tail_call arm64: emitTailJump X17 — alternate IP1 target (Arm IHI 0055 §6.4)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, 17);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encBr(17), word);
}

test "op_tail_call arm64: tail_target_gpr matches ADR-0066 thunk convention (X16 = IP0)" {
    try testing.expectEqual(@as(inst.Xn, 16), tail_target_gpr);
}
