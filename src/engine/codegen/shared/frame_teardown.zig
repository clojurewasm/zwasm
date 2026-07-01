//! Shared tail-call frame-teardown facade (ADR-0112 D3).
//!
//! Per-arch encoders live at `arm64/frame_teardown.zig` and
//! `x86_64/frame_teardown.zig`. This file is the single
//! arch-agnostic entry point (`builtin.target.cpu.arch` switch,
//! same pattern as `shared/thunk.zig` + `shared/compile.zig`)
//! and the canonical home for the `Params` shape.
//!
//! Why one shared file (vs per-arch alone, ADR-0112 Alt C):
//! the byte emit calls differ between AAPCS64 (LDP X29,X30) and
//! SysV (POP RBP), but the **invariant order** is identical —
//! SP-restore → callee-saved-restore → FP-pop, with NO RET.
//! The safepoint-free invariant audit (ADR-0112 D7: no
//! allocator / host-call / signal-check between teardown
//! start and the caller's trailing branch) reads in one place.
//!
//! Consumed by `engine/codegen/<arch>/op_tail_call.zig`, which
//! emits the args marshalling, the callee target load, this
//! teardown, and finally the BR X16 /
//! JMP R11 branch — in that order.
//!
//! Zone 2 (`src/engine/codegen/shared/`) — may import both
//! arch modules per the established shared/ cross-arch pattern.

const std = @import("std");
const builtin = @import("builtin");

const arch_impl = switch (builtin.target.cpu.arch) {
    .aarch64 => @import("../arm64/frame_teardown.zig"),
    .x86_64 => @import("../x86_64/frame_teardown.zig"),
    else => @compileError("frame_teardown not implemented for this architecture"),
};

/// Canonical `Params` shape per ADR-0112 D3. The per-arch
/// `Params` are deliberately structurally identical to this
/// one so the facade can pass them through transparently.
///
/// - `n_clobber_saved`: count of pinned-callee regs the
///   prologue STP/PUSH-saved (currently 0 in v2 since the
///   prologue does NOT stack-save the pinned cohort —
///   ADR-0066 §A2 / D-144 bridge thunks handle restoration
///   for cross-instance calls; for tail-call within the same
///   instance, no restoration is needed).
/// - `frame_bytes`: bytes the prologue's `SUB SP, SP, #N`
///   subtracted (= locals + spills + outgoing-args region).
/// - `n_incoming`: caller's incoming-args slot count (for
///   future AAPCS64 §6.4.2 overflow-region adjustment).
/// - `n_outgoing`: callee's outgoing-args slot count (same).
/// - `uses_runtime_ptr`: true iff the caller's prologue
///   PUSH-saved R15 (x86_64, per ADR-0026 Cc-pivot). Required
///   so the x86_64 teardown emits `POP R15` between `ADD RSP`
///   and `POP RBP` — otherwise the stack offset misaligns and
///   `POP RBP` loads the saved R15 word instead of saved RBP.
///   Arm64 ignores this field (X19 is MOV-installed, not
///   stack-saved, per ADR-0017 sub-2d-ii; same-module tail-call
///   keeps the same value).
pub const Params = struct {
    n_clobber_saved: u8 = 0,
    frame_bytes: u32 = 0,
    n_incoming: u8 = 0,
    n_outgoing: u8 = 0,
    uses_runtime_ptr: bool = false,
};

/// Emit the tail-call frame-teardown bytes for the active
/// target architecture. The caller's trailing BR X16 / JMP R11
/// is NOT emitted here — the per-op file owns that.
///
/// INVARIANT (ADR-0112 D7): this function never allocates,
/// never calls into host code, never branches on a
/// signal-check path. Buffer growth via the passed ArrayList
/// is the sole allocation-class operation and is bounded
/// (`std.ArrayList.ensureCapacity` underlying); for the
/// safepoint audit the allocation happens BEFORE the
/// teardown's first byte commits.
pub fn emit(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    params: Params,
) !void {
    return arch_impl.emit(allocator, buf, .{
        .n_clobber_saved = params.n_clobber_saved,
        .frame_bytes = params.frame_bytes,
        .n_incoming = params.n_incoming,
        .n_outgoing = params.n_outgoing,
        .uses_runtime_ptr = params.uses_runtime_ptr,
    });
}

// ---------------------------------------------------------------------
// Facade smoke test — confirms the dispatcher routes to the
// per-arch encoder. Detailed byte-level tests live in the
// per-arch files (run regardless of host).
// ---------------------------------------------------------------------

const testing = std.testing;

test "frame_teardown facade: zero-frame teardown emits non-empty bytes (host arch)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 0 });
    try testing.expect(buf.items.len > 0);
}

test "frame_teardown facade: 16-byte frame teardown grows the buffer" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    const zero_len = blk: {
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(testing.allocator);
        try emit(testing.allocator, &b, .{ .frame_bytes = 0 });
        break :blk b.items.len;
    };
    try emit(testing.allocator, &buf, .{ .frame_bytes = 16 });
    try testing.expect(buf.items.len > zero_len);
}
