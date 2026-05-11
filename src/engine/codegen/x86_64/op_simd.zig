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

// Re-exports for op_simd_test.zig back-compat (Phase 9 chunk 9.9-h-15;
// removed when 9.9-h-16 lands and the test file moves to per-class
// imports).
const op_simd_int_arith = @import("op_simd_int_arith.zig");
const op_simd_int_cmp_lane = @import("op_simd_int_cmp_lane.zig");
const op_simd_float = @import("op_simd_float.zig");

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
/// ADR-0053 Part 3 (§9.9 / 9.9-h-11) — spill-aware via the v128
/// helpers from gpr.zig. rhs loads to stage 0 (XMM14) when
/// spilled, lhs to stage 1 (XMM15), result also uses stage 1 so
/// the MOVAPS-from-lhs writes to the same physical XMM the
/// subsequent store flushes from. The 2-stage pool stays
/// conflict-free because the MOVAPS-from-lhs is the only write
/// to the lhs/result stage before the encoder reads rhs from
/// stage 0.
pub fn emitV128IntBinop(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const rhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, rhs_v, 0);
    const lhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, lhs_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);

    // Aliasing safety (D-066 mirror for x86_64; D-070 partial
    // discharge): regalloc's LIFO slot-reuse can assign
    // `result_v` the same physical XMM as `rhs_v` (when rhs's
    // last use is here). The naive `MOVAPS dst, lhs; encoder(dst,
    // rhs)` would overwrite rhs before encoder reads it, yielding
    // `result = lhs` (silently wrong PAND/POR/PXOR/etc. results
    // — surfaces as ~4400 simd_assert FAILs on x86_64
    // simd_bitwise / simd_i*x*_arith). Stash rhs through XMM7
    // (the project-canonical SIMD scratch — `abi.zig` reserves it
    // mirroring arm64's V31) when the alias condition holds.
    //
    // ADR-0053 Part 3 note: spilled rhs / spilled result use
    // different stages (XMM14 vs XMM15) by construction, so the
    // alias check only fires for in-reg-pool collisions.
    var rhs_for_op = rhs_x;
    if (dst_x != lhs_x and dst_x == rhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm7, rhs_x).slice());
        rhs_for_op = .xmm7;
    }
    if (dst_x != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, lhs_x).slice());
    }
    try buf.appendSlice(allocator, encoder(dst_x, rhs_for_op).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

// Per-Wasm-op wrappers. Each is a 1-line dispatch into the
// shared helper with the appropriate encoder. The function names
// document the spec op (Wasm spec §4.4.4 packed integer add/sub).

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
    // ADR-0053 Part 3c: dst v128 takes stage 0 (XMM14); the
    // subsequent MOVUPS-from-memory writes into dst directly, then
    // xmmStoreSpilledV128 flushes to the spill slot when needed.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, 16, func_idx);

    try buf.appendSlice(allocator, inst.encMovupsMemBaseIdx(false, dst_x, .rax, .rdx).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
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
    // ADR-0053 Part 3c: val v128 loads via MOVUPS when spilled.
    const val_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, val_v, 0);

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, 16, func_idx);

    try buf.appendSlice(allocator, inst.encMovupsMemBaseIdx(true, val_x, .rax, .rdx).slice());
}

/// Shared eff-addr + bounds-check prologue for v128 memory ops.
/// Mirrors op_memory.emitMemOp's prologue exactly with the access
/// size as a parameter. RAX = vm_base reload, RDX = ea base
/// (zero-ext idx + offset), RCX = ea+size scratch for the JA
/// bounds-check fixup.
pub fn v128MemPrologue(
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

/// Wasm spec §4.4.7 (v128.load32_zero) — load 4 bytes into low
/// lane; upper 96 bits zeroed. MOVSS xmm, [mem] does this in one
/// instruction per Intel SDM Vol 2A "MOVSS" (memory-source form
/// zero-extends the upper 96 bits of dst).
pub fn emitV128Load32Zero(
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
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load64_zero) — load 8 bytes into low
/// 64; upper 64 bits zeroed. MOVSD xmm, [mem] does this in one
/// instruction per Intel SDM Vol 2A "MOVSD" (memory-source form
/// zero-extends the upper 64 bits of dst).
pub fn emitV128Load64Zero(
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
    try pushed_vregs.append(allocator, result_v);
}

// =============================================================
// §9.7 / 9.7-bb — v128.load{8x8,16x4,32x2}_{s,u} (6 ops)
//
// Wasm spec §4.4.7. Load 8 bytes from mem into low qword of dst
// (upper 64 zeroed), then extend each lane to the next-larger
// size: 8→16, 16→32, 32→64. Cranelift recipe `lower.isle:
// 4977-5010` is identical: MOVQ + PMOVSX/ZX{BW,WD,DQ}. Reuses
// 9.7-ax's v128MemPrologue with access_size=8 and the existing
// PMOVSX/ZX encoders from 9.7-x. No new encoders.
// =============================================================

pub fn v128LoadExtend(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    func_idx: u32,
    extend_encoder: *const fn (dst: inst.Xmm, src: inst.Xmm) inst.EncodedInsn,
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
    try buf.appendSlice(allocator, extend_encoder(dst_x, dst_x).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.7 (v128.load8x8_s) — 8 i8 → 8 i16 sign-extend.
pub fn emitV128Load8x8S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, func_idx, inst.encPmovsxbw);
}

/// Wasm spec §4.4.7 (v128.load8x8_u) — 8 u8 → 8 i16 zero-extend.
pub fn emitV128Load8x8U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, func_idx, inst.encPmovzxbw);
}

/// Wasm spec §4.4.7 (v128.load16x4_s) — 4 i16 → 4 i32 sign-extend.
pub fn emitV128Load16x4S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, func_idx, inst.encPmovsxwd);
}

/// Wasm spec §4.4.7 (v128.load16x4_u) — 4 u16 → 4 i32 zero-extend.
pub fn emitV128Load16x4U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, func_idx, inst.encPmovzxwd);
}

/// Wasm spec §4.4.7 (v128.load32x2_s) — 2 i32 → 2 i64 sign-extend.
pub fn emitV128Load32x2S(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, func_idx, inst.encPmovsxdq);
}

/// Wasm spec §4.4.7 (v128.load32x2_u) — 2 u32 → 2 i64 zero-extend.
pub fn emitV128Load32x2U(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, func_idx: u32) Error!void {
    return v128LoadExtend(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, func_idx, inst.encPmovzxdq);
}

// =============================================================
// §9.7 / 9.7-ba — load_lane / store_lane × {8, 16, 32, 64} (8 ops)
//
// Wasm spec §4.4.7. load_lane: load N bytes from mem into a GPR
// then PINSR{B/W/D/Q} reg-form to merge into the input v128 at
// the lane immediate. store_lane: PEXTR{B/W/D/Q} reg-form to
// extract lane to a GPR then store N bytes to mem. payload =
// offset (memarg); extra = lane byte. RAX/RCX/RDX scratches are
// pool-excluded (same convention as v128MemPrologue).
//
// Cranelift recipes (`lower.isle`) use mem-form PINSR/PEXTR for
// one fewer instruction; zwasm's GPR-roundtrip path matches the
// existing 9.7-e..g lane-access shape and avoids new mem-form
// encoders for this chunk. Performance refinement is §9.10 work.
// =============================================================

pub fn v128LoadLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    lane: u32,
    func_idx: u32,
    comptime access_size: i8,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const vec_v = pushed_vregs.pop().?;
    const idx_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const vec_x = try gpr.resolveXmm(alloc, vec_v);
    const dst_x = try gpr.resolveXmm(alloc, result_v);

    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, access_size, func_idx);

    // Load value into RCX (zero-extended), then merge dst with vec
    // and PINSR the new lane.
    const enc_load = switch (access_size) {
        1 => inst.encMovzxR32_8MemBaseIdx(.rcx, .rax, .rdx),
        2 => inst.encMovzxR32_16MemBaseIdx(.rcx, .rax, .rdx),
        4 => inst.encMovR32FromBaseIdx(.rcx, .rax, .rdx),
        8 => inst.encMovR64FromBaseIdx(.rcx, .rax, .rdx),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc_load.slice());
    if (dst_x != vec_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, vec_x).slice());
    }
    const enc_pinsr = switch (access_size) {
        1 => inst.encPinsrB(dst_x, .rcx, @intCast(lane & 0xF)),
        2 => inst.encPinsrW(dst_x, .rcx, @intCast(lane & 0x7)),
        4 => inst.encPinsrD(dst_x, .rcx, @intCast(lane & 0x3)),
        8 => inst.encPinsrQ(dst_x, .rcx, @intCast(lane & 0x1)),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc_pinsr.slice());
    try pushed_vregs.append(allocator, result_v);
}

pub fn v128StoreLane(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    offset: u32,
    lane: u32,
    func_idx: u32,
    comptime access_size: i8,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const vec_v = pushed_vregs.pop().?;
    const idx_v = pushed_vregs.pop().?;

    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const vec_x = try gpr.resolveXmm(alloc, vec_v);

    // PEXTR the lane to RCX BEFORE the prologue clobbers RCX.
    const enc_pextr = switch (access_size) {
        1 => inst.encPextrB(.rcx, vec_x, @intCast(lane & 0xF)),
        2 => inst.encPextrW(.rcx, vec_x, @intCast(lane & 0x7)),
        4 => inst.encPextrD(.rcx, vec_x, @intCast(lane & 0x3)),
        8 => inst.encPextrQ(.rcx, vec_x, @intCast(lane & 0x1)),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc_pextr.slice());

    // The prologue uses RCX as a scratch (LEA RCX, [RDX+size]) —
    // we need to preserve our extracted value across that. Push/pop
    // RCX around the prologue to keep it. RBX is callee-saved,
    // could be used as a holder, but the simplest path is the
    // PUSH/POP pair (2 bytes each).
    try buf.appendSlice(allocator, inst.encPushR(.rcx).slice());
    try v128MemPrologue(allocator, buf, bounds_fixups, idx_r, offset, access_size, func_idx);
    try buf.appendSlice(allocator, inst.encPopR(.rcx).slice());

    const enc_store = switch (access_size) {
        1 => inst.encStoreR8MemBaseIdx(.rcx, .rax, .rdx),
        2 => inst.encStoreR16MemBaseIdx(.rcx, .rax, .rdx),
        4 => inst.encStoreR32MemBaseIdx(.rcx, .rax, .rdx),
        8 => inst.encStoreR64MemBaseIdx(.rcx, .rax, .rdx),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc_store.slice());
}

/// Wasm spec §4.4.7 (v128.load8_lane) — load 1 byte; merge into lane.
pub fn emitV128Load8Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128LoadLane(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, lane, func_idx, 1);
}

/// Wasm spec §4.4.7 (v128.load16_lane) — load 2 bytes; merge into lane.
pub fn emitV128Load16Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128LoadLane(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, lane, func_idx, 2);
}

/// Wasm spec §4.4.7 (v128.load32_lane) — load 4 bytes; merge into lane.
pub fn emitV128Load32Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128LoadLane(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, lane, func_idx, 4);
}

/// Wasm spec §4.4.7 (v128.load64_lane) — load 8 bytes; merge into lane.
pub fn emitV128Load64Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128LoadLane(allocator, buf, alloc, pushed_vregs, next_vreg, bounds_fixups, spill_base_off, offset, lane, func_idx, 8);
}

/// Wasm spec §4.4.7 (v128.store8_lane) — extract lane; store 1 byte.
pub fn emitV128Store8Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128StoreLane(allocator, buf, alloc, pushed_vregs, bounds_fixups, spill_base_off, offset, lane, func_idx, 1);
}

/// Wasm spec §4.4.7 (v128.store16_lane) — extract lane; store 2 bytes.
pub fn emitV128Store16Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128StoreLane(allocator, buf, alloc, pushed_vregs, bounds_fixups, spill_base_off, offset, lane, func_idx, 2);
}

/// Wasm spec §4.4.7 (v128.store32_lane) — extract lane; store 4 bytes.
pub fn emitV128Store32Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128StoreLane(allocator, buf, alloc, pushed_vregs, bounds_fixups, spill_base_off, offset, lane, func_idx, 4);
}

/// Wasm spec §4.4.7 (v128.store64_lane) — extract lane; store 8 bytes.
pub fn emitV128Store64Lane(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), bounds_fixups: *std.ArrayList(u32), spill_base_off: u32, offset: u32, lane: u32, func_idx: u32) Error!void {
    return v128StoreLane(allocator, buf, alloc, pushed_vregs, bounds_fixups, spill_base_off, offset, lane, func_idx, 8);
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
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3: src loads to stage 1 (XMM15) so the
    // "ones" scratch at stage 0 (XMM14) stays available for
    // PCMPEQ. dst defs at stage 1 (XMM15); the MOVAPS dst,src
    // copies before PCMPEQ overwrites XMM14.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 1);
    const ones = abi.fp_spill_stage_xmms[0]; // XMM14

    if (dst_x != src_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, src_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPcmpeqB(ones, ones).slice());
    try buf.appendSlice(allocator, inst.encPxor(dst_x, ones).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 (v128.and / v128.or / v128.xor) — pop two
/// v128, push v128 with the corresponding bitwise op applied per
/// 128-bit value. Reuses 9.7-b's `emitV128IntBinop` shape with the
/// SSE2 packed-int encoders (PAND / POR / PXOR — int-domain XOR
/// preferred over XORPS for bit-identical-but-domain-faster
/// semantics on older microarchitectures).
pub fn emitV128And(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPand);
}

pub fn emitV128Or(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPor);
}

pub fn emitV128Xor(allocator: Allocator, buf: *std.ArrayList(u8), alloc: regalloc.Allocation, pushed_vregs: *std.ArrayList(u32), next_vreg: *u32, spill_base_off: u32) Error!void {
    return emitV128IntBinop(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, inst.encPxor);
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
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3: rhs stage 0 (XMM14), lhs stage 1 (XMM15),
    // result stage 0 (XMM14 — same as rhs's load location: the
    // MOVAPS dst,rhs preserves rhs's value while writing to dst).
    const rhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, rhs_v, 0);
    const lhs_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, lhs_v, 1);
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);

    if (dst_x != rhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, rhs_x).slice());
    }
    try buf.appendSlice(allocator, inst.encPandn(dst_x, lhs_x).slice());
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
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
    spill_base_off: u32,
) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const c_v = pushed_vregs.pop().?;
    const b_v = pushed_vregs.pop().?;
    const a_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3b (§9.9 / 9.9-h-12): Bitselect has 3 v128
    // operand inputs + 1 v128 result = 4 operands but only 2
    // standard stage XMMs (XMM14 / XMM15) exist. Reclaim XMM7
    // (the D-066 alias-stash scratch — free in this handler since
    // we don't run an alias check) as a 3rd staging slot for `a`
    // and the spilled-result dst. Stage layout:
    //   c → stage 0 → XMM14 (also serves as the final scratch
    //                          since PANDN destroys it after c is dead).
    //   b → stage 1 → XMM15.
    //   a → XMM7 (custom; a is dead after MOVAPS dst, a).
    //   dst → result's home if in-reg; XMM7 if spilled (= same
    //          physical XMM as a; the MOVAPS-from-a is then a
    //          no-op).
    const c_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, c_v, 0);
    const b_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, b_v, 1);

    // Custom load for `a` → XMM7 (a 3rd staging slot, free for the
    // bitselect handler).
    var a_x: inst.Xmm = undefined;
    switch (alloc.slot(a_v, .fpr)) {
        .reg => |id| a_x = abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => |off| {
            const abs_off = spill_base_off + off;
            if (abs_off > 0x7FFF_FFFF) return Error.SlotOverflow;
            const disp: i32 = -@as(i32, @intCast(abs_off));
            try buf.appendSlice(allocator, inst.encLoadXmmV128MemRBPDisp32(.xmm7, disp).slice());
            a_x = .xmm7;
        },
    }

    // dst: in-reg → home; spilled → XMM7 (re-using a's physical
    // slot after a is consumed by the MOVAPS).
    const result_slot = alloc.slot(result_v, .fpr);
    const dst_x: inst.Xmm = switch (result_slot) {
        .reg => |id| abi.fpSlotToReg(id) orelse return Error.SlotOverflow,
        .spill => .xmm7,
    };

    // §9.9 / 9.9-h-14 (D-070 mirror for x86_64): regalloc LIFO
    // slot-reuse can assign `result_v` (= dst_x) the same in-reg
    // physical XMM as `c_v` or `b_v`. The MOVAPS dst,a then
    // clobbers c or b before subsequent reads. Stash whichever
    // alias hits, before step 1. c_x is stashed into XMM14
    // (= the scratch_x slot below; the MOVAPS already in place
    // for "copy c to XMM14" folds out). b_x is stashed into
    // XMM15 (= b's stage 1 if it was spilled — but if b was in-
    // reg this stage is currently unused).
    const c_safe: inst.Xmm = if (dst_x != a_x and dst_x == c_x and c_x != .xmm14) blk: {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm14, c_x).slice());
        break :blk .xmm14;
    } else c_x;
    const b_safe: inst.Xmm = if (dst_x != a_x and dst_x == b_x and b_x != .xmm15) blk: {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm15, b_x).slice());
        break :blk .xmm15;
    } else b_x;

    // Step 1: dst = MOVAPS(a). Skipped when dst already equals a
    // (in-reg alias OR both-spilled-and-routed-through-XMM7).
    if (dst_x != a_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst_x, a_x).slice());
    }
    // Step 2: dst = PAND(dst, c). c persists in c_safe past this.
    try buf.appendSlice(allocator, inst.encPand(dst_x, c_safe).slice());

    // Steps 3-4: scratch = c; scratch = PANDN(scratch, b). Reuse
    // XMM14 as scratch — when c_safe is already XMM14 (spilled
    // load OR alias-stashed above), the MOVAPS folds out.
    const scratch_x: inst.Xmm = .xmm14;
    if (c_safe != scratch_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch_x, c_safe).slice());
    }
    try buf.appendSlice(allocator, inst.encPandn(scratch_x, b_safe).slice());
    // Step 5: dst = POR(dst, scratch).
    try buf.appendSlice(allocator, inst.encPor(dst_x, scratch_x).slice());

    // Store if result is spilled.
    if (result_slot == .spill) {
        const off = result_slot.spill;
        const abs_off = spill_base_off + off;
        if (abs_off > 0x7FFF_FFFF) return Error.SlotOverflow;
        const disp: i32 = -@as(i32, @intCast(abs_off));
        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRBPDisp32(disp, .xmm7).slice());
    }
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

    // ADR-0053 Part 3: src loaded via MOVUPS into stage 0 (XMM14)
    // when spilled. The result is a GPR (i32 boolean), so no
    // XMM/spill interaction on the dst side.
    const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_v, 0);
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
pub fn emitV128AllTrue(
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

/// Append `value` to `extra_consts` if not already present (linear
/// scan dedup), returning the resulting global const_idx (i.e.
/// simd_consts_base + position-in-extra_consts).
pub fn lookupOrAppendExtraConst(
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
pub fn emitConstLoad(
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
    spill_base_off: u32,
) Error!void {
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // ADR-0053 Part 3c: dst v128 takes stage 0 (XMM14); MOVUPS-
    // RIP-rel writes into it, then store to spill if needed.
    const dst_x = try gpr.xmmDefSpilledV128(alloc, result_v, 0);
    const enc = inst.encMovupsXmmRipRelPlaceholder(dst_x);
    const start_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, enc.slice());
    const enc_len: u32 = @intCast(enc.slice().len);
    try simd_const_fixups.append(allocator, .{
        .disp32_byte_offset = start_byte + enc_len - 4,
        .post_insn_byte = start_byte + enc_len,
        .const_idx = const_idx,
    });
    try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

// ============================================================
// Back-compat re-exports (chunk 9.9-h-15) — removed in 9.9-h-16
// when op_simd_test.zig is split per ADR-0054.
// ============================================================
pub const emitI8x16Add = op_simd_int_arith.emitI8x16Add;
pub const emitI8x16Sub = op_simd_int_arith.emitI8x16Sub;
pub const emitI16x8Add = op_simd_int_arith.emitI16x8Add;
pub const emitI16x8Sub = op_simd_int_arith.emitI16x8Sub;
pub const emitI32x4Add = op_simd_int_arith.emitI32x4Add;
pub const emitI32x4Sub = op_simd_int_arith.emitI32x4Sub;
pub const emitI64x2Add = op_simd_int_arith.emitI64x2Add;
pub const emitI64x2Sub = op_simd_int_arith.emitI64x2Sub;
pub const emitI16x8Mul = op_simd_int_arith.emitI16x8Mul;
pub const emitI32x4Mul = op_simd_int_arith.emitI32x4Mul;
pub const emitI32x4Splat = op_simd_int_cmp_lane.emitI32x4Splat;
pub const emitI32x4ExtractLane = op_simd_int_cmp_lane.emitI32x4ExtractLane;
pub const emitI64x2ExtractLane = op_simd_int_cmp_lane.emitI64x2ExtractLane;
pub const emitI8x16GtS = op_simd_int_cmp_lane.emitI8x16GtS;
pub const emitI8x16LtS = op_simd_int_cmp_lane.emitI8x16LtS;
pub const emitI8x16LeS = op_simd_int_cmp_lane.emitI8x16LeS;
pub const emitI8x16GeS = op_simd_int_cmp_lane.emitI8x16GeS;
pub const emitI16x8GtS = op_simd_int_cmp_lane.emitI16x8GtS;
pub const emitI16x8LtS = op_simd_int_cmp_lane.emitI16x8LtS;
pub const emitI16x8LeS = op_simd_int_cmp_lane.emitI16x8LeS;
pub const emitI16x8GeS = op_simd_int_cmp_lane.emitI16x8GeS;
pub const emitI32x4GtS = op_simd_int_cmp_lane.emitI32x4GtS;
pub const emitI32x4LtS = op_simd_int_cmp_lane.emitI32x4LtS;
pub const emitI32x4LeS = op_simd_int_cmp_lane.emitI32x4LeS;
pub const emitI32x4GeS = op_simd_int_cmp_lane.emitI32x4GeS;
pub const emitI64x2GtS = op_simd_int_cmp_lane.emitI64x2GtS;
pub const emitI64x2LtS = op_simd_int_cmp_lane.emitI64x2LtS;
pub const emitI64x2LeS = op_simd_int_cmp_lane.emitI64x2LeS;
pub const emitI64x2GeS = op_simd_int_cmp_lane.emitI64x2GeS;
pub const emitI8x16GtU = op_simd_int_cmp_lane.emitI8x16GtU;
pub const emitI8x16LtU = op_simd_int_cmp_lane.emitI8x16LtU;
pub const emitI8x16LeU = op_simd_int_cmp_lane.emitI8x16LeU;
pub const emitI8x16GeU = op_simd_int_cmp_lane.emitI8x16GeU;
pub const emitI16x8GtU = op_simd_int_cmp_lane.emitI16x8GtU;
pub const emitI16x8LtU = op_simd_int_cmp_lane.emitI16x8LtU;
pub const emitI16x8LeU = op_simd_int_cmp_lane.emitI16x8LeU;
pub const emitI16x8GeU = op_simd_int_cmp_lane.emitI16x8GeU;
pub const emitI32x4GtU = op_simd_int_cmp_lane.emitI32x4GtU;
pub const emitI32x4LtU = op_simd_int_cmp_lane.emitI32x4LtU;
pub const emitI32x4LeU = op_simd_int_cmp_lane.emitI32x4LeU;
pub const emitI32x4GeU = op_simd_int_cmp_lane.emitI32x4GeU;
pub const emitF32x4Eq = op_simd_float.emitF32x4Eq;
pub const emitF32x4Ne = op_simd_float.emitF32x4Ne;
pub const emitF32x4Lt = op_simd_float.emitF32x4Lt;
pub const emitF32x4Gt = op_simd_float.emitF32x4Gt;
pub const emitF32x4Le = op_simd_float.emitF32x4Le;
pub const emitF32x4Ge = op_simd_float.emitF32x4Ge;
pub const emitF64x2Eq = op_simd_float.emitF64x2Eq;
pub const emitF64x2Ne = op_simd_float.emitF64x2Ne;
pub const emitF64x2Lt = op_simd_float.emitF64x2Lt;
pub const emitF64x2Gt = op_simd_float.emitF64x2Gt;
pub const emitF64x2Le = op_simd_float.emitF64x2Le;
pub const emitF64x2Ge = op_simd_float.emitF64x2Ge;
pub const emitF32x4Add = op_simd_float.emitF32x4Add;
pub const emitF32x4Sub = op_simd_float.emitF32x4Sub;
pub const emitF32x4Mul = op_simd_float.emitF32x4Mul;
pub const emitF32x4Div = op_simd_float.emitF32x4Div;
pub const emitF64x2Add = op_simd_float.emitF64x2Add;
pub const emitF64x2Sub = op_simd_float.emitF64x2Sub;
pub const emitF64x2Mul = op_simd_float.emitF64x2Mul;
pub const emitF64x2Div = op_simd_float.emitF64x2Div;
pub const emitF32x4Sqrt = op_simd_float.emitF32x4Sqrt;
pub const emitF64x2Sqrt = op_simd_float.emitF64x2Sqrt;
pub const emitF32x4Min = op_simd_float.emitF32x4Min;
pub const emitF32x4Max = op_simd_float.emitF32x4Max;
pub const emitF64x2Min = op_simd_float.emitF64x2Min;
pub const emitF64x2Max = op_simd_float.emitF64x2Max;
pub const emitI8x16AllTrue = op_simd_int_cmp_lane.emitI8x16AllTrue;
pub const emitI16x8AllTrue = op_simd_int_cmp_lane.emitI16x8AllTrue;
pub const emitI32x4AllTrue = op_simd_int_cmp_lane.emitI32x4AllTrue;
pub const emitI64x2AllTrue = op_simd_int_cmp_lane.emitI64x2AllTrue;
pub const emitI8x16Bitmask = op_simd_int_cmp_lane.emitI8x16Bitmask;
pub const emitI16x8Bitmask = op_simd_int_cmp_lane.emitI16x8Bitmask;
pub const emitI32x4Bitmask = op_simd_int_cmp_lane.emitI32x4Bitmask;
pub const emitI64x2Bitmask = op_simd_int_cmp_lane.emitI64x2Bitmask;
pub const emitI16x8Shl = op_simd_int_arith.emitI16x8Shl;
pub const emitI16x8ShrS = op_simd_int_arith.emitI16x8ShrS;
pub const emitI16x8ShrU = op_simd_int_arith.emitI16x8ShrU;
pub const emitI32x4Shl = op_simd_int_arith.emitI32x4Shl;
pub const emitI32x4ShrS = op_simd_int_arith.emitI32x4ShrS;
pub const emitI32x4ShrU = op_simd_int_arith.emitI32x4ShrU;
pub const emitI64x2Shl = op_simd_int_arith.emitI64x2Shl;
pub const emitI64x2ShrU = op_simd_int_arith.emitI64x2ShrU;
pub const emitI8x16Shl = op_simd_int_arith.emitI8x16Shl;
pub const emitI8x16ShrU = op_simd_int_arith.emitI8x16ShrU;
pub const emitF32x4Abs = op_simd_float.emitF32x4Abs;
pub const emitF64x2Abs = op_simd_float.emitF64x2Abs;
pub const emitF32x4Neg = op_simd_float.emitF32x4Neg;
pub const emitF64x2Neg = op_simd_float.emitF64x2Neg;
pub const emitF32x4Ceil = op_simd_float.emitF32x4Ceil;
pub const emitF32x4Floor = op_simd_float.emitF32x4Floor;
pub const emitF32x4Trunc = op_simd_float.emitF32x4Trunc;
pub const emitF32x4Nearest = op_simd_float.emitF32x4Nearest;
pub const emitF64x2Ceil = op_simd_float.emitF64x2Ceil;
pub const emitF64x2Floor = op_simd_float.emitF64x2Floor;
pub const emitF64x2Trunc = op_simd_float.emitF64x2Trunc;
pub const emitF64x2Nearest = op_simd_float.emitF64x2Nearest;
pub const emitI8x16Swizzle = op_simd_int_cmp_lane.emitI8x16Swizzle;
pub const emitF32x4ConvertI32x4S = op_simd_float.emitF32x4ConvertI32x4S;
pub const emitF64x2ConvertLowI32x4S = op_simd_float.emitF64x2ConvertLowI32x4S;
pub const emitF64x2PromoteLowF32x4 = op_simd_float.emitF64x2PromoteLowF32x4;
pub const emitF32x4DemoteF64x2Zero = op_simd_float.emitF32x4DemoteF64x2Zero;
pub const emitI8x16Neg = op_simd_int_arith.emitI8x16Neg;
pub const emitI16x8Neg = op_simd_int_arith.emitI16x8Neg;
pub const emitI32x4Neg = op_simd_int_arith.emitI32x4Neg;
pub const emitI64x2Neg = op_simd_int_arith.emitI64x2Neg;
pub const emitI8x16Abs = op_simd_int_arith.emitI8x16Abs;
pub const emitI16x8Abs = op_simd_int_arith.emitI16x8Abs;
pub const emitI32x4Abs = op_simd_int_arith.emitI32x4Abs;
pub const emitI64x2Abs = op_simd_int_arith.emitI64x2Abs;
pub const emitI8x16NarrowI16x8S = op_simd_int_cmp_lane.emitI8x16NarrowI16x8S;
pub const emitI8x16NarrowI16x8U = op_simd_int_cmp_lane.emitI8x16NarrowI16x8U;
pub const emitI16x8NarrowI32x4S = op_simd_int_cmp_lane.emitI16x8NarrowI32x4S;
pub const emitI16x8NarrowI32x4U = op_simd_int_cmp_lane.emitI16x8NarrowI32x4U;
pub const emitI16x8ExtendLowI8x16S = op_simd_int_cmp_lane.emitI16x8ExtendLowI8x16S;
pub const emitI16x8ExtendLowI8x16U = op_simd_int_cmp_lane.emitI16x8ExtendLowI8x16U;
pub const emitI16x8ExtendHighI8x16S = op_simd_int_cmp_lane.emitI16x8ExtendHighI8x16S;
pub const emitI16x8ExtendHighI8x16U = op_simd_int_cmp_lane.emitI16x8ExtendHighI8x16U;
pub const emitI32x4ExtendLowI16x8S = op_simd_int_cmp_lane.emitI32x4ExtendLowI16x8S;
pub const emitI32x4ExtendLowI16x8U = op_simd_int_cmp_lane.emitI32x4ExtendLowI16x8U;
pub const emitI32x4ExtendHighI16x8S = op_simd_int_cmp_lane.emitI32x4ExtendHighI16x8S;
pub const emitI32x4ExtendHighI16x8U = op_simd_int_cmp_lane.emitI32x4ExtendHighI16x8U;
pub const emitI64x2ExtendLowI32x4S = op_simd_int_cmp_lane.emitI64x2ExtendLowI32x4S;
pub const emitI64x2ExtendLowI32x4U = op_simd_int_cmp_lane.emitI64x2ExtendLowI32x4U;
pub const emitI64x2ExtendHighI32x4S = op_simd_int_cmp_lane.emitI64x2ExtendHighI32x4S;
pub const emitI64x2ExtendHighI32x4U = op_simd_int_cmp_lane.emitI64x2ExtendHighI32x4U;
pub const emitI8x16ShrS = op_simd_int_arith.emitI8x16ShrS;
pub const emitI64x2ShrS = op_simd_int_arith.emitI64x2ShrS;
pub const emitI8x16Eq = op_simd_int_cmp_lane.emitI8x16Eq;
pub const emitI16x8Eq = op_simd_int_cmp_lane.emitI16x8Eq;
pub const emitI32x4Eq = op_simd_int_cmp_lane.emitI32x4Eq;
pub const emitI64x2Eq = op_simd_int_cmp_lane.emitI64x2Eq;
pub const emitI8x16Ne = op_simd_int_cmp_lane.emitI8x16Ne;
pub const emitI16x8Ne = op_simd_int_cmp_lane.emitI16x8Ne;
pub const emitI32x4Ne = op_simd_int_cmp_lane.emitI32x4Ne;
pub const emitI64x2Ne = op_simd_int_cmp_lane.emitI64x2Ne;
pub const emitF64x2Splat = op_simd_float.emitF64x2Splat;
pub const emitF64x2ExtractLane = op_simd_float.emitF64x2ExtractLane;
pub const emitF64x2ReplaceLane = op_simd_float.emitF64x2ReplaceLane;
pub const emitF32x4Splat = op_simd_float.emitF32x4Splat;
pub const emitF32x4ExtractLane = op_simd_float.emitF32x4ExtractLane;
pub const emitF32x4ReplaceLane = op_simd_float.emitF32x4ReplaceLane;
pub const emitI8x16Splat = op_simd_int_cmp_lane.emitI8x16Splat;
pub const emitI16x8Splat = op_simd_int_cmp_lane.emitI16x8Splat;
pub const emitI64x2Splat = op_simd_int_cmp_lane.emitI64x2Splat;
pub const emitI8x16ExtractLaneS = op_simd_int_cmp_lane.emitI8x16ExtractLaneS;
pub const emitI8x16ExtractLaneU = op_simd_int_cmp_lane.emitI8x16ExtractLaneU;
pub const emitI16x8ExtractLaneS = op_simd_int_cmp_lane.emitI16x8ExtractLaneS;
pub const emitI16x8ExtractLaneU = op_simd_int_cmp_lane.emitI16x8ExtractLaneU;
pub const emitI8x16ReplaceLane = op_simd_int_cmp_lane.emitI8x16ReplaceLane;
pub const emitI16x8ReplaceLane = op_simd_int_cmp_lane.emitI16x8ReplaceLane;
pub const emitI32x4ReplaceLane = op_simd_int_cmp_lane.emitI32x4ReplaceLane;
pub const emitI64x2ReplaceLane = op_simd_int_cmp_lane.emitI64x2ReplaceLane;
pub const emitI64x2Mul = op_simd_int_arith.emitI64x2Mul;
pub const emitF32x4ConvertI32x4U = op_simd_float.emitF32x4ConvertI32x4U;
pub const emitI32x4TruncSatF32x4S = op_simd_float.emitI32x4TruncSatF32x4S;
pub const emitI32x4TruncSatF32x4U = op_simd_float.emitI32x4TruncSatF32x4U;
pub const emitF32x4Pmin = op_simd_float.emitF32x4Pmin;
pub const emitF32x4Pmax = op_simd_float.emitF32x4Pmax;
pub const emitF64x2Pmin = op_simd_float.emitF64x2Pmin;
pub const emitF64x2Pmax = op_simd_float.emitF64x2Pmax;
pub const emitI8x16MinS = op_simd_int_arith.emitI8x16MinS;
pub const emitI8x16MinU = op_simd_int_arith.emitI8x16MinU;
pub const emitI8x16MaxS = op_simd_int_arith.emitI8x16MaxS;
pub const emitI8x16MaxU = op_simd_int_arith.emitI8x16MaxU;
pub const emitI16x8MinS = op_simd_int_arith.emitI16x8MinS;
pub const emitI16x8MinU = op_simd_int_arith.emitI16x8MinU;
pub const emitI16x8MaxS = op_simd_int_arith.emitI16x8MaxS;
pub const emitI16x8MaxU = op_simd_int_arith.emitI16x8MaxU;
pub const emitI32x4MinS = op_simd_int_arith.emitI32x4MinS;
pub const emitI32x4MinU = op_simd_int_arith.emitI32x4MinU;
pub const emitI32x4MaxS = op_simd_int_arith.emitI32x4MaxS;
pub const emitI32x4MaxU = op_simd_int_arith.emitI32x4MaxU;
pub const emitI8x16AddSatS = op_simd_int_arith.emitI8x16AddSatS;
pub const emitI8x16AddSatU = op_simd_int_arith.emitI8x16AddSatU;
pub const emitI8x16SubSatS = op_simd_int_arith.emitI8x16SubSatS;
pub const emitI8x16SubSatU = op_simd_int_arith.emitI8x16SubSatU;
pub const emitI16x8AddSatS = op_simd_int_arith.emitI16x8AddSatS;
pub const emitI16x8AddSatU = op_simd_int_arith.emitI16x8AddSatU;
pub const emitI16x8SubSatS = op_simd_int_arith.emitI16x8SubSatS;
pub const emitI16x8SubSatU = op_simd_int_arith.emitI16x8SubSatU;
pub const emitI8x16AvgrU = op_simd_int_arith.emitI8x16AvgrU;
pub const emitI16x8AvgrU = op_simd_int_arith.emitI16x8AvgrU;
pub const emitI16x8Q15mulrSatS = op_simd_int_arith.emitI16x8Q15mulrSatS;
pub const emitI32x4DotI16x8S = op_simd_int_arith.emitI32x4DotI16x8S;
pub const emitI16x8ExtmulLowI8x16S = op_simd_int_cmp_lane.emitI16x8ExtmulLowI8x16S;
pub const emitI16x8ExtmulHighI8x16S = op_simd_int_cmp_lane.emitI16x8ExtmulHighI8x16S;
pub const emitI16x8ExtmulLowI8x16U = op_simd_int_cmp_lane.emitI16x8ExtmulLowI8x16U;
pub const emitI16x8ExtmulHighI8x16U = op_simd_int_cmp_lane.emitI16x8ExtmulHighI8x16U;
pub const emitI32x4ExtmulLowI16x8S = op_simd_int_cmp_lane.emitI32x4ExtmulLowI16x8S;
pub const emitI32x4ExtmulHighI16x8S = op_simd_int_cmp_lane.emitI32x4ExtmulHighI16x8S;
pub const emitI32x4ExtmulLowI16x8U = op_simd_int_cmp_lane.emitI32x4ExtmulLowI16x8U;
pub const emitI32x4ExtmulHighI16x8U = op_simd_int_cmp_lane.emitI32x4ExtmulHighI16x8U;
pub const emitI64x2ExtmulLowI32x4S = op_simd_int_cmp_lane.emitI64x2ExtmulLowI32x4S;
pub const emitI64x2ExtmulHighI32x4S = op_simd_int_cmp_lane.emitI64x2ExtmulHighI32x4S;
pub const emitI64x2ExtmulLowI32x4U = op_simd_int_cmp_lane.emitI64x2ExtmulLowI32x4U;
pub const emitI64x2ExtmulHighI32x4U = op_simd_int_cmp_lane.emitI64x2ExtmulHighI32x4U;
pub const emitI16x8ExtaddPairwiseI8x16U = op_simd_int_cmp_lane.emitI16x8ExtaddPairwiseI8x16U;
pub const emitI32x4TruncSatF64x2SZero = op_simd_float.emitI32x4TruncSatF64x2SZero;
pub const emitI8x16Popcnt = op_simd_int_arith.emitI8x16Popcnt;
pub const emitI32x4TruncSatF64x2UZero = op_simd_float.emitI32x4TruncSatF64x2UZero;
pub const emitF64x2ConvertLowI32x4U = op_simd_float.emitF64x2ConvertLowI32x4U;
pub const emitI32x4ExtaddPairwiseI16x8S = op_simd_int_cmp_lane.emitI32x4ExtaddPairwiseI16x8S;
pub const emitI8x16Shuffle = op_simd_int_cmp_lane.emitI8x16Shuffle;
pub const emitI32x4ExtaddPairwiseI16x8U = op_simd_int_cmp_lane.emitI32x4ExtaddPairwiseI16x8U;
pub const emitI16x8ExtaddPairwiseI8x16S = op_simd_int_cmp_lane.emitI16x8ExtaddPairwiseI8x16S;
