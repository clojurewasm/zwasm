//! Test-time skip helpers. ADR-0122-enforced (2026-05-27).
//!
//! Exactly TWO runtime-visible skip categories exist; any third
//! "skip" case must use a `comptime` early-return per ADR-0122 D3
//! (arch-specific assertion paths). Adding a new category to this
//! file is an ADR-grade decision — do not extend the enum sets
//! without an ADR-0122 amendment.
//!
//! Zone 0 (`src/test_support/`) — imports `std` only; no upward
//! Zone references (mirrors the `support/` discipline).
//!
//! ## Why this file exists
//!
//! Before ADR-0122 the skip surface was ~63 sites of raw
//! `return error.SkipZigTest;` with category information at best
//! in a free-text comment. D-180 (2026-05-28) showed that
//! Mac-only gates hide cross-host miscompiles for days. This
//! module makes the category load-bearing at compile time:
//! every skip is one of two enum-tagged categories OR a
//! `comptime`-guarded arch-pinned test that doesn't count
//! as a skip at all.
//!
//! ## Usage
//!
//! ```zig
//! const skip = @import("../../test_support/skip.zig");
//!
//! test "win64 phase-end batch — defer per phase boundary" {
//!     if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
//!     // ...
//! }
//!
//! test "x86_64 struct-op JIT emit blocked" {
//!     if (!ready) return skip.blocker(.@"D-211");
//!     // ...
//! }
//!
//! // Arch-specific byte-shape test — NOT a skip; comptime guard:
//! test "encStp byte-shape" {
//!     if (comptime builtin.cpu.arch != .aarch64) return;
//!     // SIBLING-AT: src/engine/codegen/x86_64/...
//!     // ...
//! }
//! ```

const std = @import("std");

/// Phase-end batch deferral. Test is intentionally NOT reviewed
/// per-commit; iteration cost of running it inline would dominate
/// (e.g. cross-compiling for Win64 on every Mac cycle). Phase
/// boundary discharges the batch via `windowsmini` SSH gate.
pub const Win64Phase = enum {
    /// Win64 (MSVC ABI) — verified at phase boundary via
    /// `scripts/run_remote_windows.sh test-all`.
    win64,
};

/// Blocker-driven skip. The test would compile + run but cannot
/// pass until the named debt row is discharged. `/continue` Step 4
/// (per ADR-0122 D6) reviews these every commit and attempts a
/// 3-minute ungate probe when nearby code changes.
///
/// **Every variant here MUST appear as a row in `.dev/debt.yaml`**;
/// `scripts/check_skip_helpers.sh --gate` enforces the pairing.
/// Add a new variant only when filing the paired debt row in
/// the same commit.
pub const Blocker = enum {
    /// 10.G x86_64 struct-op JIT emit (struct.new_default / get / set).
    /// arm64 landed first; x86_64 needs the SysV trampoline-call +
    /// slab-base emit. Subsumed by the GC-on-JIT bundle (D-211).
    @"D-211",
    /// x86_64 v128-in-GC-aggregate JIT emit (struct/array get/set/new of a
    /// v128 field/element). arm64 landed first (`f79a3ced`/`41015a9b`); the
    /// x86_64 SSE movdqu mirror is the remaining D-460 bundle work.
    @"D-460",
    /// x86_64 SIMD-under-heavy-v128-spill: a separate regalloc spill-offset
    /// class-boundary OOB (regalloc.zig:222 uses max_reg_slots_gpr to index the
    /// fp spill_offsets) crashes the x86_64 codegen before the lane-op spill
    /// path is reached. arm64 lane-op spill-awareness landed first.
    @"D-461",
    // (D-186 / D-179 / D-194 / D-212 variants removed 2026-06-14 — their
    // debt rows were discharged; check_skip_helpers enforces enum↔debt pairing.)
};

/// Phase-end batch deferral. See `Win64Phase` doc.
pub fn phaseEnd(comptime _: Win64Phase) anyerror {
    return error.SkipZigTest;
}

/// Blocker-driven skip. See `Blocker` doc.
pub fn blocker(comptime _: Blocker) anyerror {
    return error.SkipZigTest;
}

// ============================================================
// Tests — verify the helpers return SkipZigTest so migration
// sites skip identically to the pre-migration raw calls.
// ============================================================

const testing = std.testing;

fn callPhaseEnd() anyerror!void {
    return phaseEnd(.win64);
}

fn callBlocker() anyerror!void {
    return blocker(.@"D-211");
}

test "skip.phaseEnd(.win64) returns SkipZigTest" {
    try testing.expectError(error.SkipZigTest, callPhaseEnd());
}

test "skip.blocker(.@\"D-211\") returns SkipZigTest" {
    try testing.expectError(error.SkipZigTest, callBlocker());
}
