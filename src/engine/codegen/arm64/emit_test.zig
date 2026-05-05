//! ARM64 emit pass — integration tests for compile().
//!
//! Per ADR-0021 sub-deliverable b (§9.7 / 7.5d sub-b emit.zig
//! 9-module split, chunk 10 / final): extracted from emit.zig
//! so the orchestrator file stays under the §A2 hard cap (2000
//! LOC). All tests are end-to-end on `compile()` — they call
//! through the public surface (Error / EmitOutput / deinit /
//! compile) and assert on the encoded byte stream.
//!
//! Aliases mirror what emit.zig exposes; the import preamble
//! declares `compile` / `deinit` / `Error` etc. as locals so the
//! test bodies can stay byte-identical to their pre-extract form.
//!
//! Test discovery: `src/zwasm.zig`'s `test {}` block adds
//! `_ = @import("engine/codegen/arm64/emit_test.zig")` so the
//! tests run under `zig build test` / `test-all`.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const prologue = @import("prologue.zig");
const regalloc = @import("../shared/regalloc.zig");
const emit = @import("emit.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const Xn = inst.Xn;
const Error = emit.Error;
const compile = emit.compile;
const deinit = emit.deinit;
const EmitOutput = emit.EmitOutput;
const CallFixup = emit.CallFixup;

const testing = std.testing;
const liveness_mod = @import("../../../ir/analysis/liveness.zig");

test "compile: empty body without liveness errors" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
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
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // 2 prologue u32s = 8 bytes.
    try testing.expectEqual(@as(usize, 32), out.bytes.len);
    // Use the centralised opcode constants; ABI-pinned offsets [0..4] / [4..8].
    try prologue.assertPrologueOpcodes(out.bytes);
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream: STP / MOV-FP-SP / MOVZ-X9-#42 / MOV-X0-X9 / LDP / RET
    // = 6 u32 words = 24 bytes.
    try testing.expectEqual(@as(usize, 48), out.bytes.len);

    // Word 0: STP prologue (ABI-pinned per AAPCS64; offset fixed).
    try testing.expectEqual(prologue.FpLrSave.stp_word, std.mem.readInt(u32, out.bytes[0..4], .little));
    // Word 1: MOV X29, SP (ABI-pinned).
    try testing.expectEqual(prologue.FpLrSave.mov_fp_word, std.mem.readInt(u32, out.bytes[4..8], .little));
    // Body words use `prologue.body_start_offset(has_frame)` so a
    // future prologue-shape change updates one helper, not 142 sites.
    const body0 = prologue.body_start_offset(false);
    // Word 2: MOVZ X9, #42 — slot 0 → X9 per abi.slotToReg.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    // Word 3: MOV X0, X9 (ORR X0, XZR, X9).
    try testing.expectEqual(@as(u32, 0xAA0903E0), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    // Word 4: LDP epilogue.
    try testing.expectEqual(@as(u32, 0xA8C17BFD), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    // Word 5: RET.
    try testing.expectEqual(@as(u32, 0xD65F03C0), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // 7 u32s now: STP / MOV-FP-SP / MOVZ / MOVK / MOV-X0 / LDP / RET.
    try testing.expectEqual(@as(usize, 52), out.bytes.len);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0x5678)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x1234, 1)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: unsupported op surfaces UnsupportedOp" {
    // With sub-h block fully closed, the remaining unsupported MVP
    // ops live in feature/ext_2_0 (e.g. memory.copy). Use one as
    // the probe.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.copy" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty, &.{}, &.{}));
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream: STP / MOV-FP / MOVZ X9 #7 / MOVZ X10 #5 / ADD X9 X9 X10 /
    //         MOV X0 X9 / LDP / RET = 8 u32s = 32 bytes.
    try testing.expectEqual(@as(usize, 56), out.bytes.len);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 7)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovzImm16(10, 5)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddRegW(9, 9, 10)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i32.sub / i32.mul / i32.and / i32.or / i32.xor / i32.shl / i32.shr_s / i32.shr_u each emit correct W-variant ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i32.sub",   .want_word_at_offset = inst.encSubRegW(9, 9, 10) },
        .{ .op = .@"i32.mul",   .want_word_at_offset = inst.encMulRegW(9, 9, 10) },
        .{ .op = .@"i32.and",   .want_word_at_offset = inst.encAndRegW(9, 9, 10) },
        .{ .op = .@"i32.or",    .want_word_at_offset = inst.encOrrRegW(9, 9, 10) },
        .{ .op = .@"i32.xor",   .want_word_at_offset = inst.encEorRegW(9, 9, 10) },
        .{ .op = .@"i32.shl",   .want_word_at_offset = inst.encLslvRegW(9, 9, 10) },
        .{ .op = .@"i32.shr_s", .want_word_at_offset = inst.encAsrvRegW(9, 9, 10) },
        .{ .op = .@"i32.shr_u", .want_word_at_offset = inst.encLsrvRegW(9, 9, 10) },
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
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // ALU op at body+8 (after MOVZ #7, MOVZ #5).
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
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
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: i32.rotr emits single RORV W-variant" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.rotr" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // Stream: STP / MOV-FP / MOVZ #FF / MOVZ #4 / RORV / MOV X0 / LDP / RET.
    // RORV at body+8.
    try testing.expectEqual(@as(u32, inst.encRorvRegW(9, 9, 10)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i32.rotl emits 3-instr NEG-via-MOVZ-SUB + RORV sequence" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.rotl" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After body+8 (2 const u32s): MOVZ W16, #32 / SUB W16, W16, W10 / RORV W9, W9, W16.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 32)),    std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encSubRegW(16, 16, 10)),  std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encRorvRegW(9, 9, 16)),   std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: i32 cmp ops each emit CMP + CSET with the right Cond mapping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"i32.eq",   .want_cond = .eq },
        .{ .op = .@"i32.ne",   .want_cond = .ne },
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
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // CMP at body+8, CSET at body+12.
        try testing.expectEqual(@as(u32, inst.encCmpRegW(9, 10)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    }
}

test "compile: i32.clz emits direct CLZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ-W9-#FF: CLZ W9, W9 at body+4.
    try testing.expectEqual(@as(u32, inst.encClzW(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: i32.ctz emits RBIT + CLZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x100 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.ctz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ-W9-#0x100: RBIT W9, W9 / CLZ W9, W9.
    try testing.expectEqual(@as(u32, inst.encRbitW(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encClzW(9, 9)),  std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i32.popcnt emits 4-instr V-register SIMD pattern" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.popcnt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ-W9 + MOVK-W9 (0xDEADBEEF needs both lanes):
    // FMOV S31, W9 / CNT V31.8B / ADDV B31 / UMOV W9, V31.B[0].
    try testing.expectEqual(@as(u32, inst.encFmovStoFromW(31, 9)),     std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCntV8B(31, 31)),          std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddvB8B(31, 31)),         std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encUmovWFromVB0(9, 31)),     std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
}

test "compile: 1 local — prologue includes SUB SP,SP,#16; epilogue ADD SP,SP,#16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{.i32};
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream: STP / MOV-FP / SUB-SP-#16 / MOVZ W9 #7 / STR W9 [SP,#0] /
    //         LDR W9 [SP,#0] / MOV X0 X9 / ADD-SP-#16 / LDP / RET = 10 u32s = 40 bytes.
    try testing.expectEqual(@as(usize, 64), out.bytes.len);
    const body0 = prologue.body_start_offset(true);
    // SUB SP at the last prologue word (body0 - 4).
    try testing.expectEqual(@as(u32, inst.encSubImm12(31, 31, 16)), std.mem.readInt(u32, out.bytes[body0 - 4 ..][0..4], .little));
    // STR W9 [SP,#0] at body+4 (after MOVZ).
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 0)),    std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    // LDR W9 [SP,#0] at body+8.
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 0)),    std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    // ADD SP at body+16 (epilogue first word).
    try testing.expectEqual(@as(u32, inst.encAddImm12(31, 31, 16)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: 3 locals — frame rounds up to 32 bytes (3*8=24 → align to 32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{ .i32, .i32, .i32 };
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(true);
    // SUB SP, SP, #32 (3*8=24 → aligned 32) at body0 - 4.
    try testing.expectEqual(@as(u32, inst.encSubImm12(31, 31, 32)), std.mem.readInt(u32, out.bytes[body0 - 4 ..][0..4], .little));
    // local.set 2 → STR at offset 2*8=16 at body+4.
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 16)),   std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    // local.get 2 → LDR at body+8.
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 16)),   std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: local.tee writes to local but keeps value pushed" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{.i32};
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.tee", .payload = 0 });
    // After tee, vreg0 still on stack. end consumes it.
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Stream: STP / MOV-FP / SUB-SP / MOVZ W9 #42 / STR W9 [SP,#0] /
    //         MOV X0 X9 / ADD-SP / LDP / RET = 9 u32s = 36 bytes.
    try testing.expectEqual(@as(usize, 60), out.bytes.len);
    const body0 = prologue.body_start_offset(true);
    // STR (the tee) at body+4.
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    // MOV X0, X9 (kept value, then end consumes it) at body+8.
    try testing.expectEqual(@as(u32, 0xAA0903E0), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i64.const small value emits single MOVZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 42, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // Single MOVZ X9, #42 at body+0.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
}

test "compile: i64.const 0xCAFEBABEDEADBEEF emits MOVZ + 3 MOVK lanes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 0xCAFEBABEDEADBEEF: low_32=0xDEADBEEF, high_32=0xCAFEBABE.
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEADBEEF, .extra = 0xCAFEBABE });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // MOVZ #BEEF / MOVK #DEAD lsl 16 / MOVK #BABE lsl 32 / MOVK #CAFE lsl 48 at body+0,4,8,12.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0xBEEF)),       std.mem.readInt(u32, out.bytes[body0..][0..4],         .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xDEAD, 1)),    std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4],    .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xBABE, 2)),    std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],    .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xCAFE, 3)),    std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4],   .little));
}

test "compile: i64.add / sub / mul / and / or / xor each emit X-variant ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i64.add", .want_word_at_offset = inst.encAddReg(9, 9, 10) },
        .{ .op = .@"i64.sub", .want_word_at_offset = inst.encSubReg(9, 9, 10) },
        .{ .op = .@"i64.mul", .want_word_at_offset = inst.encMulReg(9, 9, 10) },
        .{ .op = .@"i64.and", .want_word_at_offset = inst.encAndReg(9, 9, 10) },
        .{ .op = .@"i64.or",  .want_word_at_offset = inst.encOrrReg(9, 9, 10) },
        .{ .op = .@"i64.xor", .want_word_at_offset = inst.encEorReg(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    }
}

test "compile: i64 cmp ops each emit CMP-X + CSET-W with the right Cond mapping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"i64.eq",   .want_cond = .eq },
        .{ .op = .@"i64.ne",   .want_cond = .ne },
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
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        try testing.expectEqual(@as(u32, inst.encCmpRegX(9, 10)),        std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],  .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    }
}

test "compile: i64 shifts emit X-variant LSLV/LSRV/ASRV/RORV" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i64.shl",   .want_word_at_offset = inst.encLslvRegX(9, 9, 10) },
        .{ .op = .@"i64.shr_s", .want_word_at_offset = inst.encAsrvRegX(9, 9, 10) },
        .{ .op = .@"i64.shr_u", .want_word_at_offset = inst.encLsrvRegX(9, 9, 10) },
        .{ .op = .@"i64.rotr",  .want_word_at_offset = inst.encRorvRegX(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    }
}

test "compile: i64.rotl emits 3-instr X-variant NEG-via-MOVZ-#64-SUB + RORV" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 4, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.rotl" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 4 prologue+const u32s (16 bytes):
    // MOVZ X16, #64 / SUB X16, X16, X10 / RORV X9, X9, X16.
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 64)),    std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encSubReg(16, 16, 10)),   std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encRorvRegX(9, 9, 16)),   std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: i64.clz emits direct CLZ X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encClzX(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: i64.ctz emits RBIT-X + CLZ-X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0x100, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.ctz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encRbitX(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encClzX(9, 9)),  std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i64.popcnt emits FMOV-D + CNT/ADDV/UMOV V-register pattern" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.popcnt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-X9 (12 bytes):
    // FMOV D31, X9 / CNT V31.8B / ADDV B31 / UMOV W9.
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encFmovDtoFromX(31, 9)),     std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encCntV8B(31, 31)),          std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encAddvB8B(31, 31)),         std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encUmovWFromVB0(9, 31)),     std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: f32.const emits emitConstU32 + FMOV S, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0f bits = 0x3F800000.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8 bytes): MOVZ + MOVK (lo=0x0000, hi=0x3F80)
    // — but lo=0 so just MOVK fires? No wait: emitConstU32 always
    // emits MOVZ (low 16) and conditionally MOVK (high 16). For
    // 0x3F800000: low 16 = 0x0000, high 16 = 0x3F80. MOVZ #0; MOVK
    // #0x3F80 lsl 16; FMOV S16, W9.
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0)),       std.mem.readInt(u32, out.bytes[body0..][0..4],         .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x3F80, 1)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4],    .little));
    try testing.expectEqual(@as(u32, inst.encFmovStoFromW(16, 9)),    std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],    .little));
    // end with f32 result → FMOV S0, S16 = 0x1E204000 | (16<<5) = 0x1E204200.
    try testing.expectEqual(@as(u32, 0x1E204200),                     std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4],   .little));
}

test "compile: f32 binary ALU each emits S-form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"f32.add", .want_word_at_offset = inst.encFAddS(16, 16, 17) },
        .{ .op = .@"f32.sub", .want_word_at_offset = inst.encFSubS(16, 16, 17) },
        .{ .op = .@"f32.mul", .want_word_at_offset = inst.encFMulS(16, 16, 17) },
        .{ .op = .@"f32.div", .want_word_at_offset = inst.encFDivS(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // Each f32.const emits MOVZ + MOVK + FMOV (3 u32s = 12 bytes).
        // After 2 consts (24 bytes), FP ALU fires.
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    }
}

test "compile: f32 cmps each emit FCMP-S + CSET-W with right Cond" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
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
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // FCMP at body+24; CSET at body+28.
        try testing.expectEqual(@as(u32, inst.encFCmpS(16, 17)),         std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    }
}

test "compile: f32 unary ops + min/max each emit correct encoding" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    const Case = struct {
        op: zir.ZirOp,
        binary: bool,
        want_word_at_offset: u32,
    };
    const cases = [_]Case{
        .{ .op = .@"f32.abs",     .binary = false, .want_word_at_offset = inst.encFAbsS(16, 16) },
        .{ .op = .@"f32.neg",     .binary = false, .want_word_at_offset = inst.encFNegS(16, 16) },
        .{ .op = .@"f32.sqrt",    .binary = false, .want_word_at_offset = inst.encFSqrtS(16, 16) },
        .{ .op = .@"f32.ceil",    .binary = false, .want_word_at_offset = inst.encFRintPS(16, 16) },
        .{ .op = .@"f32.floor",   .binary = false, .want_word_at_offset = inst.encFRintMS(16, 16) },
        .{ .op = .@"f32.trunc",   .binary = false, .want_word_at_offset = inst.encFRintZS(16, 16) },
        .{ .op = .@"f32.nearest", .binary = false, .want_word_at_offset = inst.encFRintNS(16, 16) },
        .{ .op = .@"f32.min",     .binary = true,  .want_word_at_offset = inst.encFMinS(16, 16, 17) },
        .{ .op = .@"f32.max",     .binary = true,  .want_word_at_offset = inst.encFMaxS(16, 16, 17) },
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
            try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        } else {
            try f.instrs.append(testing.allocator, .{ .op = c.op });
            ranges_buf[0] = .{ .def_pc = 0, .last_use_pc = 1 };
            ranges_buf[1] = .{ .def_pc = 1, .last_use_pc = 2 };
            try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        }
        f.liveness = .{ .ranges = if (c.binary) ranges_buf[0..3] else ranges_buf[0..2] };
        const slots_binary = [_]u8{ 0, 1, 0 };
        const slots_unary = [_]u8{ 0, 0 };
        const alloc: regalloc.Allocation = if (c.binary)
            .{ .slots = &slots_binary, .n_slots = 2 }
        else
            .{ .slots = &slots_unary, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // For unary: 1 const = 3 u32s (MOVZ + MOVK + FMOV S) → body+12.
        // For binary: 2 consts = 6 u32s → body+24.
        const op_offset: usize = body0 + (if (c.binary) @as(usize, 24) else 12);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[op_offset..op_offset + 4][0..4], .little));
    }
}

test "compile: block + br 0 + end — forward unconditional branch fixup" {
    // (block (i32.const 7) (br 0) (i32.const 99) end (i32.const 1) end)
    // The br skips the second i32.const; the third lands as the
    // returned value (just to keep the func valid). For sub-e1
    // skeleton, just check the bytes — no execution.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 5 },  // dropped at br but tracked
        .{ .def_pc = 4, .last_use_pc = 5 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #7         (i32.const 7)
    // [12]  B + (forward, patched)  ← block-end fixup
    // [16]  MOVZ W9 #1         (i32.const 1, after block)
    // [20]  MOV X0, X9
    // [24]  LDP, RET ...
    //
    // Verify the B at body+4 points 1 word forward.
    const body0 = prologue.body_start_offset(false);
    const b_word = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encB(1)), b_word);
}

test "compile: loop + br 0 + end — backward unconditional branch" {
    // (loop (br 0) end (i32.const 1) end) — infinite-loop pattern
    // (the loop's br targets the loop's start). Verify the B's
    // disp is negative.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 3, .last_use_pc = 4 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Loop entry recorded at body0; br targets it from body0 → disp = 0 words.
    // Then end (no-op for loop), then i32.const W9 #1, MOV X0, ...
    const body0 = prologue.body_start_offset(false);
    const b_word = std.mem.readInt(u32, out.bytes[body0..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encB(0)), b_word);
}

test "compile: if (i32.const N) end — single-arm if; CBZ skips to end" {
    // (i32.const 1) (if) (i32.const 7) (end) (i32.const 99) (end)
    // The if takes the cond from the const 1, and unconditionally
    // executes its then-body (i32.const 7) since 1 != 0. We're
    // testing the byte layout, not execution.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });   // closes if
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });   // closes function
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },  // cond
        .{ .def_pc = 2, .last_use_pc = 3 },  // then-body's const
        .{ .def_pc = 4, .last_use_pc = 5 },  // post-if
    } };
    const slots = [_]u8{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                     (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #1               (cond)
    // [12]  CBZ  W9, +2 (= byte 20)  (if-skip; patched at end)
    // [16]  MOVZ W9 #7               (then-body)
    // [20]  MOVZ W9 #99              (post-if; if's `end` lands here)
    // CBZ disp = 2 words. CBZ lives at body+4.
    const body0 = prologue.body_start_offset(false);
    const cbz = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encCbzW(9, 2)), cbz);
}

test "compile: if/else/end — CBZ skips to else; B-uncond skips to end" {
    // (i32.const 0) (if) (i32.const 7) (else) (i32.const 99) (end) (end)
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"else" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });   // closes if
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });   // closes function
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },  // cond
        .{ .def_pc = 2, .last_use_pc = 3 },  // then-body
        .{ .def_pc = 4, .last_use_pc = 6 },  // else-body
    } };
    const slots = [_]u8{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0   (cond)
    // [12]  CBZ  W9, ?   (patched at `else` to skip then-body)
    // [16]  MOVZ W9 #7   (then-body)
    // [20]  B    ?       (skip else-body; patched at `end`)
    // [24]  MOVZ W9 #99  (else-body; CBZ patched to here)
    // [28]  ...           (if's `end` lands here; B patched to here)
    //
    // CBZ disp = 3 words; B disp = 2 words.
    const body0 = prologue.body_start_offset(false);
    const cbz = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4],  .little);
    const b   = std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encCbzW(9, 3)), cbz);
    try testing.expectEqual(@as(u32, inst.encB(2)),       b);
}

test "compile: i32.load — emits zero-extend + bounds-check + LDR W reg-offset + trap stub" {
    // (i32.const 8) (i32.load offset=4) end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },  // addr
        .{ .def_pc = 1, .last_use_pc = 2 },  // load result
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ-W9 (body+0..4), load sequence at body+4:
    //  ORR W16, WZR, W9 / ADD X16,X16,#4 / CMP X16,X27 / B.HS trap / LDR W9,[X28,X16].
    try testing.expectEqual(@as(u32, inst.encOrrRegW(16, 31, 9)),  std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encAddImm12(16, 16, 4)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(16, 27)),     std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLdrWReg(9, 28, 16)),  std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    // Trap stub: MOVZ W17,#1 (body+36) etc.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(17, 1)),    std.mem.readInt(u32, out.bytes[body0 + 36 ..][0..4], .little));
    // B.HS placeholder is patched to point at the trap stub start.
    const bhs_patched = std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little);
    // The exact disp depends on byte layout; verify the cond field
    // is .hs (low 4 bits == 0x2) and the placeholder is now a
    // valid B.cond instruction.
    try testing.expectEqual(@as(u32, 0x2), bhs_patched & 0xF);
    try testing.expectEqual(@as(u32, 0x54000000), bhs_patched & 0xFF000010);
}

test "compile: memory ops dispatch correctly per variant" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_load_word: u32 }{
        .{ .op = .@"i32.load8_u",  .want_load_word = inst.encLdrbWReg(9, 28, 16) },
        .{ .op = .@"i32.load8_s",  .want_load_word = inst.encLdrsbWReg(9, 28, 16) },
        .{ .op = .@"i32.load16_u", .want_load_word = inst.encLdrhWReg(9, 28, 16) },
        .{ .op = .@"i32.load16_s", .want_load_word = inst.encLdrshWReg(9, 28, 16) },
        .{ .op = .@"i64.load",     .want_load_word = inst.encLdrXReg(9, 28, 16) },
        .{ .op = .@"i64.load8_s",  .want_load_word = inst.encLdrsbXReg(9, 28, 16) },
        .{ .op = .@"i64.load16_s", .want_load_word = inst.encLdrshXReg(9, 28, 16) },
        .{ .op = .@"i64.load32_s", .want_load_word = inst.encLdrswXReg(9, 28, 16) },
        .{ .op = .@"i64.load32_u", .want_load_word = inst.encLdrWReg(9, 28, 16) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op, .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u8{ 0, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // After MOVZ W9 + ORR W16 + (no ADD: offset=0) + CMP + B.HS,
        // the LDR sits at body+16.
        try testing.expectEqual(c.want_load_word, std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    }
}

test "compile: f32.load + f64.load dispatch to S/D-form LDR" {
    const sig_s: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    const sig_d: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    const cases = [_]struct { op: zir.ZirOp, sig: zir.FuncType, want_load_word: u32 }{
        .{ .op = .@"f32.load", .sig = sig_s, .want_load_word = inst.encLdrSReg(16, 28, 16) },
        .{ .op = .@"f64.load", .sig = sig_d, .want_load_word = inst.encLdrDReg(16, 28, 16) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, c.sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op, .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u8{ 0, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        try testing.expectEqual(c.want_load_word, std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    }
}

test "compile: memory.size emits LSR W_dest, W27, #16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.size" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // LSR at body+0.
    try testing.expectEqual(@as(u32, inst.encLsrImmW(9, 27, 16)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
}

test "compile: memory.grow emits MOVN W_dest, #0 (skeleton return -1)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });   // delta
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.grow" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // MOVZ W9 #1 (body+0) + MOVN W9 at body+4.
    try testing.expectEqual(@as(u32, inst.encMovnImmW(9, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: i32.store — emits bounds-check + STR W reg-offset" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });   // addr
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });  // value
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store", .payload = 0 });   // offset = 0
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Stream:
    //  [0]  STP / MOV-FP                      (8 bytes)
    //  [8]  MOVZ W9 #8                         (addr)
    // [12]  MOVZ W10 #42                       (value)
    // [16]  ORR W16, WZR, W9                   (zero-extend addr)
    // (offset == 0, no ADD)
    // [20]  CMP X16, X27
    // [24]  B.HS trap (fixup)
    // [28]  STR W10, [X28, X16]
    // [32]  LDP / RET / trap stub ...
    const body0 = prologue.body_start_offset(false);
    // After MOVZ #8 + MOVZ #42 (body+0..8): ORR / CMP / B.HS / STR.
    try testing.expectEqual(@as(u32, inst.encOrrRegW(16, 31, 9)),  std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(16, 27)),     std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encStrWReg(10, 28, 16)), std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
}

test "compile: br_table — emits CMP+B.NE+B chain + default B" {
    // (block               ; outer block 1 (depth 1)
    //   (block             ; inner block 0 (depth 0)
    //     (i32.const 0)    ; index value
    //     (br_table 0 1)   ; case 0 → depth 0, default → depth 1
    //     (i32.const 7)    ; never reached
    //   end)               ; inner end
    //   (i32.const 99)
    // end)                 ; outer end
    // (i32.const 1) (end)  ; func end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Build branch_targets: [0, 1] — case 0 → 0, default → 1.
    try f.branch_targets.append(testing.allocator, 0);
    try f.branch_targets.append(testing.allocator, 1);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_table", .payload = 1, .extra = 0 }); // count=1, start=0
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // inner block end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // outer block end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // func end
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 2, .last_use_pc = 3 },  // index
        .{ .def_pc = 5, .last_use_pc = 6 },  // post-inner block
        .{ .def_pc = 7, .last_use_pc = 8 },  // post-outer block
    } };
    const slots = [_]u8{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0      (index)
    // [12]  CMP W9, #0       (br_table case 0 cmp)
    // [16]  B.NE +2          (skip the next B if not equal)
    // [20]  B  ?             (forward fixup → inner-block end target)
    // [24]  B  ?             (forward fixup → outer-block end / default)
    // [28]  MOVZ W9 #99       ← inner-block-end target lands here
    // [32]  MOVZ W9 #1        ← outer-block-end target lands here
    // CMP at byte 12; B.NE at 16; case-0 B at 20 → +2 = byte 28; default B at 24 → +2 = byte 32.
    const body0 = prologue.body_start_offset(false);
    // After MOVZ #0 (body+0): CMP / B.NE / B(case-0) / B(default).
    try testing.expectEqual(@as(u32, inst.encCmpImmW(9, 0)),  std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encBCond(.ne, 2)),  std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encB(2)),           std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encB(2)),           std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: br_if 0 — forward CBNZ fixup" {
    // (block (i32.const 0) (br_if 0) (i32.const 7) end (i32.const 1) end)
    // br_if 0 reads the cond (0 → no branch, continues to const 7).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_if", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 3, .last_use_pc = 5 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Stream:
    //  [0]  STP                (prologue)
    //  [4]  MOV X29, SP
    //  [8]  MOVZ W9 #0         (i32.const 0 → the cond)
    // [12]  CBNZ W9, +2        (br_if; patched to skip past const 7 → end of block)
    // [16]  MOVZ W9 #7         (i32.const 7)
    // [20]  block end → target lands here
    // CBNZ at body+4, disp_words = 2.
    const body0 = prologue.body_start_offset(false);
    const cbnz = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encCbnzW(9, 2)), cbnz);
}

test "compile: f32.copysign emits 8-instr FMOV/BIC/AND/ORR sequence" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.5f magnitude src + (-2.0f) sign src → expect -1.5f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3FC00000 });  // 1.5
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xC0000000 });  // -2.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After 2 consts (each 3 u32s = 24 bytes), 8-instr copysign sequence at body+24.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 0)),         std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(16, 0x8000, 1)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encFmovWFromS(9, 16)),        std.mem.readInt(u32, out.bytes[body0 + 32 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBicRegW(9, 9, 16)),        std.mem.readInt(u32, out.bytes[body0 + 36 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encFmovWFromS(17, 17)),       std.mem.readInt(u32, out.bytes[body0 + 40 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAndRegW(17, 17, 16)),      std.mem.readInt(u32, out.bytes[body0 + 44 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 9, 17)),        std.mem.readInt(u32, out.bytes[body0 + 48 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encFmovStoFromW(16, 9)),      std.mem.readInt(u32, out.bytes[body0 + 52 ..][0..4], .little));
}

test "compile: f64.copysign emits X-form 8-instr sequence with hw=3 mask" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.5 + (-2.0) f64
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF80000 });  // 1.5
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0xC0000000 });  // -2.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // f64.const 1.5: bits=0x3FF8000000000000. Lanes: l0=0,l1=0,
    // l2=0,l3=0x3FF8. Only l3 nonzero → MOVZ + MOVK lane3 + FMOV D
    // = 3 u32s. Same shape for -2.0. After STP/MOV-FP (8) + 6 u32s
    // (24) = byte 32.
    const body0 = prologue.body_start_offset(false);
    // After 2 consts (24 bytes), 8-instr copysign sequence at body+24.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 0)),         std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(16, 0x8000, 3)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encFmovXFromD(9, 16)),        std.mem.readInt(u32, out.bytes[body0 + 32 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBicRegX(9, 9, 16)),        std.mem.readInt(u32, out.bytes[body0 + 36 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encFmovXFromD(17, 17)),       std.mem.readInt(u32, out.bytes[body0 + 40 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAndReg(17, 17, 16)),       std.mem.readInt(u32, out.bytes[body0 + 44 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(9, 9, 17)),         std.mem.readInt(u32, out.bytes[body0 + 48 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encFmovDtoFromX(16, 9)),      std.mem.readInt(u32, out.bytes[body0 + 52 ..][0..4], .little));
}

test "compile: f64 binary ALU each emits D-form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"f64.add", .want_word_at_offset = inst.encFAddD(16, 16, 17) },
        .{ .op = .@"f64.sub", .want_word_at_offset = inst.encFSubD(16, 16, 17) },
        .{ .op = .@"f64.mul", .want_word_at_offset = inst.encFMulD(16, 16, 17) },
        .{ .op = .@"f64.div", .want_word_at_offset = inst.encFDivD(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        // 1.0 + 2.0 (f64 bits): payload = lo32, extra = hi32.
        try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0x00000000, .extra = 0x3FF00000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0x00000000, .extra = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
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

test "compile: i64.eqz emits CMP-X-imm-0 + CSET EQ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    try testing.expectEqual(@as(u32, inst.encCmpImmX(9, 0)),    std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCsetW(9, .eq)),    std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: function with non-empty params surfaces UnsupportedOp" {
    const params = [_]zir.ValType{.i32};
    const sig: zir.FuncType = .{ .params = &params, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty, &.{}, &.{}));
}

test "compile: i32.eqz emits CMP-imm-0 + CSET EQ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 #0: CMP W9,#0 / CSET W9,EQ at body+4, +8.
    try testing.expectEqual(@as(u32, inst.encCmpImmW(9, 0)),   std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCsetW(9, .eq)),   std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: call N (no-arg skeleton) emits BL placeholder + records fixup + result MOV W_dest, W0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // call func_idx = 7 — a forward callee whose body offset isn't
    // known to compile(); the post-emit linker patches the BL via
    // EmitOutput.call_fixups.
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    // func_sigs[7] = i32-returning, no args.
    var sigs: [8]zir.FuncType = undefined;
    for (&sigs) |*s| s.* = .{ .params = &.{}, .results = &.{} };
    sigs[7] = .{ .params = &.{}, .results = &.{ .i32 } };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(false);
    // Body sequence for `call N` no-args:
    //   ORR X0,XZR,X19 / BL 0 / ORR W9,WZR,W0 (capture i32 result).
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[body0..][0..4],         .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)),                                   std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4],    .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 0)),                       std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],    .little));

    // One fixup recorded with byte_offset = body0+4 (the BL slot)
    // + target_func_idx = 7.
    try testing.expectEqual(@as(usize, 1), out.call_fixups.len);
    try testing.expectEqual(@as(u32, body0 + 4), out.call_fixups[0].byte_offset);
    try testing.expectEqual(@as(u32, 7), out.call_fixups[0].target_func_idx);
}

test "compile: call N — i64 callee result captured via X-form ORR" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{ .{ .params = &.{}, .results = &.{ .i64 } } };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOV X0,X19 + BL: ORR X9,XZR,X0 (X-form for i64) at body+8.
    try testing.expectEqual(@as(u32, inst.encOrrReg(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: call N — f32 callee result captured via FMOV S, S0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{ .{ .params = &.{}, .results = &.{ .f32 } } };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOV X0,X19 + BL: FMOV S16, S0 (f32 slot 0 → V16) at body+8.
    try testing.expectEqual(@as(u32, inst.encFmovSReg(16, 0)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: call N — i32 + i64 args marshalled into W1/X2 (X0=runtime ptr per ADR-0017), result in W0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // (i32.const 7) (i64.const 0xDEADBEEF) call 0  ; callee: (i32, i64) → i32
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEADBEEF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 }, // arg0 i32 → slot 0
        .{ .def_pc = 1, .last_use_pc = 2 }, // arg1 i64 → slot 1
        .{ .def_pc = 2, .last_use_pc = 3 }, // result   → slot 0 (reuses)
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const sigs = [_]zir.FuncType{
        .{ .params = &.{ .i32, .i64 }, .results = &.{ .i32 } },
    };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);

    // Layout (bytes, post-ADR-0017 prologue = 32, sub-2d-ii):
    //   [32..36]  MOVZ W9, #7               ; arg0 → slot 0 → X9
    //   [36..40]  MOVZ X10, #0xBEEF         ; arg1 lo16
    //   [40..44]  MOVK X10, #0xDEAD lsl#16  ; arg1 hi16
    //   [44..48]  ORR W1, WZR, W9           ; marshal arg0 i32 → W1
    //   [48..52]  ORR X2, XZR, X10          ; marshal arg1 i64 → X2
    //   [52..56]  ORR X0, XZR, X19          ; restore runtime_ptr
    //   [56..60]  BL 0                      ; call placeholder
    //   [60..64]  ORR W9, WZR, W0           ; capture i32 result
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 (body+0) + 2-word MOVZ/MOVK X10 (body+4..12):
    // arg-marshal at body+12.. then BL.
    try testing.expectEqual(@as(u32, inst.encOrrRegW(1, 31, 9)),                        std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(2, 31, 10)),                        std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)),  std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)),                                    std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
}

test "compile: call N — f32 + f64 args marshalled into S0/D1" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // f32.const + f64.const + call 0 ; callee: (f32, f64) → f32
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 }); // 2.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 }); // 3.0
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const sigs = [_]zir.FuncType{
        .{ .params = &.{ .f32, .f64 }, .results = &.{ .f32 } },
    };
    const out = try compile(testing.allocator, &f, alloc, &sigs, &.{});
    defer deinit(testing.allocator, out);
    // The two arg-marshal MOVs land just before the BL: search the
    // tail for FMOV S0, S16 + FMOV D1, D17 + BL 0.
    // These are stable within the byte stream irrespective of how
    // the const-load prologue lays out — we locate the BL and walk
    // backwards.
    var bl_off: usize = 0;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        if (std.mem.readInt(u32, out.bytes[p..][0..4], .little) == inst.encBL(0)) {
            bl_off = p;
            break;
        }
    }
    try testing.expect(bl_off >= 12);
    // Layout immediately before BL (post-sub-2d-ii):
    //   [bl_off-12] FMOV S0, S16     ; arg0
    //   [bl_off-8]  FMOV D1, D17     ; arg1
    //   [bl_off-4]  ORR X0, XZR, X19 ; restore runtime_ptr
    try testing.expectEqual(@as(u32, inst.encFmovSReg(0, 16)), std.mem.readInt(u32, out.bytes[bl_off - 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encFmovDReg(1, 17)), std.mem.readInt(u32, out.bytes[bl_off - 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[bl_off - 4 ..][0..4], .little));
}

test "compile: call N — void callee pushes no result vreg" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const sigs = [_]zir.FuncType{ .{ .params = &.{}, .results = &.{} } };
    const out = try compile(testing.allocator, &f, empty, &sigs, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // Body: MOV X0,X19 / BL / (epilogue follows).
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[body0..][0..4],      .little));
    try testing.expectEqual(@as(u32, inst.encBL(0)),                                   std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: call_indirect — bounds (CMP/B.HS) + sig (LDR/CMP/B.NE) + funcptr (LDR-LSL3/BLR)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 3, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    // module_types[3] is what `call_indirect type_idx=3` consults.
    var types: [4]zir.FuncType = undefined;
    for (&types) |*t| t.* = .{ .params = &.{}, .results = &.{} };
    types[3] = .{ .params = &.{}, .results = &.{ .i32 } };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &types);
    defer deinit(testing.allocator, out);

    // Layout (post-sub-2d-ii prologue=32):
    //   [32..36] MOVZ W9, #5                   ; idx const
    //   [36..40] ORR W17, WZR, W9              ; zero-extend idx
    //   [40..44] CMP W17, W25                  ; bounds
    //   [44..48] B.HS trap_stub                ; placeholder
    //   [48..52] LDR W16, [X24, X17, LSL #2]   ; sig load
    //   [52..56] CMP W16, #3                   ; sig compare
    //   [56..60] B.NE trap_stub                ; placeholder
    //   [60..64] LDR X17, [X26, X17, LSL #3]   ; funcptr
    //   [64..68] ORR X0, XZR, X19              ; restore runtime_ptr
    //   [68..72] BLR X17
    //   [72..76] ORR W9, WZR, W0               ; capture
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 #5 (body+0):
    //   ORR W17 / CMP W17,W25 / B.HS / LDR W16 / CMP W16,#3 / B.NE
    //   / LDR X17 / ORR X0,X19 / BLR X17 / ORR W9,W0
    try testing.expectEqual(@as(u32, inst.encOrrRegW(17, 31, 9)),                        std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4],  .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegW(17, 25)),                           std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4],  .little));
    const bhs = std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x2), bhs & 0xF); // cond=.hs
    try testing.expectEqual(@as(u32, inst.encLdrWRegLsl2(16, 24, 17)),                   std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCmpImmW(16, 3)),                            std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    const bne = std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0x1), bne & 0xF); // cond=.ne
    try testing.expectEqual(@as(u32, inst.encLdrXRegLsl3(17, 26, 17)),                   std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)),   std.mem.readInt(u32, out.bytes[body0 + 32 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBLR(17)),                                   std.mem.readInt(u32, out.bytes[body0 + 36 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 0)),                         std.mem.readInt(u32, out.bytes[body0 + 40 ..][0..4], .little));
}

test "compile: i32.wrap_i64 emits MOV W,W (= ORR W, WZR, W)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xCAFE, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ X9, #0xCAFE: ORR W9, WZR, W9 (in-place wrap) at body+4.
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: i64.extend_i32_s emits SXTW X, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFFFFFFFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ + MOVK loading 0xFFFFFFFF into W9 (8 bytes): SXTW X9,W9 at body+8.
    try testing.expectEqual(@as(u32, inst.encSxtw(9, 9)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}

test "compile: i64.extend_i32_u emits MOV W,W (zero-extends via W-write)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 #42: ORR W9, WZR, W9 at body+4.
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: f32.convert_i32_s emits SCVTF S, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ W9 #7: SCVTF S16, W9 at body+4.
    try testing.expectEqual(@as(u32, inst.encScvtfSFromW(16, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: f64.convert_i64_u emits UCVTF D, X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEAD, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.convert_i64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ X9 #0xDEAD: UCVTF D16, X9 at body+4.
    try testing.expectEqual(@as(u32, inst.encUcvtfDFromX(16, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: f32.demote_f64 emits FCVT S, D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.demote_f64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Find FCVT S16, D16 in the byte stream.
    const expected = inst.encFcvtSFromD(16, 16);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.promote_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFcvtDFromS(16, 16);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFcvtzsWFromS(9, 16); // dest W9, src V16
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFcvtzuXFromD(9, 16);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.reinterpret_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFmovWFromS(9, 16);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xCAFE, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.reinterpret_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encFmovDtoFromX(16, 9);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
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
        if (w == inst.encFCmpS(16, 16)) {
            found_fcmp_self = true;
            fcmp_self_count += 1;
        }
        if (w == inst.encFCmpS(16, 31)) fcmp_v31_count += 1;
        if (w == inst.encFcvtzsWFromS(9, 16)) found_fcvtzs = true;
    }
    try testing.expect(found_fcmp_self);
    try testing.expectEqual(@as(u32, 1), fcmp_self_count);  // NaN check is single FCMP self
    try testing.expectEqual(@as(u32, 2), fcmp_v31_count);  // 2 bound checks
    try testing.expect(found_fcvtzs);
}

test "compile: i32.trunc_f64_s emits NaN+f64-lower+f64-upper checks then FCVTZS W,D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f64_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Walk the byte stream looking for the D-form NaN check + 2
    // bounds compares + final FCVTZS.
    var fcmp_self_count: u32 = 0;
    var fcmp_v31_count: u32 = 0;
    var found_fcvtzs = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        const w = std.mem.readInt(u32, out.bytes[p..][0..4], .little);
        if (w == inst.encFCmpD(16, 16)) fcmp_self_count += 1;
        if (w == inst.encFCmpD(16, 31)) fcmp_v31_count += 1;
        if (w == inst.encFcvtzsWFromD(9, 16)) found_fcvtzs = true;
    }
    try testing.expectEqual(@as(u32, 1), fcmp_self_count);
    try testing.expectEqual(@as(u32, 2), fcmp_v31_count);
    try testing.expect(found_fcvtzs);
}

test "compile: ADR-0018 sub-1c — i32.const into spilled vreg, full round-trip via STR + LDR" {
    // Force vreg 0 into spill territory (slot 10). The frame
    // extends by spillBytes() = 8; spill base offset = 0
    // (no locals). i32.const handler emits MOVZ X14 #42 + STR
    // X14, [SP, #0]. end handler emits LDR X14, [SP, #0] + MOV
    // X0, X14. Inspect bytes for these key instructions.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{10};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .max_reg_slots = 10,
    };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Bytes contain (in order): STP+MOVfp + SUB sp,#16 (frame
    // rounded up to 16) + MOVZ X14,#42 + STR X14,[SP] + ORR X0,XZR,X14
    // + ADD sp,#16 + LDP + RET.
    const expected_movz = inst.encMovzImm16(14, 42);
    const expected_str = inst.encStrImm(14, 31, 0);
    const expected_ldr_at_end = inst.encLdrImm(14, 31, 0);

    var saw_movz = false;
    var saw_str = false;
    var saw_ldr_at_end = false;
    var p: usize = 0;
    while (p + 4 <= out.bytes.len) : (p += 4) {
        const w = std.mem.readInt(u32, out.bytes[p..][0..4], .little);
        if (w == expected_movz) saw_movz = true;
        if (w == expected_str) saw_str = true;
        if (w == expected_ldr_at_end) saw_ldr_at_end = true;
    }
    try testing.expect(saw_movz);
    try testing.expect(saw_str);
    try testing.expect(saw_ldr_at_end);
}

test "compile: ADR-0018 — slot 9 = last reg (X23), slot 10 = first spill" {
    const slots_9 = [_]u8{9};
    const alloc_reg: regalloc.Allocation = .{
        .slots = &slots_9,
        .n_slots = 10,
        .max_reg_slots = 10,
    };
    try testing.expectEqual(regalloc.Slot{ .reg = 9 }, alloc_reg.slot(0));

    const slots_10 = [_]u8{10};
    const alloc_spill: regalloc.Allocation = .{
        .slots = &slots_10,
        .n_slots = 11,
        .max_reg_slots = 10,
    };
    try testing.expectEqual(regalloc.Slot{ .spill = 0 }, alloc_spill.slot(0));
}

comptime {
    _ = liveness_mod; // hook upstream module so future regalloc tests are reachable
}
