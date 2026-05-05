//! ARM64 emit pass — GPR / FPR resolution + spill staging
//! helpers shared across every op-handler module.
//!
//! Per ADR-0023 §3 + ADR-0021 sub-deliverable b (§9.7 / 7.5d
//! sub-b emit.zig 9-module split): extracted from emit.zig so
//! op_const / op_alu / op_memory / etc. can reach for these
//! helpers without circular imports back to emit.zig. The
//! helpers themselves are unchanged from their pre-split shape.
//!
//! - `writeU32` — append a little-endian u32 word to the buffer.
//! - `resolveGpr` — vreg → physical Xn (declines spilled vregs).
//! - `gprLoadSpilled` — spill-aware operand load via stage reg.
//! - `gprDefSpilled` — spill-aware result def via stage reg.
//! - `gprStoreSpilled` — pair of `gprDefSpilled`; flushes stage
//!   reg to spill slot.
//! - `resolveFp` — V-class counterpart of `resolveGpr`.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const inst = @import("inst.zig");
const abi = @import("abi.zig");
const regalloc = @import("../shared/regalloc.zig");
const ctx_mod = @import("ctx.zig");

const Allocator = std.mem.Allocator;
const Error = ctx_mod.Error;

/// Append `word` as a little-endian 4-byte sequence to `buf`.
pub fn writeU32(allocator: Allocator, buf: *std.ArrayList(u8), word: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    try buf.appendSlice(allocator, &bytes);
}

/// Resolve a vreg's home register (GPR class). Returns the
/// allocated reg or `Error.UnsupportedOp` for spilled vregs
/// (handlers that haven't been migrated to spill-aware emission).
pub fn resolveGpr(alloc: regalloc.Allocation, vreg: usize) Error!inst.Xn {
    return switch (alloc.slot(vreg)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => Error.UnsupportedOp,
    };
}

/// Resolve a vreg's home for **op operand load**. If the vreg
/// is in a register, returns that reg directly. If spilled,
/// emits `LDR X_stage, [SP, #(spill_base_off + spill_off)]`
/// staging through `abi.spill_stage_gprs[stage_idx]` and
/// returns the stage reg.
///
/// `stage_idx` selects which stage reg (0=X14, 1=X15). Use 0
/// for the first/only operand, 1 for the second operand of a
/// binary op (so two spilled operands don't collide).
pub fn gprLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Xn {
    return switch (alloc.slot(vreg)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => |off| blk: {
            const stage = abi.spill_stage_gprs[stage_idx];
            const abs_off = spill_base_off + off;
            // X-form imm12 scales by 8; max byte offset is 8*4095 = 32760.
            if (abs_off > 32760 or (abs_off & 7) != 0) return Error.SlotOverflow;
            try writeU32(allocator, buf, inst.encLdrImm(stage, 31, @intCast(abs_off)));
            break :blk stage;
        },
    };
}

/// Resolve a vreg's home for **op result def**. If the vreg
/// is in a register, returns that reg directly. If spilled,
/// returns the stage reg (caller encodes the op writing into
/// it; then calls `gprStoreSpilled` to flush to the spill
/// slot).
pub fn gprDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Xn {
    return switch (alloc.slot(vreg)) {
        .reg => |id| abi.slotToReg(id) orelse Error.SlotOverflow,
        .spill => abi.spill_stage_gprs[stage_idx],
    };
}

/// Pair of `gprDefSpilled`. After encoding the op (which wrote
/// the result into the stage reg), emits `STR X_stage, [SP,
/// #(spill_base_off + spill_off)]`. No-op for vregs in
/// registers (the result is already in its home).
pub fn gprStoreSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!void {
    switch (alloc.slot(vreg)) {
        .reg => {},
        .spill => |off| {
            const stage = abi.spill_stage_gprs[stage_idx];
            const abs_off = spill_base_off + off;
            if (abs_off > 32760 or (abs_off & 7) != 0) return Error.SlotOverflow;
            try writeU32(allocator, buf, inst.encStrImm(stage, 31, @intCast(abs_off)));
        },
    }
}

/// FP-class counterpart of `resolveGpr`. Same spill-staging
/// follow-up applies via V-class scratch when spill-aware
/// FP handlers land.
pub fn resolveFp(alloc: regalloc.Allocation, vreg: usize) Error!inst.Vn {
    return switch (alloc.slot(vreg)) {
        .reg => |id| abi.fpSlotToReg(id) orelse Error.SlotOverflow,
        .spill => Error.UnsupportedOp,
    };
}
