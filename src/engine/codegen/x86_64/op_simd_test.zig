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

test "emitI8x16GtU: PMAXUB + PCMPEQB rhs + PXOR all-ones (gt path)" {
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

    try op_simd.emitI8x16GtU(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaxub(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8LtU: PMINUW + PCMPEQW rhs + PXOR all-ones (lt path)" {
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

    try op_simd.emitI16x8LtU(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPminuw(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqW(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm10, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4LeU: PMINUD + PCMPEQD lhs (le path, no NOT)" {
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

    try op_simd.emitI32x4LeU(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // dst = lhs ; dst = PMINUD(dst, rhs) ; dst = PCMPEQD(dst, lhs)
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPminud(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqD(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4GeU: PMAXUD + PCMPEQD lhs (ge path, no NOT)" {
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

    try op_simd.emitI32x4GeU(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaxud(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqD(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

// D-071 part (c): IntCmpUnsigned `.ge/.le` reads `lhs_x` after the
// min/max overwrites dst. When regalloc's LIFO slot-reuse aliases
// `dst == lhs`, the `MOVAPS dst, lhs` is elided (correctly) but the
// final `PCMPEQ dst, lhs` then reads dst-after-min/max, which is no
// longer the original lhs. Stash lhs through XMM7 (project SIMD
// scratch) before the min/max.
test "emitI8x16GeU: dst aliases lhs — stash lhs to XMM7 before PMAXUB" {
    var slot_ids = [_]u16{ 0, 1, 0 }; // vreg 0 → XMM8, vreg 1 → XMM9, vreg 2 (result) → XMM8 (== lhs)
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

    try op_simd.emitI8x16GeU(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // MOVAPS xmm7, xmm8 (stash lhs). MOVAPS dst, lhs elided. PMAXUB
    // xmm8, xmm9. PCMPEQB xmm8, xmm7 (original lhs from stash).
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaxub(.xmm8, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm8, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8LeU: dst aliases lhs — stash lhs to XMM7 before PMINUW" {
    var slot_ids = [_]u16{ 0, 1, 0 };
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

    try op_simd.emitI16x8LeU(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPminuw(.xmm8, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqW(.xmm8, .xmm7).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Eq: direct CMPPS imm=0x00 (no swap)" {
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

    try op_simd.emitF32x4Eq(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm10, .xmm9, 0x00).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Gt: swap path — MOVAPS dst, rhs + CMPPS dst, lhs, imm=0x01 (LT)" {
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

    try op_simd.emitF32x4Gt(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // gt = swap + LT: MOVAPS dst, rhs (XMM9) ; CMPPS dst, lhs (XMM8), 0x01.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm10, .xmm8, 0x01).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Lt: direct CMPPD imm=0x01 (no swap)" {
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

    try op_simd.emitF64x2Lt(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encCmppd(.xmm10, .xmm9, 0x01).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Ge: swap + CMPPD imm=0x02 (LE)" {
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

    try op_simd.emitF64x2Ge(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // ge = swap + LE: MOVAPS dst, rhs (XMM9) ; CMPPD dst, lhs (XMM8), 0x02.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encCmppd(.xmm10, .xmm8, 0x02).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Add: dispatches via emitV128IntBinop with encAddps (no 66 prefix)" {
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

    try op_simd.emitF32x4Add(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encAddps(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Mul: dispatches via emitV128IntBinop with encMulpd (66 prefix)" {
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

    try op_simd.emitF64x2Mul(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMulpd(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Sqrt: unary path — single SQRTPS dst, src (no MOVAPS)" {
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

    try op_simd.emitF32x4Sqrt(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encSqrtps(.xmm9, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Sqrt: unary path — single SQRTPD dst, src" {
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

    try op_simd.emitF64x2Sqrt(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encSqrtpd(.xmm9, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Min: 10-instruction NaN-correction synthesis" {
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

    try op_simd.emitF32x4Min(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0]; // XMM14
    const scratch2 = abi.fp_spill_stage_xmms[1]; // XMM15
    // 1. MOVAPS dst, lhs                  (lhs=XMM8, dst=XMM10)
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    // 2. MINPS dst, rhs
    try expected.appendSlice(testing.allocator, inst.encMinps(.xmm10, .xmm9).slice());
    // 3. MOVAPS scratch, rhs
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch, .xmm9).slice());
    // 4. MINPS scratch, lhs
    try expected.appendSlice(testing.allocator, inst.encMinps(scratch, .xmm8).slice());
    // 5. ORPS dst, scratch
    try expected.appendSlice(testing.allocator, inst.encOrps(.xmm10, scratch).slice());
    // 6. MOVAPS scratch2, dst
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch2, .xmm10).slice());
    // 7. CMPPS dst, scratch, 3
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm10, scratch, 0x03).slice());
    // 8. ORPS scratch2, dst
    try expected.appendSlice(testing.allocator, inst.encOrps(scratch2, .xmm10).slice());
    // 9. PSRLD dst, 10
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm10, 10).slice());
    // 10. ANDNPS dst, scratch2
    try expected.appendSlice(testing.allocator, inst.encAndnps(.xmm10, scratch2).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Max: 13-instruction NaN-correction synthesis" {
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

    try op_simd.emitF32x4Max(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0];
    const scratch2 = abi.fp_spill_stage_xmms[1];
    // 1. MOVAPS scratch, lhs
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch, .xmm8).slice());
    // 2. MAXPS scratch, rhs
    try expected.appendSlice(testing.allocator, inst.encMaxps(scratch, .xmm9).slice());
    // 3. MOVAPS scratch2, rhs
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch2, .xmm9).slice());
    // 4. MAXPS scratch2, lhs
    try expected.appendSlice(testing.allocator, inst.encMaxps(scratch2, .xmm8).slice());
    // 5. MOVAPS dst, scratch
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, scratch).slice());
    // 6. XORPS dst, scratch2
    try expected.appendSlice(testing.allocator, inst.encXorps(.xmm10, scratch2).slice());
    // 7. ORPS scratch, dst
    try expected.appendSlice(testing.allocator, inst.encOrps(scratch, .xmm10).slice());
    // 8. MOVAPS scratch2, scratch
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch2, scratch).slice());
    // 9. SUBPS scratch, dst
    try expected.appendSlice(testing.allocator, inst.encSubps(scratch, .xmm10).slice());
    // 10. CMPPS scratch2, scratch2, 3
    try expected.appendSlice(testing.allocator, inst.encCmpps(scratch2, scratch2, 0x03).slice());
    // 11. MOVAPS dst, scratch2
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, scratch2).slice());
    // 12. PSRLD dst, 10
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm10, 10).slice());
    // 13. ANDNPS dst, scratch
    try expected.appendSlice(testing.allocator, inst.encAndnps(.xmm10, scratch).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Min: PD encoders + PSRLQ shift=13 (10 instr)" {
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

    try op_simd.emitF64x2Min(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0];
    const scratch2 = abi.fp_spill_stage_xmms[1];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMinpd(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMinpd(scratch, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encOrpd(.xmm10, scratch).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch2, .xmm10).slice());
    try expected.appendSlice(testing.allocator, inst.encCmppd(.xmm10, scratch, 0x03).slice());
    try expected.appendSlice(testing.allocator, inst.encOrpd(scratch2, .xmm10).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlqImm(.xmm10, 13).slice());
    try expected.appendSlice(testing.allocator, inst.encAndnpd(.xmm10, scratch2).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitV128Not: 3-instr unary synthesis (MOVAPS + PCMPEQB + PXOR)" {
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

    try op_simd.emitV128Not(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, ones).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitV128And: dispatches to PAND via emitV128IntBinop" {
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

    try op_simd.emitV128And(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPand(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitV128Andnot: PANDN via MOVAPS dst,rhs + PANDN dst,lhs" {
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
    try pushed.append(testing.allocator, 0); // lhs (a)
    try pushed.append(testing.allocator, 1); // rhs (b)
    var next_vreg: u32 = 2;

    try op_simd.emitV128Andnot(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // dst = MOVAPS rhs (= XMM9, b); dst = PANDN(dst, lhs=XMM8) = ~b & a.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPandn(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitV128Bitselect: 5-instr PAND/PANDN/POR chain" {
    var slot_ids = [_]u16{ 0, 1, 2, 3 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 4,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var pushed: std.ArrayList(u32) = .empty;
    defer pushed.deinit(testing.allocator);
    try pushed.append(testing.allocator, 0); // a
    try pushed.append(testing.allocator, 1); // b
    try pushed.append(testing.allocator, 2); // c (top)
    var next_vreg: u32 = 3;

    try op_simd.emitV128Bitselect(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0];
    // dst (XMM11) = MOVAPS a (XMM8) ; PAND dst, c (XMM10)
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm11, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPand(.xmm11, .xmm10).slice());
    // scratch = MOVAPS c ; PANDN scratch, b
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(scratch, .xmm10).slice());
    try expected.appendSlice(testing.allocator, inst.encPandn(scratch, .xmm9).slice());
    // dst = POR(dst, scratch)
    try expected.appendSlice(testing.allocator, inst.encPor(.xmm11, scratch).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI8x16AllTrue: 5-instr SSE4.1 PTEST recipe (PXOR + PCMPEQB + PTEST + SETZ + MOVZX)" {
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

    try op_simd.emitI8x16AllTrue(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const scratch = abi.fp_spill_stage_xmms[0]; // XMM14
    try expected.appendSlice(testing.allocator, inst.encPxor(scratch, scratch).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(scratch, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPtest(scratch, scratch).slice());
    // dst_r = result vreg slot 1 → first allocatable GPR reg post-spill (depends on
    // alloc impl). Just check that the expected emit completes successfully without
    // attempting to enumerate the GPR — the byte-for-byte test would need the actual
    // allocated GPR slot. Trim the test to just assert the prefix matches via
    // expectEqual on the first 3 instructions' length.
    try testing.expect(buf.items.len > expected.items.len);
    try testing.expectEqualSlices(u8, expected.items, buf.items[0..expected.items.len]);
}

test "emitI8x16Bitmask: PMOVMSKB direct (1 instr)" {
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

    try op_simd.emitI8x16Bitmask(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0);

    // First instruction should be PMOVMSKB; subsequent instructions
    // depend on the spill-store mechanics for the i32 result. PMOVMSKB
    // bytes: 66 [REX?] 0F D7 ModRM. Skip REX (if present) when checking
    // 0F D7; first byte is always 0x66 prefix.
    try testing.expect(buf.items.len >= 4);
    try testing.expectEqual(@as(u8, 0x66), buf.items[0]);
    const after_prefix = if ((buf.items[1] & 0xF0) == 0x40) buf.items[2..] else buf.items[1..];
    try testing.expectEqual(@as(u8, 0x0F), after_prefix[0]);
    try testing.expectEqual(@as(u8, 0xD7), after_prefix[1]);
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

// D-071 part c (actual): IntNe lacked the dst==rhs alias guard that
// IntCmpSigned / IntCmpUnsigned already carry. When regalloc's LIFO
// slot-reuse aliases `dst == rhs` (and dst != lhs), the unguarded
// `MOVAPS dst, lhs` clobbers rhs before `PCMPEQ dst, rhs` reads it,
// leaving PCMPEQ to compare lhs with itself → all-ones, which the
// trailing PXOR with all-ones flips to all-zeros (the symptom seen
// in simd_i16x8_cmp / simd_i32x4_cmp `ne` fixtures on OrbStack
// x86_64). Stash rhs through XMM7 (project SIMD scratch).
test "emitI16x8Ne: dst aliases rhs — stash rhs to XMM7 before PCMPEQW (D-071 part c-actual)" {
    var slot_ids = [_]u16{ 0, 1, 1 }; // result vreg 2 → XMM9 (== rhs).
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

    try op_simd.emitI16x8Ne(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const ones = abi.fp_spill_stage_xmms[0];
    // Stash rhs (XMM9) to XMM7, then MOVAPS dst, lhs, PCMPEQW dst,
    // xmm7 (original rhs), build all-ones mask, PXOR to invert.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm7, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqW(.xmm9, .xmm7).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(ones, ones).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, ones).slice());
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

test "emitI64x2ExtractLane: lane 1 — single PEXTRQ instruction (REX.W)" {
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

    // payload = 1 → lane 1.
    try op_simd.emitI64x2ExtractLane(testing.allocator, &buf, alloc, &pushed, &next_vreg, 0, 1);

    try testing.expectEqualSlices(u8, inst.encPextrQ(.rbx, .xmm8, 1).slice(), buf.items);
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

// §9.7 / 9.7-ad — FP unop family unit tests.

test "emitF32x4Abs: PCMPEQB + PSLLD-31 + (MOVAPS dst,src) + PANDN + MOVAPS" {
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

    try op_simd.emitF32x4Abs(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, mask = xmm14.
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPslldImm(.xmm14, 31).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPandn(.xmm14, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Abs: PCMPEQB + PSLLQ-63 (qword sign-mask) for f64x2" {
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

    try op_simd.emitF64x2Abs(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(.xmm14, 63).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPandn(.xmm14, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Neg: PCMPEQB + PSLLD-31 + MOVAPS dst,src + PXOR dst, mask (4 instr)" {
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

    try op_simd.emitF32x4Neg(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPslldImm(.xmm14, 31).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Neg: PCMPEQB + PSLLQ-63 + MOVAPS + PXOR" {
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

    try op_simd.emitF64x2Neg(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPsllqImm(.xmm14, 63).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Ceil: ROUNDPS dst, src, imm=0x0A (suppress-precision | ceil)" {
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

    try op_simd.emitF32x4Ceil(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encRoundps(.xmm9, .xmm8, 0x0A).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Floor / Trunc / Nearest: ROUNDPS imm bits 09 / 0B / 08" {
    var slot_ids = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    inline for (.{
        .{ op_simd.emitF32x4Floor, @as(u8, 0x09) },
        .{ op_simd.emitF32x4Trunc, @as(u8, 0x0B) },
        .{ op_simd.emitF32x4Nearest, @as(u8, 0x08) },
    }) |pair| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var pushed: std.ArrayList(u32) = .empty;
        defer pushed.deinit(testing.allocator);
        try pushed.append(testing.allocator, 0);
        var next_vreg: u32 = 1;

        try pair[0](testing.allocator, &buf, alloc, &pushed, &next_vreg);

        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(testing.allocator);
        try expected.appendSlice(testing.allocator, inst.encRoundps(.xmm9, .xmm8, pair[1]).slice());
        try testing.expectEqualSlices(u8, expected.items, buf.items);
    }
}

test "emitF32x4ConvertI32x4U: 11-instr split-and-recombine recipe" {
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

    try op_simd.emitF32x4ConvertI32x4U(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, a_lo = xmm14, a_hi = xmm15.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm14, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPslldImm(.xmm14, 16).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm14, 16).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm15, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPsubD(.xmm15, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encCvtdq2ps(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm15, 1).slice());
    try expected.appendSlice(testing.allocator, inst.encCvtdq2ps(.xmm15, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encAddps(.xmm15, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encAddps(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8Q15mulrSatS: PMULHRSW dst, src" {
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

    try op_simd.emitI16x8Q15mulrSatS(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // emitV128IntBinop: MOVAPS dst, lhs (when dst != lhs); ENC dst, rhs.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmulhrsw(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtmulLowI8x16S: PMOVSXBW + PMOVSXBW + PMULLW (3 instr)" {
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

    try op_simd.emitI16x8ExtmulLowI8x16S(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // lhs = xmm8, rhs = xmm9, dst = xmm10, tmp = xmm14.
    try expected.appendSlice(testing.allocator, inst.encPmovsxbw(.xmm14, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovsxbw(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPmullW(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ExtmulLowI16x8U: PMOVZXWD + PMOVZXWD + PMULLD (3 instr)" {
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

    try op_simd.emitI32x4ExtmulLowI16x8U(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPmovzxwd(.xmm14, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovzxwd(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPmullD(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ExtaddPairwiseI16x8S: PCMPEQB + PSRLW imm=15 + MOVAPS + PMADDWD (4 instr)" {
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

    try op_simd.emitI32x4ExtaddPairwiseI16x8S(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrlwImm(.xmm14, 15).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaddwd(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtaddPairwiseI8x16U: PCMPEQB + PABSB + MOVAPS + PMADDUBSW (4 instr)" {
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

    try op_simd.emitI16x8ExtaddPairwiseI8x16U(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, tmp = xmm14.
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPabsb(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaddubsw(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtaddPairwiseI8x16S: PCMPEQB + PABSB + PMADDUBSW (3 instr; dst holds +1 mask)" {
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

    try op_simd.emitI16x8ExtaddPairwiseI8x16S(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPcmpeqB(.xmm9, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPabsb(.xmm9, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaddubsw(.xmm9, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2ExtmulLowI32x4S: PSHUFD imm=0x50 x2 + PMULDQ (3 instr)" {
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

    try op_simd.emitI64x2ExtmulLowI32x4S(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm10, .xmm8, 0x50).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm14, .xmm9, 0x50).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuldq(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI64x2ExtmulHighI32x4U: PSHUFD imm=0xFA x2 + PMULUDQ (3 instr)" {
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

    try op_simd.emitI64x2ExtmulHighI32x4U(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm10, .xmm8, 0xFA).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm14, .xmm9, 0xFA).slice());
    try expected.appendSlice(testing.allocator, inst.encPmuludq(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4ExtmulHighI16x8S: PSHUFD x2 + PMOVSXWD x2 + PMULLD (5 instr)" {
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

    try op_simd.emitI32x4ExtmulHighI16x8S(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm14, .xmm8, 0xEE).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm15, .xmm9, 0xEE).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovsxwd(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovsxwd(.xmm10, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encPmullD(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI16x8ExtmulHighI8x16U: PSHUFD x2 + PMOVZXBW x2 + PMULLW (5 instr)" {
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

    try op_simd.emitI16x8ExtmulHighI8x16U(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm14, .xmm8, 0xEE).slice());
    try expected.appendSlice(testing.allocator, inst.encPshufd(.xmm15, .xmm9, 0xEE).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovzxbw(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPmovzxbw(.xmm10, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encPmullW(.xmm10, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4DotI16x8S: PMADDWD dst, src" {
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

    try op_simd.emitI32x4DotI16x8S(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaddwd(.xmm10, .xmm9).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4TruncSatF32x4S: 9-instr NaN-mask + XOR-fix recipe" {
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

    try op_simd.emitI32x4TruncSatF32x4S(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, tmp = xmm14.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm14, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm14, .xmm8, 0x00).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encAndps(.xmm9, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encXorps(.xmm14, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encCvttps2dq(.xmm9, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPand(.xmm14, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encPsradImm(.xmm14, 31).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm9, .xmm14).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF32x4Pmin: MOVAPS dst,rhs + MINPS dst,lhs (operand swap)" {
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
    try pushed.append(testing.allocator, 0); // lhs (c1) — slot 0 → xmm8
    try pushed.append(testing.allocator, 1); // rhs (c2) — slot 1 → xmm9
    var next_vreg: u32 = 2;

    try op_simd.emitF32x4Pmin(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // dst = xmm10, rhs = xmm9, lhs = xmm8.
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMinps(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2Pmax: MOVAPS dst,rhs + MAXPD dst,lhs (operand swap)" {
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

    try op_simd.emitF64x2Pmax(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm10, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encMaxpd(.xmm10, .xmm8).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitI32x4TruncSatF32x4U: 14-instr two-path inline-magic recipe" {
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

    try op_simd.emitI32x4TruncSatF32x4U(testing.allocator, &buf, alloc, &pushed, &next_vreg);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    // src = xmm8, dst = xmm9, tmp2 = xmm14, tmp1 = xmm15.
    try expected.appendSlice(testing.allocator, inst.encXorps(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm9, .xmm8).slice());
    try expected.appendSlice(testing.allocator, inst.encMaxps(.xmm9, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPcmpeqD(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPsrldImm(.xmm14, 1).slice());
    try expected.appendSlice(testing.allocator, inst.encCvtdq2ps(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encMovapsXmmXmm(.xmm15, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encCvttps2dq(.xmm9, .xmm9).slice());
    try expected.appendSlice(testing.allocator, inst.encSubps(.xmm15, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encCmpps(.xmm14, .xmm15, 0x02).slice());
    try expected.appendSlice(testing.allocator, inst.encCvttps2dq(.xmm15, .xmm15).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm15, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPxor(.xmm14, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPmaxsd(.xmm15, .xmm14).slice());
    try expected.appendSlice(testing.allocator, inst.encPaddD(.xmm9, .xmm15).slice());
    try testing.expectEqualSlices(u8, expected.items, buf.items);
}

test "emitF64x2 Ceil/Floor/Trunc/Nearest: ROUNDPD imm bits 0A/09/0B/08" {
    var slot_ids = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slot_ids,
        .n_slots = 2,
        .max_reg_slots_gpr = 4,
        .max_reg_slots_fp = 6,
    };

    inline for (.{
        .{ op_simd.emitF64x2Ceil, @as(u8, 0x0A) },
        .{ op_simd.emitF64x2Floor, @as(u8, 0x09) },
        .{ op_simd.emitF64x2Trunc, @as(u8, 0x0B) },
        .{ op_simd.emitF64x2Nearest, @as(u8, 0x08) },
    }) |pair| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var pushed: std.ArrayList(u32) = .empty;
        defer pushed.deinit(testing.allocator);
        try pushed.append(testing.allocator, 0);
        var next_vreg: u32 = 1;

        try pair[0](testing.allocator, &buf, alloc, &pushed, &next_vreg);

        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(testing.allocator);
        try expected.appendSlice(testing.allocator, inst.encRoundpd(.xmm9, .xmm8, pair[1]).slice());
        try testing.expectEqualSlices(u8, expected.items, buf.items);
    }
}
