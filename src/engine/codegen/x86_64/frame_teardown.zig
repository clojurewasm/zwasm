//! x86_64 frame-teardown emit — the `ADD RSP, #frame_bytes` +
//! `POP RBP` sequence (no trailing RET; caller's `JMP R11`
//! takes over per ADR-0112 D4). Mirrors the regular epilogue
//! shape minus the RET so the safepoint-free invariant
//! (ADR-0112 D7) audit lives in one place.
//!
//! INVARIANT (ADR-0112 D7): emit body has NO allocator calls
//! (only `appendSlice` to a pre-existing ArrayList) and NO
//! host-call / signal-check branches.
//!
//! Spec: System V AMD64 ABI §3.2.2 (RBP-chained frame teardown).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");

/// `Params` mirrors the shared `frame_teardown.Params` shape.
/// `n_clobber_saved`, `n_incoming`, `n_outgoing` are reserved
/// for future use when the prologue PUSH-saves the
/// pinned-callee cohort (currently x86_64 v2 saves only R15
/// per ADR-0026) and when stack-arg overflow shape changes
/// across the tail-call boundary.
pub const Params = struct {
    n_clobber_saved: u8 = 0,
    frame_bytes: u32 = 0,
    n_incoming: u8 = 0,
    n_outgoing: u8 = 0,
    /// True iff the caller's prologue PUSH-saved R15 (per
    /// `usage.usesRuntimePtr(func)`). Drives the `POP R15`
    /// emit between `ADD RSP` and `POP RBP` so the stack
    /// offset matches the regular epilogue
    /// (`op_control.emitFunctionReturn`) shape minus RET.
    /// Without this, `POP RBP` loads the saved-R15 stack
    /// slot — silent RBP corruption in the tail-called frame.
    uses_runtime_ptr: bool = false,
};

/// Emit the tail-call frame-teardown sequence:
///   (1) `ADD RSP, #frame_bytes` — Imm8 form when frame_bytes
///       fits in [-128, 127]; Imm32 form otherwise. Skipped
///       when frame_bytes == 0.
///   (2) `POP R15` — only when `uses_runtime_ptr` (mirror of
///       the regular epilogue at `op_control.emitFunctionReturn`).
///   (3) `POP RBP` (1 byte, opcode 0x5D).
///   (4) Caller emits `JMP rel32` / `JMP R11` next (NOT this
///       function's responsibility — the per-op file owns it).
///
/// Byte length: 1 (frame_bytes==0, uses_runtime_ptr=false; POP
/// RBP only), 3 (POP R15 + POP RBP), 5/8 (Imm8/Imm32 ADD + POP
/// RBP), or 7/10 (ADD + POP R15 + POP RBP).
pub fn emit(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    params: Params,
) !void {
    if (params.frame_bytes > 0) {
        if (params.frame_bytes <= 127) {
            const enc = inst.encAddRSpImm8(@intCast(params.frame_bytes));
            try buf.appendSlice(allocator, enc.slice());
        } else {
            const enc = inst.encAddRSpImm32(@intCast(params.frame_bytes));
            try buf.appendSlice(allocator, enc.slice());
        }
    }
    if (params.uses_runtime_ptr) {
        try buf.appendSlice(allocator, inst.encPopR(.r15).slice());
    }
    const pop_enc = inst.encPopR(.rbp);
    try buf.appendSlice(allocator, pop_enc.slice());
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots. Mac-host tests of the x86_64
// encoders exercise the encoding logic directly (no target dependency).
// ---------------------------------------------------------------------

const testing = std.testing;

test "frame_teardown x86_64: frame_bytes=0 emits POP RBP only (1 byte)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 0 });
    try testing.expectEqual(@as(usize, 1), buf.items.len);
    try testing.expectEqual(@as(u8, 0x5D), buf.items[0]); // POP RBP
}

test "frame_teardown x86_64: frame_bytes=16 emits ADD RSP,16 (Imm8) + POP RBP (5 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 16 });
    try testing.expectEqual(@as(usize, 5), buf.items.len);
    // ADD RSP, #16 → 48 83 C4 10
    try testing.expectEqual(@as(u8, 0x48), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x83), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xC4), buf.items[2]);
    try testing.expectEqual(@as(u8, 0x10), buf.items[3]);
    try testing.expectEqual(@as(u8, 0x5D), buf.items[4]); // POP RBP
}

test "frame_teardown x86_64: frame_bytes=256 uses Imm32 ADD + POP (8 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 256 });
    try testing.expectEqual(@as(usize, 8), buf.items.len);
    // ADD RSP, #256 → 48 81 C4 00 01 00 00
    try testing.expectEqual(@as(u8, 0x48), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x81), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xC4), buf.items[2]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[3]);
    try testing.expectEqual(@as(u8, 0x01), buf.items[4]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[5]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[6]);
    try testing.expectEqual(@as(u8, 0x5D), buf.items[7]); // POP RBP
}

test "frame_teardown x86_64: trailing emit does NOT include RET (caller's JMP R11 takes over)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 32 });
    // Last byte is POP RBP (0x5D), NOT RET (0xC3).
    try testing.expectEqual(@as(u8, 0x5D), buf.items[buf.items.len - 1]);
    try testing.expect(buf.items[buf.items.len - 1] != 0xC3);
}

test "frame_teardown x86_64: frame_bytes=127 stays in Imm8 (5 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 127 });
    try testing.expectEqual(@as(usize, 5), buf.items.len);
    try testing.expectEqual(@as(u8, 0x83), buf.items[1]); // Imm8 ADD
    try testing.expectEqual(@as(u8, 0x7F), buf.items[3]); // 127
}

test "frame_teardown x86_64: frame_bytes=128 promotes to Imm32 (8 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 128 });
    try testing.expectEqual(@as(usize, 8), buf.items.len);
    try testing.expectEqual(@as(u8, 0x81), buf.items[1]); // Imm32 ADD
}

test "frame_teardown x86_64: uses_runtime_ptr=true emits POP R15 before POP RBP (3 bytes, frame=0)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 0, .uses_runtime_ptr = true });
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    // POP R15 = 41 5F (REX.B + 0x5F)
    try testing.expectEqual(@as(u8, 0x41), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x5F), buf.items[1]);
    // POP RBP = 5D
    try testing.expectEqual(@as(u8, 0x5D), buf.items[2]);
}

test "frame_teardown x86_64: uses_runtime_ptr=true + frame=16 emits ADD + POP R15 + POP RBP (7 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emit(testing.allocator, &buf, .{ .frame_bytes = 16, .uses_runtime_ptr = true });
    try testing.expectEqual(@as(usize, 7), buf.items.len);
    // ADD RSP, 16 (4 bytes Imm8 form: 48 83 C4 10)
    try testing.expectEqual(@as(u8, 0x48), buf.items[0]); // REX.W
    try testing.expectEqual(@as(u8, 0x83), buf.items[1]); // Imm8 ADD
    try testing.expectEqual(@as(u8, 0xC4), buf.items[2]); // ModR/M /0 rsp
    try testing.expectEqual(@as(u8, 0x10), buf.items[3]); // 16
    // POP R15 = 41 5F
    try testing.expectEqual(@as(u8, 0x41), buf.items[4]);
    try testing.expectEqual(@as(u8, 0x5F), buf.items[5]);
    // POP RBP = 5D
    try testing.expectEqual(@as(u8, 0x5D), buf.items[6]);
}

test "frame_teardown x86_64: uses_runtime_ptr=false preserves the pre-fix shape (1 byte, frame=0)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // Default false → behaviour preservation for callers that don't
    // thread `uses_runtime_ptr` (smoke tests etc.).
    try emit(testing.allocator, &buf, .{ .frame_bytes = 0 });
    try testing.expectEqual(@as(usize, 1), buf.items.len);
    try testing.expectEqual(@as(u8, 0x5D), buf.items[0]);
}
