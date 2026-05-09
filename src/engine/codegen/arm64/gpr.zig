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
//! - `fpLoadSpilled` / `fpDefSpilled` / `fpStoreSpilled` — V-class
//!   spill-staging trio (D-037 — mirrors the GPR three; uses
//!   `abi.fp_spill_stage_vregs` (V29/V30) and the D-form (8-byte)
//!   spill encoders for class-uniform 8-byte spill stride).
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
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
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse blk: {
            // §9.7 / 7.9-d-12 diag: slot id beyond pool. Surfaces
            // when `max_reg_slots_gpr` exceeds `slotToReg.len`
            // (config drift) or when class disagreement assigns a
            // GPR-bound id that's too high for the GPR pool.
            std.debug.print("arm64/gpr: SlotOverflow resolveGpr vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => blk: {
            // §9.7 / 7.5-diag-spill: surface which vreg / spill
            // slot triggered the reject so the next chunk can
            // narrow scope (spill-aware handler vs pool extension).
            std.debug.print(
                "arm64/gpr: resolveGpr rejected spilled vreg={d} (handler not spill-aware)\n",
                .{vreg},
            );
            break :blk Error.UnsupportedOp;
        },
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
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse blk: {
            std.debug.print("arm64/gpr: SlotOverflow gprLoadSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => |off| blk: {
            const stage = abi.spill_stage_gprs[stage_idx];
            const abs_off = spill_base_off + off;
            // X-form imm12 scales by 8; max byte offset is 8*4095 = 32760.
            if (abs_off > 32760 or (abs_off & 7) != 0) {
                std.debug.print("arm64/gpr: SlotOverflow gprLoadSpilled.spill vreg={d} abs_off={d} (base={d}+off={d})\n", .{ vreg, abs_off, spill_base_off, off });
                return Error.SlotOverflow;
            }
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
    return switch (alloc.slot(vreg, .gpr)) {
        .reg => |id| abi.slotToReg(id) orelse blk: {
            std.debug.print("arm64/gpr: SlotOverflow gprDefSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
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
    switch (alloc.slot(vreg, .gpr)) {
        .reg => {},
        .spill => |off| {
            const stage = abi.spill_stage_gprs[stage_idx];
            const abs_off = spill_base_off + off;
            if (abs_off > 32760 or (abs_off & 7) != 0) {
                std.debug.print("arm64/gpr: SlotOverflow gprStoreSpilled.spill vreg={d} abs_off={d} (base={d}+off={d})\n", .{ vreg, abs_off, spill_base_off, off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst.encStrImm(stage, 31, @intCast(abs_off)));
        },
    }
}

/// FP-class counterpart of `resolveGpr`. Consults the class-aware
/// `Allocation.slot(vreg, .fpr)` API (D-036): the FP boundary
/// `max_reg_slots_fp` (default 13 post-D-037, matching
/// `abi.allocatable_v_regs.len`) decides reg-vs-spill, distinct
/// from the GPR boundary. Slot ids 0..12 resolve to V16..V28 via
/// `fpSlotToReg`; ids ≥ 13 surface as `.spill` and reject here
/// (handlers that have not yet been migrated to FP-spill-aware
/// emission via `fpLoadSpilled` / `fpDefSpilled` /
/// `fpStoreSpilled`). The chunk-q `alloc.slots[]` band-aid
/// remains eliminated.
pub fn resolveFp(alloc: regalloc.Allocation, vreg: usize) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            std.debug.print("arm64/gpr: SlotOverflow resolveFp vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => |off| blk: {
            std.debug.print(
                "arm64/gpr: resolveFp rejected spilled vreg={d} spill_off={d} (handler not FP-spill-aware)\n",
                .{ vreg, off },
            );
            break :blk Error.UnsupportedOp;
        },
    };
}

/// V-class counterpart of `gprLoadSpilled`. If the FP vreg is in
/// a V-register, returns that reg directly. If spilled, emits
/// `LDR D_stage, [SP, #(spill_base_off + spill_off)]` staging
/// through `abi.fp_spill_stage_vregs[stage_idx]` (V29/V30) and
/// returns the stage reg.
///
/// `stage_idx` selects which stage reg (0=V29, 1=V30). Use 0 for
/// the first/only operand, 1 for the second operand of a binary
/// FP op. The D-form (8-byte) is used uniformly so the spill
/// frame stride matches GPR (8-byte) — a spilled f32 vreg writes
/// 64 bits with the upper 32 bits unspecified, but the load reads
/// the same 64 bits and FP ops on S-form ignore the upper 32, so
/// observable behaviour matches the spec.
pub fn fpLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            std.debug.print("arm64/gpr: SlotOverflow fpLoadSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => |off| blk: {
            const stage = abi.fp_spill_stage_vregs[stage_idx];
            const abs_off = spill_base_off + off;
            // D-form imm12 scales by 8; max byte offset is 8*4095 = 32760.
            if (abs_off > 32760 or (abs_off & 7) != 0) {
                std.debug.print("arm64/gpr: SlotOverflow fpLoadSpilled.spill vreg={d} abs_off={d} (base={d}+off={d})\n", .{ vreg, abs_off, spill_base_off, off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst.encLdrDImm(stage, 31, @intCast(abs_off)));
            break :blk stage;
        },
    };
}

/// V-class counterpart of `gprDefSpilled`. If the FP vreg is in a
/// V-register, returns that reg directly. If spilled, returns the
/// stage reg (caller encodes the op writing into it; then calls
/// `fpStoreSpilled` to flush to the spill slot).
pub fn fpDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            std.debug.print("arm64/gpr: SlotOverflow fpDefSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => abi.fp_spill_stage_vregs[stage_idx],
    };
}

/// Pair of `fpDefSpilled`. After encoding the op (which wrote the
/// result into the stage V-reg), emits `STR D_stage, [SP,
/// #(spill_base_off + spill_off)]`. No-op for vregs in V-registers
/// (the result is already in its home).
pub fn fpStoreSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!void {
    switch (alloc.slot(vreg, .fpr)) {
        .reg => {},
        .spill => |off| {
            const stage = abi.fp_spill_stage_vregs[stage_idx];
            const abs_off = spill_base_off + off;
            if (abs_off > 32760 or (abs_off & 7) != 0) {
                std.debug.print("arm64/gpr: SlotOverflow fpStoreSpilled.spill vreg={d} abs_off={d} (base={d}+off={d})\n", .{ vreg, abs_off, spill_base_off, off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst.encStrDImm(stage, 31, @intCast(abs_off)));
        },
    }
}

/// V-class counterpart of `fpLoadSpilled` for v128 (Q-form, 16-byte
/// stride per ADR-0041 §"Decision" / 2). Used by SIMD op-handlers
/// (`op_simd.zig`) when the popped vreg is a spilled v128. If the
/// vreg is in a V-register, returns that reg directly; if spilled,
/// emits `LDR Q<stage>, [SP, #(spill_base_off + spill_off)]` staging
/// through `abi.fp_spill_stage_vregs[stage_idx]` (V29/V30) — the
/// 128-bit Q-form view of the same V regs the D-form fp helpers
/// use.
///
/// The 16-byte alignment requirement is enforced: `byte_offset` must
/// be a multiple of 16 and ≤ 65520 (= 4095 × 16, max imm12-encoded
/// offset for the Q-form). The spill_base_off + spill_off
/// combination must therefore be 16-byte aligned at the call site —
/// the caller (op_simd) is responsible for laying out v128 spill
/// slots at 16-byte strides per ADR-0041 §"Negative" /
/// "Conservative spill-frame size".
pub fn qLoadSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            std.debug.print("arm64/gpr: SlotOverflow qLoadSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => |off| blk: {
            const stage = abi.fp_spill_stage_vregs[stage_idx];
            const abs_off = spill_base_off + off;
            // Q-form imm12 scales by 16; max byte offset is 16*4095 = 65520.
            if (abs_off > 65520 or (abs_off & 0xF) != 0) {
                std.debug.print("arm64/gpr: SlotOverflow qLoadSpilled.spill vreg={d} abs_off={d} (must be 16-byte aligned & ≤ 65520)\n", .{ vreg, abs_off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst_neon.encLdrQImm(stage, 31, @intCast(abs_off)));
            break :blk stage;
        },
    };
}

/// V-class counterpart of `fpDefSpilled` for v128 (Q-form). If the
/// vreg is in a V-register, returns that reg directly; if spilled,
/// returns the stage reg (caller encodes the op writing into it,
/// then calls `qStoreSpilled` to flush).
pub fn qDefSpilled(
    alloc: regalloc.Allocation,
    vreg: usize,
    stage_idx: u8,
) Error!inst.Vn {
    return switch (alloc.slot(vreg, .fpr)) {
        .reg => |id| abi.fpSlotToReg(id) orelse blk: {
            std.debug.print("arm64/gpr: SlotOverflow qDefSpilled.reg vreg={d} slot_id={d}\n", .{ vreg, id });
            break :blk Error.SlotOverflow;
        },
        .spill => abi.fp_spill_stage_vregs[stage_idx],
    };
}

/// Pair of `qDefSpilled`. After encoding the op (which wrote into
/// the stage V-reg), emits `STR Q<stage>, [SP, #(spill_base_off +
/// spill_off)]`. No-op for vregs already in V-registers.
pub fn qStoreSpilled(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    vreg: usize,
    stage_idx: u8,
) Error!void {
    switch (alloc.slot(vreg, .fpr)) {
        .reg => {},
        .spill => |off| {
            const stage = abi.fp_spill_stage_vregs[stage_idx];
            const abs_off = spill_base_off + off;
            if (abs_off > 65520 or (abs_off & 0xF) != 0) {
                std.debug.print("arm64/gpr: SlotOverflow qStoreSpilled vreg={d} abs_off={d}\n", .{ vreg, abs_off });
                return Error.SlotOverflow;
            }
            try writeU32(allocator, buf, inst_neon.encStrQImm(stage, 31, @intCast(abs_off)));
        },
    }
}

// ============================================================
// Tests — D-037 FP-spill helpers (chunk-d037-a)
// ============================================================

const testing = std.testing;

test "fpLoadSpilled: vreg in V-reg returns it directly without emitting bytes" {
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const v = try fpLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(inst.Vn, 16), v); // V16 = first allocatable
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "fpLoadSpilled: spilled vreg emits LDR D and returns stage reg V29 (stage_idx=0)" {
    const slots = [_]u16{13}; // just past the new max_reg_slots_fp boundary
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // spill_off = (13-8)*8 = 40; abs_off = spill_base_off (16) + 40 = 56
    const v = try fpLoadSpilled(testing.allocator, &buf, alloc, 16, 0, 0);
    try testing.expectEqual(@as(inst.Vn, 29), v);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encLdrDImm(29, 31, 56), word);
}

test "fpLoadSpilled: stage_idx=1 yields V30" {
    const slots = [_]u16{13};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const v = try fpLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 1);
    try testing.expectEqual(@as(inst.Vn, 30), v);
}

test "fpStoreSpilled: spilled vreg emits STR D from stage reg" {
    const slots = [_]u16{14};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 15 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // spill_off = (14-8)*8 = 48; abs_off = 0 + 48 = 48
    try fpStoreSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encStrDImm(29, 31, 48), word);
}

test "fpStoreSpilled: in-V-reg vreg emits no bytes (no-op)" {
    const slots = [_]u16{5};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 6 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try fpStoreSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "fpDefSpilled: in-V-reg vreg returns the V-reg; spilled returns stage" {
    const slots = [_]u16{ 3, 13 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    try testing.expectEqual(@as(inst.Vn, 19), try fpDefSpilled(alloc, 0, 0)); // V16+3
    try testing.expectEqual(@as(inst.Vn, 29), try fpDefSpilled(alloc, 1, 0));
    try testing.expectEqual(@as(inst.Vn, 30), try fpDefSpilled(alloc, 1, 1));
}

// ============================================================
// §9.9 / 9.5-c — Q-form (v128, 16-byte) spill helpers tests
// ============================================================

test "qLoadSpilled: vreg in V-reg returns it directly without emitting bytes" {
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const v = try qLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(inst.Vn, 16), v); // V16 (FP slot 0)
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "qLoadSpilled: spilled vreg emits LDR Q stage from SP-relative offset" {
    // Allocation.slot's 8-byte spill formula: spill_off =
    // (slot_id - max_reg_slots_gpr) * 8. For 16-byte alignment, the
    // caller must lay v128 spill slots at even-pair indices. Slot 14:
    // spill_off = (14 - 8) * 8 = 48 (16-byte aligned). spill_base_off=0
    // → abs_off = 48 ✓.
    const slots = [_]u16{14};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 15 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const v = try qLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(inst.Vn, 29), v); // stage V29
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    // LDR Q29, [SP=31, #48] = encLdrQImm(29, 31, 48)
    try testing.expectEqual(inst_neon.encLdrQImm(29, 31, 48), word);
}

test "qLoadSpilled: rejects unaligned offset" {
    // Slot 13: spill_off = (13 - 8) * 8 = 40 (NOT 16-byte aligned).
    const slots = [_]u16{13};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectError(Error.SlotOverflow, qLoadSpilled(testing.allocator, &buf, alloc, 0, 0, 0));
}

test "qDefSpilled: in-V-reg vreg returns the V-reg; spilled returns stage" {
    const slots = [_]u16{ 5, 13 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 14 };
    try testing.expectEqual(@as(inst.Vn, 21), try qDefSpilled(alloc, 0, 0)); // V16+5
    try testing.expectEqual(@as(inst.Vn, 29), try qDefSpilled(alloc, 1, 0));
    try testing.expectEqual(@as(inst.Vn, 30), try qDefSpilled(alloc, 1, 1));
}

test "qStoreSpilled: in-V-reg vreg is no-op (no bytes emitted)" {
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try qStoreSpilled(testing.allocator, &buf, alloc, 0, 0, 0);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "qStoreSpilled: spilled vreg emits STR Q stage to SP-relative offset" {
    // Slot 14 → spill_off = 48 (16-byte aligned). spill_base_off=16
    // → abs_off = 64 ✓.
    const slots = [_]u16{14};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 15 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try qStoreSpilled(testing.allocator, &buf, alloc, 16, 0, 0);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst_neon.encStrQImm(29, 31, 64), word);
}
