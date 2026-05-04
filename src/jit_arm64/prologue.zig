//! ARM64 prologue layout — single source of truth for byte offsets.
//!
//! Background (regret #6 from 2026-05-04 retrospective): test
//! suites in this layer hard-coded byte offsets like
//! `out.bytes[32..36]` to assert that the first body instruction
//! lands at byte 32 (after the 32-byte ARM64 prologue). When the
//! prologue grew during sub-2 (ADR-0017's 5 LDRs) the offset
//! cascade required manual updates at 124+ sites. Future prologue
//! changes (Phase 8 optimisation, Phase 15 v1 ports) would
//! re-trigger the same cascade.
//!
//! This module isolates prologue-shape knowledge to one place.
//! Per ADR-0021 (sub-deliverable a), the helper lands first; the
//! 132 test-site relativisation is sequenced under §9.7 / 7.5d
//! sub-deliverable b alongside the emit.zig split, so
//! mechanical migration runs in a single review-friendly cycle.
//!
//! Prologue layout (per ADR-0017, current as of 2026-05-04):
//!
//!   Word 0:   STP X29, X30, [SP, #-16]!     (4 bytes)
//!   Word 1:   MOV X29, SP                   (4 bytes)
//!   Word 2:   LDR X28, [X0, #vm_base_off]   (4 bytes)
//!   Word 3:   LDR X27, [X0, #mem_limit_off] (4 bytes)
//!   Word 4:   LDR X26, [X0, #funcptr_base]  (4 bytes)
//!   Word 5:   LDR W25, [X0, #table_size]    (4 bytes)
//!   Word 6:   LDR X24, [X0, #typeidx_base]  (4 bytes)
//!   Word 7:   ORR X19, XZR, X0  (= MOV X19, X0)  (4 bytes)
//!   Word 8 (optional, if frame > 0): SUB SP, SP, #frame_bytes (4 bytes)
//!
//! Total: 32 bytes (no frame) or 36 bytes (frame > 0).
//!
//! The first 8 words are AAPCS64-pinned (Arm IHI 0055 §6.4) and
//! cannot move; the optional SUB SP only appears when the
//! function has locals + spill bytes.
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3.

const std = @import("std");

/// AAPCS64-pinned prologue prefix: STP FP/LR + MOV FP, SP.
/// These two words are fixed by the ABI; their opcodes do not
/// depend on regalloc decisions.
pub const FpLrSave = struct {
    /// `STP X29, X30, [SP, #-16]!`
    pub const stp_word: u32 = 0xA9BF7BFD;
    /// `MOV X29, SP` (encoded as `ADD X29, SP, #0`)
    pub const mov_fp_word: u32 = 0x910003FD;
    /// 2 words = 8 bytes.
    pub const size_bytes: u32 = 8;
};

/// 5 LDRs from `*X0 = JitRuntime` into reserved invariants
/// X28 / X27 / X26 / W25 / X24 (per ADR-0017).
pub const InvariantLoads = struct {
    /// 5 words = 20 bytes.
    pub const size_bytes: u32 = 20;
};

/// `MOV X19, X0` saves the runtime pointer to a callee-saved
/// register so each call site can restore X0 (caller-saved by
/// AAPCS64) before BL/BLR. ADR-0017 sub-2d-ii.
pub const RuntimePtrSave = struct {
    /// 1 word = 4 bytes.
    pub const size_bytes: u32 = 4;
};

/// Frame allocation: `SUB SP, SP, #frame_bytes` when the
/// function has locals + spill region. Omitted for empty frames.
pub const FrameAlloc = struct {
    pub fn size_bytes(has_frame: bool) u32 {
        return if (has_frame) 4 else 0;
    }
};

/// Total prologue size in bytes. The first body instruction
/// starts at this offset.
///
/// `has_frame` = true when the function has any locals OR any
/// spilled vregs (i.e. `frame_bytes > 0` in emit.zig). Tests
/// that exercise pure-register code pass `false`.
pub fn prologue_size(has_frame: bool) u32 {
    return FpLrSave.size_bytes +
        InvariantLoads.size_bytes +
        RuntimePtrSave.size_bytes +
        FrameAlloc.size_bytes(has_frame);
}

/// Alias for `prologue_size`. The first body instruction is
/// emitted at this byte offset; the name "body_start" reads
/// more naturally at test sites.
pub fn body_start_offset(has_frame: bool) u32 {
    return prologue_size(has_frame);
}

/// Read the prologue's first two ABI-pinned words and assert
/// they match the AAPCS64-mandated opcodes. Use when a test
/// wants a one-line ABI sanity check instead of inlining the
/// magic-number constants.
pub fn assertPrologueOpcodes(bytes: []const u8) error{ PrologueTooShort, BadStpOpcode, BadMovFpOpcode }!void {
    if (bytes.len < 8) return error.PrologueTooShort;
    const stp = std.mem.readInt(u32, bytes[0..4], .little);
    const mov = std.mem.readInt(u32, bytes[4..8], .little);
    if (stp != FpLrSave.stp_word) return error.BadStpOpcode;
    if (mov != FpLrSave.mov_fp_word) return error.BadMovFpOpcode;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "prologue_size: no frame = 32 bytes (8 + 20 + 4)" {
    try testing.expectEqual(@as(u32, 32), prologue_size(false));
}

test "prologue_size: with frame = 36 bytes (32 + 4 SUB SP)" {
    try testing.expectEqual(@as(u32, 36), prologue_size(true));
}

test "body_start_offset matches prologue_size" {
    try testing.expectEqual(prologue_size(false), body_start_offset(false));
    try testing.expectEqual(prologue_size(true), body_start_offset(true));
}

test "FpLrSave constants match AAPCS64 standard opcodes" {
    try testing.expectEqual(@as(u32, 0xA9BF7BFD), FpLrSave.stp_word);
    try testing.expectEqual(@as(u32, 0x910003FD), FpLrSave.mov_fp_word);
}

test "section sizes sum correctly" {
    const expected_no_frame = FpLrSave.size_bytes +
        InvariantLoads.size_bytes +
        RuntimePtrSave.size_bytes;
    try testing.expectEqual(expected_no_frame, prologue_size(false));
    try testing.expectEqual(expected_no_frame + 4, prologue_size(true));
}

test "assertPrologueOpcodes: accepts well-formed prologue prefix" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], FpLrSave.stp_word, .little);
    std.mem.writeInt(u32, buf[4..8], FpLrSave.mov_fp_word, .little);
    try assertPrologueOpcodes(&buf);
}

test "assertPrologueOpcodes: rejects bad STP opcode" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0xDEADBEEF, .little);
    std.mem.writeInt(u32, buf[4..8], FpLrSave.mov_fp_word, .little);
    try testing.expectError(error.BadStpOpcode, assertPrologueOpcodes(&buf));
}

test "assertPrologueOpcodes: rejects bad MOV FP opcode" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], FpLrSave.stp_word, .little);
    std.mem.writeInt(u32, buf[4..8], 0xDEADBEEF, .little);
    try testing.expectError(error.BadMovFpOpcode, assertPrologueOpcodes(&buf));
}

test "assertPrologueOpcodes: rejects too-short input" {
    const buf: [4]u8 = undefined;
    try testing.expectError(error.PrologueTooShort, assertPrologueOpcodes(&buf));
}
