//! x86_64 tail-call emit helpers (ADR-0112 D2 + D4).
//!
//! Mirror of `arm64/op_tail_call.zig`. Per ADR-0112 D4 the
//! emit sequence is:
//!
//!   (1) marshal args → RDI/RSI/RDX/RCX/R8/R9 + XMM0..7
//!   (2) load callee_rt → RDI
//!   (3) load callee_entry → R11
//!   (4) frame_teardown.emit(…)
//!   (5) JMP R11
//!
//! This file currently lands step (5) — `emitTailJump` — as the
//! observable foundation. Subsequent chunks layer on the rest.
//!
//! INVARIANT (ADR-0112 D7): the segment from frame_teardown
//! start through JMP R11 contains NO allocator calls, NO
//! host-call dispatches, NO signal-check branches.
//!
//! Spec: Wasm Core 3.0 §3.3.8.18-20 (tail-call proposal).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const abi = @import("abi.zig");

/// R11 — System V AMD64 caller-saved scratch (no fixed role in
/// the ABI) per System V §3.2.3. ADR-0066 § (bridge thunk)
/// already uses RAX as the callee-target-load register; tail-
/// call uses R11 to keep RAX free for the callee's prologue
/// (which expects RAX clobber by `marshalReturnRegs` on RET).
/// R11 also matches the convention in
/// `src/engine/codegen/x86_64/op_call.zig`'s indirect-call path
/// where R11 holds the resolved funcptr through the CALL.
pub const tail_target_gpr: inst.Gpr = .r11;

/// Emit step (2) of the ADR-0112 D4 tail-call sequence for
/// the SAME-MODULE case: restore RDI = runtime_ptr so the
/// callee's prologue (which does `MOV R15, RDI` per ADR-0026
/// Cc-pivot) sees the correct runtime pointer. For
/// same-module tail-call, caller_rt == callee_rt and R15 is
/// already correct, so we simply `MOV RDI, R15`.
///
/// Cross-module tail-call (ADR-0112 D4 / 10.TC-3f follow-on)
/// loads callee_rt from the caller's literal pool instead;
/// that path lives in `cross_module_tail_call.zig`.
pub fn emitLoadCalleeRtSameModule(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
) !void {
    // MOV RDI, R15 — 64-bit reg-to-reg move.
    const enc = inst.encMovRR(.q, .rdi, abi.runtime_ptr_save_gpr);
    try buf.appendSlice(allocator, enc.slice());
}

/// Emit step (5) of the ADR-0112 D4 tail-call sequence: the
/// `JMP R11` unconditional indirect branch to the callee entry.
/// Caller MUST have already loaded the callee target into R11
/// and emitted `frame_teardown.emit(...)` immediately above this
/// (the safepoint-free invariant per ADR-0112 D7).
pub fn emitTailJump(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    target: inst.Gpr,
) !void {
    const enc = inst.encJmpReg(target);
    try buf.appendSlice(allocator, enc.slice());
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots for the JMP r encoder. Mac-host
// tests verify the encoding directly via the x86_64 encoders.
// ---------------------------------------------------------------------

const testing = std.testing;

test "op_tail_call x86_64: emitTailJump R11 → 41 FF E3 (REX.B + JMP r/m64 /4)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, tail_target_gpr);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    // JMP R11 = 41 FF E3
    //   41 = REX.B (R11 high bit)
    //   FF = FF /4 opcode for JMP r/m64
    //   E3 = ModR/M: mod=11, reg=4 (/4 = JMP), rm=3 (R11 low 3 bits)
    try testing.expectEqual(@as(u8, 0x41), buf.items[0]);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xE3), buf.items[2]);
}

test "op_tail_call x86_64: emitTailJump RAX → FF E0 (no REX, ADR-0066 bridge thunk shape)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, .rax);
    try testing.expectEqual(@as(usize, 2), buf.items.len);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[0]);
    try testing.expectEqual(@as(u8, 0xE0), buf.items[1]);
}

test "op_tail_call x86_64: tail_target_gpr is R11 (System V scratch, not RAX)" {
    try testing.expectEqual(inst.Gpr.r11, tail_target_gpr);
}

test "op_tail_call x86_64: emitLoadCalleeRtSameModule emits MOV RDI, R15 (4C 89 FF)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitLoadCalleeRtSameModule(testing.allocator, &buf);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    // MOV RDI, R15 → 4C 89 FF
    //   4C = REX.W + REX.R (R15 is reg-side via the MOV r/m, r form)
    //   89 = MOV r/m64, r64
    //   FF = ModR/M: mod=11, reg=7 (R15 low 3), rm=7 (RDI)
    try testing.expectEqual(@as(u8, 0x4C), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x89), buf.items[1]);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[2]);
}

test "op_tail_call x86_64: emitLoadCalleeRtSameModule uses abi.runtime_ptr_save_gpr (R15) as source" {
    try testing.expectEqual(inst.Gpr.r15, abi.runtime_ptr_save_gpr);
}
