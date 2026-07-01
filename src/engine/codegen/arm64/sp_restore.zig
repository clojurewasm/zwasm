//! arm64 SP-restore emit helper for the EH landing path
//! (ADR-0114 D6).
//!
//! After `zwasm_throw.dispatchThrow` returns `.handler{
//! handler_fp, landing_pad_pc, kind }`, the assembly
//! trampoline must restore SP to
//! the handler frame's prologue-completion boundary before
//! jumping to `landing_pad_pc`. On AAPCS64 the prologue's
//! `MOV X29, SP` leaves SP == FP at prologue completion;
//! after a `SUB SP, SP, #frame_bytes` the relation becomes
//! SP == FP - frame_bytes_of_handler_function.
//!
//! Current atom: emit the zero-locals restore (SP = FP).
//! Functions with locals + spills use the frame-bytes-aware
//! emit path that lands when CodeMap.Entry gains the
//! frame_bytes field.
//!
//! Spec: AAPCS64 §6.4.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const inst = @import("inst.zig");
const gpr = @import("gpr.zig");

const sp_reg: inst.Xn = 31;

/// Emit `MOV SP, Xn` (= `ADD SP, Xn, #0` per AAPCS64). The
/// trampoline calls this with `src_gpr` set to the GPR holding
/// the handler frame's FP (= handler_fp returned from
/// `unwind.walk`).
///
/// Zero-locals restore: caller's frame_bytes == 0, so SP == FP
/// at the catch landing pad. Functions with locals require the
/// `SUB SP, SP, #frame_bytes` follow-up emit.
pub fn emitSpFromGpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    src_gpr: inst.Xn,
) !void {
    try gpr.writeU32(allocator, buf, inst.encAddImm12(sp_reg, src_gpr, 0));
}

/// Emit the full SP-restore sequence: `MOV SP, src_gpr` followed
/// by `SUB SP, SP, #frame_bytes` (split into LSL-12 + low-12
/// immediates per AAPCS64 large-frame discipline). For
/// `frame_bytes == 0`, identical to `emitSpFromGpr`.
///
/// The trampoline calls this from the .handler return path
/// with `src_gpr` holding `handler_fp` and `frame_bytes` =
/// `code_map.Entry.frame_bytes` of the catching function.
pub fn emitSpRestoreFull(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    src_gpr: inst.Xn,
    frame_bytes: u32,
) !void {
    try emitSpFromGpr(allocator, buf, src_gpr);
    if (frame_bytes == 0) return;
    const fb_high: u12 = @intCast((frame_bytes >> 12) & 0xFFF);
    const fb_low: u12 = @intCast(frame_bytes & 0xFFF);
    if (fb_high != 0) try gpr.writeU32(allocator, buf, inst.encSubImm12Lsl12(sp_reg, sp_reg, fb_high));
    if (fb_low != 0) try gpr.writeU32(allocator, buf, inst.encSubImm12(sp_reg, sp_reg, fb_low));
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots for the AAPCS64 MOV SP, Xn
// encoding. Run on every host since the arm64 encoders are pure
// comptime helpers.
// ---------------------------------------------------------------------

const testing = std.testing;

test "sp_restore arm64: emitSpFromGpr X29 → MOV SP, X29 (ADD SP, X29, #0 = 0x910003BF)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpFromGpr(testing.allocator, &buf, 29);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    // 0x91000000 | (29 << 5) | 31 = 0x910003BF.
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0x910003BF), word);
}

test "sp_restore arm64: emitSpFromGpr X1 — handler_fp landed in X1 by dispatchThrow result marshal" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpFromGpr(testing.allocator, &buf, 1);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encAddImm12(31, 1, 0), word);
}

test "sp_restore arm64: emitSpFromGpr X0 — ADR-0017 prologue X0 = runtime_ptr restore form" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpFromGpr(testing.allocator, &buf, 0);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    // 0x91000000 | (0 << 5) | 31 = 0x9100001F
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0x9100001F), word);
}

test "sp_restore arm64: emitSpRestoreFull frame_bytes=0 → emits only MOV SP, Xn (4 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpRestoreFull(testing.allocator, &buf, 29, 0);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0x910003BF), word);
}

test "sp_restore arm64: emitSpRestoreFull frame_bytes=16 → MOV SP,X29 + SUB SP,SP,#16 (8 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpRestoreFull(testing.allocator, &buf, 29, 16);
    try testing.expectEqual(@as(usize, 8), buf.items.len);
    const mov_word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0x910003BF), mov_word);
    const sub_word = std.mem.readInt(u32, buf.items[4..8], .little);
    try testing.expectEqual(inst.encSubImm12(31, 31, 16), sub_word);
}

test "sp_restore arm64: emitSpRestoreFull large frame_bytes uses SUB LSL-12 + SUB imm12 (12 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // 0x12345 = (0x12 << 12) | 0x345
    try emitSpRestoreFull(testing.allocator, &buf, 29, 0x12345);
    try testing.expectEqual(@as(usize, 12), buf.items.len);
    const mov_word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0x910003BF), mov_word);
    const sub_high = std.mem.readInt(u32, buf.items[4..8], .little);
    try testing.expectEqual(inst.encSubImm12Lsl12(31, 31, 0x12), sub_high);
    const sub_low = std.mem.readInt(u32, buf.items[8..12], .little);
    try testing.expectEqual(inst.encSubImm12(31, 31, 0x345), sub_low);
}
