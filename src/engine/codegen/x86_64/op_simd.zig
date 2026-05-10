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
const jit_abi = @import("../shared/jit_abi.zig");
const trace = @import("../../../diagnostic/trace.zig");

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

/// Wasm spec §4.4.7 (v128.load) — pop i32 idx, push v128 loaded
/// from `[mem_base + idx + offset]` (16-byte unaligned). Spec
/// trap iff `idx + offset + 16 > mem_limit`. Mirror of scalar
/// `op_memory.emitMemOp` shape with access_size = 16 + MOVUPS
/// final encoding. RAX/RCX/RDX scratches are pool-excluded
/// (allocatable_caller_saved_scratch_gprs = R10/R11 only).
pub fn emitV128Load(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, 16, func_idx);

    try buf.appendSlice(allocator, inst.encMovupsMemBaseIdx(false, dst_x, .rax, .rdx).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.store) — pop v128 val, pop i32 idx;
/// store val at `[mem_base + idx + offset]` (16 bytes unaligned).
/// Spec trap iff `idx + offset + 16 > mem_limit`. Mirror of
/// emitV128Load with reversed direction (MOVUPS [mem], xmm).
pub fn emitV128Store(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const val_v = pushed_vregs.pop().?;
    const idx_v = pushed_vregs.pop().?;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const val_x = try gpr.resolveXmm(alloc, val_v);

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, 16, func_idx);

    try buf.appendSlice(allocator, inst.encMovupsMemBaseIdx(true, val_x, .rax, .rdx).slice());
}

/// Shared eff-addr + bounds-check prologue for v128 memory ops.
/// Mirrors op_memory.emitMemOp's prologue exactly with the access
/// size as a parameter. RAX = vm_base reload, RDX = ea base
/// (zero-ext idx + offset), RCX = ea+size scratch for the JA
/// bounds-check fixup.
fn v128MemPrologue(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    bounds_fixups: *std.ArrayList(u32),
    idx_r: inst.Gpr,
    offset: u32,
    access_size: i8,
    func_idx: u32,
) Error!void {
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rdx, idx_r).slice());
    if (offset != 0) {
        if (offset <= 0x7FFFFFFF) {
            try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, @intCast(offset)).slice());
        } else {
            try buf.appendSlice(allocator, inst.encMovImm64Q(.rcx, @as(u64, offset)).slice());
            try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .rcx).slice());
        }
    }
    try buf.appendSlice(allocator, inst.encLeaR64BaseDisp8(.rcx, .rdx, access_size).slice());
    try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rcx, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
    try bounds_fixups.append(allocator, fixup_at);
    trace.writeBounds(func_idx, fixup_at);
}

/// Wasm spec §4.4.7 (v128.load8_splat) — pop i32 idx, load 1 byte
/// from `[mem + idx + offset]`, broadcast to all 16 lanes. Recipe:
/// MOVZX RCX, byte [RAX+RDX]; MOVD dst, ECX; PXOR XMM14, XMM14;
/// PSHUFB dst, XMM14 (zero-mask broadcast). Cranelift recipe at
/// `lower.isle:4840-4843` uses PINSRB-mem which we don't yet have
/// in encoder form; the GPR round-trip is one extra instr.
pub fn emitV128Load8Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14: zero ctrl mask

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, 1, func_idx);
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.rcx, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, .rcx).slice());
    try buf.appendSlice(allocator, inst.encPxor(scratch_x, scratch_x).slice());
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, scratch_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load16_splat) — load 2 bytes, broadcast
/// to all 8 lanes. PSHUFLW broadcasts the low 16 to lanes 0-3 (low
/// qword); PSHUFD then broadcasts the low 32 (= 2× the value) to
/// all 4 dwords (= 8 lanes total).
pub fn emitV128Load16Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, 2, func_idx);
    try buf.appendSlice(allocator, inst.encMovzxR32_16MemBaseIdx(.rcx, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, .rcx).slice());
    try buf.appendSlice(allocator, inst.encPshuflw(dst_x, dst_x, 0).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load32_splat) — load 4 bytes, broadcast
/// to all 4 lanes. MOVSS loads 4 bytes into lane 0 + zeros upper
/// 96; PSHUFD imm 0 broadcasts lane 0 to all 4.
pub fn emitV128Load32Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, 4, func_idx);
    try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(.f32, false, dst_x, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load64_splat) — load 8 bytes, broadcast
/// to both 64-bit lanes. MOVSD loads 8 bytes into low qword +
/// zeros upper qword; PSHUFD imm 0x44 (= 01_00_01_00) broadcasts
/// the low qword (dwords 0+1) to the upper qword (dwords 2+3).
pub fn emitV128Load64Splat(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, 8, func_idx);
    try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(.f64, false, dst_x, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, dst_x, 0x44).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.3 (i64x2.extract_lane <imm>) — pop v128, push
/// scalar i64 = the 64-bit lane at the immediate index. Single
/// `PEXTRQ r64, xmm, imm8` (SSE4.1 REX.W=1; lane is u1 since
/// i64x2 has 2 lanes). Mirror of i32x4.extract_lane (9.7-e) with
/// the .q-form encoder.
pub fn emitI64x2ExtractLane(
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

    const lane: u1 = @intCast(payload & 0b1);
    try buf.appendSlice(allocator, inst.encPextrQ(dst_r, src_x, lane).slice());
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

/// Wasm spec §4.4.4 (v128.not) — pop one v128, push v128 with
/// every bit inverted. SSE has no native NOT instruction;
/// synthesise via `PCMPEQB scratch, scratch` (= all-ones) +
/// `PXOR dst, scratch` (= ~src). 3-instruction emit including the
/// MOVAPS preamble to copy src into dst.
pub fn emitV128Not(
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
    const ones = abi.fp_spill_stage_xmms[0]; // XMM14

    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (v128.and / v128.or / v128.xor) — pop two
/// v128, push v128 with the corresponding bitwise op applied per
/// 128-bit value. Reuses 9.7-b's `emitV128IntBinop` shape with the
/// SSE2 packed-int encoders (PAND / POR / PXOR — int-domain XOR
/// preferred over XORPS for bit-identical-but-domain-faster
/// semantics on older microarchitectures).

pub fn emitV128And(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPand);
}

pub fn emitV128Or(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPor);
}

pub fn emitV128Xor(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPxor);
}

/// Wasm spec §4.4.4 (v128.andnot) — `andnot(a, b) = a & ~b`. SSE
/// `PANDN dst, src` computes `dst = ~dst & src`, so we MOVAPS
/// rhs (=b) into dst then PANDN dst, lhs (=a) → dst = ~b & a =
/// a & ~b. 2-instruction emit (or 1 if dst==rhs).
pub fn emitV128Andnot(
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

    if (dst_x != rhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, rhs_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPandn(dst_x, lhs_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (v128.bitselect) — pop c, b, a (top-of-stack
/// is c); push `(a & c) | (b & ~c)`. 5-instruction PAND/PANDN/POR
/// recipe (cranelift uses PBLENDVB on AVX but the PAND chain is
/// SSE2-baseline-clean and one fewer encoder dependency):
///
///   dst = MOVAPS(a)        (skip if dst==a)
///   dst = PAND(dst, c)     ; dst = a & c
///   scratch = MOVAPS(c)
///   scratch = PANDN(scratch, b) ; scratch = ~c & b = b & ~c
///   dst = POR(dst, scratch) ; dst = (a & c) | (b & ~c)
///
/// Wasm spec stack order: bottom→top: a, b, c. Pops in order: c
/// first (top), then b, then a.
pub fn emitV128Bitselect(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const c_v = pushed_vregs.pop().?;
    const b_v = pushed_vregs.pop().?;
    const a_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const c_x = try gpr.resolveXmm(alloc, c_v);
    const b_x = try gpr.resolveXmm(alloc, b_v);
    const a_x = try gpr.resolveXmm(alloc, a_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14

    if (dst_x != a_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, a_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPand(dst_x, c_x).slice());
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch_x, c_x).slice());
    try buf.appendSlice(allocator, inst.encPandn(scratch_x, b_x).slice());
    try buf.appendSlice(allocator, inst.encPor(dst_x, scratch_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (v128.any_true) — pop v128, push i32 (1 if any
/// bit of the v128 is non-zero else 0). Recipe (cranelift
/// `lower.isle` `vany_true`):
///
///   PTEST xmm, xmm        ; sets EFLAGS.ZF=1 iff all bits zero
///   SETNE dst.lo8         ; dst[0..8] = (ZF==0) ? 1 : 0
///   MOVZX dst, dst.lo8    ; zero-extend to i32
///
/// PTEST is SSE4.1 (66 0F 38 17 /r). Per ADR-0041 §5 (post-9.7-m
/// SSE4.2 baseline), SSE4.1 + SSE4.2 are both available.
pub fn emitV128AnyTrue(
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

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);

    try buf.appendSlice(allocator, inst.encPtest(src_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.ne, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i*x*.all_true) — pop v128, push i32 (1 if
/// every lane is non-zero else 0). 5-instruction recipe per
/// cranelift `lower.isle:4936-4941` SSE4.1 path:
///
///   scratch = PXOR(scratch, scratch)        ; scratch = zero
///   scratch = PCMPEQ_lane(scratch, src)     ; lanes==0 → 0xFF; non-zero → 0x00
///   PTEST(scratch, scratch)                  ; ZF=1 iff scratch==0 iff no lane was zero
///   dst.lo8 = SETZ                            ; (ZF==1) ? 1 : 0 = all_true result
///   dst = MOVZX(dst, dst.lo8)
///
/// `encoder_pcmpeq` selects the lane width: PCMPEQB / W / D / Q.
fn emitV128AllTrue(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_pcmpeq: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, inst.encPxor(scratch_x, scratch_x).slice());
    try buf.appendSlice(allocator, encoder_pcmpeq(scratch_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encPtest(scratch_x, scratch_x).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.e, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16AllTrue(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128AllTrue(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqB);
}

pub fn emitI16x8AllTrue(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128AllTrue(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqW);
}

pub fn emitI32x4AllTrue(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128AllTrue(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqD);
}

pub fn emitI64x2AllTrue(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128AllTrue(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPcmpeqQ);
}

/// Wasm spec §4.4.4 (i*x*.bitmask) — pop v128, push i32 with the
/// high bit of each lane packed into the low bits of the result.
/// Per-shape recipes from cranelift `lower.isle:4962-4981`:
///   i8x16: PMOVMSKB direct (1 instr; 16-bit mask in low 16 bits).
///   i32x4: MOVMSKPS direct (1 instr; 4-bit mask).
///   i64x2: MOVMSKPD direct (1 instr; 2-bit mask).
///   i16x8: PACKSSWB(src, src) duplicates word high bits into byte
///          high bits, then PMOVMSKB extracts 16 bits, SHR 8 keeps
///          one half (8-bit mask).

pub fn emitI8x16Bitmask(
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

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    try buf.appendSlice(allocator, inst.encPmovmskb(dst_r, src_x).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI16x8Bitmask(
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

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14

    // scratch = MOVAPS src ; scratch = PACKSSWB(scratch, src) — packs
    // 8 words from each operand into 16 saturated bytes; high bit of
    // each output byte = high bit of source word. Both halves carry
    // the same pattern when src is duplicated.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encPacksswb(scratch_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encPmovmskb(dst_r, scratch_x).slice());
    try buf.appendSlice(allocator, inst.encShrRImm8(.d, dst_r, 8).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI32x4Bitmask(
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

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    try buf.appendSlice(allocator, inst.encMovmskps(dst_r, src_x).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI64x2Bitmask(
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

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    try buf.appendSlice(allocator, inst.encMovmskpd(dst_r, src_x).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i*x*.{shl, shr_s, shr_u}) for shapes that
/// have direct SSE2 packed-shift instructions — i16x8 / i32x4 /
/// i64x2 (with PSRAQ / i8x16 deferred to §9.7-u for synthesis).
/// Stack: pop count (i32), pop vec (v128), push v128.
///
/// SSE shift count semantics differ from Wasm: Intel SDM "If the
/// count value is greater than the operand size, destination is
/// set to all-zeros (PSLL/PSRL) or sign-extended (PSRA)". Wasm
/// requires `c mod lane_width` semantics. The explicit
/// `AND count_r, lane_width-1` aligns the two — when c <
/// lane_width, both behave identically.
///
/// 5-instruction emit:
///   AND count_r, mask_imm           ; mask to lane bits
///   MOVD scratch_xmm, count_r       ; count → low 32 of scratch
///   MOVAPS dst, vec                 ; (skip if dst==vec)
///   <shift> dst, scratch_xmm        ; shift dst in-place
fn emitV128IntShift(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder_shift: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    mask_imm: i8,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, mask_imm).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(scratch_x, count_r).slice());
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    try buf.appendSlice(allocator, encoder_shift(dst_x, scratch_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI16x8Shl(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsllwReg, 15);
}

pub fn emitI16x8ShrS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsrawReg, 15);
}

pub fn emitI16x8ShrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsrlwReg, 15);
}

pub fn emitI32x4Shl(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPslldReg, 31);
}

pub fn emitI32x4ShrS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsradReg, 31);
}

pub fn emitI32x4ShrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsrldReg, 31);
}

pub fn emitI64x2Shl(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsllqReg, 63);
}

pub fn emitI64x2ShrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntShift(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPsrlqReg, 63);
}

/// Wasm spec §4.4.4 (i64x2.shr_s) — pop count (i32), pop vec
/// (v128), push v128 with arithmetic (signed) shift-right per
/// 64-bit lane. SSE2 lacks PSRAQ (added in AVX-512); synthesise
/// per cranelift `lower.isle:943-951` with runtime sign-bit-mask
/// generation (avoids the const-pool plumbing the cranelift code
/// uses via `flip_high_bit_mask`):
///
///   AND count_r, 63                ; mask count
///   PCMPEQB scratch_mask, scratch_mask ; XMM14 = all-ones
///   PSLLQ-imm scratch_mask, 63     ; XMM14 = 0x80...0 per qword (sign bits)
///   MOVD scratch_count, count_r    ; XMM15 = count
///   PSRLQ-reg scratch_mask, scratch_count ; XMM14 = sign_bit_loc =
///                                  ;   0x80...0 >> c per qword
///   MOVAPS dst, vec                ; (skip if dst==vec)
///   PSRLQ-reg dst, scratch_count   ; ushr lanes
///   PXOR dst, scratch_mask         ; flip sign-bit-loc bits
///   PSUBQ dst, scratch_mask        ; subtract sign_bit_loc → arithmetic shr
///
/// 9-instruction emit; XMM14 holds sign_bit_loc (= mask shifted),
/// XMM15 holds count. dst gets the canonical signed-shifted result.
/// Wasm spec §4.4.4 (i8x16.shl) — pop count (i32), pop vec
/// (v128), push v128 with each byte shifted left by `c & 7`.
/// SSE has no native byte shift; synthesise via 16-bit-lane
/// shift + AND-mask broadcast (cranelift's approach uses a
/// const-pool table; we synthesise the mask inline to avoid
/// the still-pending ADR-0042 const-pool dependency).
///
/// 9-instruction emit:
///   AND count_r, 7                    ; mask count
///   PCMPEQB XMM14, XMM14              ; XMM14 = all-0xFF
///   MOVD XMM15, count_r                ; XMM15 = count
///   PSLLW XMM14, XMM15                  ; XMM14 = 0xFFFF<<c per word;
///                                      ;   low byte of each word = 0xFF<<c (= mask byte)
///   MOVAPS dst, vec                    ; (skip-elide if dst==vec)
///   PSLLW dst, XMM15                    ; shift vec lanes (16-bit shift; carry pollutes high bytes)
///   PXOR XMM15, XMM15                   ; reuse XMM15 as zero-control for PSHUFB
///   PSHUFB XMM14, XMM15                 ; broadcast byte 0 of XMM14 to all 16 bytes (uniform mask)
///   PAND dst, XMM14                     ; clear cross-byte carry bits
pub fn emitI8x16Shl(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14
    const count_x = abi.fp_spill_stage_xmms[1]; // XMM15

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, 7).slice());
    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(count_x, count_r).slice());
    try buf.appendSlice(allocator, inst.encPsllwReg(mask_x, count_x).slice());
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPsllwReg(dst_x, count_x).slice());
    try buf.appendSlice(allocator, inst.encPxor(count_x, count_x).slice()); // reuse as zero ctrl
    try buf.appendSlice(allocator, inst.encPshufb(mask_x, count_x).slice()); // broadcast byte 0
    try buf.appendSlice(allocator, inst.encPand(dst_x, mask_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i8x16.shr_u) — pop count (i32), pop vec,
/// push v128 with each byte logically shifted right by `c & 7`.
/// 10-instruction synthesis: PSRLW(0xFFFF, 8) → 0x00FF per word,
/// PSRLW that by c → 0x00FF >> c whose low byte = 0xFF >> c =
/// per-byte mask. PSHUFB-broadcast then PAND.
pub fn emitI8x16ShrU(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14
    const count_x = abi.fp_spill_stage_xmms[1]; // XMM15

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, 7).slice());
    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(mask_x, 8).slice()); // → 0x00FF per word
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(count_x, count_r).slice());
    try buf.appendSlice(allocator, inst.encPsrlwReg(mask_x, count_x).slice()); // → 0x00FF >> c per word
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPsrlwReg(dst_x, count_x).slice());
    try buf.appendSlice(allocator, inst.encPxor(count_x, count_x).slice()); // zero ctrl
    try buf.appendSlice(allocator, inst.encPshufb(mask_x, count_x).slice()); // broadcast byte 0
    try buf.appendSlice(allocator, inst.encPand(dst_x, mask_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i8x16.shr_s) — pop count (i32), pop vec
/// (v128), push v128 with each byte signed-shifted right by
/// `c & 7`. SSE has no native byte arithmetic shift and no
/// PSRAQ; synthesise per cranelift `lower.isle:846+` by sign-
/// extending bytes to words, applying PSRAW per half, and
/// packing back with signed saturation:
///
///   AND count_r, 7
///   PXOR XMM14, XMM14                ; XMM14 = zero
///   PCMPGTB XMM14, vec                ; XMM14 = sign-mask of src
///                                     ;   (0xFF where src byte < 0, else 0x00)
///   MOVAPS XMM15, vec                 ; XMM15 = src (preserve for high-half)
///   MOVAPS dst, vec                   ; (skip-elide if dst==vec)
///   PUNPCKLBW dst, XMM14              ; dst = sign-extended low 8 bytes (8 i16)
///   PUNPCKHBW XMM15, XMM14            ; XMM15 = sign-extended high 8 bytes
///   MOVD XMM14, count_r               ; XMM14 = count (sign-mask consumed)
///   PSRAW dst, XMM14                  ; signed shift low half
///   PSRAW XMM15, XMM14                ; signed shift high half
///   PACKSSWB dst, XMM15               ; pack 16 i16 → 16 i8 with signed saturation
///
/// Saturation is a no-op in this path because each i16 word
/// holds an in-range sign-extended-then-shifted i8 value (the
/// PSRAW preserves the sign bit invariant, and the resulting
/// magnitude is bounded by the original i8 range). 11
/// instructions; uses both XMM14 + XMM15 scratches.
/// Wasm spec §4.4.4 (f*x*.{abs, neg}) — sign-mask synthesis
/// inline (no const-pool dep). 5-instr abs / 4-instr neg.
///
/// abs(x) = x AND ~sign-mask:
///   PCMPEQB XMM14, XMM14            ; 0xFF per byte
///   PSLL{D,Q} XMM14, {31,63}        ; sign-mask per dword/qword
///   MOVAPS dst, src                 ; (skip-elide if alias)
///   PANDN XMM14, dst                ; XMM14 = ~sign-mask & src = abs
///   MOVAPS dst, XMM14
///
/// neg(x) = x XOR sign-mask:
///   PCMPEQB XMM14, XMM14
///   PSLL{D,Q} XMM14, {31,63}
///   MOVAPS dst, src                 ; (skip-elide)
///   PXOR dst, XMM14                 ; dst = src XOR sign-mask = -x
fn emitV128FpAbs(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    psll_imm: *const fn (dst: inst.Xmm, count: u8) inst.EncodedInsn,
    shift_count: u8,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, psll_imm(mask_x, shift_count).slice());
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPandn(mask_x, dst_x).slice()); // mask = ~mask & dst = abs
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, mask_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

fn emitV128FpNeg(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    psll_imm: *const fn (dst: inst.Xmm, count: u8) inst.EncodedInsn,
    shift_count: u8,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, psll_imm(mask_x, shift_count).slice());
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPxor(dst_x, mask_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpAbs(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPslldImm, 31);
}

pub fn emitF64x2Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpAbs(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsllqImm, 63);
}

pub fn emitF32x4Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpNeg(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPslldImm, 31);
}

pub fn emitF64x2Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpNeg(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsllqImm, 63);
}

/// Wasm spec §4.4.4 (f*x*.{ceil, floor, trunc, nearest}) —
/// SSE4.1 ROUNDPS/ROUNDPD with imm8 mode bits + suppress
/// precision exception (bit 3 set). Single-instr unary.
fn emitV128FpRound(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm, imm8: u8) inst.EncodedInsn,
    mode: u8,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    try buf.appendSlice(allocator, encoder(dst_x, src_x, 0x08 | (mode & 0x03)).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitF32x4Ceil(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encRoundps, 0b10);
}

pub fn emitF32x4Floor(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encRoundps, 0b01);
}

pub fn emitF32x4Trunc(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encRoundps, 0b11);
}

pub fn emitF32x4Nearest(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encRoundps, 0b00);
}

pub fn emitF64x2Ceil(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encRoundpd, 0b10);
}

pub fn emitF64x2Floor(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encRoundpd, 0b01);
}

pub fn emitF64x2Trunc(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encRoundpd, 0b11);
}

pub fn emitF64x2Nearest(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpRound(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encRoundpd, 0b00);
}

/// Wasm spec §4.4.5 (i8x16.swizzle) — pop idx (v128), pop v
/// (v128), push v128 with `out[i] = (idx[i] < 16) ? v[idx[i]] :
/// 0`. SSE PSHUFB has different semantics for ctrl bytes in
/// 16..127 (it indexes into src instead of zeroing); cranelift's
/// PADDUSB(0x70) saturating-fixup approach needs a const-pool
/// constant. This handler synthesises the correction inline
/// without const-pool by detecting `idx > 15` via PCMPGTB
/// (signed compare) and OR-ing the high bit into the corrected
/// ctrl. PSHUFB itself handles idx in 128..255 correctly (high
/// bit of ctrl = zero output).
///
/// 10-instruction emit:
///   PCMPEQB XMM14, XMM14            ; XMM14 = 0xFF per byte
///   PSRLW XMM14, 12                  ; XMM14 = 0x000F per word
///                                    ;   (low byte = 0x0F)
///   PXOR XMM15, XMM15                ; XMM15 = zero ctrl
///   PSHUFB XMM14, XMM15              ; XMM14 = 0x0F broadcast
///   MOVAPS XMM15, idx                 ; preserve idx in scratch
///   PCMPGTB XMM15, XMM14              ; XMM15 = (idx > 15) ? 0xFF : 0
///   POR XMM15, idx                    ; XMM15 = idx | mask =
///                                    ;   corrected ctrl (high bit
///                                    ;   set for idx>15 → PSHUFB → 0)
///   MOVAPS dst, v                     ; (skip-elide if dst==v)
///   PSHUFB dst, XMM15                 ; dst = shuffle(v, corrected_idx)
pub fn emitI8x16Swizzle(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const v_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_x = try gpr.resolveXmm(alloc, idx_v);
    const v_x = try gpr.resolveXmm(alloc, v_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const f_x = abi.fp_spill_stage_xmms[0]; // XMM14: 0x0F broadcast
    const c_x = abi.fp_spill_stage_xmms[1]; // XMM15: corrected ctrl

    try buf.appendSlice(allocator, inst.encPcmpeqB(f_x, f_x).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(f_x, 12).slice());
    try buf.appendSlice(allocator, inst.encPxor(c_x, c_x).slice());
    try buf.appendSlice(allocator, inst.encPshufb(f_x, c_x).slice()); // f_x = 0x0F broadcast
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(c_x, idx_x).slice());
    try buf.appendSlice(allocator, inst.encPcmpgtB(c_x, f_x).slice());
    try buf.appendSlice(allocator, inst.encPor(c_x, idx_x).slice());
    if (dst_x != v_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, v_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, c_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (FP convert family — signed + promote/demote)
/// — single-instr unaries via emitV128FpUnop:
///
///   f32x4.convert_i32x4_s   → CVTDQ2PS (4 i32 → 4 f32)
///   f64x2.convert_low_i32x4_s → CVTDQ2PD (2 low i32 → 2 f64)
///   f64x2.promote_low_f32x4 → CVTPS2PD (2 low f32 → 2 f64)
///   f32x4.demote_f64x2_zero → CVTPD2PS (2 f64 → 2 low f32, high 0)
///
/// Unsigned conversions and trunc-sat ops defer to later chunks
/// (cranelift uses const-pool float magic numbers per
/// `lower.isle:3761+`; pending ADR-0042 plumbing).

pub fn emitF32x4ConvertI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCvtdq2ps);
}

pub fn emitF64x2ConvertLowI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCvtdq2pd);
}

pub fn emitF64x2PromoteLowF32x4(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCvtps2pd);
}

pub fn emitF32x4DemoteF64x2Zero(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encCvtpd2ps);
}

/// Wasm spec §4.4.4 (i*x*.neg) — pop one v128, push v128 with
/// per-lane signed negation. Computed as `0 - src` via PSUB:
///
///   PXOR XMM14, XMM14            ; XMM14 = zero
///   PSUB_<shape> XMM14, src      ; XMM14 = 0 - src = -src
///   MOVAPS dst, XMM14            ; dst = -src
///
/// 3-instruction emit; aliasing-safe (dst is written only at
/// the end, after src has been fully consumed). PSUB doesn't
/// saturate at INT_MIN so the negation wraps modulo lane width
/// (matches Wasm spec).
fn emitV128IntNeg(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder_psub: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const scratch_x = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, inst.encPxor(scratch_x, scratch_x).slice());
    try buf.appendSlice(allocator, encoder_psub(scratch_x, src_x).slice());
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, scratch_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI8x16Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntNeg(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubB);
}

pub fn emitI16x8Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntNeg(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubW);
}

pub fn emitI32x4Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntNeg(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubD);
}

pub fn emitI64x2Neg(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntNeg(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubq);
}

/// Wasm spec §4.4.4 (i*x*.abs) — pop one v128, push v128 with
/// per-lane signed absolute value. SSSE3 PABSB/W/D directly
/// handle 8/16/32-bit lanes. i64x2.abs has no native SSE
/// instruction (PABSQ is AVX-512); synthesise per cranelift
/// `lower.isle:vec_int_abs` via sign-mask + PXOR/PSUBQ:
///
///   sign_mask = (src < 0) ? 0xFF...F : 0     (per qword)
///   result = (src ^ sign_mask) - sign_mask
///
/// For src >= 0: sign_mask = 0; result = src.
/// For src < 0:  sign_mask = -1; result = ~src - (-1) = -src.

pub fn emitI8x16Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPabsb);
}

pub fn emitI16x8Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPabsw);
}

pub fn emitI32x4Abs(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpUnop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPabsd);
}

/// i64x2.abs synthesis (no PABSQ in SSE; SSE4.2 PCMPGTQ
/// available per ADR-0041 baseline post-9.7-m). 5-instr recipe:
///   PXOR XMM14, XMM14                ; XMM14 = zero
///   PCMPGTQ XMM14, src                ; XMM14 = sign-mask of src
///                                     ;   (0xFF...F where src < 0, else 0)
///   MOVAPS dst, src                   ; (skip-elide if alias)
///   PXOR dst, XMM14                   ; flip bits where negative
///   PSUBQ dst, XMM14                  ; subtract sign-mask → abs
pub fn emitI64x2Abs(
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
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, inst.encPxor(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPcmpgtQ(mask_x, src_x).slice());
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPxor(dst_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPsubq(dst_x, mask_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i*x*.narrow_*_s / _u) — pop two v128, push
/// v128 with each pair of input lanes packed/saturated to a
/// half-width lane. SSE2/SSE4.1 PACK* instructions match the
/// Wasm spec exactly: signed pack saturates to signed half-
/// width range; unsigned pack clamps signed input to unsigned
/// half-width range.

pub fn emitI8x16NarrowI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPacksswb);
}

pub fn emitI8x16NarrowI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPackuswb);
}

pub fn emitI16x8NarrowI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPackssdw);
}

pub fn emitI16x8NarrowI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPackusdw);
}

/// Wasm spec §4.4.4 (i*x*.extend_low / extend_high) — pop one
/// v128, push one v128 with each lane sign- or zero-extended to
/// the wider lane width. SSE4.1 PMOVSX*/PMOVZX* directly handle
/// the LOW half (low 8 bytes / 4 i16 / 2 i32 of src extended).
/// HIGH half: shuffle src's upper 64 bits into the lower 64 via
/// PSHUFD imm=0xEE (selects lanes 2,3,2,3 — upper qword
/// duplicated into both 64-bit halves), then PMOVSX/ZX on the
/// shuffled register.
fn emitV128ExtendLow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    try buf.appendSlice(allocator, encoder(dst_x, src_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

fn emitV128ExtendHigh(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    // PSHUFD(dst, src, 0xEE): selects src lanes [2,3,2,3] →
    // dst's low 64 = src's upper 64. Then encoder reads low 64
    // of dst (now = src's upper 64) and extends to dst's lanes.
    try buf.appendSlice(allocator, inst.encPshufd(dst_x, src_x, 0xEE).slice());
    try buf.appendSlice(allocator, encoder(dst_x, dst_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI16x8ExtendLowI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxbw);
}

pub fn emitI16x8ExtendLowI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxbw);
}

pub fn emitI16x8ExtendHighI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxbw);
}

pub fn emitI16x8ExtendHighI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxbw);
}

pub fn emitI32x4ExtendLowI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxwd);
}

pub fn emitI32x4ExtendLowI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxwd);
}

pub fn emitI32x4ExtendHighI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxwd);
}

pub fn emitI32x4ExtendHighI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxwd);
}

pub fn emitI64x2ExtendLowI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxdq);
}

pub fn emitI64x2ExtendLowI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxdq);
}

pub fn emitI64x2ExtendHighI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxdq);
}

pub fn emitI64x2ExtendHighI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128ExtendHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxdq);
}

pub fn emitI8x16ShrS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const sign_x = abi.fp_spill_stage_xmms[0]; // XMM14: sign-mask, then count
    const high_x = abi.fp_spill_stage_xmms[1]; // XMM15: src copy, then high-half sign-extended

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, 7).slice());
    try buf.appendSlice(allocator, inst.encPxor(sign_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encPcmpgtB(sign_x, vec_x).slice());
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(high_x, vec_x).slice());
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPunpcklbw(dst_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encPunpckhbw(high_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(sign_x, count_r).slice()); // sign_x repurposed → count
    try buf.appendSlice(allocator, inst.encPsrawReg(dst_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encPsrawReg(high_x, sign_x).slice());
    try buf.appendSlice(allocator, inst.encPacksswb(dst_x, high_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI64x2ShrS(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const count_v = pushed_vregs.pop().?;
    const vec_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const count_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, count_v, 0);
    const mask_x = abi.fp_spill_stage_xmms[0]; // XMM14 — sign_bit_loc
    const count_x = abi.fp_spill_stage_xmms[1]; // XMM15 — count broadcast

    try buf.appendSlice(allocator, inst.encAndRImm8(.d, count_r, 63).slice());
    try buf.appendSlice(allocator, inst.encPcmpeqB(mask_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPsllqImm(mask_x, 63).slice());
    try buf.appendSlice(allocator, inst.encMovdXmmFromR32(count_x, count_r).slice());
    try buf.appendSlice(allocator, inst.encPsrlqReg(mask_x, count_x).slice());
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPsrlqReg(dst_x, count_x).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, mask_x).slice());
    try buf.appendSlice(allocator, inst.encPsubq(dst_x, mask_x).slice());
    try pushed_vregs.append(allocator, result_v);
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

/// Wasm spec §4.4.4 (f32x4.convert_i32x4_u) — convert 4 unsigned
/// i32 lanes to f32. SSE has no native CVTUDQ2PS (AVX-512 only);
/// recipe per cranelift `lower.isle:3811-3831` splits each u32 into
/// low/high 16-bit halves, converts each via signed CVTDQ2PS, and
/// recombines: low half is exact, high half is shifted-right-1
/// then doubled to fit signed conversion's range. 11-instruction
/// inline recipe, no const-pool dep.
pub fn emitF32x4ConvertI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const a_lo = abi.fp_spill_stage_xmms[0]; // XMM14
    const a_hi = abi.fp_spill_stage_xmms[1]; // XMM15

    // 1-3: a_lo = src masked to low 16 bits per lane.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(a_lo, src_x).slice());
    try buf.appendSlice(allocator, inst.encPslldImm(a_lo, 16).slice());
    try buf.appendSlice(allocator, inst.encPsrldImm(a_lo, 16).slice());

    // 4-5: a_hi = src - a_lo gives the high 16 bits in each lane
    // (still up high; we never shifted them down).
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(a_hi, src_x).slice());
    try buf.appendSlice(allocator, inst.encPsubD(a_hi, a_lo).slice());

    // 6: convert low halves via signed CVTDQ2PS (low halves fit
    // signed range cleanly — at most 0xFFFF).
    try buf.appendSlice(allocator, inst.encCvtdq2ps(a_lo, a_lo).slice());

    // 7-9: shift a_hi right by 1 to clear the sign bit so signed
    // CVTDQ2PS is exact, then double via ADDPS to undo the /2.
    try buf.appendSlice(allocator, inst.encPsrldImm(a_hi, 1).slice());
    try buf.appendSlice(allocator, inst.encCvtdq2ps(a_hi, a_hi).slice());
    try buf.appendSlice(allocator, inst.encAddps(a_hi, a_hi).slice());

    // 10-11: dst = a_hi + a_lo.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, a_hi).slice());
    try buf.appendSlice(allocator, inst.encAddps(dst_x, a_lo).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.trunc_sat_f32x4_s) — saturating truncate
/// f32→i32. CVTTPS2DQ produces 0x80000000 for both NaN and OOR; the
/// Wasm spec requires NaN→0 and positive-OOR→INT32_MAX. Recipe per
/// cranelift `lower.isle:3848-3869`: 9-instruction inline path that
/// uses CMPPS-self-eq to detect NaN, AND-masks NaN to +0.0 before
/// CVTTPS2DQ, then XOR-corrects positive-OOR's 0x80000000 to
/// 0x7FFFFFFF via a sign-extend-of-bit-31 derived mask.
pub fn emitI32x4TruncSatF32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14

    // 1-2: tmp = CMPPS(src, src, EQ_OQ) → all-1s where lane is not
    // NaN (since x==x is false only for NaN), 0 elsewhere.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(tmp, src_x).slice());
    try buf.appendSlice(allocator, inst.encCmpps(tmp, src_x, 0x00).slice());

    // 3-4: dst = src AND tmp → NaN lanes become +0.0, valid lanes
    // pass through.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encAndps(dst_x, tmp).slice());

    // 5: tmp ^= dst — high bit of each lane is (¬NaN) XOR (sign of
    // src). Captures the "should be MAX" hint for positive OOR.
    try buf.appendSlice(allocator, inst.encXorps(tmp, dst_x).slice());

    // 6: trunc-saturate. NaN was already zeroed; positive OOR and
    // negative OOR both produce 0x80000000 (INT_MIN sentinel).
    try buf.appendSlice(allocator, inst.encCvttps2dq(dst_x, dst_x).slice());

    // 7-9: derive a per-lane mask = (positive-OOR? all-1s : 0),
    // applied via XOR to flip 0x80000000 → 0x7FFFFFFF without
    // touching valid or negative-OOR lanes.
    try buf.appendSlice(allocator, inst.encPand(tmp, dst_x).slice());
    try buf.appendSlice(allocator, inst.encPsradImm(tmp, 31).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, tmp).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.trunc_sat_f32x4_u) — saturating
/// truncate f32→u32 (NaN→0, negative→0, OOR→UINT32_MAX). Recipe
/// per cranelift `lower.isle:3919-3962`: 14-instruction inline
/// path. CVTTPS2DQ saturates positive OOR to 0x80000000 (signed
/// INT_MIN), so the unsigned recipe splits into two paths:
/// (1) clamped src → CVTTPS2DQ direct for [0, INT_MAX]; (2) src
/// minus magic (INT_MAX+1 = 0x4f000000 as f32) → CVTTPS2DQ for
/// [INT_MAX+1, UINT_MAX]; mask the second-path result to 0 where
/// the lane belongs to path (1) and add. The "3 scratch xmm"
/// limit reported by cranelift's regalloc2 maps to dst (regalloc'd
/// from XMM8..XMM13) + XMM14 + XMM15 in zwasm — already covered
/// by the existing fp_spill_stage_xmms reservation; no ABI change
/// needed. Closes the last of the 4 deferred §9.7-ae u-variants.
pub fn emitI32x4TruncSatF32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const tmp2 = abi.fp_spill_stage_xmms[0]; // XMM14: zero, then magic, then mask, then zero again
    const tmp1 = abi.fp_spill_stage_xmms[1]; // XMM15: second-path copy

    // 1: tmp2 = 0 (XORPS XMM14, XMM14).
    try buf.appendSlice(allocator, inst.encXorps(tmp2, tmp2).slice());

    // 2: dst = MAXPS(src, 0) — clamp negatives + NaN to 0.
    // (MAXPS returns 2nd operand on NaN per Intel SDM; with
    // 2nd operand = 0 the result is 0 for NaN lanes.)
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encMaxps(dst_x, tmp2).slice());

    // 3-5: tmp2 = magic = 0x4f000000 (= f32(INT_MAX+1) via PSRLD-1
    // on all-ones then CVTDQ2PS round-up at the 2^23 boundary).
    try buf.appendSlice(allocator, inst.encPcmpeqD(tmp2, tmp2).slice());
    try buf.appendSlice(allocator, inst.encPsrldImm(tmp2, 1).slice());
    try buf.appendSlice(allocator, inst.encCvtdq2ps(tmp2, tmp2).slice());

    // 6: tmp1 = dst (clamped src) — second-path copy.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(tmp1, dst_x).slice());

    // 7: dst = CVTTPS2DQ(dst) — first path. Lanes in [0, INT_MAX]
    // produce correct i32; lanes >= INT_MAX+1 saturate to
    // 0x80000000 (signed INT_MIN sentinel) per Intel SDM.
    try buf.appendSlice(allocator, inst.encCvttps2dq(dst_x, dst_x).slice());

    // 8: tmp1 -= magic. Lanes in [0, INT_MAX] become negative;
    // lanes in [INT_MAX+1, UINT_MAX] become [0, INT_MAX]; lanes
    // >= UINT_MAX+1 become >= INT_MAX+1.
    try buf.appendSlice(allocator, inst.encSubps(tmp1, tmp2).slice());

    // 9: tmp2 = (magic LE tmp1) — mask: 0xFFFFFFFF where the
    // post-subtract value is >= magic (= original src >= UINT_MAX),
    // 0 elsewhere. CMPPS imm 0x02 = LE_OS.
    try buf.appendSlice(allocator, inst.encCmpps(tmp2, tmp1, 0x02).slice());

    // 10: tmp1 = CVTTPS2DQ(tmp1). Same saturation behaviour.
    try buf.appendSlice(allocator, inst.encCvttps2dq(tmp1, tmp1).slice());

    // 11: tmp1 ^= mask. Where the lane should saturate to UINT_MAX,
    // CVTTPS2DQ returned 0x80000000; XOR with 0xFFFFFFFF flips it
    // to 0x7FFFFFFF. (PADDD with first-path's 0x80000000 then
    // gives 0xFFFFFFFF = UINT_MAX.) Other lanes XOR with 0 = no-op.
    try buf.appendSlice(allocator, inst.encPxor(tmp1, tmp2).slice());

    // 12-13: clamp tmp1's first-path-only lanes (originally negative
    // post-subtract) to 0 via SMAX(tmp1, 0). Saturates to 0 the
    // [0, INT_MAX] lanes whose second path produced negative junk.
    try buf.appendSlice(allocator, inst.encPxor(tmp2, tmp2).slice());
    try buf.appendSlice(allocator, inst.encPmaxsd(tmp1, tmp2).slice());

    // 14: dst = first_path + second_path. For [0, INT_MAX] lanes
    // dst already holds the correct value + 0; for [INT_MAX+1,
    // UINT_MAX] dst holds 0x80000000 + (i32)(src - magic) = the
    // correct u32 reinterpreted as i32; for OOR-high lanes dst
    // holds 0x80000000 + 0x7FFFFFFF = 0xFFFFFFFF = UINT_MAX. ✓
    try buf.appendSlice(allocator, inst.encPaddD(dst_x, tmp1).slice());

    try pushed_vregs.append(allocator, result_v);
}

// =============================================================
// §9.7 / 9.7-av — FP pseudo-min/max (4 ops: f32x4/f64x2.pmin/pmax)
// Wasm pmin(c1, c2) = if c2 < c1: c2 else c1. The MINPS/MINPD
// "return src on equal/NaN/both-zero" behaviour (Intel SDM Vol 2A)
// matches this exactly — provided we swap operands so dst holds
// c2 and src holds c1. cranelift `lower.isle:1542-1545` makes the
// same call via CLIF bitselect-of-fcmp-LT pattern matching MINPS.
// No new encoders; reuses 9.7-q's encMinps/Maxps/Minpd/Maxpd.
// =============================================================

fn emitV128FpPseudoBinop(
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

    if (dst_x != rhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, rhs_x).slice());
    }
    try buf.appendSlice(allocator, encoder(dst_x, lhs_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (f32x4.pmin) — pseudo-min, NaN-propagating c1.
pub fn emitF32x4Pmin(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpPseudoBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encMinps);
}

/// Wasm spec §4.4.4 (f32x4.pmax) — pseudo-max, NaN-propagating c1.
pub fn emitF32x4Pmax(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpPseudoBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encMaxps);
}

/// Wasm spec §4.4.4 (f64x2.pmin) — pseudo-min, NaN-propagating c1.
pub fn emitF64x2Pmin(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpPseudoBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encMinpd);
}

/// Wasm spec §4.4.4 (f64x2.pmax) — pseudo-max, NaN-propagating c1.
pub fn emitF64x2Pmax(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128FpPseudoBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encMaxpd);
}

// =============================================================
// §9.7 / 9.7-au — int min/max + saturating arith + avgr_u (22 ops)
// All single-instruction native SSE2/SSE4.1 ops. Each wrapper
// dispatches through emitV128IntBinop (2-in 1-out) with the
// matching encoder. No new helpers; cranelift maps the same way
// (`inst.isle:2470-2486`).
// =============================================================

/// Wasm spec §4.4.4 (i8x16.min_s) — packed signed 8-bit min.
pub fn emitI8x16MinS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminsb);
}

/// Wasm spec §4.4.4 (i8x16.min_u) — packed unsigned 8-bit min.
pub fn emitI8x16MinU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminub);
}

/// Wasm spec §4.4.4 (i8x16.max_s) — packed signed 8-bit max.
pub fn emitI8x16MaxS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxsb);
}

/// Wasm spec §4.4.4 (i8x16.max_u) — packed unsigned 8-bit max.
pub fn emitI8x16MaxU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxub);
}

/// Wasm spec §4.4.4 (i16x8.min_s) — packed signed 16-bit min.
pub fn emitI16x8MinS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminsw);
}

/// Wasm spec §4.4.4 (i16x8.min_u) — packed unsigned 16-bit min.
pub fn emitI16x8MinU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminuw);
}

/// Wasm spec §4.4.4 (i16x8.max_s) — packed signed 16-bit max.
pub fn emitI16x8MaxS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxsw);
}

/// Wasm spec §4.4.4 (i16x8.max_u) — packed unsigned 16-bit max.
pub fn emitI16x8MaxU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxuw);
}

/// Wasm spec §4.4.4 (i32x4.min_s) — packed signed 32-bit min.
pub fn emitI32x4MinS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminsd);
}

/// Wasm spec §4.4.4 (i32x4.min_u) — packed unsigned 32-bit min.
pub fn emitI32x4MinU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPminud);
}

/// Wasm spec §4.4.4 (i32x4.max_s) — packed signed 32-bit max.
pub fn emitI32x4MaxS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxsd);
}

/// Wasm spec §4.4.4 (i32x4.max_u) — packed unsigned 32-bit max.
pub fn emitI32x4MaxU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaxud);
}

/// Wasm spec §4.4.4 (i8x16.add_sat_s) — packed signed saturating add.
pub fn emitI8x16AddSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPaddsb);
}

/// Wasm spec §4.4.4 (i8x16.add_sat_u) — packed unsigned saturating add.
pub fn emitI8x16AddSatU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPaddusb);
}

/// Wasm spec §4.4.4 (i8x16.sub_sat_s) — packed signed saturating sub.
pub fn emitI8x16SubSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubsb);
}

/// Wasm spec §4.4.4 (i8x16.sub_sat_u) — packed unsigned saturating sub.
pub fn emitI8x16SubSatU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubusb);
}

/// Wasm spec §4.4.4 (i16x8.add_sat_s) — packed signed saturating add.
pub fn emitI16x8AddSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPaddsw);
}

/// Wasm spec §4.4.4 (i16x8.add_sat_u) — packed unsigned saturating add.
pub fn emitI16x8AddSatU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPaddusw);
}

/// Wasm spec §4.4.4 (i16x8.sub_sat_s) — packed signed saturating sub.
pub fn emitI16x8SubSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubsw);
}

/// Wasm spec §4.4.4 (i16x8.sub_sat_u) — packed unsigned saturating sub.
pub fn emitI16x8SubSatU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPsubusw);
}

/// Wasm spec §4.4.4 (i8x16.avgr_u) — packed unsigned 8-bit
/// rounded average: (a+b+1) >> 1 per lane.
pub fn emitI8x16AvgrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPavgb);
}

/// Wasm spec §4.4.4 (i16x8.avgr_u) — packed unsigned 16-bit
/// rounded average: (a+b+1) >> 1 per lane.
pub fn emitI16x8AvgrU(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPavgw);
}

/// Wasm spec §4.4.4 (i16x8.q15mulr_sat_s) — Q15-format multiply
/// with rounding and saturating clamp to i16. PMULHRSW (SSSE3,
/// `lower.isle:1287-1294`) implements exactly this in 1
/// instruction; reuses emitV128IntBinop.
pub fn emitI16x8Q15mulrSatS(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmulhrsw);
}

/// Wasm spec §4.4.4 (i32x4.dot_i16x8_s) — pairwise dot product
/// of i16 lanes producing 4 i32 lanes. PMADDWD (SSE2,
/// `lower.isle:4073-4078`) implements exactly this in 1
/// instruction. Wrapping i32 accumulation matches Wasm spec
/// (INT16_MIN^2 + INT16_MIN^2 wraps modulo 2^32).
pub fn emitI32x4DotI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmaddwd);
}

/// Wasm spec §4.4.4 (i16x8.extmul_low_i8x16_{s,u}) — extend low 8
/// i8 lanes of each operand to i16 then multiply pairwise. 3-instr
/// recipe per cranelift `lower.isle:1197-1285`: PMOVSX/ZX BW on
/// each operand into XMM14 + dst, then PMULLW.
fn emitV128IntExtmulLow(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder_extend: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    encoder_mul: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, encoder_extend(tmp, lhs_x).slice());
    try buf.appendSlice(allocator, encoder_extend(dst_x, rhs_x).slice());
    try buf.appendSlice(allocator, encoder_mul(dst_x, tmp).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i16x8.extmul_high_i8x16_{s,u}) — like extmul_low
/// but operates on the HIGH half of each i8x16. 5-instr recipe:
/// PSHUFD imm=0xEE on each operand to swap high→low into scratches,
/// then PMOVSX/ZX BW + PMULLW.
fn emitV128IntExtmulHigh(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    encoder_extend: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
    encoder_mul: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14
    const t2 = abi.fp_spill_stage_xmms[1]; // XMM15

    try buf.appendSlice(allocator, inst.encPshufd(t1, lhs_x, 0xEE).slice());
    try buf.appendSlice(allocator, inst.encPshufd(t2, rhs_x, 0xEE).slice());
    try buf.appendSlice(allocator, encoder_extend(t1, t1).slice());
    try buf.appendSlice(allocator, encoder_extend(dst_x, t2).slice());
    try buf.appendSlice(allocator, encoder_mul(dst_x, t1).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI16x8ExtmulLowI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntExtmulLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxbw, inst.encPmullW);
}
pub fn emitI16x8ExtmulHighI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntExtmulHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxbw, inst.encPmullW);
}
pub fn emitI16x8ExtmulLowI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntExtmulLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxbw, inst.encPmullW);
}
pub fn emitI16x8ExtmulHighI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntExtmulHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxbw, inst.encPmullW);
}

pub fn emitI32x4ExtmulLowI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntExtmulLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxwd, inst.encPmullD);
}
pub fn emitI32x4ExtmulHighI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntExtmulHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovsxwd, inst.encPmullD);
}
pub fn emitI32x4ExtmulLowI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntExtmulLow(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxwd, inst.encPmullD);
}
pub fn emitI32x4ExtmulHighI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128IntExtmulHigh(allocator, buf, alloc, pushed_vregs, next_vreg, inst.encPmovzxwd, inst.encPmullD);
}

/// Wasm spec §4.4.4 (i64x2.extmul_{low,high}_i32x4_{s,u}) —
/// distinct shape from i16x8/i32x4 extmul because PMULDQ /
/// PMULUDQ already widen i32→i64; no separate extend needed.
/// Recipe: PSHUFD imm to position the source lanes (0x50 for
/// low half: lanes 0/1 → slots 0/2; 0xFA for high half: lanes
/// 2/3 → slots 0/2), then PMULDQ (signed) or PMULUDQ (unsigned).
/// 3-instr inline.
fn emitV128I64x2Extmul(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    pshufd_imm: u8,
    encoder_mul: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14

    try buf.appendSlice(allocator, inst.encPshufd(dst_x, lhs_x, pshufd_imm).slice());
    try buf.appendSlice(allocator, inst.encPshufd(tmp, rhs_x, pshufd_imm).slice());
    try buf.appendSlice(allocator, encoder_mul(dst_x, tmp).slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn emitI64x2ExtmulLowI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128I64x2Extmul(allocator, buf, alloc, pushed_vregs, next_vreg, 0x50, inst.encPmuldq);
}
pub fn emitI64x2ExtmulHighI32x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128I64x2Extmul(allocator, buf, alloc, pushed_vregs, next_vreg, 0xFA, inst.encPmuldq);
}
pub fn emitI64x2ExtmulLowI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128I64x2Extmul(allocator, buf, alloc, pushed_vregs, next_vreg, 0x50, inst.encPmuludq);
}
pub fn emitI64x2ExtmulHighI32x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    return emitV128I64x2Extmul(allocator, buf, alloc, pushed_vregs, next_vreg, 0xFA, inst.encPmuludq);
}

/// Wasm spec §4.4.4 (i16x8.extadd_pairwise_i8x16_u) — pairwise-
/// add adjacent unsigned i8 lanes, widening to i16. PMADDUBSW
/// (SSSE3) computes saturating dot product where the first
/// operand is read as unsigned bytes and the second as signed
/// bytes; with a +1 vector as the signed operand, this reduces
/// to plain pairwise-add. Synthesise the +1 vector inline via
/// PCMPEQB ones + PABSB → 0x01 per byte (no const-pool dep).
/// 4-instr recipe.
pub fn emitI16x8ExtaddPairwiseI8x16U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14

    // 1-2: tmp = 0x01 per byte (signed +1).
    try buf.appendSlice(allocator, inst.encPcmpeqB(tmp, tmp).slice());
    try buf.appendSlice(allocator, inst.encPabsb(tmp, tmp).slice());
    // 3-4: dst = src (unsigned bytes); PMADDUBSW dst, tmp →
    // result_word = u8(src[2i]) * 1 + u8(src[2i+1]) * 1.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPmaddubsw(dst_x, tmp).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.trunc_sat_f64x2_s_zero) — saturating
/// truncate low 2 f64 lanes → i32, with high 2 lanes of result
/// zeroed. Recipe per cranelift `lower.isle:4194-4214`:
///   1. NaN-detect via CMPPD self-EQ_OQ → mask
///   2. MINPD src, INT32_MAX_f64 → clamp positive OOR
///   3. ANDPD src, mask → zero NaN
///   4. CVTTPD2DQ dst, src → trunc; "_zero" suffix is automatic
///      (CVTTPD2DQ writes 2 i32 to low half, zeros high half).
/// Negative OOR (-INF / very-negative) becomes 0x80000000 by
/// CVTTPD2DQ's saturation semantics, matching Wasm INT32_MIN
/// clamp. The INT32_MAX_f64 const is stored in `extra_consts`
/// (a per-emit-pass pool extension since it's a shared static
/// constant rather than a per-instance literal).
const INT32_MAX_F64_BROADCAST: [16]u8 = blk: {
    // 2147483647.0 as f64 = 0x41DFFFFFFFC00000.
    // Per-qword broadcast, little-endian.
    var bytes: [16]u8 = undefined;
    const v: u64 = 0x41DFFFFFFFC00000;
    var i: usize = 0;
    while (i < 8) : (i += 1) bytes[i] = @intCast((v >> @intCast(i * 8)) & 0xFF);
    i = 0;
    while (i < 8) : (i += 1) bytes[8 + i] = bytes[i];
    break :blk bytes;
};

pub fn emitI32x4TruncSatF64x2SZero(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const tmp_const = abi.fp_spill_stage_xmms[0]; // XMM14
    const tmp_mask = abi.fp_spill_stage_xmms[1]; // XMM15

    // Look up or append INT32_MAX_F64_BROADCAST in extra_consts.
    var const_idx: u32 = 0;
    var found = false;
    for (extra_consts.items, 0..) |c, i| {
        if (std.mem.eql(u8, &c, &INT32_MAX_F64_BROADCAST)) {
            const_idx = simd_consts_base + @as(u32, @intCast(i));
            found = true;
            break;
        }
    }
    if (!found) {
        const_idx = simd_consts_base + @as(u32, @intCast(extra_consts.items.len));
        try extra_consts.append(allocator, INT32_MAX_F64_BROADCAST);
    }

    // 1: load INT32_MAX_F64-broadcast → tmp_const (RIP-relative).
    const enc = inst.encMovupsXmmRipRelPlaceholder(tmp_const);
    const start_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, enc.slice());
    const enc_len: u32 = @intCast(enc.slice().len);
    try simd_const_fixups.append(allocator, .{
        .disp32_byte_offset = start_byte + enc_len - 4,
        .post_insn_byte = start_byte + enc_len,
        .const_idx = const_idx,
    });

    // 2: MOVAPS dst, src.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    // 3: CMPPD tmp_mask, dst, EQ_OQ → mask of (lane==lane), 0 for NaN.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(tmp_mask, dst_x).slice());
    try buf.appendSlice(allocator, inst.encCmppd(tmp_mask, dst_x, 0x00).slice());
    // 4: MINPD dst, tmp_const → clamp upper to INT32_MAX_f64.
    try buf.appendSlice(allocator, inst.encMinpd(dst_x, tmp_const).slice());
    // 5: ANDPD dst, tmp_mask → zero NaN lanes.
    try buf.appendSlice(allocator, inst.encAndpd(dst_x, tmp_mask).slice());
    // 6: CVTTPD2DQ dst, dst → truncate; high 2 lanes auto-zeroed.
    try buf.appendSlice(allocator, inst.encCvttpd2dq(dst_x, dst_x).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// 16-byte UINT32_MAX as f64 broadcast (4294967295.0 =
/// 0x41EFFFFFFFE00000 per qword). Used by `i32x4.trunc_sat_f64x2_u_zero`
/// to clamp positive OOR before the mantissa-overlay extraction.
const UINT32_MAX_F64_BROADCAST: [16]u8 = [_]u8{ 0x00, 0x00, 0xE0, 0xFF, 0xFF, 0xFF, 0xEF, 0x41 } ** 2;

/// 16-byte 0x43300000-per-dword broadcast — single-precision
/// pattern of 0x1.0p+52 used by `f64x2.convert_low_i32x4_u`'s
/// UNPCKLPS interleave.
const UINT_MASK_LOW: [16]u8 = [_]u8{ 0x00, 0x00, 0x30, 0x43 } ** 4;

/// 16-byte 0x4330000000000000-per-qword broadcast — f64 value of
/// 2^52, subtracted to extract the original u32 from the
/// mantissa-overlay.
const UINT_MASK_HIGH: [16]u8 = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x43 } ** 2;

/// 16-byte 0x0F-per-byte mask used by popcnt's nibble-split path.
const NIBBLE_MASK_BROADCAST: [16]u8 = [_]u8{0x0F} ** 16;

/// Wasm spec §4.4.4 (i8x16.popcnt) per-byte popcount LUT used by
/// popcnt's PSHUFB-LUT path. Byte i = popcount(i) for i in 0..15.
const POPCNT_LUT: [16]u8 = [_]u8{ 0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4 };

/// Append `value` to `extra_consts` if not already present (linear
/// scan dedup), returning the resulting global const_idx (i.e.
/// simd_consts_base + position-in-extra_consts).
fn lookupOrAppendExtraConst(
    allocator: Allocator,
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
    value: [16]u8,
) Error!u32 {
    for (extra_consts.items, 0..) |c, i| {
        if (std.mem.eql(u8, &c, &value)) {
            return simd_consts_base + @as(u32, @intCast(i));
        }
    }
    const idx: u32 = simd_consts_base + @as(u32, @intCast(extra_consts.items.len));
    try extra_consts.append(allocator, value);
    return idx;
}

/// Emit a MOVUPS-RIP-rel placeholder targeting the given const-pool
/// idx and record the SimdConstFixup. Returns the destination XMM
/// (handler must already have decided which scratch to load into).
fn emitConstLoad(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    dst: inst.Xmm,
    const_idx: u32,
) Error!void {
    const enc = inst.encMovupsXmmRipRelPlaceholder(dst);
    const start_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, enc.slice());
    const enc_len: u32 = @intCast(enc.slice().len);
    try simd_const_fixups.append(allocator, .{
        .disp32_byte_offset = start_byte + enc_len - 4,
        .post_insn_byte = start_byte + enc_len,
        .const_idx = const_idx,
    });
}

/// Wasm spec §4.4.4 (i8x16.popcnt) — per-byte population count
/// via SSSE3 PSHUFB-LUT (cranelift `lower.isle:2491-2517`). Two
/// const-pool entries: 16-byte LUT[0..15] = popcount(i), and a
/// 0x0F-per-byte nibble mask. The recipe splits each byte into
/// low/high nibbles, looks each up in the LUT via PSHUFB, then
/// adds. PSHUFB clobbers its destination so the LUT must be
/// reloaded between the two halves.
///
/// Recipe (11 instr including 2 const loads, fits 2-scratch budget):
/// 1.  MOVUPS XMM15, [RIP+nibble_mask]
/// 2-4. compute high_nibbles into XMM14 (MOVAPS+PSRLW+PAND)
/// 5.  MOVUPS dst, [RIP+LUT]
/// 6.  PSHUFB dst, XMM14                ; popcount(high)
/// 7-8. compute low_nibbles into XMM14 (MOVAPS+PAND)
/// 9.  MOVUPS XMM15, [RIP+LUT]          ; reload (clobbers mask)
/// 10. PSHUFB XMM15, XMM14              ; popcount(low)
/// 11. PADDB dst, XMM15
pub fn emitI8x16Popcnt(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14
    const t2 = abi.fp_spill_stage_xmms[1]; // XMM15

    const lut_idx = try lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, POPCNT_LUT);
    const mask_idx = try lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, NIBBLE_MASK_BROADCAST);

    // 1: t2 = nibble_mask (0x0F per byte).
    try emitConstLoad(allocator, buf, simd_const_fixups, t2, mask_idx);
    // 2-4: t1 = high_nibbles per byte. PSRLW shifts at word level
    // so the mask AND is required.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(t1, src_x).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(t1, 4).slice());
    try buf.appendSlice(allocator, inst.encPand(t1, t2).slice());
    // 5-6: dst = LUT, then PSHUFB(dst, t1) → dst = popcount(high).
    try emitConstLoad(allocator, buf, simd_const_fixups, dst_x, lut_idx);
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, t1).slice());
    // 7-8: t1 = low_nibbles per byte. PAND with mask suffices —
    // no shift needed.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(t1, src_x).slice());
    try buf.appendSlice(allocator, inst.encPand(t1, t2).slice());
    // 9-10: t2 = LUT (reload — t2 was the mask, no longer needed),
    // then PSHUFB(t2, t1) → t2 = popcount(low).
    try emitConstLoad(allocator, buf, simd_const_fixups, t2, lut_idx);
    try buf.appendSlice(allocator, inst.encPshufb(t2, t1).slice());
    // 11: dst = popcount(high) + popcount(low) = popcount(byte).
    try buf.appendSlice(allocator, inst.encPaddB(dst_x, t2).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.trunc_sat_f64x2_u_zero) — saturating
/// truncate low 2 f64 lanes → u32, with high 2 lanes of result
/// zeroed. Recipe per cranelift `lower.isle:5061-5093`:
///   1. MOVAPD dst, src
///   2. XORPD t1, t1                ; clear t1 (zeros)
///   3. MAXPD dst, t1                ; NaN→0 (MAXPD propagates 2nd
///      operand on unordered) AND negative-OOR→0
///   4. MINPD dst, UMAX_f64          ; clamp positive OOR
///   5. ROUNDPD dst, dst, 0x0B        ; round-to-zero +
///      precision-suppress (0x08 | 0x03)
///   6. ADDPD dst, 2^52_f64           ; add magic; mantissa low
///      32 of each qword is now the truncated u32
///   7. SHUFPS dst, t1, 0x88          ; gather lane[0..1].low32
///      into result lanes 0/1, lanes 2/3 zero (from t1=zeros)
///
/// Reuses 9.7-ao's UINT_MASK_HIGH (= 2^52 magic) via extra_consts
/// dedup. New const: UINT32_MAX_F64_BROADCAST.
pub fn emitI32x4TruncSatF64x2UZero(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14 (zeros + final SHUFPS source)
    const t2 = abi.fp_spill_stage_xmms[1]; // XMM15 (const loads)

    const umax_idx = try lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, UINT32_MAX_F64_BROADCAST);
    const magic_idx = try lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, UINT_MASK_HIGH);

    // 1: dst = src.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    // 2: t1 = zeros via PXOR.
    try buf.appendSlice(allocator, inst.encPxor(t1, t1).slice());
    // 3: MAXPD dst, t1 — NaN + negative-OOR clamp to 0.
    try buf.appendSlice(allocator, inst.encMaxpd(dst_x, t1).slice());
    // 4: MINPD dst, UMAX_f64 — clamp positive OOR.
    try emitConstLoad(allocator, buf, simd_const_fixups, t2, umax_idx);
    try buf.appendSlice(allocator, inst.encMinpd(dst_x, t2).slice());
    // 5: ROUNDPD dst, dst, 0x0B — round-to-zero + suppress
    // precision exception.
    try buf.appendSlice(allocator, inst.encRoundpd(dst_x, dst_x, 0x0B).slice());
    // 6: ADDPD dst, 2^52_f64 — mantissa-overlay; low 32 of each
    // qword is now the truncated u32.
    try emitConstLoad(allocator, buf, simd_const_fixups, t2, magic_idx);
    try buf.appendSlice(allocator, inst.encAddpd(dst_x, t2).slice());
    // 7: SHUFPS dst, t1, 0x88 — gather low 32 of each qword into
    // i32x4 lanes 0/1, lanes 2/3 zero (from t1=zeros).
    try buf.appendSlice(allocator, inst.encShufps(dst_x, t1, 0x88).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (f64x2.convert_low_i32x4_u) — convert low 2
/// unsigned i32 lanes to f64. SSE has no native CVTUDQ2PD;
/// recipe per cranelift `lower.isle:3775-3779` exploits IEEE-754
/// mantissa placement: interleave each u32 with 0x43300000 (the
/// f64 exponent for 2^52) to form 0x4330000000000000 + u32, which
/// as f64 = 2^52 + u32; subtract 2^52 to recover u32 exactly.
///
/// 5-instr recipe: load uint_mask_low + UNPCKLPS interleave +
/// load uint_mask_high + SUBPD.
pub fn emitF64x2ConvertLowI32x4U(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14

    const low_idx = try lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, UINT_MASK_LOW);
    const high_idx = try lookupOrAppendExtraConst(allocator, extra_consts, simd_consts_base, UINT_MASK_HIGH);

    // 1: dst = src.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    // 2: tmp = uint_mask_low (0x43300000-per-dword).
    try emitConstLoad(allocator, buf, simd_const_fixups, tmp, low_idx);
    // 3: UNPCKLPS dst, tmp — interleave low 32-bit lanes.
    // dst.lanes = [dst[0], tmp[0], dst[1], tmp[1]].
    // After this each qword of dst is 0x4330_0000_<u32_lane>, which
    // as f64 = 2^52 + u32_lane.
    try buf.appendSlice(allocator, inst.encUnpcklps(dst_x, tmp).slice());
    // 4: tmp = uint_mask_high (0x4330000000000000-per-qword = 2^52 as f64).
    try emitConstLoad(allocator, buf, simd_const_fixups, tmp, high_idx);
    // 5: SUBPD dst, tmp — dst = (2^52 + u32) - 2^52 = u32 as f64.
    try buf.appendSlice(allocator, inst.encSubpd(dst_x, tmp).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.5 (v128.const) — push a 16-byte literal as a
/// v128 value. Per ADR-0042: the lower pass populates
/// `func.simd_consts` and stores the array index in
/// `ZirInstr.payload`. This handler emits a `MOVUPS xmm,
/// [RIP+0]` placeholder and records a SimdConstFixup; the
/// per-function emit close (emit.zig) appends the const-pool
/// 16-byte aligned past the trap stub and patches each fixup's
/// disp32.
pub fn emitV128Const(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    const_idx: u32,
) Error!void {
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const enc = inst.encMovupsXmmRipRelPlaceholder(dst_x);
    const start_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, enc.slice());
    const enc_len: u32 = @intCast(enc.slice().len);
    try simd_const_fixups.append(allocator, .{
        .disp32_byte_offset = start_byte + enc_len - 4,
        .post_insn_byte = start_byte + enc_len,
        .const_idx = const_idx,
    });
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.extadd_pairwise_i16x8_s) — pairwise-
/// add adjacent signed i16 lanes, widening to i32. PMADDWD (SSE2)
/// computes pairwise dot product of i16 lanes; with +1-per-i16
/// as one operand it reduces to plain pairwise add. Synthesise
/// the 0x00010001-per-dword (= +1 per word) mask inline via
/// PCMPEQB ones + PSRLW imm 15 → 0x0001 per word. 4-instr recipe;
/// no const-pool dep. The _u variant cannot use the same recipe
/// (PMADDWD reads operands as signed i16, treating high u16 lanes
/// as negative) — deferred to a later chunk pending ADR-0042.
pub fn emitI32x4ExtaddPairwiseI16x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const tmp = abi.fp_spill_stage_xmms[0]; // XMM14

    // 1-2: tmp = 0x0001 per word (= +1 per i16 lane).
    try buf.appendSlice(allocator, inst.encPcmpeqB(tmp, tmp).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(tmp, 15).slice());
    // 3-4: dst = src; PMADDWD dst, tmp computes adjacent pairs of
    // src's i16 lanes summed (multiplied by +1) into i32 lanes.
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPmaddwd(dst_x, tmp).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.5 (i8x16.shuffle) — pop 2 v128 (lhs, rhs), push
/// v128 result whose i-th byte = src[mask[i]] for mask[i] in 0..31
/// (lhs supplies indices 0..15, rhs supplies 16..31).
///
/// Recipe per cranelift `lower.isle:4710+`:
///   PSHUFB(src1, a_mask) | PSHUFB(src2, b_mask)
/// where a_mask[i] = mask[i]  if mask[i] < 16 else 0x80
///       b_mask[i] = mask[i]-16 if mask[i] >= 16 else 0x80.
/// PSHUFB writes 0 to a lane when its control byte's bit 7 is set
/// (= 0x80), so each side contributes only its valid lanes; POR
/// merges them.
///
/// 9-instr recipe (incl. 2 MOVUPS-RIP-rel const loads for derived
/// masks): 2 derived masks per call site, appended to extra_consts
/// (no dedup since masks are per-instance).
pub fn emitI8x16Shuffle(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    simd_const_fixups: *std.ArrayList(@import("types.zig").SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    simd_consts_base: u32,
    simd_consts: ?[]const [16]u8,
    const_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const consts = simd_consts orelse return Error.AllocationMissing;
    if (const_idx >= consts.len) return Error.AllocationMissing;
    const mask = consts[const_idx];

    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const lhs_x = try gpr.resolveXmm(alloc, lhs_v);
    const rhs_x = try gpr.resolveXmm(alloc, rhs_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14 — mask register
    const t2 = abi.fp_spill_stage_xmms[1]; // XMM15 — src2 PSHUFB result

    // Derive a_mask + b_mask from the original Wasm mask. PSHUFB's
    // bit-7 = "zero output" semantics handles the cross-source
    // selection without a separate compare.
    var a_mask: [16]u8 = undefined;
    var b_mask: [16]u8 = undefined;
    for (mask, 0..) |m, i| {
        a_mask[i] = if (m < 16) m else 0x80;
        b_mask[i] = if (m >= 16 and m < 32) m - 16 else 0x80;
    }
    // Per-instance — append unconditionally (no dedup; future
    // instances of i8x16.shuffle land their own pair).
    const a_idx: u32 = simd_consts_base + @as(u32, @intCast(extra_consts.items.len));
    try extra_consts.append(allocator, a_mask);
    const b_idx: u32 = simd_consts_base + @as(u32, @intCast(extra_consts.items.len));
    try extra_consts.append(allocator, b_mask);

    // 1: t1 = a_mask.
    try emitConstLoad(allocator, buf, simd_const_fixups, t1, a_idx);
    // 2: dst = lhs.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    // 3: PSHUFB dst, t1 → dst = lhs[a_mask] (zeros where a_mask
    // had bit 7 set = lanes that selected from rhs).
    try buf.appendSlice(allocator, inst.encPshufb(dst_x, t1).slice());
    // 4: t1 = b_mask.
    try emitConstLoad(allocator, buf, simd_const_fixups, t1, b_idx);
    // 5: t2 = rhs.
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(t2, rhs_x).slice());
    // 6: PSHUFB t2, t1 → t2 = rhs[b_mask] (zeros where b_mask had
    // bit 7 set = lanes that selected from lhs).
    try buf.appendSlice(allocator, inst.encPshufb(t2, t1).slice());
    // 7: dst = dst | t2 → merge the two halves.
    try buf.appendSlice(allocator, inst.encPor(dst_x, t2).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i32x4.extadd_pairwise_i16x8_u) — pairwise-
/// add adjacent unsigned i16 lanes, widening to i32. PMADDWD
/// reads operands as signed i16 so we sign-flip src first
/// (XOR with 0x8000-per-word converts u16 → signed i16 in
/// [-0x8000, 0x7FFF]), pairwise-multiply with +1, then add a
/// per-i32-lane correction (0x00010000 = 65536) to undo the
/// 2*0x8000 = 0x10000 bias introduced by sign-flipping each pair.
///
/// 11-instr inline recipe (no const-pool dep):
/// 1-2: t1 = 0x8000-per-word    (PCMPEQB ones + PSLLW imm 15)
/// 3-4: dst = src XOR t1         (sign-flip; MOVAPS + PXOR)
/// 5-6: t1 = 0x0001-per-word    (PCMPEQB ones + PSRLW imm 15)
/// 7  : PMADDWD dst, t1          (pairwise sum into i32)
/// 8-10: t1 = 0x00010000-per-dword (PCMPEQB + PSRLD 31 + PSLLD 16)
/// 11 : PADDD dst, t1            (correction: + 0x10000 per i32)
pub fn emitI32x4ExtaddPairwiseI16x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);
    const t1 = abi.fp_spill_stage_xmms[0]; // XMM14

    // 1-2: t1 = 0x8000-per-word (sign-flip mask).
    try buf.appendSlice(allocator, inst.encPcmpeqB(t1, t1).slice());
    try buf.appendSlice(allocator, inst.encPsllwImm(t1, 15).slice());
    // 3-4: dst = src XOR t1 (u16 → signed i16 via 2's-complement bias).
    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPxor(dst_x, t1).slice());
    // 5-6: t1 = 0x0001-per-word (+1 mask for PMADDWD).
    try buf.appendSlice(allocator, inst.encPcmpeqB(t1, t1).slice());
    try buf.appendSlice(allocator, inst.encPsrlwImm(t1, 15).slice());
    // 7: PMADDWD dst, t1 → pairs of (i16+i16) sums in i32 lanes.
    try buf.appendSlice(allocator, inst.encPmaddwd(dst_x, t1).slice());
    // 8-10: t1 = 0x00010000-per-dword (correction; + 0x10000 per i32 to
    // undo the 2*0x8000 = 0x10000 bias from sign-flipping each pair).
    try buf.appendSlice(allocator, inst.encPcmpeqB(t1, t1).slice());
    try buf.appendSlice(allocator, inst.encPsrldImm(t1, 31).slice());
    try buf.appendSlice(allocator, inst.encPslldImm(t1, 16).slice());
    // 11: PADDD dst, t1 → recover the original (u16+u16) sum per i32.
    try buf.appendSlice(allocator, inst.encPaddD(dst_x, t1).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (i16x8.extadd_pairwise_i8x16_s) — pairwise-
/// add adjacent signed i8 lanes, widening to i16. Same PMADDUBSW
/// recipe as the unsigned variant but with operand roles swapped:
/// the +1 vector goes into the unsigned slot (dst) so PMADDUBSW
/// reads the source's signed bytes correctly. 4-instr recipe.
pub fn emitI16x8ExtaddPairwiseI8x16S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const src_x = try gpr.resolveXmm(alloc, src_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    // 1-2: dst = 0x01 per byte (read as unsigned 1 by PMADDUBSW).
    try buf.appendSlice(allocator, inst.encPcmpeqB(dst_x, dst_x).slice());
    try buf.appendSlice(allocator, inst.encPabsb(dst_x, dst_x).slice());
    // 3: PMADDUBSW dst, src — result_word = unsigned(1)*signed(b0)
    // + unsigned(1)*signed(b1) = i8 + i8 (sign-extended sum).
    try buf.appendSlice(allocator, inst.encPmaddubsw(dst_x, src_x).slice());
    try pushed_vregs.append(allocator, result_v);
}
