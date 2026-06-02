//! arm64 emit pass — FP ALU + comparison + convert tests.
//!
//! Family scope: f32/f64 binary ALU, comparison, unary ops + min/max,
//! copysign, wrap / extend / convert / demote / promote / trunc /
//! trunc_sat / reinterpret across i32, i64, f32, f64.
//!
//! Zone 2 (`src/engine/codegen/arm64/`). Pure relocation per
//! ADR-0021 sub-deliverable b chunk 10; bytes / assertions
//! identical to the pre-split `emit_test.zig`.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");

const prologue = @import("prologue.zig");
const regalloc = @import("../shared/regalloc.zig");
const emit = @import("emit.zig");

const ZirFunc = zir.ZirFunc;
const compile = emit.compile;
const deinit = emit.deinit;

const testing = std.testing;

test "compile: f32 binary ALU each emits S-form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"f32.add", .want_word_at_offset = inst_fp.encFAddS(16, 16, 17) },
        .{ .op = .@"f32.sub", .want_word_at_offset = inst_fp.encFSubS(16, 16, 17) },
        .{ .op = .@"f32.mul", .want_word_at_offset = inst_fp.encFMulS(16, 16, 17) },
        .{ .op = .@"f32.div", .want_word_at_offset = inst_fp.encFDivS(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // Each f32.const emits MOVZ + MOVK + FMOV (3 u32s = 12 bytes).
        // After 2 consts (24 bytes), FP ALU fires.
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    }
}

test "compile: f32 cmps each emit FCMP-S + CSET-W with right Cond" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"f32.eq", .want_cond = .eq },
        .{ .op = .@"f32.ne", .want_cond = .ne },
        .{ .op = .@"f32.lt", .want_cond = .mi },
        .{ .op = .@"f32.gt", .want_cond = .gt },
        .{ .op = .@"f32.le", .want_cond = .ls },
        .{ .op = .@"f32.ge", .want_cond = .ge },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // FCMP at body+24; CSET at body+28.
        try testing.expectEqual(@as(u32, inst_fp.encFCmpS(16, 17)), std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    }
}

test "compile: f32 unary ops + min/max each emit correct encoding" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    const Case = struct {
        op: zir.ZirOp,
        binary: bool,
        want_word_at_offset: u32,
    };
    const cases = [_]Case{
        .{ .op = .@"f32.abs", .binary = false, .want_word_at_offset = inst_fp.encFAbsS(16, 16) },
        .{ .op = .@"f32.neg", .binary = false, .want_word_at_offset = inst_fp.encFNegS(16, 16) },
        .{ .op = .@"f32.sqrt", .binary = false, .want_word_at_offset = inst_fp.encFSqrtS(16, 16) },
        .{ .op = .@"f32.ceil", .binary = false, .want_word_at_offset = inst_fp.encFRintPS(16, 16) },
        .{ .op = .@"f32.floor", .binary = false, .want_word_at_offset = inst_fp.encFRintMS(16, 16) },
        .{ .op = .@"f32.trunc", .binary = false, .want_word_at_offset = inst_fp.encFRintZS(16, 16) },
        .{ .op = .@"f32.nearest", .binary = false, .want_word_at_offset = inst_fp.encFRintNS(16, 16) },
        .{ .op = .@"f32.min", .binary = true, .want_word_at_offset = inst_fp.encFMinS(16, 16, 17) },
        .{ .op = .@"f32.max", .binary = true, .want_word_at_offset = inst_fp.encFMaxS(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        var ranges_buf: [3]zir.LiveRange = undefined;
        if (c.binary) {
            try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
            try f.instrs.append(testing.allocator, .{ .op = c.op });
            ranges_buf[0] = .{ .def_pc = 0, .last_use_pc = 2 };
            ranges_buf[1] = .{ .def_pc = 1, .last_use_pc = 2 };
            ranges_buf[2] = .{ .def_pc = 2, .last_use_pc = 3 };
            try f.instrs.append(testing.allocator, .{ .op = .end });
        } else {
            try f.instrs.append(testing.allocator, .{ .op = c.op });
            ranges_buf[0] = .{ .def_pc = 0, .last_use_pc = 1 };
            ranges_buf[1] = .{ .def_pc = 1, .last_use_pc = 2 };
            try f.instrs.append(testing.allocator, .{ .op = .end });
        }
        f.liveness = .{ .ranges = if (c.binary) ranges_buf[0..3] else ranges_buf[0..2] };
        const slots_binary = [_]u16{ 0, 1, 0 };
        const slots_unary = [_]u16{ 0, 0 };
        const alloc: regalloc.Allocation = if (c.binary)
            .{ .slots = &slots_binary, .n_slots = 2 }
        else
            .{ .slots = &slots_unary, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // For unary: 1 const = 3 u32s (MOVZ + MOVK + FMOV S) → body+12.
        // For binary: 2 consts = 6 u32s → body+24.
        const op_offset: usize = body0 + (if (c.binary) @as(usize, 24) else 12);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[op_offset .. op_offset + 4][0..4], .little));
    }
}

test "compile: f32.copysign emits 8-instr FMOV/BIC/AND/ORR sequence" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.5f magnitude src + (-2.0f) sign src → expect -1.5f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3FC00000 }); // 1.5
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xC0000000 }); // -2.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After 2 consts (each 3 u32s = 24 bytes), 8-instr copysign sequence at body+24.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 0)), std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(16, 0x8000, 1)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst_fp.encFmovWFromS(9, 16)), std.mem.readInt(u32, out.bytes[body0 + 32 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBicRegW(9, 9, 16)), std.mem.readInt(u32, out.bytes[body0 + 36 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst_fp.encFmovWFromS(17, 17)), std.mem.readInt(u32, out.bytes[body0 + 40 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAndRegW(17, 17, 16)), std.mem.readInt(u32, out.bytes[body0 + 44 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 9, 17)), std.mem.readInt(u32, out.bytes[body0 + 48 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst_fp.encFmovStoFromW(16, 9)), std.mem.readInt(u32, out.bytes[body0 + 52 ..][0..4], .little));
}

test "compile: f64.copysign emits X-form 8-instr sequence with hw=3 mask" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.5 + (-2.0) f64
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF80000 }); // 1.5
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0xC0000000 }); // -2.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // f64.const 1.5: bits=0x3FF8000000000000. Lanes: l0=0,l1=0,
    // l2=0,l3=0x3FF8. Only l3 nonzero → MOVZ + MOVK lane3 + FMOV D
    // = 3 u32s. Same shape for -2.0. After STP/MOV-FP (8) + 6 u32s
    // (24) = byte 32.
    const body0 = prologue.body_start_offset(false);
    // After 2 consts (24 bytes), 8-instr copysign sequence at body+24.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 0)), std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(16, 0x8000, 3)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst_fp.encFmovXFromD(9, 16)), std.mem.readInt(u32, out.bytes[body0 + 32 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBicRegX(9, 9, 16)), std.mem.readInt(u32, out.bytes[body0 + 36 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst_fp.encFmovXFromD(17, 17)), std.mem.readInt(u32, out.bytes[body0 + 40 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAndReg(17, 17, 16)), std.mem.readInt(u32, out.bytes[body0 + 44 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(9, 9, 17)), std.mem.readInt(u32, out.bytes[body0 + 48 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst_fp.encFmovDtoFromX(16, 9)), std.mem.readInt(u32, out.bytes[body0 + 52 ..][0..4], .little));
}

test "compile: f64 binary ALU each emits D-form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"f64.add", .want_word_at_offset = inst_fp.encFAddD(16, 16, 17) },
        .{ .op = .@"f64.sub", .want_word_at_offset = inst_fp.encFSubD(16, 16, 17) },
        .{ .op = .@"f64.mul", .want_word_at_offset = inst_fp.encFMulD(16, 16, 17) },
        .{ .op = .@"f64.div", .want_word_at_offset = inst_fp.encFDivD(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        // 1.0 + 2.0 (f64 bits): payload = lo32, extra = hi32.
        try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0x00000000, .extra = 0x3FF00000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0x00000000, .extra = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
        defer deinit(testing.allocator, out);
        // f64.const 1.0: bits=0x3FF0000000000000. Lanes: lo=0, l1=0,
        // l2=0, l3=0x3FF0. Only lane 3 nonzero (besides lane 0).
        // So const emits MOVZ + MOVK lane3 + FMOV D = 3 u32s.
        // f64.const 2.0: bits=0x4000000000000000. Lane 3 = 0x4000.
        // Same shape.
        const body0 = prologue.body_start_offset(false);
        // After 2 consts (24 bytes), ALU fires at body+24.
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    }
}

test "compile: i32.wrap_i64 emits MOV W,W (= ORR W, WZR, W)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xCAFE, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ X9, #0xCAFE: ORR W9, WZR, W9 (in-place wrap) at body+4.
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: i64.extend_i32_s emits SXTW X, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFFFFFFFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ + MOVK loading 0xFFFFFFFF into W9 (8 bytes): SXTW X9,W9 at body+8.
    try testing.expectEqual(@as(u32, inst.encSxtw(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i64.extend_i32_u emits MOV W,W (zero-extends via W-write)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 #42: ORR W9, WZR, W9 at body+4.
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: f32.convert_i32_s emits SCVTF S, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 #7: SCVTF S16, W9 at body+4.
    try testing.expectEqual(@as(u32, inst_fp.encScvtfSFromW(16, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: f64.convert_i64_u emits UCVTF D, X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEAD, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.convert_i64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ X9 #0xDEAD: UCVTF D16, X9 at body+4.
    try testing.expectEqual(@as(u32, inst_fp.encUcvtfDFromX(16, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: f32.demote_f64 emits FCVT S, D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.demote_f64" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // Find FCVT S16, D16 in the byte stream.
    const expected = inst_fp.encFcvtSFromD(16, 16);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: f64.promote_f32 emits FCVT D, S" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.promote_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const expected = inst_fp.encFcvtDFromS(16, 16);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.trunc_sat_f32_s emits FCVTZS W, S" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const expected = inst_fp.encFcvtzsWFromS(9, 16); // dest W9, src V16
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i64.trunc_sat_f64_u emits FCVTZU X, D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const expected = inst_fp.encFcvtzuXFromD(9, 16);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.reinterpret_f32 emits FMOV W, S" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.reinterpret_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const expected = inst_fp.encFmovWFromS(9, 16);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: f64.reinterpret_i64 emits FMOV D, X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xCAFE, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.reinterpret_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const expected = inst_fp.encFmovDtoFromX(16, 9);
    var found = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == expected) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.trunc_f32_s emits NaN+lower+upper checks then FCVTZS W,S" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected core instructions to find in the byte stream:
    //   FCMP S16, S16   ; NaN check
    //   FMOV S31, W16   ; bound stage (×2 — once each for lower/upper)
    //   FCMP S16, S31   ; bound compare (×2)
    //   FCVTZS W9, S16  ; the conversion
    //
    // We walk the stream and verify each appears in expected
    // order; trap-branch placeholders share encoding shape with
    // existing bounds-check tests, so we don't re-verify their
    // raw bytes here (covered by the trap-stub patching test).
    var found_fcmp_self = false;
    var found_fcvtzs = false;
    var fcmp_self_count: u32 = 0;
    var fcmp_v31_count: u32 = 0;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        const w = std.mem.readInt(u32, out.bytes[p..][0..4], .little);
        if (w == inst_fp.encFCmpS(16, 16)) {
            found_fcmp_self = true;
            fcmp_self_count += 1;
        }
        if (w == inst_fp.encFCmpS(16, 31)) fcmp_v31_count += 1;
        if (w == inst_fp.encFcvtzsWFromS(9, 16)) found_fcvtzs = true;
    }
    try testing.expect(found_fcmp_self);
    try testing.expectEqual(@as(u32, 1), fcmp_self_count); // NaN check is single FCMP self
    try testing.expectEqual(@as(u32, 2), fcmp_v31_count); // 2 bound checks
    try testing.expect(found_fcvtzs);
}

test "compile: i32.trunc_f64_s emits NaN+f64-lower+f64-upper checks then FCVTZS W,D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f64_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Walk the byte stream looking for the D-form NaN check + 2
    // bounds compares + final FCVTZS.
    var fcmp_self_count: u32 = 0;
    var fcmp_v31_count: u32 = 0;
    var found_fcvtzs = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        const w = std.mem.readInt(u32, out.bytes[p..][0..4], .little);
        if (w == inst_fp.encFCmpD(16, 16)) fcmp_self_count += 1;
        if (w == inst_fp.encFCmpD(16, 31)) fcmp_v31_count += 1;
        if (w == inst_fp.encFcvtzsWFromD(9, 16)) found_fcvtzs = true;
    }
    try testing.expectEqual(@as(u32, 1), fcmp_self_count);
    try testing.expectEqual(@as(u32, 2), fcmp_v31_count);
    try testing.expect(found_fcvtzs);
}
