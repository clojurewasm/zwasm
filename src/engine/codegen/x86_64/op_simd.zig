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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "emitI32x4Add: three fresh XMM slots — MOVAPS xmm10, xmm8 + PADDD xmm10, xmm9" {
    // Synthetic regalloc state: 3 v128 vregs at slot ids 0/1/2 →
    // XMM8/XMM9/XMM10 via abi.fpSlotToReg. Push lhs (vreg 0) +
    // rhs (vreg 1); the handler allocates result (vreg 2).
    var slot_ids = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 3,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    // Expected:
    //   MOVAPS xmm10, xmm8   = 45 0F 28 D0  (REX = 0x40|R|B = 0x45)
    //   PADDD  xmm10, xmm9   = 66 45 0F FE D1
    var expected_buf: [32]u8 = undefined;
    var n: usize = 0;
    const mov = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    @memcpy(expected_buf[n..][0..mov.slice().len], mov.slice());
    n += mov.slice().len;
    const padd = inst.encPaddD(.xmm10, .xmm9);
    @memcpy(expected_buf[n..][0..padd.slice().len], padd.slice());
    n += padd.slice().len;
    try testing.expectEqualSlices(u8, expected_buf[0..n], buf.items);
    try testing.expectEqual(@as(usize, 1), pushed.items.len);
    try testing.expectEqual(@as(u32, 2), pushed.items[0]);
    try testing.expectEqual(@as(u32, 3), next_vreg);
}

test "emitI32x4Add: dst aliases lhs slot — MOVAPS elided, only PADDD emitted" {
    // Force dst onto the same physical XMM as lhs by giving
    // them the same slot id (the regalloc would do this via the
    // free-pool LIFO when lhs's last use is the binop). The
    // handler should detect dst_x == lhs_x and skip the MOVAPS.
    var slot_ids = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    try testing.expectEqualSlices(u8, inst.encPaddD(.xmm8, .xmm9).slice(), buf.items);
}

test "emitI8x16Sub: dispatches to encPsubB — opcode 0xF8 reaches the buffer" {
    // Sanity guard against encoder mis-wiring: a 1-line wrapper
    // could easily dispatch to the wrong inst.encXxx if copy-pasted
    // carelessly. Verify the actual byte landing matches PSUBB.
    var slot_ids = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 3,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try emitI8x16Sub(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected_buf: [32]u8 = undefined;
    var n: usize = 0;
    const mov = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    @memcpy(expected_buf[n..][0..mov.slice().len], mov.slice());
    n += mov.slice().len;
    const psub = inst.encPsubB(.xmm10, .xmm9);
    @memcpy(expected_buf[n..][0..psub.slice().len], psub.slice());
    n += psub.slice().len;
    try testing.expectEqualSlices(u8, expected_buf[0..n], buf.items);
}

test "emitI8x16ExtractLaneS: PEXTRB + MOVSX r32, r8" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try emitI8x16ExtractLaneS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 7);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPextrB(.rbx, .xmm8, 7).slice());
    try expected.appendSlice(testing.allocator, inst.encMovsxR32R8(.rbx, .rbx).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtractLaneU: PEXTRW only (zero-extended already)" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try emitI16x8ExtractLaneU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 5);

    // Expect just PEXTRW; no MOVSX for unsigned.
    try testing.expectEqualSlices(u8, inst.encPextrW(.rbx, .xmm8, 5).slice(), buf.items);
}

test "emitI8x16ReplaceLane: MOVAPS + PINSRB at lane 12" {
    var slot_ids = [_]u16{ 0, 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    try emitI8x16ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 12);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPinsrB(.xmm9, .rbx, 12).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ReplaceLane: pop scalar + v128, emit MOVAPS + PINSRD" {
    // Synthetic regalloc:
    //   vreg 0 = vec (v128 input)  → XMM slot 0 = XMM8
    //   vreg 1 = value (i32 scalar) → GPR slot 0 = RBX
    //   vreg 2 = result (v128)      → XMM slot 1 = XMM9
    var slot_ids = [_]u16{ 0, 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value (top of stack)
    var next_vreg: u32 = 2;

    // payload = lane 1.
    try emitI32x4ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPinsrD(.xmm9, .rbx, 1).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2ReplaceLane: dst aliases vec — MOVAPS elided, PINSRQ only" {
    // result vreg shares slot 0 with vec → MOVAPS elided.
    var slot_ids = [_]u16{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    // payload = lane 1 (only 0 or 1 valid for i64x2).
    try emitI64x2ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    try testing.expectEqualSlices(u8, inst.encPinsrQ(.xmm8, .rbx, 1).slice(), buf.items);
}

test "emitI32x4Splat: GPR slot 0 → XMM slot 0 (RBX → XMM8) — MOVD + PSHUFD" {
    // SysV alloc: GPR pool starts at RBX (slot 0). XMM pool
    // starts at XMM8 (slot 0). The handler resolves vreg 0 as
    // GPR (i32 source) and vreg 1 as XMM (v128 result) — no
    // class collision because alloc.slot is class-aware.
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    try emitI32x4Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovdXmmFromR32(.xmm8, .rbx).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm8, .xmm8, 0x00).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ExtractLane: lane 2 — single PEXTRD instruction" {
    var slot_ids = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 1,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    var next_vreg: u32 = 1;

    // payload = 2 → lane 2.
    try emitI32x4ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 2);

    // Expected: PEXTRD rbx, xmm8, 2. (vreg 0 v128 at slot 0 →
    // XMM8; vreg 1 i32 at slot 0 → RBX in the GPR class.)
    try testing.expectEqualSlices(u8, inst.encPextrD(.rbx, .xmm8, 2).slice(), buf.items);
}

test "emitI64x2Mul: emits the 11-instruction PMULUDQ synthesis sequence" {
    // Synthetic regalloc: lhs at slot 0 (XMM8), rhs at slot 1
    // (XMM9), dst at slot 2 (XMM10) — none aliased, so the final
    // MOVAPS dst, lhs is emitted.
    var slot_ids = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 3,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try emitI64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    // Build expected sequence verbatim from the encoders (use
    // the same constants as the handler so encoder churn is
    // caught here, not at runtime).
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const s1 = abi.fp_spill_stage_xmms[0];
    const s2 = abi.fp_spill_stage_xmms[1];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s1, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s1, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s1, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s2, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s2, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s2, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(s1, s2).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(s1, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(.xmm10, s1).slice());

    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2Mul: dst aliases lhs — final MOVAPS elided" {
    var slot_ids = [_]u16{ 0, 1, 0 }; // dst (vreg 2) reuses lhs slot
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try emitI64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    // Same sequence minus the `MOVAPS dst, lhs` step (instructions
    // 1-8 unchanged; step 9 = dst_x == lhs_x = XMM8 → elided).
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const s1 = abi.fp_spill_stage_xmms[0];
    const s2 = abi.fp_spill_stage_xmms[1];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s1, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s1, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s1, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(s2, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(s2, 32).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(s2, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(s1, s2).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(s1, 32).slice());
    // (no MOVAPS dst, lhs — they alias)
    try expected.appendSlice(testing.allocator, inst.encPmuludq(.xmm8, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddQ(.xmm8, s1).slice());

    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4Mul: dispatches to encPmullD — opcode 0x40 with 0x38 escape reaches the buffer" {
    // Sanity guard for the SSE4.1 encoder path: PMULLD's second
    // escape byte (0x38) must land between 0x0F and the opcode.
    var slot_ids = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 3,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try emitI32x4Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected_buf: [32]u8 = undefined;
    var n: usize = 0;
    const mov = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    @memcpy(expected_buf[n..][0..mov.slice().len], mov.slice());
    n += mov.slice().len;
    const pmull = inst.encPmullD(.xmm10, .xmm9);
    @memcpy(expected_buf[n..][0..pmull.slice().len], pmull.slice());
    n += pmull.slice().len;
    try testing.expectEqualSlices(u8, expected_buf[0..n], buf.items);
}

test "emitI16x8Mul: dispatches to encPmullW — opcode 0xD5 (SSE2 path)" {
    var slot_ids = [_]u16{ 0, 1, 0 }; // dst aliases lhs → MOVAPS elided
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try emitI16x8Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    try testing.expectEqualSlices(u8, inst.encPmullW(.xmm8, .xmm9).slice(), buf.items);
}

test "emitI64x2Add: dispatches to encPaddQ — opcode 0xD4 reaches the buffer" {
    var slot_ids = [_]u16{ 0, 1, 0 }; // dst aliases lhs → MOVAPS elided
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try emitI64x2Add(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    try testing.expectEqualSlices(u8, inst.encPaddQ(.xmm8, .xmm9).slice(), buf.items);
}

test "emitI32x4Add: spilled rhs surfaces UnsupportedOp (16-byte spill defers to 9.7-c)" {
    // Slot id 6 is past max_reg_slots_fp = 6; alloc.slot(.fpr)
    // returns .spill, and resolveXmm rejects spilled FP vregs
    // with Error.UnsupportedOp because xmmLoadSpilled's MOVSD
    // path is 8-byte (truncates the upper 64 bits of a v128).
    // 16-byte MOVDQU spill helpers are the 9.7-c lift.
    var slot_ids = [_]u16{ 0, 6, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 7,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0);
    try pushed.append(testing.allocator, 1);
    var next_vreg: u32 = 2;

    try testing.expectError(Error.UnsupportedOp, emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg));
}
