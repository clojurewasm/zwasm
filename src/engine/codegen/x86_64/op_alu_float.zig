//! x86_64 emit pass — FP-class scalar handlers (D-030 chunk-c).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape. Behaviour change zero — handler
//! bodies are unchanged from their pre-split shape; only their
//! home file moves.
//!
//! Handlers in this module (SSE2 scalar family):
//!   - `emitFpConst`    — f32/f64 const via RAX → MOVD/MOVQ.
//!   - `emitFpBinary`   — f32/f64 add/sub/mul/div via ADDSS/SD etc.
//!   - `emitFpUnary`    — f32/f64 abs/neg/sqrt/ceil/floor/trunc/
//!     nearest. Uses `emitFpRound` + `emitFpAbsNeg` helpers below.
//!   - `emitFpCompare`  — f32/f64 eq/ne/lt/gt/le/ge with NaN-
//!     aware SETcc combinations.
//!   - `emitFpCopysign` — bit-twiddling via RAX/RCX/RDX scratch.
//!   - `emitFpMinMax`   — three-path NaN/eq/normal IEEE min/max.
//!
//! FP↔i conversions (TruncSat / TruncTrap / Convert / Reinterpret
//! / Demote / Promote) live in `op_convert.zig` (chunk-d030-d).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const ctx_mod = @import("ctx.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// `(ctx, ins)` adapters for the FP
/// const cohort (`f32.const`, `f64.const`). Both wrap
/// `emitFpConst` (which dispatches on `ins.op` internally). Per-op
/// aliases preserve the per-op-file shape.
pub fn emitF32Const(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpConst(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
        @as(u32, @intCast(ins.payload)),
        ins.extra,
    );
}
pub const emitF64Const = emitF32Const;

/// Wasm spec §4.4.1.5 (f32.const / f64.const) — push the literal
/// onto the operand stack. Materialises the IEEE-754 bit pattern
/// in RAX (caller-saved scratch, not in pool), then MOVD/MOVQ
/// into the result XMM slot. ZirInstr packs the f64 bit pattern
/// across (payload=low32, extra=high32); f32 uses payload only.
pub fn emitFpConst(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
    payload: u32,
    extra: u32,
) Error!void {
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const xmm_dst = try gpr.xmmDefSpilled(alloc, result_v, 0);

    switch (op) {
        .@"f32.const" => {
            try buf.appendSlice(allocator, inst.encMovImm32W(.rax, payload).slice());
            try buf.appendSlice(allocator, inst.encMovdXmmFromR32(xmm_dst, .rax).slice());
        },
        .@"f64.const" => {
            const value: u64 = (@as(u64, extra) << 32) | @as(u64, payload);
            try buf.appendSlice(allocator, inst.encMovImm64Q(.rax, value).slice());
            try buf.appendSlice(allocator, inst.encMovqXmmFromR64(xmm_dst, .rax).slice());
        },
        else => unreachable,
    }
    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.5 (f32/f64 min/max — IEEE 754-2008 minNum /
/// maxNum semantics). Three-path implementation:
///
///   UCOMI lhs, rhs       ; sets ZF / CF / PF
///   JP nan_path          ; PF=1 → NaN; propagate
///   JE eq_path           ; equal — sign matters for ±0
///   common_path: MOVAPS dst,lhs ; MIN/MAX dst,rhs ; JMP end
///   eq_path: MOVAPS dst,lhs ; ORPS/ANDPS dst,rhs ; JMP end
///     (min uses ORPS — sign(-0) | sign(+0) = sign(-0) → -0;
///      max uses ANDPS — sign(-0) & sign(+0) = sign(+0) → +0)
///   nan_path: MOVAPS dst,lhs ; ADDSS dst,rhs (NaN propagates)
///   end:
///
/// All branches use rel32 placeholders patched at end-of-emit
/// to keep the layout independent of REX-byte length variance.
/// `(ctx, ins)` adapter for FP
/// min/max cohort (f32/f64.min/max, 4 ops).
pub fn emitFpMinMaxCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpMinMax(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitFpMinMax(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    var lhs_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    var rhs_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst = try gpr.xmmDefSpilled(alloc, result_v, 0);
    // min/max are commutative across all three emitted branches —
    // UCOMI's PF/ZF flags are symmetric, MINSS/MAXSS in the
    // common (non-NaN, non-equal) path is mathematically
    // commutative, ORPS/ANDPS in the eq path is commutative, and
    // ADDSS in the NaN path propagates NaN regardless of operand
    // order. When the regalloc gives dst == rhs (the case
    // emitFpBinary handles via its commutative branch), swap
    // operand roles so MOVAPS dst,lhs becomes a no-op (dst now
    // already holds rhs after the swap → MOVAPS dst,dst skipped).
    if (dst == rhs_x and dst != lhs_x) {
        const tmp = lhs_x;
        lhs_x = rhs_x;
        rhs_x = tmp;
    }

    const is_f64 = switch (op) {
        .@"f64.min", .@"f64.max" => true,
        else => false,
    };
    const is_max = switch (op) {
        .@"f32.max", .@"f64.max" => true,
        else => false,
    };
    const scalar_kind: inst.SseScalarKind = if (is_f64) .f64 else .f32;
    const packed_kind: inst.SsePackedKind = if (is_f64) .f64 else .f32;

    // 1. UCOMI lhs, rhs.
    if (is_f64) {
        try buf.appendSlice(allocator, inst.encUcomisd(lhs_x, rhs_x).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(lhs_x, rhs_x).slice());
    }

    // 2. JP rel32 (nan_path) placeholder.
    const jp_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.p, 0).slice());

    // 3. JE rel32 (eq_path) placeholder.
    const je_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());

    // 4. Common path: MOVAPS dst,lhs ; MIN/MAX dst,rhs.
    if (dst != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, lhs_x).slice());
    }
    const minmax_opcode: u8 = if (is_max) 0x5F else 0x5D;
    try buf.appendSlice(allocator, inst.encSseScalarBinary(scalar_kind, minmax_opcode, dst, rhs_x).slice());

    // 5. JMP rel32 (end) placeholder.
    const jmp_common_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 6. eq_path start; patch JE.
    const eq_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, je_byte, 6, @as(i32, @intCast(eq_byte)) - @as(i32, @intCast(je_byte)) - 6);

    // 7. eq path: MOVAPS dst,lhs ; ORPS/ANDPS dst,rhs.
    if (dst != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, lhs_x).slice());
    }
    const eq_opcode: u8 = if (is_max) 0x54 else 0x56; // ANDPS=54 (max), ORPS=56 (min)
    try buf.appendSlice(allocator, inst.encSsePackedBinary(packed_kind, eq_opcode, dst, rhs_x).slice());

    // 8. JMP rel32 (end) placeholder.
    const jmp_eq_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 9. nan_path start; patch JP.
    const nan_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jp_byte, 6, @as(i32, @intCast(nan_byte)) - @as(i32, @intCast(jp_byte)) - 6);

    // 10. nan path: MOVAPS dst,lhs ; ADDSS dst,rhs (NaN propagates).
    if (dst != lhs_x) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, lhs_x).slice());
    }
    try buf.appendSlice(allocator, inst.encSseScalarBinary(scalar_kind, 0x58, dst, rhs_x).slice());

    // 11. end; patch both common-JMP and eq-JMP.
    const end_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jmp_common_byte, 5, @as(i32, @intCast(end_byte)) - @as(i32, @intCast(jmp_common_byte)) - 5);
    inst.patchRel32(buf.items, jmp_eq_byte, 5, @as(i32, @intCast(end_byte)) - @as(i32, @intCast(jmp_eq_byte)) - 5);

    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.5 (f32/f64 copysign) — magnitude(lhs) |
/// sign(rhs). Composes via GPR bit-twiddling:
///   MOVD/Q EAX/RAX, lhs_xmm
///   MOVD/Q EDX/RDX, rhs_xmm
///   MOV ECX/RCX, magnitude_mask (0x7FFF.. low + low_imm or MOVABS)
///   AND EAX/RAX, ECX/RCX
///   MOV ECX/RCX, sign_mask (0x8000..)
///   AND EDX/RDX, ECX/RCX
///   OR EAX/RAX, EDX/RDX
///   MOVD/Q dst_xmm, EAX/RAX
///
/// **Scratches**: RAX/RCX/RDX — none in regalloc pool (RAX is
/// return_gpr, RCX/RDX are arg_gprs[3]/[2]; pool excludes both).
/// All caller-saved (no calls within this op so OK).
/// `(ctx, ins)` adapter for FP
/// copysign cohort (f32/f64.copysign, 2 ops).
pub fn emitFpCopysignCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpCopysign(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitFpCopysign(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 0);

    const is_f64 = op == .@"f64.copysign";

    if (is_f64) {
        try buf.appendSlice(allocator, inst.encMovqR64FromXmm(.rax, lhs_x).slice());
        try buf.appendSlice(allocator, inst.encMovqR64FromXmm(.rdx, rhs_x).slice());
        try buf.appendSlice(allocator, inst.encMovImm64Q(.rcx, 0x7FFFFFFFFFFFFFFF).slice());
        try buf.appendSlice(allocator, inst.encAndRR(.q, .rax, .rcx).slice());
        try buf.appendSlice(allocator, inst.encMovImm64Q(.rcx, 0x8000000000000000).slice());
        try buf.appendSlice(allocator, inst.encAndRR(.q, .rdx, .rcx).slice());
        try buf.appendSlice(allocator, inst.encOrRR(.q, .rax, .rdx).slice());
        try buf.appendSlice(allocator, inst.encMovqXmmFromR64(dst_x, .rax).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovdR32FromXmm(.rax, lhs_x).slice());
        try buf.appendSlice(allocator, inst.encMovdR32FromXmm(.rdx, rhs_x).slice());
        try buf.appendSlice(allocator, inst.encMovImm32W(.rcx, 0x7FFFFFFF).slice());
        try buf.appendSlice(allocator, inst.encAndRR(.d, .rax, .rcx).slice());
        try buf.appendSlice(allocator, inst.encMovImm32W(.rcx, 0x80000000).slice());
        try buf.appendSlice(allocator, inst.encAndRR(.d, .rdx, .rcx).slice());
        try buf.appendSlice(allocator, inst.encOrRR(.d, .rax, .rdx).slice());
        try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, .rax).slice());
    }

    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.5 (f32/f64 abs/neg/sqrt/ceil/floor/trunc/
/// nearest — 14 ops total). Strategies:
/// - sqrt: SQRTSS/SQRTSD dst, src (single instruction).
/// - ceil/floor/trunc/nearest: ROUNDSS/ROUNDSD dst, src, mode
///   (SSE4.1; mode imm 0=nearest, 1=floor, 2=ceil, 3=trunc).
/// - abs: materialise mask 0x7F.. into XMM7 via GPR → MOVD/MOVQ,
///   MOVAPS dst, src (if dst != src), ANDPS/ANDPD dst, XMM7.
/// - neg: same shape with mask 0x80.. and XORPS/XORPD.
///
/// **Scratches**: RAX (GPR mask materialisation, not in pool)
/// + XMM7 (per abi.zig comment "XMM7 is reserved as a SIMD
/// scratch"; pool starts at XMM8). Neither collides with any
/// live vreg.
/// `(ctx, ins)` adapter for the FP
/// unary cohort (f32/f64.abs/neg/sqrt/ceil/floor/trunc/nearest,
/// 14 ops).
pub fn emitFpUnaryCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpUnary(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitFpUnary(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst = try gpr.xmmDefSpilled(alloc, result_v, 1);

    const is_f64 = switch (op) {
        .@"f64.abs",
        .@"f64.neg",
        .@"f64.sqrt",
        .@"f64.ceil",
        .@"f64.floor",
        .@"f64.trunc",
        .@"f64.nearest",
        => true,
        else => false,
    };

    switch (op) {
        .@"f32.sqrt", .@"f64.sqrt" => {
            const kind: inst.SseScalarKind = if (is_f64) .f64 else .f32;
            try buf.appendSlice(allocator, inst.encSseScalarBinary(kind, 0x51, dst, src).slice());
        },
        .@"f32.ceil", .@"f64.ceil" => try emitFpRound(allocator, buf, dst, src, is_f64, 2),
        .@"f32.floor", .@"f64.floor" => try emitFpRound(allocator, buf, dst, src, is_f64, 1),
        .@"f32.trunc", .@"f64.trunc" => try emitFpRound(allocator, buf, dst, src, is_f64, 3),
        .@"f32.nearest", .@"f64.nearest" => try emitFpRound(allocator, buf, dst, src, is_f64, 0),
        .@"f32.abs", .@"f64.abs" => try emitFpAbsNeg(allocator, buf, dst, src, is_f64, true),
        .@"f32.neg", .@"f64.neg" => try emitFpAbsNeg(allocator, buf, dst, src, is_f64, false),
        else => unreachable,
    }
    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 1);
    try pushed_vregs.append(allocator, result_v);
}

/// Helper: ROUNDSS / ROUNDSD `dst, src, mode`.
fn emitFpRound(allocator: Allocator, buf: *std.ArrayList(u8), dst: inst.Xmm, src: inst.Xmm, is_f64: bool, mode: u8) Error!void {
    const enc = if (is_f64) inst.encRoundsd(dst, src, mode) else inst.encRoundss(dst, src, mode);
    try buf.appendSlice(allocator, enc.slice());
}

/// Helper: f32/f64 abs/neg via mask materialisation in XMM7
/// followed by ANDPS/ANDPD (abs) or XORPS/XORPD (neg).
fn emitFpAbsNeg(allocator: Allocator, buf: *std.ArrayList(u8), dst: inst.Xmm, src: inst.Xmm, is_f64: bool, is_abs: bool) Error!void {
    const mask_f32: u32 = if (is_abs) 0x7FFFFFFF else 0x80000000;
    const mask_f64: u64 = if (is_abs) 0x7FFFFFFFFFFFFFFF else 0x8000000000000000;
    const scratch: inst.Xmm = .xmm7;

    if (is_f64) {
        try buf.appendSlice(allocator, inst.encMovImm64Q(.rax, mask_f64).slice());
        try buf.appendSlice(allocator, inst.encMovqXmmFromR64(scratch, .rax).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovImm32W(.rax, mask_f32).slice());
        try buf.appendSlice(allocator, inst.encMovdXmmFromR32(scratch, .rax).slice());
    }

    if (dst != src) {
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
    }

    const kind: inst.SsePackedKind = if (is_f64) .f64 else .f32;
    const opcode: u8 = if (is_abs) 0x54 else 0x57; // ANDPS/PD = 54, XORPS/PD = 57
    try buf.appendSlice(allocator, inst.encSsePackedBinary(kind, opcode, dst, scratch).slice());
}

/// Wasm spec §4.4.1.5 (f32/f64 eq/ne/lt/gt/le/ge — 12 ops).
/// Returns i32 0/1 boolean per Wasm spec; NaN comparisons return
/// 0 (eq/lt/gt/le/ge) or 1 (ne) — the "unordered" case.
///
/// **Strategy** — UCOMISS/UCOMISD set ZF/CF/PF; we drive SETcc:
/// - lt / le: swap operands, then SETA / SETAE. Since SETA/AE
///   require CF=0, NaN (CF=1) returns 0 cleanly.
/// - gt / ge: no swap; SETA / SETAE.
/// - eq: SETNP (PF=0 → ordered) + SETE (ZF=1) AND-combined.
///   NaN (PF=1) zeros the SETNP byte; ordered-equal sets both.
/// - ne: SETP (PF=1 → unordered) + SETNE (ZF=0) OR-combined.
///   NaN sets SETP=1; ordered-not-equal sets SETNE=1.
///
/// **Scratch**: AL is used as the SETNP/SETP byte. RAX is not
/// in the regalloc pool so AL doesn't collide with any vreg.
/// `(ctx, ins)` adapter for the FP
/// compare cohort (f32/f64.eq/ne/lt/gt/le/ge, 12 ops).
pub fn emitFpCompareCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpCompare(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitFpCompare(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst = try gpr.gprDefSpilled(alloc, result_v, 0);

    const is_f64 = switch (op) {
        .@"f64.eq", .@"f64.ne", .@"f64.lt", .@"f64.gt", .@"f64.le", .@"f64.ge" => true,
        else => false,
    };
    // For lt / le, compare in swapped order so SETA / SETAE
    // expresses (lhs < rhs) / (lhs <= rhs) cleanly even with
    // NaN (UCOMI sets CF=1 on unordered, which SETA / SETAE
    // reject correctly).
    const swap = switch (op) {
        .@"f32.lt", .@"f32.le", .@"f64.lt", .@"f64.le" => true,
        else => false,
    };
    const a = if (swap) rhs_x else lhs_x;
    const b = if (swap) lhs_x else rhs_x;

    if (is_f64) {
        try buf.appendSlice(allocator, inst.encUcomisd(a, b).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(a, b).slice());
    }

    switch (op) {
        .@"f32.lt", .@"f32.gt", .@"f64.lt", .@"f64.gt" => {
            try buf.appendSlice(allocator, inst.encSetccR(.a, dst).slice());
            try buf.appendSlice(allocator, inst.encMovzxR32R8(dst, dst).slice());
        },
        .@"f32.le", .@"f32.ge", .@"f64.le", .@"f64.ge" => {
            try buf.appendSlice(allocator, inst.encSetccR(.ae, dst).slice());
            try buf.appendSlice(allocator, inst.encMovzxR32R8(dst, dst).slice());
        },
        .@"f32.eq", .@"f64.eq" => {
            // SETNP AL ; MOVZX EAX, AL ; SETE dst_low8 ;
            // MOVZX dst32, dst_low8 ; AND dst, EAX.
            try buf.appendSlice(allocator, inst.encSetccR(.np, .rax).slice());
            try buf.appendSlice(allocator, inst.encMovzxR32R8(.rax, .rax).slice());
            try buf.appendSlice(allocator, inst.encSetccR(.e, dst).slice());
            try buf.appendSlice(allocator, inst.encMovzxR32R8(dst, dst).slice());
            try buf.appendSlice(allocator, inst.encAndRR(.d, dst, .rax).slice());
        },
        .@"f32.ne", .@"f64.ne" => {
            // SETP AL ; MOVZX EAX, AL ; SETNE dst_low8 ;
            // MOVZX dst32, dst_low8 ; OR dst, EAX.
            try buf.appendSlice(allocator, inst.encSetccR(.p, .rax).slice());
            try buf.appendSlice(allocator, inst.encMovzxR32R8(.rax, .rax).slice());
            try buf.appendSlice(allocator, inst.encSetccR(.ne, dst).slice());
            try buf.appendSlice(allocator, inst.encMovzxR32R8(dst, dst).slice());
            try buf.appendSlice(allocator, inst.encOrRR(.d, dst, .rax).slice());
        },
        else => unreachable,
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.5 (f32/f64 add/sub/mul/div) — SSE2 scalar
/// ops (ADDSS/ADDSD/SUBSS/SUBSD/MULSS/MULSD/DIVSS/DIVSD). Emits
/// `MOVAPS dst, lhs` then `<op> dst, rhs` (mirrors the integer
/// always-MOV form; the peephole that elides the MOV when
/// dst == lhs lands when regalloc starts reusing slots).
///
/// **Constraint**: dst must not equal rhs (MOVAPS dst, lhs would
/// clobber rhs before OP reads it). With fresh-vreg-per-op
/// allocation this never fires; surfaces as `UnsupportedOp` —
/// same shape as `emitI32Binary`.
/// `(ctx, ins)` adapter for the FP
/// arithmetic cohort (f32/f64.add/sub/mul/div, 8 ops).
pub fn emitFpBinaryCtx(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpBinary(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}

pub fn emitFpBinary(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, lhs_v, 0);
    const rhs = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, rhs_v, 1);
    const dst = try gpr.xmmDefSpilled(alloc, result_v, 0);

    // Parallel-move for the dst==rhs case on FP
    // (XMM-class mirror of D-029). Commute commutative add/mul;
    // scratch through XMM14 for non-commutative sub/div.
    const commutative = switch (op) {
        .@"f32.add", .@"f32.mul", .@"f64.add", .@"f64.mul" => true,
        .@"f32.sub", .@"f32.div", .@"f64.sub", .@"f64.div" => false,
        else => unreachable,
    };
    const kind: inst.SseScalarKind = switch (op) {
        .@"f32.add", .@"f32.sub", .@"f32.mul", .@"f32.div" => .f32,
        .@"f64.add", .@"f64.sub", .@"f64.mul", .@"f64.div" => .f64,
        else => unreachable,
    };
    const opcode: u8 = switch (op) {
        .@"f32.add", .@"f64.add" => 0x58,
        .@"f32.sub", .@"f64.sub" => 0x5C,
        .@"f32.mul", .@"f64.mul" => 0x59,
        .@"f32.div", .@"f64.div" => 0x5E,
        else => unreachable,
    };

    if (dst == rhs and dst != lhs) {
        if (commutative) {
            try buf.appendSlice(allocator, inst.encSseScalarBinary(kind, opcode, dst, lhs).slice());
        } else {
            const scratch = abi.fp_spill_stage_xmms[0];
            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(scratch, lhs).slice());
            try buf.appendSlice(allocator, inst.encSseScalarBinary(kind, opcode, scratch, rhs).slice());
            if (dst != scratch) {
                try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, scratch).slice());
            }
        }
    } else {
        if (dst != lhs) {
            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, lhs).slice());
        }
        try buf.appendSlice(allocator, inst.encSseScalarBinary(kind, opcode, dst, rhs).slice());
    }

    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.4 / §3.3.2.2 — `select_typed t` for `t ∈ {f32,
/// f64}`. x86 has no FP CMOV, so we shuttle the FP bits through
/// scratch GPRs (R10/R11 from `abi.spill_stage_gprs`), do a GPR
/// `CMOVNE`, and MOVD/Q back into the destination XMM. 6 instr
/// (8 with MOV/Q-back). is_f64=true uses MOVQ (full 64-bit
/// shuttle); is_f64=false uses MOVD (low 32 bits — upper 96
/// bits of XMM register are don't-care for Wasm f32 semantics).
pub fn emitFpSelect(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    pushed_vregs: *std.ArrayList(u32),
    is_f64: bool,
    cond_v: u32,
    val1_v: u32,
    val2_v: u32,
    result_v: u32,
) Error!void {
    const xmm_val1 = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, val1_v, 0);
    const xmm_val2 = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, val2_v, 1);
    const cond_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, cond_v, 0);
    const r_a = abi.spill_stage_gprs[0];
    const r_b = abi.spill_stage_gprs[1];
    // TEST cond BEFORE the MOVQ/MOVD that load val1 into r_a: when `cond_v` is
    // SPILLED, gprLoadSpilled stages it through spill_stage_gprs[0] == r_a, so
    // `MOVQ r_a, xmm_val1` would clobber cond before the test (D-330 fix exposed
    // this once `<` strict expiry spilled cond). MOVQ/MOVD don't touch EFLAGS, so
    // the flags survive to the CMOV.
    try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
    if (is_f64) {
        try buf.appendSlice(allocator, inst.encMovqR64FromXmm(r_a, xmm_val1).slice());
        try buf.appendSlice(allocator, inst.encMovqR64FromXmm(r_b, xmm_val2).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovdR32FromXmm(r_a, xmm_val1).slice());
        try buf.appendSlice(allocator, inst.encMovdR32FromXmm(r_b, xmm_val2).slice());
    }
    try buf.appendSlice(allocator, inst.encCmovccRR(.q, .ne, r_b, r_a).slice());
    const xmm_dst = try gpr.xmmDefSpilled(alloc, result_v, 0);
    if (is_f64) {
        try buf.appendSlice(allocator, inst.encMovqXmmFromR64(xmm_dst, r_b).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovdXmmFromR32(xmm_dst, r_b).slice());
    }
    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}
