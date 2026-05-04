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

/// Caller-saved (volatile) GPRs other than args. AAPCS64
/// classifies X9..X15 as caller-clobberable temporaries; the
/// §9.7 / 7.3 emit pass uses these as scratch between calls.
/// (X0..X7 are caller-saved too but conceptually serve as args/
/// returns rather than scratch.)
pub const caller_saved_scratch_gprs = [_]Xn{ 9, 10, 11, 12, 13, 14, 15 };

/// Reserved for spill load/store staging (per ADR-0018). The
/// emit pass uses these as scratches when materialising a
/// spilled vreg's value into a register before an op, or
/// writing a result back to its spill slot. Two stage regs
/// support binary ops where both operands are spilled.
///
/// Excluded from `allocatable_gprs` by construction. X16/X17
/// (IP0/IP1) cannot serve this role because §9.7 / 7.3 sub-g3c
/// already uses them mid-op for call_indirect's idx/typeidx
/// pipeline; using them for spill staging would clobber
/// in-flight values.
pub const spill_stage_gprs = [_]Xn{ 14, 15 };

/// Caller-saved scratch minus the spill-stage carve-out. Used by
/// `allocatable_gprs` so the regalloc never lands a vreg on a
/// stage reg.
pub const allocatable_caller_saved_scratch_gprs = [_]Xn{ 9, 10, 11, 12, 13 };

/// Intra-procedure-call scratch (linker-clobbered). Reserved
/// for the platform's PLT veneer; emit may use these only
/// short-lived.
pub const ip_gprs = [_]Xn{ 16, 17 };

/// Platform-reserved register — Apple/Darwin AAPCS reserves X18
/// for the OS, so we treat it as never-allocatable.
pub const platform_gpr: Xn = 18;

/// Callee-saved (non-volatile) GPRs per AAPCS64 §6.4.1.
/// Callee must preserve these across calls; saved in prologue,
/// restored in epilogue. The full callee-saved range is
/// X19..X28; `reserved_invariant_gprs` carves out X24..X28 for
/// JitRuntime-derived invariants (per ADR-0017 / 0018), leaving
/// `allocatable_callee_saved_gprs` (X19..X23) available to the
/// regalloc.
pub const callee_saved_gprs = [_]Xn{ 19, 20, 21, 22, 23, 24, 25, 26, 27, 28 };

/// Registers reserved for runtime invariants (per ADR-0017 +
/// ADR-0018):
///   X28 — vm_base       (linear-memory base pointer)
///   X27 — mem_limit     (linear-memory size in bytes)
///   X26 — funcptr_base  (table 0 — array of u64 funcptrs)
///   X25 — table_size    (W25 = u32 count of entries)
///   X24 — typeidx_base  (parallel array of u32 typeidx values)
///
/// The function prologue LDRs these from `*X0` (= `*const
/// JitRuntime`) once per call (ADR-0017). They are excluded from
/// the regalloc pool by construction — `allocatable_gprs` is
/// defined as the complement, so a future reorganisation that
/// adds or removes a reserved reg automatically propagates.
pub const reserved_invariant_gprs = [_]Xn{ 24, 25, 26, 27, 28 };

/// Allocatable callee-saved GPRs = callee_saved_gprs minus
/// reserved_invariant_gprs. Five regs (X19..X23). Kept as its
/// own constant so `allocatable_gprs` reads cleanly and
/// `audit_scaffolding` can spot-check the reservation invariant
/// (ADR-0018 §I).
pub const allocatable_callee_saved_gprs = [_]Xn{ 19, 20, 21, 22, 23 };

pub const frame_pointer: Xn = 29;
pub const link_register: Xn = 30;

/// Pool of GPRs the regalloc may freely use, in priority order:
/// caller-saved scratch first (cheapest, no prologue cost), then
/// allocatable callee-saved (forces save/restore but invariant-safe).
///
/// **Excluded from the pool by construction**:
///   - X0..X7 (arg / return marshalling)
///   - X8 (indirect-result-location ptr)
///   - X16/X17 (IP0/IP1, used as op-handler scratches per
///     `single_slot_dual_meaning.md`)
///   - X18 (Apple/Darwin platform-reserved)
///   - X24..X28 (`reserved_invariant_gprs` per ADR-0017+0018)
///   - X29 (FP), X30 (LR), X31 (SP/XZR)
///
/// Pool size: 10 (was 17 pre-ADR-0018). A function with > 10
/// concurrently-live vregs spills to the function's spill frame
/// per ADR-0018. Slot ids 0..9 resolve via this table; slot ids
/// 10+ resolve to `Slot.spill` byte offsets (consumed by the
/// emit pass via `regalloc.Allocation.slot()`).
pub const allocatable_gprs = allocatable_caller_saved_scratch_gprs ++ allocatable_callee_saved_gprs;

// Compile-time invariant: allocatable / reserved / spill_stage
// sets are pairwise disjoint. Catching overlap at comptime is
// the structural fix for the W54-class regression that motivated
// ADR-0018.
comptime {
    for (allocatable_gprs) |a| {
        for (reserved_invariant_gprs) |r| {
            if (a == r) @compileError("regalloc pool overlaps reserved_invariant_gprs — ADR-0018 invariant violated");
        }
        for (spill_stage_gprs) |s| {
            if (a == s) @compileError("regalloc pool overlaps spill_stage_gprs — ADR-0018 invariant violated");
        }
    }
}

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

test "allocatable_gprs covers allocatable-caller-scratch + allocatable-callee-saved (10 regs post-ADR-0018)" {
    try testing.expectEqual(@as(usize, 10), allocatable_gprs.len);
}

test "reserved_invariant_gprs is exactly X24..X28 (5 regs)" {
    try testing.expectEqual(@as(usize, 5), reserved_invariant_gprs.len);
    const expected = [_]Xn{ 24, 25, 26, 27, 28 };
    for (reserved_invariant_gprs, expected) |a, e| try testing.expectEqual(e, a);
}

test "spill_stage_gprs is exactly X14, X15 (2 regs for binary-op spill staging)" {
    try testing.expectEqual(@as(usize, 2), spill_stage_gprs.len);
    try testing.expectEqual(@as(Xn, 14), spill_stage_gprs[0]);
    try testing.expectEqual(@as(Xn, 15), spill_stage_gprs[1]);
}

test "allocatable_gprs is pairwise disjoint with reserved + spill_stage (runtime check; comptime guard above)" {
    for (allocatable_gprs) |a| {
        for (reserved_invariant_gprs) |r| try testing.expect(a != r);
        for (spill_stage_gprs) |s| try testing.expect(a != s);
    }
}

test "slotToReg: slot 0 maps to x9 (first allocatable caller-scratch)" {
    try testing.expectEqual(@as(Xn, 9), slotToReg(0).?);
}

test "slotToReg: slot 4 maps to x13 (last allocatable caller-scratch; X14/X15 reserved for spill staging)" {
    try testing.expectEqual(@as(Xn, 13), slotToReg(4).?);
}

test "slotToReg: slot 5 maps to x19 (first allocatable callee-saved; caller-scratch exhausts at slot 4)" {
    try testing.expectEqual(@as(Xn, 19), slotToReg(5).?);
}

test "slotToReg: slot 9 maps to x23 (last allocatable callee-saved before reserved invariants)" {
    try testing.expectEqual(@as(Xn, 23), slotToReg(9).?);
}

test "slotToReg: slot 10 returns null (pool exhausted; spill territory per ADR-0018)" {
    try testing.expect(slotToReg(10) == null);
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
