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
//! ~128 site bulk relativisation is sequenced under §9.7 / 7.5d
//! sub-deliverable b alongside the emit.zig split.
//!
//! Prologue layout (per ADR-0017, current as of 2026-05-04):
//!
//!   Word 0:   STP X29, X30, [SP, #-16]!     (4 bytes — ABI-pinned)
//!   Word 1:   MOV X29, SP                   (4 bytes — ABI-pinned)
//!   Words 2-6: 5 LDRs into X28/X27/X26/W25/X24 (20 bytes — ADR-0017)
//!   Word 7:   ORR X19, XZR, X0  (= MOV X19, X0)  (4 bytes — ADR-0017 sub-2d-ii)
//!   Word 8 (optional, frame > 0): SUB SP, SP, #frame_bytes  (4 bytes)
//!
//! Total: 32 bytes (no frame) or 36 bytes (frame > 0). Words 0-1
//! are pinned by AAPCS64 (Arm IHI 0055 §6.4); the optional SUB SP
//! only appears when the function has locals + spill bytes.
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3.

const std = @import("std");

/// AAPCS64-pinned prologue prefix opcodes. These are fixed by the
/// ABI; their offsets are byte 0 and byte 4 regardless of frame.
pub const FpLrSave = struct {
    /// `STP X29, X30, [SP, #-16]!`
    pub const stp_word: u32 = 0xA9BF7BFD;
    /// `MOV X29, SP` (encoded as `ADD X29, SP, #0`)
    pub const mov_fp_word: u32 = 0x910003FD;
};

/// First body instruction byte offset.
///
/// `has_frame` = true when the function has any locals OR any
/// spilled vregs (i.e. `frame_bytes > 0` in emit.zig). Tests
/// that exercise pure-register code pass `false`.
pub fn body_start_offset(has_frame: bool) u32 {
    return if (has_frame) 36 else 32;
}

/// Read a u32 word at `byte_offset` in `bytes` (little-endian).
/// Convenience wrapper for the common test pattern
/// `std.mem.readInt(u32, bytes[off..][0..4], .little)`.
pub fn wordAt(bytes: []const u8, byte_offset: u32) u32 {
    return std.mem.readInt(u32, bytes[byte_offset..][0..4], .little);
}

/// Read the prologue's first two ABI-pinned words and assert
/// they match the AAPCS64-mandated opcodes. One-line ABI sanity
/// check for tests that don't otherwise inspect the prologue.
pub fn assertPrologueOpcodes(bytes: []const u8) error{ PrologueTooShort, BadStpOpcode, BadMovFpOpcode }!void {
    if (bytes.len < 8) return error.PrologueTooShort;
    if (wordAt(bytes, 0) != FpLrSave.stp_word) return error.BadStpOpcode;
    if (wordAt(bytes, 4) != FpLrSave.mov_fp_word) return error.BadMovFpOpcode;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "body_start_offset: 32 bytes no frame, 36 bytes with frame" {
    try testing.expectEqual(@as(u32, 32), body_start_offset(false));
    try testing.expectEqual(@as(u32, 36), body_start_offset(true));
}

test "wordAt reads u32 little-endian at offset" {
    const bytes = [_]u8{ 0xFD, 0x7B, 0xBF, 0xA9, 0xFD, 0x03, 0x00, 0x91 };
    try testing.expectEqual(FpLrSave.stp_word, wordAt(&bytes, 0));
    try testing.expectEqual(FpLrSave.mov_fp_word, wordAt(&bytes, 4));
}

test "assertPrologueOpcodes: accepts well-formed prefix" {
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
