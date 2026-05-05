//! x86_64 calling-convention tables (§9.7 / 7.6 chunk c).
//!
//! Mirrors the role of `arm64/abi.zig`'s ABI tables but for the
//! AMD64 / Intel® 64 architecture under the System V x86_64 ABI
//! (Linux, macOS, BSD). Win64 ABI (Windows) lands in a follow-up
//! chunk c2 — selecting between the two adds a `Cc` enum + a
//! per-target binding layer that emit.zig consumes; today there
//! is no x86_64 emit pass yet so the second-CC plumbing has no
//! consumer.
//!
//! Per the AMD64 ABI v0.99.6 §3.2:
//!
//!   RAX                  primary return value
//!   RDX                  secondary return (128-bit / pair)
//!   RDI, RSI, RDX, RCX,
//!   R8, R9               integer args (in order; 6 regs)
//!   XMM0..XMM7           FP args (in order; 8 regs)
//!   XMM0, XMM1           FP return values
//!   RBX, RBP, R12, R13,
//!   R14, R15             callee-saved (preserved across calls)
//!   RAX, RCX, RDX, RSI,
//!   RDI, R8, R9, R10,
//!   R11, XMM0..XMM15     caller-saved (volatile across calls)
//!   RSP                  stack pointer
//!   R10                  static chain (rarely used)
//!   R11                  intra-procedure scratch (PLT, etc.)
//!
//! Phase 7.6 chunk-c scope: declarative ABI tables + the
//! `slotToReg` / `fpSlotToReg` mappers. Three load-bearing
//! consumers are intentionally deferred:
//!
//!   - **`reserved_invariant_gprs`** (mirrors arm64's X28/X27/
//!     X26/X25/X24/X19 reservation pattern). x86_64 has only 6
//!     callee-saved GPRs in the SysV-∩-Win64 intersection; if
//!     all six were reserved, the regalloc pool would collapse
//!     to 2 caller-saved scratch regs (R10, R11). The reservation
//!     model needs a per-arch design decision — likely "reload
//!     invariants from runtime_ptr at point of use" rather than
//!     arm64's "load once into callee-saved at prologue", trading
//!     per-use latency for pool size. That decision belongs with
//!     emit.zig prologue design (§9.7 / 7.7) not the ABI table.
//!   - **`spill_stage_gprs`** (mirrors arm64's X14/X15). Awaits
//!     the spill-aware emit port that mirrors arm64's sub-1c.
//!   - **Win64 ABI**: distinct arg regs (RCX/RDX/R8/R9), 32-byte
//!     shadow space, RSI/RDI callee-saved. The `Cc` enum + per-
//!     target binding lands in chunk c2 once emit.zig has a
//!     concrete consumer for the choice.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

const reg_class = @import("reg_class.zig");

pub const Gpr = reg_class.Gpr;
pub const Xmm = reg_class.Xmm;

/// First 6 GPR arg slots per System V x86_64 ABI §3.2.3, in
/// canonical pass order (arg0 → RDI, arg1 → RSI, …).
pub const arg_gprs = [_]Gpr{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

/// First 8 XMM slots carry FP args per System V §3.2.3 (arg0 →
/// XMM0, arg1 → XMM1, …, arg7 → XMM7).
pub const arg_xmms = [_]Xmm{ .xmm0, .xmm1, .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7 };

/// Primary integer return register (RAX). Secondary (RDX) is
/// used for 128-bit / pair returns; emit currently rejects
/// multi-result so RDX-as-return-2 is unimplemented.
pub const return_gpr: Gpr = .rax;

/// Primary FP return register (XMM0). Secondary (XMM1) is used
/// for pair returns; same multi-result restriction applies.
pub const return_xmm: Xmm = .xmm0;

/// Callee-saved (non-volatile) GPRs per System V §3.2.1. Callee
/// must preserve these across calls; saved in prologue, restored
/// in epilogue. Note: this set is identical to the SysV-∩-Win64
/// intersection (Win64 also has RBX/RBP/R12-R15 as callee-saved
/// plus RDI/RSI), so picking from this list keeps a future Cc-
/// agnostic reservation portable.
pub const callee_saved_gprs = [_]Gpr{ .rbx, .rbp, .r12, .r13, .r14, .r15 };

/// Caller-saved (volatile) GPRs per System V §3.2.1. Caller must
/// save these before a call if the value is needed afterwards.
/// Includes the 6 arg regs + RAX (return) + R10 (static chain) +
/// R11 (intra-procedure scratch).
pub const caller_saved_gprs = [_]Gpr{ .rax, .rcx, .rdx, .rdi, .rsi, .r8, .r9, .r10, .r11 };

/// Stack pointer (always RSP per AMD64 spec).
pub const stack_pointer: Gpr = .rsp;

/// Frame pointer (RBP by convention; AMD64 omits-frame-pointer
/// is permitted). Phase 7.7 emit will adopt the non-FP shape
/// per ROADMAP P3 (cold-start; smaller prologue) unless the
/// ADR-0017 mapping for x86_64 prologue revisits this.
pub const frame_pointer: Gpr = .rbp;

/// Caller-saved scratch GPRs other than args / return. R10 +
/// R11 are the SysV "general scratch" regs — RAX is excluded
/// here because it's the return slot (its post-call value is
/// the function's return) and arg regs RDI..R9 are excluded
/// because they carry args at call sites.
pub const allocatable_caller_saved_scratch_gprs = [_]Gpr{ .r10, .r11 };

/// Pool of GPRs the regalloc may freely use, in priority order:
/// caller-saved scratch first (cheapest, no prologue cost), then
/// the full callee-saved set.
///
/// **Excluded from the pool by construction**:
///   - RDI, RSI, RDX, RCX, R8, R9 (arg marshalling — caller
///     must own these around call sites)
///   - RAX (return slot)
///   - RSP (stack pointer)
///
/// **NOT yet excluded** (compared to arm64's `reserved_invariant_
/// gprs`): the JitRuntime invariants (vm_base / mem_limit /
/// funcptr_base / table_size / typeidx_base / runtime_ptr_save).
/// On arm64 those reserve 6 of the 10 callee-saved X-registers.
/// On x86_64 only 6 callee-saved GPRs exist total — applying the
/// same reservation depth would collapse the pool. The decision
/// (reload-from-runtime-ptr vs arm64-style load-once-to-callee-
/// saved) is deferred to §9.7 / 7.7 emit prologue design; the
/// pool below is the upper bound the post-decision pool will
/// shrink from.
///
/// Pool size: 8 (R10, R11 + RBX, RBP, R12..R15). For comparison
/// arm64's pool is 9 (X9..X13 + X20..X23) post-ADR-0017 sub-2d-ii.
pub const allocatable_gprs = allocatable_caller_saved_scratch_gprs ++ callee_saved_gprs;

// Compile-time invariant: allocatable_gprs is disjoint from the
// arg / return slots — the arm64-style W54-class structural fix
// against pool/role overlap.
comptime {
    for (allocatable_gprs) |a| {
        for (arg_gprs) |arg| {
            if (a == arg) @compileError("regalloc pool overlaps arg_gprs — SysV §3.2.3 invariant violated");
        }
        if (a == return_gpr) @compileError("regalloc pool overlaps return_gpr — SysV §3.2.1 invariant violated");
        if (a == stack_pointer) @compileError("regalloc pool overlaps stack_pointer");
    }
}

/// XMM regalloc pool. SysV calls have all of XMM0..XMM15 as
/// caller-saved, so we use XMM6..XMM15 (skipping the arg regs
/// XMM0..XMM5 which marshal at call sites; XMM6, XMM7 are also
/// arg slots 6/7 — but realistic functions take ≤ 6 FP args so
/// XMM6/XMM7 are usable for vregs in the common case). XMM7
/// is reserved as a SIMD scratch (mirroring arm64's V31 popcnt
/// scratch); the regalloc pool starts at XMM8.
///
/// TODO(p7-7.7): when emit.zig has a concrete consumer, decide
/// whether to make XMM6/XMM7 allocatable and arrange call-site
/// save/restore — saving 2 slots may matter for FP-heavy code.
pub const allocatable_xmms = [_]Xmm{
    .xmm8, .xmm9, .xmm10, .xmm11, .xmm12, .xmm13, .xmm14, .xmm15,
};

/// Translate a regalloc slot id (from `engine/codegen/shared/
/// regalloc.compute`) into a concrete GPR via the allocatable
/// pool. Returns null when the slot id exceeds the pool size —
/// the §9.7 / 7.7 emit pass treats that as a cue to spill.
pub fn slotToReg(slot_id: u8) ?Gpr {
    if (slot_id >= allocatable_gprs.len) return null;
    return allocatable_gprs[slot_id];
}

/// FP-class counterpart of `slotToReg`.
pub fn fpSlotToReg(slot_id: u8) ?Xmm {
    if (slot_id >= allocatable_xmms.len) return null;
    return allocatable_xmms[slot_id];
}

/// Is `g` caller-saved per SysV x86_64? Used by emit to decide
/// whether a vreg held in `g` needs a save before a call.
pub fn isCallerSaved(g: Gpr) bool {
    for (caller_saved_gprs) |c| {
        if (c == g) return true;
    }
    return false;
}

/// Is `g` callee-saved per SysV x86_64? Inverse of caller-saved
/// for the allocatable range; RSP returns false.
pub fn isCalleeSaved(g: Gpr) bool {
    for (callee_saved_gprs) |c| {
        if (c == g) return true;
    }
    return false;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "arg_gprs covers RDI, RSI, RDX, RCX, R8, R9 in SysV order" {
    try testing.expectEqual(@as(usize, 6), arg_gprs.len);
    try testing.expectEqual(Gpr.rdi, arg_gprs[0]);
    try testing.expectEqual(Gpr.rsi, arg_gprs[1]);
    try testing.expectEqual(Gpr.rdx, arg_gprs[2]);
    try testing.expectEqual(Gpr.rcx, arg_gprs[3]);
    try testing.expectEqual(Gpr.r8,  arg_gprs[4]);
    try testing.expectEqual(Gpr.r9,  arg_gprs[5]);
}

test "arg_xmms covers XMM0..XMM7" {
    try testing.expectEqual(@as(usize, 8), arg_xmms.len);
    try testing.expectEqual(Xmm.xmm0, arg_xmms[0]);
    try testing.expectEqual(Xmm.xmm7, arg_xmms[7]);
}

test "callee_saved_gprs covers RBX, RBP, R12..R15" {
    try testing.expectEqual(@as(usize, 6), callee_saved_gprs.len);
    try testing.expectEqual(Gpr.rbx, callee_saved_gprs[0]);
    try testing.expectEqual(Gpr.rbp, callee_saved_gprs[1]);
    try testing.expectEqual(Gpr.r12, callee_saved_gprs[2]);
    try testing.expectEqual(Gpr.r15, callee_saved_gprs[5]);
}

test "return_gpr is RAX, return_xmm is XMM0" {
    try testing.expectEqual(Gpr.rax, return_gpr);
    try testing.expectEqual(Xmm.xmm0, return_xmm);
}

test "allocatable_gprs is 8 regs (R10, R11, RBX, RBP, R12..R15)" {
    try testing.expectEqual(@as(usize, 8), allocatable_gprs.len);
    try testing.expectEqual(Gpr.r10, allocatable_gprs[0]);
    try testing.expectEqual(Gpr.r11, allocatable_gprs[1]);
    try testing.expectEqual(Gpr.rbx, allocatable_gprs[2]);
}

test "allocatable_gprs is disjoint from arg/return at runtime" {
    for (allocatable_gprs) |a| {
        for (arg_gprs) |arg| try testing.expect(a != arg);
        try testing.expect(a != return_gpr);
        try testing.expect(a != stack_pointer);
    }
}

test "slotToReg: slot 0 → R10 (first allocatable caller-saved scratch)" {
    try testing.expectEqual(Gpr.r10, slotToReg(0).?);
}

test "slotToReg: slot 2 → RBX (first callee-saved after the 2 caller-scratch)" {
    try testing.expectEqual(Gpr.rbx, slotToReg(2).?);
}

test "slotToReg: slot 7 → R15 (last in the 8-slot pool)" {
    try testing.expectEqual(Gpr.r15, slotToReg(7).?);
}

test "slotToReg: slot 8 returns null (pool exhausted; spill territory)" {
    try testing.expect(slotToReg(8) == null);
}

test "fpSlotToReg: slot 0 → XMM8 (first allocatable XMM after arg regs)" {
    try testing.expectEqual(Xmm.xmm8, fpSlotToReg(0).?);
}

test "fpSlotToReg: slot 7 → XMM15 (last in the 8-slot pool)" {
    try testing.expectEqual(Xmm.xmm15, fpSlotToReg(7).?);
}

test "fpSlotToReg: slot 8 returns null" {
    try testing.expect(fpSlotToReg(8) == null);
}

test "isCallerSaved: SysV caller-saved set" {
    try testing.expect(isCallerSaved(.rax));
    try testing.expect(isCallerSaved(.rcx));
    try testing.expect(isCallerSaved(.rdi));
    try testing.expect(isCallerSaved(.r10));
    try testing.expect(isCallerSaved(.r11));
    try testing.expect(!isCallerSaved(.rbx));
    try testing.expect(!isCallerSaved(.r15));
}

test "isCalleeSaved: SysV callee-saved set" {
    try testing.expect(isCalleeSaved(.rbx));
    try testing.expect(isCalleeSaved(.rbp));
    try testing.expect(isCalleeSaved(.r12));
    try testing.expect(isCalleeSaved(.r15));
    try testing.expect(!isCalleeSaved(.rax));
    try testing.expect(!isCalleeSaved(.rdi));
    try testing.expect(!isCalleeSaved(.rsp));
}

test "frame_pointer + stack_pointer tracked" {
    try testing.expectEqual(Gpr.rbp, frame_pointer);
    try testing.expectEqual(Gpr.rsp, stack_pointer);
}
