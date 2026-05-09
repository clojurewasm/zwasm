//! x86_64 emit pass — SIMD-128 op handlers (§9.7 / 9.7-a + 9.7-b
//! per ADR-0041).
//!
//! Mirrors the role of `arm64/op_simd.zig` for the SSE2 / SSE4.1
//! lowering of v128 ops. The shape-tag pipeline itself
//! (`engine/codegen/shared/regalloc.populateShapeTags`) is shared
//! across arches per ADR-0041 §"Decision" / 2 and needs no
//! x86_64-side wiring.
//!
//! 9.7-a + 9.7-b scope (packed integer add/sub family — 8 ops):
//!
//! - `emitV128IntBinop(encoder)` — shared helper. Pop 2 v128;
//!   `MOVAPS dst, lhs` (elided when dst aliases lhs) then
//!   `<encoder>(dst, rhs)`; push result. v128 reg-reg copy uses
//!   `encMovapsXmmXmm` (0F 28 /r): MOVAPS and MOVDQA are
//!   interchangeable for register-to-register moves on every
//!   shipped Intel/AMD micro-architecture.
//! - 8 per-op wrappers (`emitI8x16Add` / `emitI8x16Sub` /
//!   `emitI16x8Add` / `emitI16x8Sub` / `emitI32x4Add` /
//!   `emitI32x4Sub` / `emitI64x2Add` / `emitI64x2Sub`) — each
//!   one-line dispatch into `emitV128IntBinop` with the
//!   appropriate `inst.encPadd*` / `inst.encPsub*` encoder.
//!
//! Out of scope (defers to later 9.7 chunks):
//!
//! - v128 spill helpers (16-byte stride MOVDQU). The existing
//!   `gpr.xmmLoadSpilled` / `xmmDefSpilled` use 8-byte MOVSD
//!   which truncates the upper 64 bits of an XMM. Spilled v128
//!   vregs therefore return `Error.UnsupportedOp` via
//!   `gpr.resolveXmm` until the 16-byte spill helpers land
//!   (queued for 9.7-c).
//! - v128.const / v128.load / v128.store / splat / extract_lane
//!   / replace_lane / mul / compare / shuffle / FP arith / FP
//!   compare / convert. Each of these introduces new encoder
//!   families or non-trivial synthesis (e.g. PMULLD requires
//!   SSE4.1 minimum baseline; i64x2.mul has no native form),
//!   so they ship as separate chunks per the chunk-bundle rule.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");

const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// Shared v128 packed-integer binop helper. Wasm spec §4.4.4
/// (packed integer add/sub) — pop two v128, push their
/// element-wise wraparound result. x86_64 lowering: `MOVAPS dst,
/// lhs` (elided when dst already aliases lhs) followed by
/// `<encoder>(dst, rhs)` (PADDB/W/D/Q or PSUBB/W/D/Q per the
/// caller's encoder choice). Mirror of ARM64's
/// `arm64/op_simd.emitV128Binop` shape; ARM64's three-address
/// `ADD Vd.<T>, Vn.<T>, Vm.<T>` collapses both the MOV and the
/// op into one instruction, which has no x86_64 equivalent until
/// AVX VPADD* (out of scope per ADR-0041 §"5. SSE4.1 minimum
/// baseline").
///
/// Spilled v128 vregs surface as `Error.UnsupportedOp` from
/// `gpr.resolveXmm` — the 16-byte MOVDQU spill helpers land in
/// 9.7-c. Until then, functions whose v128 vregs all fit in
/// `abi.allocatable_xmms` (XMM8..XMM13, 6 slots) compile cleanly;
/// over-pressure functions return early.
fn emitV128IntBinop(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    try buf.appendSlice(allocator, encoder(dst_x, rhs_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

// Per-Wasm-op wrappers. Each is a 1-line dispatch into the
// shared helper with the appropriate encoder. The function names
// document the spec op (Wasm spec §4.4.4 packed integer add/sub).

pub fn emitI8x16Add(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPaddB);
}

pub fn emitI8x16Sub(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubB);
}

pub fn emitI16x8Add(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPaddW);
}

pub fn emitI16x8Sub(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubW);
}

pub fn emitI32x4Add(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPaddD);
}

pub fn emitI32x4Sub(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubD);
}

pub fn emitI64x2Add(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPaddQ);
}

pub fn emitI64x2Sub(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubQ);
}

// §9.7-c: native multiply ops. i16x8.mul reaches PMULLW (SSE2);
// i32x4.mul reaches PMULLD (SSE4.1). i64x2.mul has no native
// SSE4.1 instruction and synthesises via PMULUDQ + shifts/adds —
// queued for §9.7-d. The Wasm spec's modular-wraparound semantics
// match the CPU's truncating low-half multiply for both ops.

pub fn emitI16x8Mul(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmullW);
}

pub fn emitI32x4Mul(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmullD);
}

/// Wasm spec §4.4.3 (i32x4.splat) — pop scalar i32, push v128
/// with all four lanes equal to the scalar. x86_64 lowering:
/// `MOVD xmm, r32` (zero-extends to 128 bits) followed by
/// `PSHUFD xmm, xmm, 0x00` to broadcast lane 0 to lanes 1-3.
///
/// Mirror of arm64's `emitI32x4Splat` (DUP V<vd>.4S, W<wn>) per
/// ROADMAP P7. The 2-instruction x86_64 sequence has no native
/// equivalent until AVX2's VPBROADCASTD; under ADR-0041's SSE4.1
/// baseline the MOVD + PSHUFD pair is the canonical idiom.
pub fn emitI32x4Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, src_r).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0x00).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i32x4.extract_lane <imm>) — pop v128, push
/// scalar i32 = the lane at the immediate index. x86_64 lowering:
/// single `PEXTRD r32, xmm, imm8` (SSE4.1, mandated by ADR-0041
/// §"5. SSE4.1 minimum baseline"). The lane immediate is in
/// `ins.payload` (§9.4 lower's 1-byte encoding).
pub fn emitI32x4ExtractLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    const lane: u2 = @intCast(payload & 0b11);
    try buf.appendSlice(allocator, inst.encPextrD(dst_r, src_x, lane).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (signed lt_s/gt_s/le_s/ge_s) — pop two v128,
/// push v128 with all-ones lanes where the signed compare holds.
/// PCMPGT_<shape> is SSE2; the four Wasm variants synthesise as:
///
///   gt_s: PCMPGT(dst=lhs, rhs)              ; lhs > rhs
///   lt_s: PCMPGT(dst=rhs, lhs)              ; rhs > lhs ⇔ lhs < rhs
///   le_s: NOT PCMPGT(dst=lhs, rhs)          ; ¬(lhs > rhs) ⇔ lhs ≤ rhs
///   ge_s: NOT PCMPGT(dst=rhs, lhs)          ; ¬(lhs < rhs) ⇔ lhs ≥ rhs
///
/// NOT applies via PXOR with an all-ones mask (PCMPEQB scratch,
/// scratch on XMM14) — same idiom as 9.7-k's emitV128IntNe.
const SignedCmpKind = enum { gt, lt, le, ge };

fn emitV128IntCmpSigned(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder_gt: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    kind: SignedCmpKind,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    // For lt_s / ge_s the operand sense is reversed:
    // PCMPGT(dst=rhs, lhs) computes "rhs > lhs" = "lhs < rhs".
    const swap = (kind == .lt) or (kind == .ge);
    const base_x = if (swap) rhs_x else lhs_x;
    const cmp_x = if (swap) lhs_x else rhs_x;

    if (dst_x != base_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, base_x).slice());
    }
    try buf.appendSlice(allocator, encoder_gt(dst_x, cmp_x).slice());

    // le_s / ge_s: invert via PXOR with all-ones.
    if (kind == .le or kind == .ge) {
        const ones = abi.fp_spill_stage_xmms[0]; // XMM14
        try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
        try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16GtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtB, .gt);
}

pub fn emitI8x16LtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtB, .lt);
}

pub fn emitI8x16LeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtB, .le);
}

pub fn emitI8x16GeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtB, .ge);
}

pub fn emitI16x8GtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtW, .gt);
}

pub fn emitI16x8LtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtW, .lt);
}

pub fn emitI16x8LeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtW, .le);
}

pub fn emitI16x8GeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtW, .ge);
}

pub fn emitI32x4GtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtD, .gt);
}

pub fn emitI32x4LtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtD, .lt);
}

pub fn emitI32x4LeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtD, .le);
}

pub fn emitI32x4GeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtD, .ge);
}

/// Wasm spec §4.4.4 (i64x2.gt_s) — pop two v128, push v128 where
/// each 64-bit lane is all-ones if lhs > rhs (signed) else
/// all-zero. Threads the SSE4.2 PCMPGTQ encoder through 9.7-l's
/// shared `emitV128IntCmpSigned` helper (operand swap for lt;
/// PXOR-with-all-ones for le/ge). Per ADR-0041 §5 (post-9.7-m
/// SSE4.2 amendment) — synthesis from SSE4.1 primitives rejected.
pub fn emitI64x2GtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtQ, .gt);
}

/// Wasm spec §4.4.4 (i64x2.lt_s) — see emitI64x2GtS docstring.
pub fn emitI64x2LtS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtQ, .lt);
}

/// Wasm spec §4.4.4 (i64x2.le_s) — see emitI64x2GtS docstring.
pub fn emitI64x2LeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtQ, .le);
}

/// Wasm spec §4.4.4 (i64x2.ge_s) — see emitI64x2GtS docstring.
pub fn emitI64x2GeS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpSigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpgtQ, .ge);
}

/// Wasm spec §4.4.4 (i*x*.{lt_u, gt_u, le_u, ge_u}) — pop two v128,
/// push v128 where each lane is all-ones if lhs op rhs (unsigned)
/// else all-zero. PMINU/PMAXU + PCMPEQ recipe (cranelift
/// `lower.isle:2016-2080`):
///
///   gt_u(a,b): max=PMAXU(a,b) ; result = NOT PCMPEQ(max,b)
///   lt_u(a,b): min=PMINU(a,b) ; result = NOT PCMPEQ(min,b)
///   ge_u(a,b): max=PMAXU(a,b) ; result = PCMPEQ(a,max)
///   le_u(a,b): min=PMINU(a,b) ; result = PCMPEQ(a,min)
///
/// dst gets MOVAPS lhs first (skip-elision when dst==lhs) then the
/// PMINU/PMAXU encoder writes max/min into dst. For ge/le, PCMPEQ
/// dst, lhs computes (max/min == lhs) which is the unsigned ≥/≤
/// result. For gt/lt, PCMPEQ dst, rhs computes (max/min == rhs)
/// then PXOR with all-ones (XMM14 scratch) inverts.
///
/// Two-instruction MOVAPS+PMINU/PMAXU (when dst != lhs) plus the
/// ≤ 3-instr tail mirrors `emitV128IntCmpSigned`'s MOVAPS-elide
/// pattern. Aliasing `dst == rhs` is not handled (matches
/// emitV128IntCmpSigned's stance — current x86_64 regalloc allocates
/// fresh xmm slots for new vregs; D-036 / Phase 15 class-aware
/// allocation will revisit alongside coalescer-driven aliasing).
const UnsignedCmpKind = enum { gt, lt, le, ge };

fn emitV128IntCmpUnsigned(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder_minmax: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    encoder_pcmpeq: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    kind: UnsignedCmpKind,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    try buf.appendSlice(allocator, encoder_minmax(dst_x, rhs_x).slice());

    switch (kind) {
        .ge, .le => {
            try buf.appendSlice(allocator, encoder_pcmpeq(dst_x, lhs_x).slice());
        },
        .gt, .lt => {
            try buf.appendSlice(allocator, encoder_pcmpeq(dst_x, rhs_x).slice());
            const ones = abi.fp_spill_stage_xmms[0];
            try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
            try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());
        },
    }
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16GtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxub, inst.encPcmpeqB, .gt);
}

pub fn emitI8x16LtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminub, inst.encPcmpeqB, .lt);
}

pub fn emitI8x16LeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminub, inst.encPcmpeqB, .le);
}

pub fn emitI8x16GeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxub, inst.encPcmpeqB, .ge);
}

pub fn emitI16x8GtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxuw, inst.encPcmpeqW, .gt);
}

pub fn emitI16x8LtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminuw, inst.encPcmpeqW, .lt);
}

pub fn emitI16x8LeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminuw, inst.encPcmpeqW, .le);
}

pub fn emitI16x8GeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxuw, inst.encPcmpeqW, .ge);
}

pub fn emitI32x4GtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxud, inst.encPcmpeqD, .gt);
}

pub fn emitI32x4LtU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminud, inst.encPcmpeqD, .lt);
}

pub fn emitI32x4LeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminud, inst.encPcmpeqD, .le);
}

pub fn emitI32x4GeU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntCmpUnsigned(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxud, inst.encPcmpeqD, .ge);
}

/// Wasm spec §4.4.4 (f*x*.{eq, ne, lt, gt, le, ge}) — pop two
/// v128, push v128 where each lane is all-ones if the IEEE-754
/// comparison holds else all-zero. Wasm requires ordered eq / lt /
/// gt / le / ge (NaN inputs ⇒ false) and unordered ne (NaN ⇒
/// true). Mapped to CMPPS / CMPPD imm8 predicates per Intel SDM
/// Vol 2A "CMPPS" Table 3-7:
///   0 = EQ_OQ  (Wasm eq)
///   1 = LT_OS  (Wasm lt; via swap covers gt)
///   2 = LE_OS  (Wasm le; via swap covers ge)
///   4 = NEQ_UQ (Wasm ne)
///
/// gt and ge use `swap_operands = true` with predicate LT / LE
/// per cranelift `lower.isle:2169-2172` (no native ordered-gt
/// predicate exists in the legacy 0..7 imm8 range; CMPPS(b, a, LT)
/// computes b < a which is a > b). One-instruction emit + the
/// MOVAPS preamble matches the integer signed-compare shape.
fn emitV128FpCmp(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm, imm8: u8) inst.EncodedInsn,
    imm8: u8,
    swap_operands: bool,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    const base_x = if (swap_operands) rhs_x else lhs_x;
    const cmp_x = if (swap_operands) lhs_x else rhs_x;

    if (dst_x != base_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, base_x).slice());
    }
    try buf.appendSlice(allocator, encoder(dst_x, cmp_x, imm8).slice());

    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Eq(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmpps, 0x00, false);
}

pub fn emitF32x4Ne(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmpps, 0x04, false);
}

pub fn emitF32x4Lt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmpps, 0x01, false);
}

pub fn emitF32x4Gt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmpps, 0x01, true);
}

pub fn emitF32x4Le(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmpps, 0x02, false);
}

pub fn emitF32x4Ge(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmpps, 0x02, true);
}

pub fn emitF64x2Eq(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmppd, 0x00, false);
}

pub fn emitF64x2Ne(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmppd, 0x04, false);
}

pub fn emitF64x2Lt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmppd, 0x01, false);
}

pub fn emitF64x2Gt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmppd, 0x01, true);
}

pub fn emitF64x2Le(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmppd, 0x02, false);
}

pub fn emitF64x2Ge(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpCmp(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCmppd, 0x02, true);
}

/// Wasm spec §4.4.4 (f*x*.{add, sub, mul, div}) — pop two v128,
/// push v128 with per-lane IEEE-754 binary FP result. Reuses
/// 9.7-b's `emitV128IntBinop` shape unchanged because the encoder
/// signature `(dst, src) → EncodedInsn` is identical (the int /
/// fp distinction is purely in the encoder's opcode byte). NaN
/// propagation matches Wasm spec since SSE FP-arith instructions
/// (add/sub/mul/div) are canonical IEEE-754 ops — NaN inputs
/// produce NaN outputs without correction.
///
/// f32x4/f64x2.min and .max are NOT in this chunk because SSE
/// MINPS/MAXPS use "if unordered, return src2" semantics that
/// differ from Wasm's IEEE-754-2019 minimum/maximum (NaN-
/// propagating, signed-zero-aware). Cranelift wraps MINPS/MAXPS
/// with a 7-instruction NaN/zero correction sequence per
/// `lower.isle` "F32X4 (fmin _ x y)" — deferred to §9.7-q with
/// proper synthesis.

pub fn emitF32x4Add(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encAddps);
}

pub fn emitF32x4Sub(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encSubps);
}

pub fn emitF32x4Mul(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encMulps);
}

pub fn emitF32x4Div(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encDivps);
}

pub fn emitF64x2Add(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encAddpd);
}

pub fn emitF64x2Sub(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encSubpd);
}

pub fn emitF64x2Mul(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encMulpd);
}

pub fn emitF64x2Div(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encDivpd);
}

/// Wasm spec §4.4.4 (f*x*.sqrt) — pop one v128, push v128 with
/// per-lane sqrt result. Single-instruction emit (SQRTPS/SQRTPD
/// xmm_dst, xmm_src) — no MOVAPS preamble needed because SQRT is
/// pure unary (src is read-only; dst is written). NaN inputs
/// propagate canonically per IEEE-754.
fn emitV128FpUnop(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const val_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const val_x = try gpr.resolveXmm(alloc, val_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try buf.appendSlice(allocator, encoder(dst_x, val_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Sqrt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encSqrtps);
}

pub fn emitF64x2Sqrt(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encSqrtpd);
}

/// Wasm spec §4.4.4 (f*x*.{min, max}) — pop two v128, push v128
/// with per-lane IEEE-754-2019 minimum / maximum (NaN-propagating,
/// signed-zero-aware). Native SSE MINPS/MAXPS use "if unordered,
/// return src2" semantics that don't match the spec; cranelift's
/// recipe (`lower.isle:2783-2939`) wraps MINPS/MAXPS with a NaN
/// /zero-correction synthesis sequence per
/// `lessons_vs_adr.md` cross-reference.
///
/// fmin (10 instr): MINPS twice (forced ordering) + ORPS to merge
/// signed-zero distinguishability + CMPPS-UNORD to detect NaN
/// lanes + ORPS to lift NaN payloads + PSRLD to leave canonical
/// QNaN bits + ANDNPS to mask off non-canonical NaN payload bits.
///
/// fmax (13 instr): MAXPS twice + XORPS to detect divergence +
/// ORPS to compose NaN exponent + SUBPS to ensure +0 over -0 in
/// the +0/-0 mismatch case + CMPPS-UNORD self-compare for NaN
/// detection + PSRLD + ANDNPS for NaN canonicalisation.
///
/// F32X4 uses PSRLD shift=10 (1 sign + 8 exponent + 1 QNaN bit
/// preserved); F64X2 uses PSRLQ shift=13 (1 + 11 + 1).
///
/// Two scratch xmms are needed: XMM14 (fp_spill_stage_xmms[0])
/// and XMM15 (fp_spill_stage_xmms[1]) per abi.zig. Aliasing
/// invariants match emitV128IntCmpSigned (current x86_64 regalloc
/// allocates fresh xmm slots for new vregs; D-036 / Phase 15
/// class-aware allocation will revisit alongside coalescer-driven
/// aliasing).
const FpMinMaxEncoders = struct {
    minmax: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    or_: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    xor_: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    sub: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    cmp: *const fn (dst: inst.Xmm, src: inst.Xmm, imm8: u8) inst.EncodedInsn,
    andn: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    psrl_imm: *const fn (dst: inst.Xmm, count: u8) inst.EncodedInsn,
    shift_count: u8, // 10 for F32X4, 13 for F64X2
};

const f32x4_minmax_encs: FpMinMaxEncoders = .{
    .minmax = undefined, // set per call (encMinps for fmin, encMaxps for fmax)
    .or_ = inst.encOrps,
    .xor_ = inst.encXorps,
    .sub = inst.encSubps,
    .cmp = inst.encCmpps,
    .andn = inst.encAndnps,
    .psrl_imm = inst.encPsrldImm,
    .shift_count = 10,
};

const f64x2_minmax_encs: FpMinMaxEncoders = .{
    .minmax = undefined,
    .or_ = inst.encOrpd,
    .xor_ = inst.encXorpd,
    .sub = inst.encSubpd,
    .cmp = inst.encCmppd,
    .andn = inst.encAndnpd,
    .psrl_imm = inst.encPsrlqImm,
    .shift_count = 13,
};

/// fmin recipe (10 instructions). dst ends holding the canonical
/// fmin result. scratch (XMM14) holds intermediate min2; scratch2
/// (XMM15) holds intermediate min_or → is_nan_mask → masked.
fn emitV128FpMin(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encs: FpMinMaxEncoders,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14
    const scratch2_x = abi.fp_spill_stage_xmms[1]; // XMM15

    // 1. dst = MOVAPS lhs (skip if dst==lhs)
    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    // 2. dst = MIN(dst, rhs)            ; dst = min1
    try buf.appendSlice(allocator, encs.minmax(dst_x, rhs_x).slice());
    // 3. scratch = MOVAPS rhs
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch_x, rhs_x).slice());
    // 4. scratch = MIN(scratch, lhs)    ; scratch = min2
    try buf.appendSlice(allocator, encs.minmax(scratch_x, lhs_x).slice());
    // 5. dst = OR(dst, scratch)         ; dst = min_or
    try buf.appendSlice(allocator, encs.or_(dst_x, scratch_x).slice());
    // 6. scratch2 = MOVAPS dst          ; scratch2 = min_or
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch2_x, dst_x).slice());
    // 7. dst = CMP(dst, scratch, UNORD=3) ; dst = is_nan_mask
    try buf.appendSlice(allocator, encs.cmp(dst_x, scratch_x, 0x03).slice());
    // 8. scratch2 = OR(scratch2, dst)   ; scratch2 = min_or_2
    try buf.appendSlice(allocator, encs.or_(scratch2_x, dst_x).slice());
    // 9. dst = PSRL(dst, shift_count)   ; dst = nan_fraction_mask
    try buf.appendSlice(allocator, encs.psrl_imm(dst_x, encs.shift_count).slice());
    // 10. dst = ANDN(dst, scratch2)     ; dst = ~nan_fraction_mask & min_or_2 = final
    try buf.appendSlice(allocator, encs.andn(dst_x, scratch2_x).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// fmax recipe (13 instructions). dst ends holding the canonical
/// fmax result.
fn emitV128FpMax(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encs: FpMinMaxEncoders,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14
    const scratch2_x = abi.fp_spill_stage_xmms[1]; // XMM15

    // 1. scratch = MOVAPS lhs
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch_x, lhs_x).slice());
    // 2. scratch = MAX(scratch, rhs)        ; scratch = max1
    try buf.appendSlice(allocator, encs.minmax(scratch_x, rhs_x).slice());
    // 3. scratch2 = MOVAPS rhs
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch2_x, rhs_x).slice());
    // 4. scratch2 = MAX(scratch2, lhs)      ; scratch2 = max2
    try buf.appendSlice(allocator, encs.minmax(scratch2_x, lhs_x).slice());
    // 5. dst = MOVAPS scratch              ; dst = max1
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, scratch_x).slice());
    // 6. dst = XOR(dst, scratch2)          ; dst = max_xor (= max1 ^ max2)
    try buf.appendSlice(allocator, encs.xor_(dst_x, scratch2_x).slice());
    // 7. scratch = OR(scratch, dst)        ; scratch = max1 | max_xor = max_blended_nan
    try buf.appendSlice(allocator, encs.or_(scratch_x, dst_x).slice());
    // 8. scratch2 = MOVAPS scratch         ; scratch2 = max_blended_nan
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch2_x, scratch_x).slice());
    // 9. scratch = SUB(scratch, dst)       ; scratch = max_blended_nan - max_xor = max_blended_nan_positive
    try buf.appendSlice(allocator, encs.sub(scratch_x, dst_x).slice());
    // 10. scratch2 = CMP(scratch2, scratch2, UNORD=3) ; scratch2 = is_nan_mask
    try buf.appendSlice(allocator, encs.cmp(scratch2_x, scratch2_x, 0x03).slice());
    // 11. dst = MOVAPS scratch2            ; dst = is_nan_mask
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, scratch2_x).slice());
    // 12. dst = PSRL(dst, shift_count)     ; dst = nan_fraction_mask
    try buf.appendSlice(allocator, encs.psrl_imm(dst_x, encs.shift_count).slice());
    // 13. dst = ANDN(dst, scratch)         ; dst = ~nan_fraction_mask & max_blended_nan_positive = final
    try buf.appendSlice(allocator, encs.andn(dst_x, scratch_x).slice());

    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Min(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    var encs = f32x4_minmax_encs;
    encs.minmax = inst.encMinps;
    return emitV128FpMin(allocator, buf, alloc, pushed_vregs, next_vreg, encs);
}

pub fn emitF32x4Max(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    var encs = f32x4_minmax_encs;
    encs.minmax = inst.encMaxps;
    return emitV128FpMax(allocator, buf, alloc, pushed_vregs, next_vreg, encs);
}

pub fn emitF64x2Min(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    var encs = f64x2_minmax_encs;
    encs.minmax = inst.encMinpd;
    return emitV128FpMin(allocator, buf, alloc, pushed_vregs, next_vreg, encs);
}

pub fn emitF64x2Max(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    var encs = f64x2_minmax_encs;
    encs.minmax = inst.encMaxpd;
    return emitV128FpMax(allocator, buf, alloc, pushed_vregs, next_vreg, encs);
}

/// Wasm spec §4.4.4 (i*x*.eq variants) — pop two v128, push v128
/// where each lane is all-ones if the inputs match else all-zero.
/// Per-shape encoders (PCMPEQB / PCMPEQW / PCMPEQD / PCMPEQQ)
/// reuse the shared 9.7-b `emitV128IntBinop` helper unchanged —
/// equality comparison's structural shape (pop 2, push 1, MOVAPS-
/// elide when aliased) is identical to int add/sub.

pub fn emitI8x16Eq(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpeqB);
}

pub fn emitI16x8Eq(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpeqW);
}

pub fn emitI32x4Eq(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpeqD);
}

pub fn emitI64x2Eq(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpeqQ);
}

/// Wasm spec §4.4.4 (i*x*.ne variants) — invert PCMPEQ via XOR
/// against an all-ones mask. The mask is generated cheaply with
/// `PCMPEQB scratch, scratch` (any width works; byte chosen as
/// shortest encoding) on `abi.fp_spill_stage_xmms[0]` (XMM14).
///
/// Emit sequence (4 instructions plus optional MOVAPS preamble):
///   MOVAPS dst, lhs            ; only when dst != lhs
///   <PCMPEQ_eq> dst, rhs       ; per-shape encoder
///   PCMPEQB scratch, scratch   ; build all-ones mask
///   PXOR    dst, scratch       ; flip every bit → ne result
fn emitV128IntNe(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder_eq: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const ones = abi.fp_spill_stage_xmms[0]; // XMM14 — all-ones scratch

    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    try buf.appendSlice(allocator, encoder_eq(dst_x, rhs_x).slice());
    try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16Ne(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntNe(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpeqB);
}

pub fn emitI16x8Ne(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntNe(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpeqW);
}

pub fn emitI32x4Ne(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntNe(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpeqD);
}

pub fn emitI64x2Ne(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    return emitV128IntNe(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPcmpeqQ);
}

/// Wasm spec §4.4.3 (f64x2.splat) — pop scalar f64 (XMM low 64),
/// push v128 with both 64-bit lanes equal. Single-instruction
/// `PSHUFD dst, src, 0x44` broadcasts the source's low qword
/// across both destination qwords (imm 0x44 = 0b01_00_01_00
/// selects src dwords 0,1,0,1 → dst.q[0] = (src.d[0], src.d[1]) =
/// src.q[0] and dst.q[1] = (src.d[0], src.d[1]) = src.q[0]).
pub fn emitF64x2Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, 0x44).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f64x2.extract_lane <imm>) — pop v128, push
/// scalar f64 (XMM low 64). PSHUFD imm: lane=0 → 0x44 (= splat
/// shape, low qword copied through); lane=1 → 0xEE
/// (= 0b11_10_11_10, selecting src dwords 2,3,2,3 → dst.q[0] =
/// src.q[1]). The result XMM's high qword is duplicated; Wasm
/// consumers read only the low 64.
pub fn emitF64x2ExtractLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    const lane: u1 = @intCast(payload & 0b1);
    const imm8: u8 = if (lane == 0) 0x44 else 0xEE;
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, imm8).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f64x2.replace_lane <imm>) — pop scalar f64,
/// pop v128, push v128 with one lane replaced.
///
/// Sequence:
///   MOVAPS dst, vec   (elided when dst aliases vec)
///   lane=0: MOVSD dst, value (overwrites low qword, preserves high)
///   lane=1: MOVLHPS dst, value (writes value's low qword to
///           dst's high qword, preserves dst's low qword)
///
/// Both reg-reg paths preserve the unchanged qword without an
/// extra MOVAPS or SHUFPD imm dance.
pub fn emitF64x2ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const value_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const value_x = try gpr.resolveXmm(alloc, value_v);
    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    const lane: u1 = @intCast(payload & 0b1);
    if (lane == 0) {
        try buf.appendSlice(allocator, inst.encMovsdXmmXmm(dst_x, value_x).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovlhps(dst_x, value_x).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f32x4.splat) — pop scalar f32 (XMM-class
/// vreg with the value in lane 0), push v128 with all four lanes
/// equal to the scalar. x86_64 lowering: a single `PSHUFD dst,
/// src, 0x00` broadcasts source lane 0 across all four 32-bit
/// destination lanes. Uses the integer-domain shuffle (PSHUFD)
/// even on FP data — the bit-level operation is identical, and
/// modern Intel / AMD micro-architectures bypass the FP↔int
/// domain crossing penalty when the surrounding ops also stay
/// in one domain.
pub fn emitF32x4Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, 0x00).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f32x4.extract_lane <imm>) — pop v128, push
/// scalar f32 (XMM-class result with the chosen lane in low 32).
/// x86_64 lowering: a single `PSHUFD dst, src, lane * 0x55`.
/// `lane * 0x55` produces 0x00, 0x55, 0xAA, 0xFF — each value
/// has all four 2-bit fields equal to `lane`, so PSHUFD broadcasts
/// the source's `lane`-th dword across all four destination lanes
/// (lane 0 holds the desired value; subsequent FP scalar ops only
/// read low 32, so the duplication is harmless).
pub fn emitF32x4ExtractLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    const lane: u8 = @intCast(payload & 0b11);
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, lane *% 0x55).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (f32x4.replace_lane <imm>) — pop scalar f32
/// (XMM low 32), pop v128, push v128 with lane `imm` replaced.
/// x86_64 lowering: `MOVAPS dst, vec` (elided when aliased) +
/// `INSERTPS dst, value, (lane << 4)`. The INSERTPS imm encodes
/// (count_s = 0, count_d = lane, ZMASK = 0): copy lane 0 of
/// `value` (= the scalar) into lane `lane` of `dst`, leave the
/// other three lanes untouched.
pub fn emitF32x4ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    payload: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const value_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const value_x = try gpr.resolveXmm(alloc, value_v);
    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    const lane: u8 = @intCast(payload & 0b11);
    const imm8: u8 = lane << 4;
    try buf.appendSlice(allocator, inst.encInsertps(dst_x, value_x, imm8).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i8x16.splat) — pop scalar i32, push v128
/// with all 16 byte lanes equal to the low 8 bits of the scalar.
/// x86_64 lowering: `MOVD xmm_dst, src_gpr` (zero-extends to
/// 128) — places `src8` in byte 0 with the rest cleared. Then
/// `PXOR scratch, scratch` (build all-zero PSHUFB control mask)
/// + `PSHUFB xmm_dst, scratch` — PSHUFB reads each control byte's
/// low 4 bits as a source-lane index; an all-zero ctrl makes
/// every output byte = source byte 0 = `src8`.
///
/// **Scratch reuse**: borrows `abi.fp_spill_stage_xmms[0]` as
/// the zero ctrl mask (mirrors §9.7-d's i64x2.mul scratch
/// strategy). Safe — the handler is atomic; no nested
/// `xmmLoadSpilled` intervenes.
pub fn emitI8x16Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const ctrl = abi.fp_spill_stage_xmms[0]; // XMM14 — zero ctrl mask scratch

    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, src_r).slice());
    try buf.appendSlice(allocator, inst.encPxor(ctrl, ctrl).slice());
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, ctrl).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i16x8.splat) — pop scalar i32, push v128
/// with 8 word lanes equal to the low 16 bits of the scalar.
/// Lowering: `MOVD xmm_dst, src_gpr` (low 32 bits of XMM = src,
/// rest zeroed) → `PSHUFLW xmm_dst, xmm_dst, 0x00` (broadcasts
/// word 0 to lanes 0-3 of the lower 64) → `PSHUFD xmm_dst,
/// xmm_dst, 0x00` (broadcasts dword 0 across all 4 dwords,
/// filling the upper 64 bits).
pub fn emitI16x8Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, src_r).slice());
    try buf.appendSlice(allocator, inst.encPshuflw(dst_x, dst_x, 0x00).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0x00).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i64x2.splat) — pop scalar i64, push v128
/// with both 64-bit lanes equal to the scalar. Lowering: `MOVQ
/// xmm_dst, src_gpr` (zero-extends i64 into the low 64 bits;
/// upper 64 cleared) → `PUNPCKLQDQ xmm_dst, xmm_dst` (unpacks
/// low qwords from both operands — same XMM here — producing
/// `(src64, src64)`).
pub fn emitI64x2Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try buf.appendSlice(allocator, inst.encMovqXmmFromR64(dst_x, src_r).slice());
    try buf.appendSlice(allocator, inst.encPunpcklqdq(dst_x, dst_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i8x16 / i16x8 extract_lane variants) — pop
/// v128, push i32. PEXTRB / PEXTRW write the byte/word lane into
/// the destination GPR's low 8/16 bits zero-extended to 32 bits.
/// `i*.extract_lane_u` accepts that result directly; `_s` follows
/// up with `MOVSX r32, r8` / `MOVSX r32, r16` to sign-extend.
const NarrowExtractKind = enum { i8x16_s, i8x16_u, i16x8_s, i16x8_u };

fn emitV128IntExtractLaneNarrow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
    kind: NarrowExtractKind,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    switch (kind) {
        .i8x16_s, .i8x16_u => {
            const lane: u4 = @intCast(payload & 0xF);
            try buf.appendSlice(allocator, inst.encPextrB(dst_r, src_x, lane).slice());
            if (kind == .i8x16_s) {
                try buf.appendSlice(allocator, inst.encMovsxR32R8(dst_r, dst_r).slice());
            }
        },
        .i16x8_s, .i16x8_u => {
            const lane: u3 = @intCast(payload & 0b111);
            try buf.appendSlice(allocator, inst.encPextrW(dst_r, src_x, lane).slice());
            if (kind == .i16x8_s) {
                try buf.appendSlice(allocator, inst.encMovsxR32R16(dst_r, dst_r).slice());
            }
        },
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16ExtractLaneS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntExtractLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i8x16_s);
}

pub fn emitI8x16ExtractLaneU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntExtractLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i8x16_u);
}

pub fn emitI16x8ExtractLaneS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntExtractLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i16x8_s);
}

pub fn emitI16x8ExtractLaneU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntExtractLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i16x8_u);
}

/// Wasm spec §4.4.3 (i8x16 / i16x8 replace_lane) — pop scalar
/// (i32, treated as i8/i16 by truncation), pop v128, push v128
/// with the lane updated. `MOVAPS dst, vec` (elided when aliased)
/// + `PINSRB / PINSRW dst, value, lane`.
const NarrowReplaceKind = enum { i8x16, i16x8 };

fn emitV128IntReplaceLaneNarrow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
    kind: NarrowReplaceKind,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const value_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const value_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, value_v, 0);
    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    switch (kind) {
        .i8x16 => {
            const lane: u4 = @intCast(payload & 0xF);
            try buf.appendSlice(allocator, inst.encPinsrB(dst_x, value_r, lane).slice());
        },
        .i16x8 => {
            const lane: u3 = @intCast(payload & 0b111);
            try buf.appendSlice(allocator, inst.encPinsrW(dst_x, value_r, lane).slice());
        },
    }
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntReplaceLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i8x16);
}

pub fn emitI16x8ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntReplaceLaneNarrow(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, .i16x8);
}

/// Wasm spec §4.4.3 (i32x4.replace_lane <imm>) — pop scalar i32
/// `value`, pop v128 `vec`; push a v128 with lane `imm` set to
/// `value` and the other three lanes preserved from `vec`.
/// x86_64 lowering: copy `vec` into `dst` via MOVAPS (elided
/// when dst already aliases vec), then `PINSRD dst, value, lane`.
fn emitV128IntReplaceLane32Or64(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
    is_64: bool,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const value_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const value_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, value_v, 0);
    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    if (is_64) {
        const lane: u1 = @intCast(payload & 0b1);
        try buf.appendSlice(allocator, inst.encPinsrQ(dst_x, value_r, lane).slice());
    } else {
        const lane: u2 = @intCast(payload & 0b11);
        try buf.appendSlice(allocator, inst.encPinsrD(dst_x, value_r, lane).slice());
    }
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI32x4ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntReplaceLane32Or64(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, false);
}

pub fn emitI64x2ReplaceLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    payload: u32,
) Error!void {
    return emitV128IntReplaceLane32Or64(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, payload, true);
}

/// Wasm spec §4.4.4 (i64x2.mul) — pop two v128, push their
/// element-wise 64-bit product per lane (2 lanes; modular
/// wraparound at 2^64). x86_64 has **no native instruction**
/// for 64×64→64 packed multiply at the SSE4.1 baseline (AVX-512
/// VPMULLQ exists but is gated by ADR-0041 §"5. SSE4.1 minimum
/// baseline").
///
/// Synthesis (cranelift idiom — 8 instructions, 2 SIMD scratches):
///
/// Let lhs = (a1:a0) and rhs = (b1:b0) per 64-bit lane (a1 / b1
/// = high 32, a0 / b0 = low 32). The product mod 2^64 is:
///   a*b ≡ (a_hi * b_lo + a_lo * b_hi) << 32 + a_lo * b_lo
///
///   1. MOVAPS s1, lhs              ; s1 = a
///   2. PSRLQ  s1, 32               ; s1 = (0:a_hi)
///   3. PMULUDQ s1, rhs             ; s1 = a_hi * b_lo
///   4. MOVAPS s2, rhs              ; s2 = b
///   5. PSRLQ  s2, 32               ; s2 = (0:b_hi)
///   6. PMULUDQ s2, lhs             ; s2 = b_hi * a_lo
///   7. PADDQ  s1, s2               ; s1 = a_hi*b_lo + a_lo*b_hi
///   8. PSLLQ  s1, 32               ; (cross terms) << 32
///   9. MOVAPS dst, lhs (if dst != lhs)
///  10. PMULUDQ dst, rhs            ; dst = a_lo * b_lo (full 64-bit)
///  11. PADDQ  dst, s1              ; final = low + (cross<<32)
///
/// **Scratch reservation**: reuses `abi.fp_spill_stage_xmms`
/// (XMM14 / XMM15) as in-handler SIMD scratch. Safe because the
/// synthesis is atomic — no nested `xmmLoadSpilled` calls
/// intervene between the MOVAPS s1/s2 setup and the final
/// PADDQ. Avoids a new ABI reservation; mirrors the principle
/// from ARM64 op_simd.zig that scratch reuse is preferable to
/// pool churn (per ROADMAP P3 cold-start; per p9-9.7-d-survey.md
/// "scratch strategy B").
pub fn emitI64x2Mul(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    // SIMD scratch: reuse fp_spill_stage_xmms[0..1]. The spill-
    // staging path is unused inside this handler (no nested
    // xmmLoadSpilled), so XMM14 / XMM15 are free to clobber.
    const s1 = abi.fp_spill_stage_xmms[0]; // XMM14
    const s2 = abi.fp_spill_stage_xmms[1]; // XMM15

    // 1-3: cross term a_hi * b_lo into s1.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(s1, lhs_x).slice());
    try buf.appendSlice(allocator, inst.encPsrlqImm(s1, 32).slice());
    try buf.appendSlice(allocator, inst.encPmuludq(s1, rhs_x).slice());

    // 4-6: cross term a_lo * b_hi into s2.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(s2, rhs_x).slice());
    try buf.appendSlice(allocator, inst.encPsrlqImm(s2, 32).slice());
    try buf.appendSlice(allocator, inst.encPmuludq(s2, lhs_x).slice());

    // 7-8: combine cross terms and shift into the high half.
    try buf.appendSlice(allocator, inst.encPaddQ(s1, s2).slice());
    try buf.appendSlice(allocator, inst.encPsllqImm(s1, 32).slice());

    // 9-11: low product into dst, then add cross terms.
    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPmuludq(dst_x, rhs_x).slice());
    try buf.appendSlice(allocator, inst.encPaddQ(dst_x, s1).slice());

    try pushed_vregs.append(allocator, result_v);
}

