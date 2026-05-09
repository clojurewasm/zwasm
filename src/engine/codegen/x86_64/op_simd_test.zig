//! Byte-level tests for x86_64 SIMD-128 op handlers. Extracted
//! from `op_simd.zig` for ROADMAP §A2 hard-cap discipline (the
//! source file crossed 2000 LOC at §9.7-l). The split mirrors
//! the `emit_test*.zig` pattern from D-030 / D-051: source on
//! one side, byte-level expected-encoding tests on the other.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");
const testing = std.testing;

const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");
const op_simd = @import("op_simd.zig");

const Error = types.Error;


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

    try op_simd.emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg);

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

    try op_simd.emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg);

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

    try op_simd.emitI8x16Sub(testing.allocator, &buf, alloc, &pushed, &next_vreg);

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

test "emitI32x4GtS: direct PCMPGT (no NOT, no swap) — MOVAPS + PCMPGTD" {
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

    try op_simd.emitI32x4GtS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtD(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8LtS: operand-swap path — MOVAPS dst, rhs + PCMPGTW dst, lhs" {
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
    try pushed.append(testing.allocator, 0); // lhs
    try pushed.append(testing.allocator, 1); // rhs
    var next_vreg: u32 = 2;

    try op_simd.emitI16x8LtS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // Swap: base=rhs (XMM9 → MOVAPS into dst XMM10), cmp=lhs (XMM8).
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtW(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16LeS: gt + NOT (PCMPEQB scratch + PXOR)" {
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

    try op_simd.emitI8x16LeS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtB(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4GeS: lt + NOT (operand swap then NOT)" {
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

    try op_simd.emitI32x4GeS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    // ge: swap(rhs, lhs) → MOVAPS dst, rhs (XMM9) + PCMPGTD dst, lhs (XMM8) + NOT.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtD(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2GtS: direct PCMPGTQ (SSE4.2) — MOVAPS + PCMPGTQ" {
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

    try op_simd.emitI64x2GtS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtQ(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2LtS: operand-swap path — MOVAPS dst, rhs + PCMPGTQ dst, lhs" {
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
    try pushed.append(testing.allocator, 0); // lhs
    try pushed.append(testing.allocator, 1); // rhs
    var next_vreg: u32 = 2;

    try op_simd.emitI64x2LtS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // lt: swap → base=rhs (XMM9 → MOVAPS into dst XMM10), cmp=lhs (XMM8).
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtQ(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2LeS: gt + NOT (PCMPGTQ + PCMPEQB ones + PXOR)" {
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

    try op_simd.emitI64x2LeS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtQ(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2GeS: lt + NOT (operand swap then NOT)" {
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

    try op_simd.emitI64x2GeS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    // ge: swap(rhs, lhs) → MOVAPS dst, rhs (XMM9) + PCMPGTQ dst, lhs (XMM8) + NOT.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpgtQ(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4Eq: dispatches to encPcmpeqD via shared helper" {
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

    try op_simd.emitI32x4Eq(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqD(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16Ne: PCMPEQB + all-ones-mask + PXOR (4-instr sequence)" {
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

    try op_simd.emitI8x16Ne(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2Ne: dispatches to PCMPEQQ (SSE4.1 0x29)" {
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

    try op_simd.emitI64x2Ne(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqQ(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Splat: PSHUFD dst, src, 0x44 — broadcast low qword" {
    var slot_ids = [_]u16{ 0, 1 };
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
    var next_vreg: u32 = 1;

    try op_simd.emitF64x2Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    try testing.expectEqualSlices(u8, inst.encPshufd(.xmm9, .xmm8, 0x44).slice(), buf.items);
}

test "emitF64x2ExtractLane: lane 1 → PSHUFD imm 0xEE (select high qword)" {
    var slot_ids = [_]u16{ 0, 1 };
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
    var next_vreg: u32 = 1;

    try op_simd.emitF64x2ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 1);

    try testing.expectEqualSlices(u8, inst.encPshufd(.xmm9, .xmm8, 0xEE).slice(), buf.items);
}

test "emitF64x2ReplaceLane: lane 0 → MOVAPS + MOVSD (preserves high qword)" {
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
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    try op_simd.emitF64x2ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMovsdXmmXmm(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2ReplaceLane: lane 1 → MOVAPS + MOVLHPS (writes value to dst's high qword)" {
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

    try op_simd.emitF64x2ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 1);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMovlhps(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Splat: PSHUFD dst, src, 0x00" {
    var slot_ids = [_]u16{ 0, 1 };
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
    var next_vreg: u32 = 1;

    try op_simd.emitF32x4Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    try testing.expectEqualSlices(u8, inst.encPshufd(.xmm9, .xmm8, 0x00).slice(), buf.items);
}

test "emitF32x4ExtractLane: lane 2 → PSHUFD dst, src, 0xAA" {
    var slot_ids = [_]u16{ 0, 1 };
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
    var next_vreg: u32 = 1;

    try op_simd.emitF32x4ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 2);

    // lane 2 → 2 * 0x55 = 0xAA.
    try testing.expectEqualSlices(u8, inst.encPshufd(.xmm9, .xmm8, 0xAA).slice(), buf.items);
}

test "emitF32x4ReplaceLane: lane 1 → MOVAPS + INSERTPS imm 0x10" {
    // vec @ slot 0 (XMM8); value @ slot 1 (XMM9); result @ slot 2
    // (XMM10). MOVAPS preamble + INSERTPS with count_d=lane=1.
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
    try pushed.append(testing.allocator, 0); // vec
    try pushed.append(testing.allocator, 1); // value
    var next_vreg: u32 = 2;

    try op_simd.emitF32x4ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 1);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encInsertps(.xmm10, .xmm9, 0x10).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16Splat: MOVD + PXOR + PSHUFB sequence" {
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

    try op_simd.emitI8x16Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ctrl = abi.fp_spill_stage_xmms[0]; // XMM14
    try expected.appendSlice(testing.allocator, inst.encMovdXmmFromR32(.xmm8, .rbx).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(ctrl, ctrl).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufb(.xmm8, ctrl).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8Splat: MOVD + PSHUFLW + PSHUFD sequence" {
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

    try op_simd.emitI16x8Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovdXmmFromR32(.xmm8, .rbx).slice());
    try expected.appendSlice(testing.allocator, inst.encPshuflw(.xmm8, .xmm8, 0x00).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm8, .xmm8, 0x00).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2Splat: MOVQ + PUNPCKLQDQ sequence" {
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

    try op_simd.emitI64x2Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovqXmmFromR64(.xmm8, .rbx).slice());
    try expected.appendSlice(testing.allocator, inst.encPunpcklqdq(.xmm8, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
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

    try op_simd.emitI8x16ExtractLaneS(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 7);

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

    try op_simd.emitI16x8ExtractLaneU(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 5);

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

    try op_simd.emitI8x16ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 12);

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
    try op_simd.emitI32x4ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

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
    try op_simd.emitI64x2ReplaceLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

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

    try op_simd.emitI32x4Splat(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

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
    try op_simd.emitI32x4ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 2);

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

    try op_simd.emitI64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

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

    try op_simd.emitI64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

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

    try op_simd.emitI32x4Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

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

    try op_simd.emitI16x8Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

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

    try op_simd.emitI64x2Add(testing.allocator, &buf, alloc, &pushed, &next_vreg);

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

    try testing.expectError(Error.UnsupportedOp, op_simd.emitI32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg));
}
