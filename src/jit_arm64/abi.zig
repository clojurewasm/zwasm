//! AAPCS64 calling-convention tables (§9.7 / 7.2 chunk b).
//!
//! Declares the AArch64 register inventory the §9.7 / 7.3 emit
//! pass consults: which X-registers carry function arguments,
//! which are caller-saved vs callee-saved, the link / frame /
//! stack pointer slots, and a `slotToReg` mapper translating a
//! regalloc slot id (from §9.7 / 7.1) into a concrete `Xn`.
//!
//! Per AAPCS64 (Arm IHI 0055 — Procedure Call Standard for the
//! Arm 64-bit Architecture):
//!
//!   X0..X7      arg / return registers (also caller-saved)
//!   X8          indirect result location
//!   X9..X15     temporaries (caller-saved)
//!   X16, X17    intra-procedure-call scratch (IP0, IP1)
//!   X18         platform reg (do not use on Apple/Darwin)
//!   X19..X28    callee-saved
//!   X29 (FP)    frame pointer
//!   X30 (LR)    link register
//!   X31         SP / XZR (depends on opcode)
//!
//! Phase 7.2 chunk-b scope: declarative tables only + the
//! `slotToReg` mapper. Real spill-slot allocation lives in
//! §9.7 / 7.1's regalloc; this module only translates "slot N
//! of the GPR class" into "Xn".
//!
//! Zone 2 (`src/jit_arm64/`).

const std = @import("std");

const inst = @import("inst.zig");
const Xn = inst.Xn;

/// First 8 X-registers carry function arguments + return values
/// (X0 is the primary return register).
pub const arg_gprs = [_]Xn{ 0, 1, 2, 3, 4, 5, 6, 7 };

/// X8 is the indirect-result-location pointer when the callee
/// returns a struct via memory.
pub const indirect_result_gpr: Xn = 8;

/// Caller-saved (volatile) GPRs other than args. The §9.7 / 7.3
/// emit pass uses these as scratch between calls. (X0..X7 are
/// caller-saved too but conceptually serve as args/returns
/// rather than scratch.)
pub const caller_saved_scratch_gprs = [_]Xn{ 9, 10, 11, 12, 13, 14, 15 };

/// Intra-procedure-call scratch (linker-clobbered). Reserved
/// for the platform's PLT veneer; emit may use these only
/// short-lived.
pub const ip_gprs = [_]Xn{ 16, 17 };

/// Platform-reserved register — Apple/Darwin AAPCS reserves X18
/// for the OS, so we treat it as never-allocatable.
pub const platform_gpr: Xn = 18;

/// Callee-saved (non-volatile) GPRs. The §9.7 / 7.3 emit pass
/// uses these for vregs that span calls — the prologue saves
/// them, the epilogue restores them.
pub const callee_saved_gprs = [_]Xn{ 19, 20, 21, 22, 23, 24, 25, 26, 27, 28 };

pub const frame_pointer: Xn = 29;
pub const link_register: Xn = 30;

/// Pool of GPRs the regalloc may freely use, in priority order:
/// caller-saved scratch first (cheapest, no prologue cost), then
/// callee-saved (forces save/restore). X0..X7 are NOT in this
/// pool by default — emit reserves them for arg / return
/// marshalling. X8 / X16-18 / X29-30 are reserved for special
/// purposes.
pub const allocatable_gprs = caller_saved_scratch_gprs ++ callee_saved_gprs;

/// Translate a regalloc slot id (from `jit/regalloc.compute`)
/// into a concrete X-register via the allocatable pool.
/// Returns null when the slot id exceeds the pool size — the
/// §9.7 / 7.3 emit pass treats that as a cue to spill (Phase-7
/// follow-up; today we error rather than silently drop).
pub fn slotToReg(slot_id: u8) ?Xn {
    if (slot_id >= allocatable_gprs.len) return null;
    return allocatable_gprs[slot_id];
}

/// Float / SIMD V-register pool (caller-saved scratch range,
/// V16..V30 → 15 slots). V31 is reserved for popcnt's V-register
/// pipeline. V0..V7 are arg/return; V8..V15 callee-saved (skipped
/// to avoid prologue cost). `fpSlotToReg` is the float-class
/// counterpart of `slotToReg` — the §9.7 / 7.3 sub-d3 f32/f64
/// handlers use it.
///
/// **Mixing caveat**: a vreg's slot id is per-class. Within a
/// single function's live ranges, a slot id used by a GPR vreg
/// and a slot id used by a V-vreg map to *different* physical
/// registers (X9 vs V16 for slot 0). This is correct semantically
/// because the regalloc only ensures non-overlapping VREG ids,
/// not non-overlapping physical regs. Phase-7 follow-up will add
/// per-class slot pools so the regalloc is fully class-aware;
/// today the int + float pools coexist by physical-register
/// disjointness.
pub const allocatable_v_regs = [_]Xn{
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
};

pub fn fpSlotToReg(slot_id: u8) ?Xn {
    if (slot_id >= allocatable_v_regs.len) return null;
    return allocatable_v_regs[slot_id];
}

/// Is `xn` caller-saved per AAPCS64? Used by emit to decide
/// whether a vreg held in `xn` needs a save before a call.
pub fn isCallerSaved(xn: Xn) bool {
    if (xn <= 7) return true; // args/returns
    if (xn >= 9 and xn <= 17) return true; // scratch + IP0/1
    return false;
}

/// Is `xn` callee-saved per AAPCS64? Inverse of caller-saved
/// for the allocatable range; FP/LR/SP/PR return false.
pub fn isCalleeSaved(xn: Xn) bool {
    return xn >= 19 and xn <= 28;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "arg_gprs covers x0..x7" {
    try testing.expectEqual(@as(usize, 8), arg_gprs.len);
    for (arg_gprs, 0..) |x, i| {
        try testing.expectEqual(@as(Xn, @intCast(i)), x);
    }
}

test "callee_saved_gprs covers x19..x28" {
    try testing.expectEqual(@as(usize, 10), callee_saved_gprs.len);
    try testing.expectEqual(@as(Xn, 19), callee_saved_gprs[0]);
    try testing.expectEqual(@as(Xn, 28), callee_saved_gprs[9]);
}

test "allocatable_gprs covers caller-scratch + callee-saved (17 regs)" {
    try testing.expectEqual(@as(usize, 17), allocatable_gprs.len);
}

test "slotToReg: slot 0 maps to x9 (first caller-scratch)" {
    try testing.expectEqual(@as(Xn, 9), slotToReg(0).?);
}

test "slotToReg: slot 7 falls into callee_saved (x19) since caller_scratch exhausts at slot 6 (x15)" {
    try testing.expectEqual(@as(Xn, 19), slotToReg(7).?);
}

test "slotToReg: out-of-pool slot returns null (cue to spill)" {
    try testing.expect(slotToReg(99) == null);
}

test "isCallerSaved: x0..x7, x9..x17" {
    try testing.expect(isCallerSaved(0));
    try testing.expect(isCallerSaved(7));
    try testing.expect(isCallerSaved(9));
    try testing.expect(isCallerSaved(17));
    try testing.expect(!isCallerSaved(19));
    try testing.expect(!isCallerSaved(28));
    try testing.expect(!isCallerSaved(30)); // LR
}

test "isCalleeSaved: x19..x28" {
    try testing.expect(isCalleeSaved(19));
    try testing.expect(isCalleeSaved(28));
    try testing.expect(!isCalleeSaved(0));
    try testing.expect(!isCalleeSaved(18)); // platform reg
    try testing.expect(!isCalleeSaved(29)); // FP
}

test "frame_pointer + link_register tracked" {
    try testing.expectEqual(@as(Xn, 29), frame_pointer);
    try testing.expectEqual(@as(Xn, 30), link_register);
}

test "fpSlotToReg: slot 0 → V16 (first caller-saved scratch V)" {
    try testing.expectEqual(@as(Xn, 16), fpSlotToReg(0).?);
}

test "fpSlotToReg: slot 14 → V30 (last in the 15-slot pool)" {
    try testing.expectEqual(@as(Xn, 30), fpSlotToReg(14).?);
}

test "fpSlotToReg: slot 15 returns null (V31 reserved for popcnt scratch)" {
    try testing.expect(fpSlotToReg(15) == null);
}
