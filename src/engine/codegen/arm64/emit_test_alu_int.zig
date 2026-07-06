//! arm64 emit pass — i32 / i64 ALU + comparison + bitcount tests.
//!
//! Family scope: i32/i64 add/sub/mul/and/or/xor/shl/shr_s/shr_u/
//! rotr/rotl, i32/i64 cmp ops, i32/i64 clz/ctz/popcnt, i32/i64 eqz,
//! and the AllocationMissing stack-underflow probe on i32.add.
//!
//! Zone 2 (`src/engine/codegen/arm64/`). Pure relocation per
//! ADR-0021 sub-deliverable b; bytes / assertions
//! identical to the pre-split `emit_test.zig`.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");
const prologue = @import("prologue.zig");
const regalloc = @import("../shared/regalloc.zig");
const emit = @import("emit.zig");

const ZirFunc = zir.ZirFunc;
const Error = emit.Error;
const compile = emit.compile;
const deinit = emit.deinit;

const testing = std.testing;

test "compile: (i32.const 7) (i32.const 5) i32.add end → returns 12 in X0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
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
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Stream: STP / MOV-FP / MOVZ X9 #7 / MOVZ X10 #5 / ADD X9 X9 X10 /
    //         MOV X0 X9 / LDP / RET = 8 u32s = 32 bytes.
    try testing.expectEqual(@as(usize, 212), out.bytes.len);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 7)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovzImm16(10, 5)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddRegW(9, 9, 10)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i32.sub / i32.mul / i32.and / i32.or / i32.xor / i32.shl / i32.shr_s / i32.shr_u each emit correct W-variant ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i32.sub", .want_word_at_offset = inst.encSubRegW(9, 9, 10) },
        .{ .op = .@"i32.mul", .want_word_at_offset = inst.encMulRegW(9, 9, 10) },
        .{ .op = .@"i32.and", .want_word_at_offset = inst.encAndRegW(9, 9, 10) },
        .{ .op = .@"i32.or", .want_word_at_offset = inst.encOrrRegW(9, 9, 10) },
        .{ .op = .@"i32.xor", .want_word_at_offset = inst.encEorRegW(9, 9, 10) },
        .{ .op = .@"i32.shl", .want_word_at_offset = inst.encLslvRegW(9, 9, 10) },
        .{ .op = .@"i32.shr_s", .want_word_at_offset = inst.encAsrvRegW(9, 9, 10) },
        .{ .op = .@"i32.shr_u", .want_word_at_offset = inst.encLsrvRegW(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // ALU op at body+8 (after MOVZ #7, MOVZ #5).
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    }
}

test "compile: stack underflow on ALU op with 1 pushed vreg surfaces AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false));
}

test "compile: i32.rotr emits single RORV W-variant" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.rotr" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // Stream: STP / MOV-FP / MOVZ #FF / MOVZ #4 / RORV / MOV X0 / LDP / RET.
    // RORV at body+8.
    try testing.expectEqual(@as(u32, inst.encRorvRegW(9, 9, 10)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i32.rotl emits 3-instr NEG-via-MOVZ-SUB + RORV sequence" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.rotl" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After body+8 (2 const u32s): MOVZ W16, #32 / SUB W16, W16, W10 / RORV W9, W9, W16.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 32)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encSubRegW(16, 16, 10)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encRorvRegW(9, 9, 16)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: i32 cmp ops each emit CMP + CSET with the right Cond mapping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"i32.eq", .want_cond = .eq },
        .{ .op = .@"i32.ne", .want_cond = .ne },
        .{ .op = .@"i32.lt_s", .want_cond = .lt },
        .{ .op = .@"i32.lt_u", .want_cond = .lo },
        .{ .op = .@"i32.gt_s", .want_cond = .gt },
        .{ .op = .@"i32.gt_u", .want_cond = .hi },
        .{ .op = .@"i32.le_s", .want_cond = .le },
        .{ .op = .@"i32.le_u", .want_cond = .ls },
        .{ .op = .@"i32.ge_s", .want_cond = .ge },
        .{ .op = .@"i32.ge_u", .want_cond = .hs },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // CMP at body+8, CSET at body+12.
        try testing.expectEqual(@as(u32, inst.encCmpRegW(9, 10)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    }
}

test "compile: i32.clz emits direct CLZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ-W9-#FF: CLZ W9, W9 at body+4.
    try testing.expectEqual(@as(u32, inst.encClzW(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: i32.ctz emits RBIT + CLZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x100 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.ctz" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ-W9-#0x100: RBIT W9, W9 / CLZ W9, W9.
    try testing.expectEqual(@as(u32, inst.encRbitW(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encClzW(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i32.popcnt emits 4-instr V-register SIMD pattern" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.popcnt" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ-W9 + MOVK-W9 (0xDEADBEEF needs both lanes):
    // FMOV S31, W9 / CNT V31.8B / ADDV B31 / UMOV W9, V31.B[0].
    try testing.expectEqual(@as(u32, inst_fp.encFmovStoFromW(31, 9)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCntV8B(31, 31)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddvB8B(31, 31)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encUmovWFromVB0(9, 31)), std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
}

test "compile: i64.add / sub / mul / and / or / xor each emit X-variant ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i64.add", .want_word_at_offset = inst.encAddReg(9, 9, 10) },
        .{ .op = .@"i64.sub", .want_word_at_offset = inst.encSubReg(9, 9, 10) },
        .{ .op = .@"i64.mul", .want_word_at_offset = inst.encMulReg(9, 9, 10) },
        .{ .op = .@"i64.and", .want_word_at_offset = inst.encAndReg(9, 9, 10) },
        .{ .op = .@"i64.or", .want_word_at_offset = inst.encOrrReg(9, 9, 10) },
        .{ .op = .@"i64.xor", .want_word_at_offset = inst.encEorReg(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    }
}

test "compile: i64 cmp ops each emit CMP-X + CSET-W with the right Cond mapping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"i64.eq", .want_cond = .eq },
        .{ .op = .@"i64.ne", .want_cond = .ne },
        .{ .op = .@"i64.lt_s", .want_cond = .lt },
        .{ .op = .@"i64.lt_u", .want_cond = .lo },
        .{ .op = .@"i64.gt_s", .want_cond = .gt },
        .{ .op = .@"i64.gt_u", .want_cond = .hi },
        .{ .op = .@"i64.le_s", .want_cond = .le },
        .{ .op = .@"i64.le_u", .want_cond = .ls },
        .{ .op = .@"i64.ge_s", .want_cond = .ge },
        .{ .op = .@"i64.ge_u", .want_cond = .hs },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        try testing.expectEqual(@as(u32, inst.encCmpRegX(9, 10)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    }
}

test "compile: i64 shifts emit X-variant LSLV/LSRV/ASRV/RORV" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i64.shl", .want_word_at_offset = inst.encLslvRegX(9, 9, 10) },
        .{ .op = .@"i64.shr_s", .want_word_at_offset = inst.encAsrvRegX(9, 9, 10) },
        .{ .op = .@"i64.shr_u", .want_word_at_offset = inst.encLsrvRegX(9, 9, 10) },
        .{ .op = .@"i64.rotr", .want_word_at_offset = inst.encRorvRegX(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    }
}

test "compile: i64.rotl emits 3-instr X-variant NEG-via-MOVZ-#64-SUB + RORV" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 4, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.rotl" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After 4 prologue+const u32s (16 bytes):
    // MOVZ X16, #64 / SUB X16, X16, X10 / RORV X9, X9, X16.
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 64)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encSubReg(16, 16, 10)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encRorvRegX(9, 9, 16)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: i64.clz emits direct CLZ X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encClzX(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: i64.ctz emits RBIT-X + CLZ-X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0x100, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.ctz" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encRbitX(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encClzX(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i64.popcnt emits FMOV-D + CNT/ADDV/UMOV V-register pattern" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.popcnt" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-X9 (12 bytes):
    // FMOV D31, X9 / CNT V31.8B / ADDV B31 / UMOV W9.
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst_fp.encFmovDtoFromX(31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCntV8B(31, 31)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddvB8B(31, 31)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encUmovWFromVB0(9, 31)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: i64.eqz emits CMP-X-imm-0 + CSET EQ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encCmpImmX(9, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCsetW(9, .eq)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i32.eqz emits CMP-imm-0 + CSET EQ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 #0: CMP W9,#0 / CSET W9,EQ at body+4, +8.
    try testing.expectEqual(@as(u32, inst.encCmpImmW(9, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCsetW(9, .eq)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: select_typed i64 (extra=0x7E) emits CSEL Xd, not Wd" {
    // Wasm spec §3.3.2.2 / §4.4.4 — select_typed with type=i64
    // requires 64-bit conditional move so the high 32 bits aren't
    // truncated (a W-form CSEL would silently miscompile i64 select
    // to a 32-bit operation). This test gates the X-form CSEL on the
    // i64 path.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Payload is u32; encode just the low 32 bits of an i64
    // marker constant. The select_typed dispatch we're gating
    // doesn't depend on the actual value, only on the type
    // dispatch (extra=0x7E). Keep payload simple.
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEADBEEF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    // select_typed [i64]: extra = 0x7E (i64 valtype byte)
    try f.instrs.append(testing.allocator, .{ .op = .select_typed, .extra = 0x7E });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 3 }, // val1 (i64 0xCAFE…)
            .{ .def_pc = 1, .last_use_pc = 3 }, // val2 (i64 0)
            .{ .def_pc = 2, .last_use_pc = 3 }, // cond (i32 1)
            .{ .def_pc = 3, .last_use_pc = 4 }, // result
        },
    };
    const slots = [_]u16{ 0, 1, 2, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);

    // Walk emitted body looking for a CSEL — the i64 path emits
    // `encCselX` (opcode base 0x9A800000); the (incorrect, pre-
    // fix) i32 path would emit `encCselW` (0x1A800000). Bytewise
    // pattern: bits[31:21] = 0x9AC for X-form (sf=1) per ARMv8-A
    // ref. Search the body for any 32-bit instr matching the
    // X-form CSEL bit-pattern, and assert NO W-form CSEL appears.
    const body0 = prologue.body_start_offset(false);
    var saw_csel_x: bool = false;
    var saw_csel_w: bool = false;
    var i: usize = body0;
    while (i + 4 <= out.bytes.len) : (i += 4) {
        const word = std.mem.readInt(u32, out.bytes[i..][0..4], .little);
        // CSEL X form: bits[31:21] == 0b10011010100 == 0x4D4 →
        // top 11 bits of opcode word == 0x9A800000 >> 21 == 0x4D4
        if ((word & 0xFFE00000) == 0x9A800000) saw_csel_x = true;
        if ((word & 0xFFE00000) == 0x1A800000) saw_csel_w = true;
    }
    try testing.expect(saw_csel_x);
    try testing.expect(!saw_csel_w);
}

test "compile: select_typed f64 (extra=0x7C) emits FCSEL Dd via FP regalloc" {
    // FCSEL D form: opcode base 0x1E600C00. Bit pattern check —
    // search emitted body for at least one instr matching
    // (word & 0xFFE00C00) == 0x1E600C00 (FCSEL D class). f64
    // operands flow through fpLoadSpilled / fpDefSpilled to
    // V-registers, not GPRs.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .select_typed, .extra = 0x7C });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 3 },
        .{ .def_pc = 1, .last_use_pc = 3 },
        .{ .def_pc = 2, .last_use_pc = 3 },
        .{ .def_pc = 3, .last_use_pc = 4 },
    } };
    const slots = [_]u16{ 0, 1, 2, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    var saw_fcsel_d: bool = false;
    var i: usize = body0;
    while (i + 4 <= out.bytes.len) : (i += 4) {
        const word = std.mem.readInt(u32, out.bytes[i..][0..4], .little);
        // FCSEL D-class: bits[31:21] == 0b00011110011 (0x0F3); plus
        // the [11:10]=11 fixed bits. Mask 0xFFE00C00 captures both.
        if ((word & 0xFFE00C00) == 0x1E600C00) saw_fcsel_d = true;
    }
    try testing.expect(saw_fcsel_d);
}
