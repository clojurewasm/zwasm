//! x86_64 emit pass — i32 ALU / compare / shift / bitcount /
//! width-cross handlers (D-030 chunk-b).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape. Behaviour change zero — handler
//! bodies are unchanged from their pre-split shape; only their
//! home file moves. Signatures stay positional (allocator + buf
//! + alloc + pushed_vregs + next_vreg + op) to defer the
//! `EmitCtx` consolidation to a later chunk that materialises a
//! consumer for it.
//!
//! Handlers in this module:
//!   - `emitI32Binary`  — i32 add / sub / mul / and / or / xor.
//!   - `emitI32Compare` — i32 eq / ne / lt_s / lt_u / gt_s / gt_u
//!     / le_s / le_u / ge_s / ge_u (10 ops; SETcc + MOVZX).
//!   - `emitI32Eqz`     — TEST + SETE + MOVZX shape.
//!   - `emitI32Shift`   — shl / shr_s / shr_u / rotl / rotr;
//!     count routed through CL.
//!   - `emitI32Bitcount`— clz / ctz / popcnt via LZCNT / TZCNT
//!     / POPCNT.
//!   - `emitConvertWidth` — i32.wrap_i64 / i64.extend_i32_u /
//!     i64.extend_i32_s (MOV / MOVSXD).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// Wasm spec §4.4.1.1 (i32 add/sub/mul/and/or/xor) — pop two
/// i32, push their result. x86_64 lowering: `MOV dst, lhs ; OP
/// dst, rhs` (always-MOV form — the peephole that elides the MOV
/// when dst == lhs lands when regalloc starts reusing slots for
/// in-place updates).
///
/// **Constraint**: dst must not equal rhs (MOV dst, lhs would
/// clobber rhs before OP reads it). With fresh-vreg-per-op
/// allocation this never fires; surfaces as `UnsupportedOp`
/// when the regalloc port needs to handle slot reuse.
pub fn emitI32Binary(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
    if (dst_r == rhs_r and dst_r != lhs_r) return Error.UnsupportedOp;

    if (dst_r != lhs_r) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, dst_r, lhs_r).slice());
    }
    const enc = switch (op) {
        .@"i32.add" => inst.encAddRR(.d, dst_r, rhs_r),
        .@"i32.sub" => inst.encSubRR(.d, dst_r, rhs_r),
        .@"i32.mul" => inst.encImulRR(.d, dst_r, rhs_r),
        .@"i32.and" => inst.encAndRR(.d, dst_r, rhs_r),
        .@"i32.or"  => inst.encOrRR(.d, dst_r, rhs_r),
        .@"i32.xor" => inst.encXorRR(.d, dst_r, rhs_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.2 (i32 eq/ne/lt/gt/le/ge — signed/unsigned
/// variants) — pop two i32, push 0 or 1. x86_64 pattern:
///
///   CMP lhs, rhs           ; sets EFLAGS based on lhs - rhs
///   SETcc dst_low8         ; writes 0 / 1 to low byte of dst
///   MOVZX dst, dst_low8    ; zero-extend to 32 bits
///
/// Total ~10 bytes per compare (3 instr × 3-4 bytes each with
/// REX). Signed vs unsigned distinction is the cc code only —
/// operand encoding is identical.
pub fn emitI32Compare(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    const cc: inst.Cond = switch (op) {
        .@"i32.eq"   => .e,
        .@"i32.ne"   => .ne,
        .@"i32.lt_s" => .l,
        .@"i32.lt_u" => .b,
        .@"i32.gt_s" => .g,
        .@"i32.gt_u" => .a,
        .@"i32.le_s" => .le,
        .@"i32.le_u" => .be,
        .@"i32.ge_s" => .ge,
        .@"i32.ge_u" => .ae,
        else => unreachable,
    };

    try buf.appendSlice(allocator, inst.encCmpRR(.d, lhs_r, rhs_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(cc, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.2 (i32.eqz) — unary "is the operand zero?".
/// Emits TEST src, src ; SETE dst_low8 ; MOVZX dst, dst_low8.
/// Same 3-instr shape as compare; operand reuse means no
/// separate rhs vreg.
pub fn emitI32Eqz(
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
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    try buf.appendSlice(allocator, inst.encTestRR(.d, src_r, src_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.e, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.3 (i32 shl/shr_s/shr_u/rotl/rotr — 5 ops).
/// x86_64 SHL/SHR/SAR/ROL/ROR with variable count require the
/// count in CL (RCX low byte). Emit:
///
///   MOV ECX, rhs       ; (skip if rhs already in RCX — never
///                        the case since RCX is excluded from
///                        the regalloc pool per abi.zig)
///   MOV dst, lhs       ; (skip if dst == lhs)
///   <op> dst, CL       ; D3 / kind
///
/// Wasm shift count is implicit-modulo-(width); x86_64 SHL/SHR
/// also mask the count by (width - 1), so the semantics line up
/// without an extra AND.
///
/// Constraints (caller cannot violate without UnsupportedOp):
/// - dst != RCX: RCX is the count register; would self-clobber.
///   In practice this never fires because abi.allocatable_gprs
///   excludes RCX.
/// - dst != rhs (when dst != lhs): the MOV dst, lhs would clobber
///   rhs before the shift reads CL. Guard mirrors emitI32Binary.
pub fn emitI32Shift(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
    if (dst_r == .rcx) return Error.UnsupportedOp;
    if (dst_r == rhs_r and dst_r != lhs_r) return Error.UnsupportedOp;

    // 1. Move shift count into ECX (CL is the low byte).
    if (rhs_r != .rcx) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, .rcx, rhs_r).slice());
    }
    // 2. Materialise lhs into dst (skip if already same reg).
    if (dst_r != lhs_r) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, dst_r, lhs_r).slice());
    }
    // 3. Shift / rotate.
    const kind: inst.ShiftKind = switch (op) {
        .@"i32.shl"   => .shl,
        .@"i32.shr_s" => .sar,
        .@"i32.shr_u" => .shr,
        .@"i32.rotl"  => .rol,
        .@"i32.rotr"  => .ror,
        else => unreachable,
    };
    try buf.appendSlice(allocator, inst.encShiftRCl(.d, kind, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.4 (i32 clz/ctz/popcnt — 3 ops). Direct 1:1
/// mapping to LZCNT / TZCNT / POPCNT (BMI1 + POPCNT extensions).
/// All three:
/// - Take src in r/m and write dst in reg (operand-role
///   inversion vs the ADD/SUB/CMP family).
/// - Return 32 for input 0 (LZCNT/TZCNT) which matches Wasm
///   spec — the older BSR/BSF would leave dst undefined at 0
///   and would need a fixup; LZCNT/TZCNT exist exactly to
///   provide defined-at-zero semantics.
pub fn emitI32Bitcount(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    const enc = switch (op) {
        .@"i32.clz"    => inst.encLzcntR32(dst_r, src_r),
        .@"i32.ctz"    => inst.encTzcntR32(dst_r, src_r),
        .@"i32.popcnt" => inst.encPopcntR32(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.1 (i64 add / sub / mul / and / or / xor) —
/// 64-bit counterpart of `emitI32Binary`. Identical handler shape;
/// only the encoder Width changes from `.d` to `.q` (REX.W set
/// → 64-bit operands).
pub fn emitI64Binary(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
    if (dst_r == rhs_r and dst_r != lhs_r) return Error.UnsupportedOp;

    if (dst_r != lhs_r) {
        try buf.appendSlice(allocator, inst.encMovRR(.q, dst_r, lhs_r).slice());
    }
    const enc = switch (op) {
        .@"i64.add" => inst.encAddRR(.q, dst_r, rhs_r),
        .@"i64.sub" => inst.encSubRR(.q, dst_r, rhs_r),
        .@"i64.mul" => inst.encImulRR(.q, dst_r, rhs_r),
        .@"i64.and" => inst.encAndRR(.q, dst_r, rhs_r),
        .@"i64.or"  => inst.encOrRR(.q, dst_r, rhs_r),
        .@"i64.xor" => inst.encXorRR(.q, dst_r, rhs_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.2 (i64 eq / ne / lt_{s,u} / gt_{s,u} /
/// le_{s,u} / ge_{s,u}) — 64-bit comparison; result is i32 0/1.
/// CMP becomes 64-bit (.q) but SETcc + MOVZX stay 8/32-bit since
/// the result is i32.
pub fn emitI64Compare(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    const cc: inst.Cond = switch (op) {
        .@"i64.eq"   => .e,
        .@"i64.ne"   => .ne,
        .@"i64.lt_s" => .l,
        .@"i64.lt_u" => .b,
        .@"i64.gt_s" => .g,
        .@"i64.gt_u" => .a,
        .@"i64.le_s" => .le,
        .@"i64.le_u" => .be,
        .@"i64.ge_s" => .ge,
        .@"i64.ge_u" => .ae,
        else => unreachable,
    };

    try buf.appendSlice(allocator, inst.encCmpRR(.q, lhs_r, rhs_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(cc, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.2 (i64.eqz) — TEST is 64-bit (.q); SETcc +
/// MOVZX stay 8/32-bit (i32 result).
pub fn emitI64Eqz(
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
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    try buf.appendSlice(allocator, inst.encTestRR(.q, src_r, src_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.e, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.3 (i64 shl / shr_s / shr_u / rotl / rotr) —
/// 64-bit shift family. CL is the count register (shared with
/// i32 shifts; abi.zig already excludes RCX from the regalloc
/// pool). The MOV ECX, rhs is 32-bit since only CL is read.
pub fn emitI64Shift(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
    if (dst_r == .rcx) return Error.UnsupportedOp;
    if (dst_r == rhs_r and dst_r != lhs_r) return Error.UnsupportedOp;

    if (rhs_r != .rcx) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, .rcx, rhs_r).slice());
    }
    if (dst_r != lhs_r) {
        try buf.appendSlice(allocator, inst.encMovRR(.q, dst_r, lhs_r).slice());
    }
    const kind: inst.ShiftKind = switch (op) {
        .@"i64.shl"   => .shl,
        .@"i64.shr_s" => .sar,
        .@"i64.shr_u" => .shr,
        .@"i64.rotl"  => .rol,
        .@"i64.rotr"  => .ror,
        else => unreachable,
    };
    try buf.appendSlice(allocator, inst.encShiftRCl(.q, kind, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.4 (i64 clz / ctz / popcnt) — direct mapping
/// to LZCNT64 / TZCNT64 / POPCNT64 (REX.W variants). Defined-at-
/// zero semantics match Wasm (returns 64 for input 0).
pub fn emitI64Bitcount(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    const enc = switch (op) {
        .@"i64.clz"    => inst.encLzcntR64(dst_r, src_r),
        .@"i64.ctz"    => inst.encTzcntR64(dst_r, src_r),
        .@"i64.popcnt" => inst.encPopcntR64(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());

    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.1.4 (i32.wrap_i64 / i64.extend_i32_u /
/// i64.extend_i32_s) — i32 ↔ i64 width-cross. `i32.wrap_i64`
/// and `i64.extend_i32_u` both lower to `MOV r32_dst, r32_src`
/// (the 32-bit write zero-extends the upper half of the
/// destination's 64-bit slot, matching Wasm's value-class
/// representation). `i64.extend_i32_s` lowers to MOVSXD.
/// Mirrors arm64/op_convert.zig's emitWrap32 / emitExtendI32S.
pub fn emitConvertWidth(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    const enc = switch (op) {
        .@"i32.wrap_i64", .@"i64.extend_i32_u" => inst.encMovRR(.d, dst_r, src_r),
        .@"i64.extend_i32_s" => inst.encMovsxdR64R32(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());

    try pushed_vregs.append(allocator, result_v);
}
