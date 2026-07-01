//! ARM64 frame-teardown emit — the SP-restore + LDP X29,X30
//! sequence shared with the regular epilogue but WITHOUT the
//! trailing `RET`. Consumed by `op_tail_call.zig`: after
//! the args are marshalled and the callee
//! target loaded into X16, the caller's frame is torn down
//! here and the caller's BR X16 takes over (no LR clobber —
//! LR carries the original caller's return address so the
//! callee's eventual RET returns to caller's caller per Wasm
//! 3.0 tail-call semantics).
//!
//! Per ADR-0112 D3. The mirror sequence in the regular
//! `arm64/emit.zig` epilogue (lines ~1245-1252) stays for
//! the standard return path; this helper carves out the
//! tail-call slice so the safepoint-free invariant
//! (ADR-0112 D7) audits in one place.
//!
//! INVARIANT (ADR-0112 D7): emit body has NO allocator calls
//! (only `gpr.writeU32` which appends to a pre-existing
//! ArrayList) and NO host-call / signal-check branches.
//!
//! Spec: AAPCS64 §6.4 frame teardown.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const gpr = @import("gpr.zig");

const sp_reg: inst.Xn = 31;
const fp_reg: inst.Xn = 29;
const lr_reg: inst.Xn = 30;

/// `Params` mirrors the shared `frame_teardown.Params` shape.
/// Per ADR-0112 D3 the four axes describe the caller's frame
/// state that the teardown unwinds. Currently only
/// `frame_bytes` is consumed; `n_clobber_saved` becomes
/// functional when the prologue STP-saves the pinned-callee
/// cohort (ADR-0066 §A2 / D-144), and the `n_incoming` /
/// `n_outgoing` axes drive the AAPCS64 §6.4.2 overflow-args
/// region adjustment when callee param shape differs from
/// caller's.
pub const Params = struct {
    n_clobber_saved: u8 = 0,
    frame_bytes: u32 = 0,
    n_incoming: u8 = 0,
    n_outgoing: u8 = 0,
    /// arm64-ignored — X19 is MOV-installed (not stack-saved)
    /// per ADR-0017 sub-2d-ii. Carried in Params for facade
    /// structural symmetry with x86_64 (which DOES stack-save R15).
    uses_runtime_ptr: bool = false,
};

/// Emit the tail-call frame-teardown sequence:
///   (1) `ADD SP, SP, #frame_bytes` (split into LSL-12 + low
///       12-bit immediates per AAPCS64 large-frame discipline;
///       mirrors `emit.zig` epilogue exactly).
///   (2) `LDP X29, X30, [SP], #16` — post-index pop of FP/LR.
///   (3) Caller emits `BR X16` next (NOT this function's
///       responsibility — the per-op file owns the branch).
///
/// Byte length: 4 (if frame_bytes==0; one LDP) or 8 (one ADD +
/// LDP) or 12 (high + low ADDs + LDP) bytes.
pub fn emit(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    params: Params,
) !void {
    if (params.frame_bytes > 0) {
        const fb_high: u12 = @intCast((params.frame_bytes >> 12) & 0xFFF);
        const fb_low: u12 = @intCast(params.frame_bytes & 0xFFF);
        if (fb_high != 0) try gpr.writeU32(allocator, buf, inst.encAddImm12Lsl12(sp_reg, sp_reg, fb_high));
        if (fb_low != 0) try gpr.writeU32(allocator, buf, inst.encAddImm12(sp_reg, sp_reg, fb_low));
    }
    try gpr.writeU32(allocator, buf, inst.encLdpPostIdx(fp_reg, lr_reg, sp_reg, 16));
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots. Run on every host (Mac aarch64,
// ubuntunote x86_64) since the arm64 encoders are pure comptime
// helpers with no target dependency.
// ---------------------------------------------------------------------

const testing = std.testing;

test "frame_teardown arm64: frame_bytes=0 emits LDP X29,X30,[SP],#16 (4 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 0 });
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0xA8C17BFD), word); // LDP X29, X30, [SP], #16
}

test "frame_teardown arm64: frame_bytes=16 emits ADD SP,SP,#16 + LDP (8 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 16 });
    try testing.expectEqual(@as(usize, 8), buf.items.len);
    const add_word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encAddImm12(sp_reg, sp_reg, 16), add_word);
    const ldp_word = std.mem.readInt(u32, buf.items[4..8], .little);
    try testing.expectEqual(@as(u32, 0xA8C17BFD), ldp_word);
}

test "frame_teardown arm64: large frame_bytes uses ADD LSL-12 + ADD imm12 + LDP (12 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // 0x12345 = (0x12 << 12) | 0x345
    try emit(testing.allocator, &buf, .{ .frame_bytes = 0x12345 });
    try testing.expectEqual(@as(usize, 12), buf.items.len);
    const add_high = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encAddImm12Lsl12(sp_reg, sp_reg, 0x12), add_high);
    const add_low = std.mem.readInt(u32, buf.items[4..8], .little);
    try testing.expectEqual(inst.encAddImm12(sp_reg, sp_reg, 0x345), add_low);
    const ldp_word = std.mem.readInt(u32, buf.items[8..12], .little);
    try testing.expectEqual(@as(u32, 0xA8C17BFD), ldp_word);
}

test "frame_teardown arm64: trailing emit does NOT include RET (caller's BR X16 takes over)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 32 });
    // Last word must be the LDP (0xA8C17BFD), NOT RET (0xD65F03C0).
    const last_word = std.mem.readInt(u32, buf.items[buf.items.len - 4 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0xA8C17BFD), last_word);
    try testing.expect(last_word != 0xD65F03C0);
}
