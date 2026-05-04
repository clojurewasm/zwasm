//! ZIR → ARM64 emit pass (§9.7 / 7.3 — skeleton).
//!
//! Walks a `ZirFunc.instrs` stream (consumed in def_pc order)
//! and emits a fixed-width AArch64 instruction stream into a
//! caller-supplied byte buffer. Slot ids from the §9.7 / 7.1
//! regalloc map to physical X-registers via §9.7 / 7.2's
//! `abi.slotToReg`.
//!
//! Phase 7.3 skeleton scope (this commit):
//! - Function prologue: save FP/LR, set up frame pointer.
//! - Function epilogue: restore FP/LR, RET.
//! - `i32.const` → `MOVZ Xd, #imm16` (lower 16 bits) +
//!   optional `MOVK` lanes for the upper 16 bits. Emits to a
//!   single result register dictated by the function's return
//!   slot.
//! - `end` of function → epilogue.
//!
//! Other op handlers land in subsequent §9.7 / 7.3 commits
//! per the row's "produce function bodies" exit; the §9.7 / 7.4
//! spec-pass gate is what closes the full op-coverage loop.
//!
//! AAPCS64 prologue / epilogue shape (per Arm IHI 0055 §6.4):
//!
//!   prologue:
//!     STP FP, LR, [SP, #-16]!     // push FP/LR pair
//!     MOV FP, SP                   // set frame pointer
//!     [optional: SUB SP, SP, #N for locals]
//!
//!   epilogue:
//!     [optional: ADD SP, SP, #N]
//!     LDP FP, LR, [SP], #16        // pop FP/LR pair
//!     RET
//!
//! For 7.3 skeleton we omit the optional stack-frame
//! adjustment (no spilled vregs in straight-line MVP code with
//! ≤17 GPRs available; spills are §9.7 / 7.3 follow-up).
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3.

const std = @import("std");

const zir = @import("../ir/zir.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const regalloc = @import("../jit/regalloc.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const Xn = inst.Xn;

pub const Error = error{
    AllocationMissing,
    UnsupportedOp,
    SlotOverflow,
    OutOfMemory,
};

pub const EmitOutput = struct {
    /// Encoded function body bytes (little-endian u32 stream).
    /// Caller owns; pair with `deinit` to free.
    bytes: []u8,
    /// Distinct GPR slots used (mirrors `Allocation.n_slots`).
    /// The §9.7 / 7.4 gate consults this for stack-frame sizing
    /// when the spill follow-up lands.
    n_slots: u8,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
}

/// Emit ARM64 machine code for `func`. Requires `alloc.slots`
/// to be populated (call `regalloc.compute` first; pass the
/// `Allocation` here).
pub fn compile(
    allocator: Allocator,
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
) Error!EmitOutput {
    if (alloc.slots.len != (func.liveness orelse return Error.AllocationMissing).ranges.len) {
        return Error.AllocationMissing;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // ============================================================
    // Prologue: STP FP, LR, [SP, #-16]! ; MOV FP, SP
    // ============================================================
    try writeU32(allocator, &buf, encStpFpLrPreIdx());
    try writeU32(allocator, &buf, encMovSpToFp());

    // ============================================================
    // Body: walk instrs, dispatch per op.
    //
    // For Phase 7.3 skeleton: track a "result vreg" cursor that
    // records which vreg holds the latest pushed value. The
    // function's `end` reads that vreg, ensures it ends up in X0
    // (the AAPCS64 return register), and then runs the epilogue.
    // ============================================================
    var pushed_vregs: std.ArrayList(u32) = .empty;
    defer pushed_vregs.deinit(allocator);
    var next_vreg: u32 = 0;

    for (func.instrs.items, 0..) |ins, pc| {
        _ = pc;
        switch (ins.op) {
            .@"i32.const" => {
                // The const's destination vreg is the next-to-be-pushed
                // vreg id. Slot it and emit MOVZ + optional MOVK lanes.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
                try emitConstU32(allocator, &buf, xd, ins.payload);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i32.add",
            .@"i32.sub",
            .@"i32.mul",
            .@"i32.and",
            .@"i32.or",
            .@"i32.xor",
            => {
                // Binary ALU: pop rhs, lhs; allocate next_vreg as
                // result; emit `<op> Xd, Xn(lhs), Xm(rhs)`.
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const xm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const word: u32 = switch (ins.op) {
                    .@"i32.add" => inst.encAddReg(xd, xn, xm),
                    .@"i32.sub" => inst.encSubReg(xd, xn, xm),
                    .@"i32.mul" => inst.encMulReg(xd, xn, xm),
                    .@"i32.and" => inst.encAndReg(xd, xn, xm),
                    .@"i32.or"  => inst.encOrrReg(xd, xn, xm),
                    .@"i32.xor" => inst.encEorReg(xd, xn, xm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"end" => {
                // Function-level end: marshal the top-of-stack vreg
                // into X0 (the AAPCS64 result register), then run
                // the epilogue. Only fires once per function in the
                // 7.3 skeleton (multi-end via blocks lands later).
                if (pushed_vregs.items.len > 0) {
                    const top_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
                    const src_xn = abi.slotToReg(alloc.slots[top_vreg]) orelse return Error.SlotOverflow;
                    if (src_xn != 0) {
                        // MOV X0, Xsrc — encoded as ORR X0, XZR, Xsrc.
                        try writeU32(allocator, &buf, encOrrZrIntoX0(src_xn));
                    }
                }
                try writeU32(allocator, &buf, encLdpFpLrPostIdx());
                try writeU32(allocator, &buf, inst.encRet(abi.link_register));
                break;
            },
            else => return Error.UnsupportedOp,
        }
    }

    return .{
        .bytes = try buf.toOwnedSlice(allocator),
        .n_slots = alloc.n_slots,
    };
}

fn writeU32(allocator: Allocator, buf: *std.ArrayList(u8), word: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    try buf.appendSlice(allocator, &bytes);
}

/// Emit a 32-bit constant into Xd via MOVZ + MOVK pairs.
/// Strategy: MOVZ Xd, #(lo16); if hi16 != 0, MOVK Xd, #hi16, lsl #16.
/// (For a full 64-bit constant — Phase 9+ — extend to 4 lanes.)
fn emitConstU32(allocator: Allocator, buf: *std.ArrayList(u8), xd: Xn, value: u32) !void {
    const lo16: u16 = @truncate(value & 0xFFFF);
    const hi16: u16 = @truncate(value >> 16);
    try writeU32(allocator, buf, inst.encMovzImm16(xd, lo16));
    if (hi16 != 0) {
        try writeU32(allocator, buf, inst.encMovkImm16(xd, hi16, 1));
    }
}

// ============================================================
// AAPCS64 prologue / epilogue micro-encodings
//
// These are the four fixed encodings every leaf function body
// uses. Inlined here rather than added to inst.zig because
// they're convention-shaped (always the same operands) — adding
// a dedicated enc* in inst.zig would invite false flexibility.
// ============================================================

/// `STP X29, X30, [SP, #-16]!` — pre-index push of FP/LR pair.
/// Encoding (STP 64-bit pre-indexed):
///   `1010 1001 10 [imm7:7] [Rt2:5] [Rn:5] [Rt:5]`
/// imm7 = -16/8 = -2 (signed) = 7'b1111110 = 0x7E.
/// Rn = 31 (SP), Rt = 29 (FP), Rt2 = 30 (LR).
fn encStpFpLrPreIdx() u32 {
    // 0xA9BF7BFD = STP X29, X30, [SP, #-16]!
    return 0xA9BF7BFD;
}

/// `LDP X29, X30, [SP], #16` — post-index pop of FP/LR pair.
/// Encoding (LDP 64-bit post-indexed):
///   `1010 1000 11 [imm7:7] [Rt2:5] [Rn:5] [Rt:5]`
/// imm7 = +16/8 = 2.
fn encLdpFpLrPostIdx() u32 {
    // 0xA8C17BFD = LDP X29, X30, [SP], #16
    return 0xA8C17BFD;
}

/// `MOV X29, SP` — encoded as `ADD X29, SP, #0` (the canonical
/// MOV between SP-form and a register).
/// Encoding (ADD 64-bit imm, sh=0): `1 00 10001 00 0 0000 0000 0000 [Rn:5] [Rd:5]`
/// Rn = 31 (SP), Rd = 29 (FP).
fn encMovSpToFp() u32 {
    // 0x910003FD = mov x29, sp
    return 0x910003FD;
}

/// `MOV X0, Xsrc` — encoded as `ORR X0, XZR, Xsrc` (the
/// canonical 64-bit register-to-register MOV).
/// Encoding: `1 01 01010 00 0 [Rm:5] 000000 11111 [Rd:5]`
/// = 0xAA0003E0 | (Rm << 16).
fn encOrrZrIntoX0(rm: Xn) u32 {
    return 0xAA0003E0 | (@as(u32, rm) << 16);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const liveness_mod = @import("../ir/liveness.zig");

test "compile: empty body without liveness errors" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty_alloc));
}

test "compile: empty function (no instrs, empty liveness) emits prologue+epilogue" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    // No `end` op in the stream → emit walks zero instrs and
    // returns just the prologue (no epilogue). That's the expected
    // shape for a malformed body; the §9.7 / 7.4 gate filters such
    // funcs at validate-time, so emit doesn't enforce well-formedness.
    const out = try compile(testing.allocator, &f, empty_alloc);
    defer deinit(testing.allocator, out);
    // 2 prologue u32s = 8 bytes.
    try testing.expectEqual(@as(usize, 8), out.bytes.len);
    try testing.expectEqual(@as(u32, 0xA9BF7BFD), std.mem.readInt(u32, out.bytes[0..4], .little));
    try testing.expectEqual(@as(u32, 0x910003FD), std.mem.readInt(u32, out.bytes[4..8], .little));
}

test "compile: (i32.const 42) end yields 5-instr body returning 42 in X0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);

    // Expected stream: STP / MOV-FP-SP / MOVZ-X9-#42 / MOV-X0-X9 / LDP / RET
    // = 6 u32 words = 24 bytes.
    try testing.expectEqual(@as(usize, 24), out.bytes.len);

    // Word 0: STP prologue.
    try testing.expectEqual(@as(u32, 0xA9BF7BFD), std.mem.readInt(u32, out.bytes[0..4], .little));
    // Word 1: MOV X29, SP.
    try testing.expectEqual(@as(u32, 0x910003FD), std.mem.readInt(u32, out.bytes[4..8], .little));
    // Word 2: MOVZ X9, #42 — slot 0 → X9 per abi.slotToReg.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[8..12], .little));
    // Word 3: MOV X0, X9 (ORR X0, XZR, X9).
    try testing.expectEqual(@as(u32, 0xAA0903E0), std.mem.readInt(u32, out.bytes[12..16], .little));
    // Word 4: LDP epilogue.
    try testing.expectEqual(@as(u32, 0xA8C17BFD), std.mem.readInt(u32, out.bytes[16..20], .little));
    // Word 5: RET.
    try testing.expectEqual(@as(u32, 0xD65F03C0), std.mem.readInt(u32, out.bytes[20..24], .little));
}

test "compile: i32.const 0x12345678 emits MOVZ + MOVK (full 32-bit)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x12345678 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);

    // 7 u32s now: STP / MOV-FP-SP / MOVZ / MOVK / MOV-X0 / LDP / RET.
    try testing.expectEqual(@as(usize, 28), out.bytes.len);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0x5678)), std.mem.readInt(u32, out.bytes[8..12], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x1234, 1)), std.mem.readInt(u32, out.bytes[12..16], .little));
}

test "compile: unsupported op surfaces UnsupportedOp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.popcnt" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty));
}

test "compile: (i32.const 7) (i32.const 5) i32.add end → returns 12 in X0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    // 3 vregs: vreg0 = const 7, vreg1 = const 5, vreg2 = add result.
    // vreg0 dies at pc=2 (consumed by add); vreg1 dies at pc=2;
    // vreg2 dies at pc=3 (end).
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Greedy regalloc would assign slot 0 to vreg0, slot 1 to
    // vreg1 (overlap), slot 0 again to vreg2 (vreg0 + vreg1 die
    // at the add's pc=2, so slot 0 frees AT use). Hand-supplied
    // allocation matches what greedy produces.
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);

    // Stream: STP / MOV-FP / MOVZ X9 #7 / MOVZ X10 #5 / ADD X9 X9 X10 /
    //         MOV X0 X9 / LDP / RET = 8 u32s = 32 bytes.
    try testing.expectEqual(@as(usize, 32), out.bytes.len);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 7)),  std.mem.readInt(u32, out.bytes[8..12], .little));
    try testing.expectEqual(@as(u32, inst.encMovzImm16(10, 5)), std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encAddReg(9, 9, 10)), std.mem.readInt(u32, out.bytes[16..20], .little));
}

test "compile: i32.sub / i32.mul / i32.and / i32.or / i32.xor each emit correct ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i32.sub", .want_word_at_offset = inst.encSubReg(9, 9, 10) },
        .{ .op = .@"i32.mul", .want_word_at_offset = inst.encMulReg(9, 9, 10) },
        .{ .op = .@"i32.and", .want_word_at_offset = inst.encAndReg(9, 9, 10) },
        .{ .op = .@"i32.or",  .want_word_at_offset = inst.encOrrReg(9, 9, 10) },
        .{ .op = .@"i32.xor", .want_word_at_offset = inst.encEorReg(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        // ALU op lives at u32 offset 4 (= byte 16).
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[16..20], .little));
    }
}

test "compile: stack underflow on ALU op with 1 pushed vreg surfaces AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc));
}

comptime {
    _ = liveness_mod; // hook upstream module so future regalloc tests are reachable
}
