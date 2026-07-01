//! x86_64 SP-restore emit helper for the EH landing path
//! (ADR-0114 D6). Mirror of `arm64/sp_restore.zig`.
//!
//! After `zwasm_throw.dispatchThrow` returns `.handler{
//! handler_fp, landing_pad_pc, kind }`, the assembly
//! trampoline must restore RSP to the handler frame's
//! prologue-completion boundary before jumping to
//! `landing_pad_pc`. On SysV/Win64 the prologue's `PUSH RBP;
//! MOV RBP, RSP` leaves RBP == RSP at prologue completion;
//! after a `SUB RSP, #frame_bytes` (locals + spills) the
//! relation becomes RSP == RBP - frame_bytes.
//!
//! Current atom: emit the zero-locals restore (RSP = RBP).
//! Functions with locals use the frame-bytes-aware restore
//! that lands when CodeMap.Entry gains the frame_bytes field.
//!
//! Spec: System V AMD64 ABI §3.2.2.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const inst = @import("inst.zig");

/// Emit `MOV RSP, <src_gpr>` (64-bit reg-to-reg move). The
/// trampoline calls this with `src_gpr` set to the GPR holding
/// the handler frame's FP value (= handler_fp returned from
/// `unwind.walk`; typically materialised into RBP-equivalent
/// scratch by the trampoline's call-result marshal).
///
/// Zero-locals restore: caller's frame_bytes == 0, so RSP == RBP
/// at the catch landing pad. Functions with locals require the
/// `SUB RSP, #frame_bytes` follow-up emit.
pub fn emitSpFromGpr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    src_gpr: inst.Gpr,
) !void {
    const enc = inst.encMovRR(.q, .rsp, src_gpr);
    try buf.appendSlice(allocator, enc.slice());
}

/// Emit the full SP-restore sequence: `MOV RSP, src_gpr` followed
/// by `SUB RSP, #frame_bytes` (Imm8 form for ≤127; Imm32 form
/// otherwise). For `frame_bytes == 0`, identical to
/// `emitSpFromGpr`.
///
/// The trampoline calls this from the .handler return path
/// with `src_gpr` holding `handler_fp` and `frame_bytes` =
/// `code_map.Entry.frame_bytes` of the catching function.
pub fn emitSpRestoreFull(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    src_gpr: inst.Gpr,
    frame_bytes: u32,
) !void {
    try emitSpFromGpr(allocator, buf, src_gpr);
    if (frame_bytes == 0) return;
    if (frame_bytes <= 127) {
        const enc = inst.encSubRSpImm8(@intCast(frame_bytes));
        try buf.appendSlice(allocator, enc.slice());
    } else {
        const enc = inst.encSubRSpImm32(@intCast(frame_bytes));
        try buf.appendSlice(allocator, enc.slice());
    }
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots for the MOV r/m64, r64
// encoding. Mac-host tests verify the encoding directly via the
// x86_64 encoders.
// ---------------------------------------------------------------------

const testing = std.testing;

test "sp_restore x86_64: emitSpFromGpr RBP → MOV RSP, RBP (48 89 EC = canonical zero-locals)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpFromGpr(testing.allocator, &buf, .rbp);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    // MOV RSP, RBP → 48 89 EC
    //   48 = REX.W
    //   89 = MOV r/m64, r64
    //   EC = ModR/M: mod=11, reg=5 (RBP), rm=4 (RSP)
    try testing.expectEqual(@as(u8, 0x48), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x89), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xEC), buf.items[2]);
}

test "sp_restore x86_64: emitSpFromGpr RAX → MOV RSP, RAX (48 89 C4)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpFromGpr(testing.allocator, &buf, .rax);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    // MOV RSP, RAX → 48 89 C4
    //   48 = REX.W
    //   89 = MOV r/m64, r64
    //   C4 = ModR/M: mod=11, reg=0 (RAX), rm=4 (RSP)
    try testing.expectEqual(@as(u8, 0x48), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x89), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xC4), buf.items[2]);
}

test "sp_restore x86_64: emitSpFromGpr R11 — handler_fp returned in R11 (REX.W+REX.R)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpFromGpr(testing.allocator, &buf, .r11);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    // MOV RSP, R11 → 4C 89 DC
    //   4C = REX.W + REX.R (R11 is reg-side; high bit via REX.R)
    //   89 = MOV r/m64, r64
    //   DC = ModR/M: mod=11, reg=3 (R11 low 3 bits), rm=4 (RSP)
    try testing.expectEqual(@as(u8, 0x4C), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x89), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xDC), buf.items[2]);
}

test "sp_restore x86_64: emitSpRestoreFull frame_bytes=0 → MOV RSP, Rsrc only (3 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpRestoreFull(testing.allocator, &buf, .rbp, 0);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    try testing.expectEqual(@as(u8, 0x48), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x89), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xEC), buf.items[2]);
}

test "sp_restore x86_64: emitSpRestoreFull frame_bytes=16 → MOV RSP,RBP + SUB RSP,#16 (Imm8 = 7 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpRestoreFull(testing.allocator, &buf, .rbp, 16);
    try testing.expectEqual(@as(usize, 7), buf.items.len);
    // MOV RSP, RBP → 48 89 EC
    try testing.expectEqual(@as(u8, 0x48), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x89), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xEC), buf.items[2]);
    // SUB RSP, 16 → 48 83 EC 10
    try testing.expectEqual(@as(u8, 0x48), buf.items[3]);
    try testing.expectEqual(@as(u8, 0x83), buf.items[4]);
    try testing.expectEqual(@as(u8, 0xEC), buf.items[5]);
    try testing.expectEqual(@as(u8, 0x10), buf.items[6]);
}

test "sp_restore x86_64: emitSpRestoreFull frame_bytes=256 promotes SUB to Imm32 (10 bytes)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitSpRestoreFull(testing.allocator, &buf, .rbp, 256);
    try testing.expectEqual(@as(usize, 10), buf.items.len);
    // MOV RSP, RBP (3 bytes) + SUB RSP, 256 via Imm32 (7 bytes).
    try testing.expectEqual(@as(u8, 0x81), buf.items[4]); // Imm32 opcode
    try testing.expectEqual(@as(u8, 0x00), buf.items[6]); // low byte of 256
    try testing.expectEqual(@as(u8, 0x01), buf.items[7]); // high byte of 256
}
