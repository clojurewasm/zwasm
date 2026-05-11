//! arm64 emit pass — memory load/store + memory.* + global tests.
//!
//! Family scope: i32/i64/f32/f64 .load / .load{8,16,32}_{s,u} /
//! .store / .store{8,16,32}, memory.size / memory.grow,
//! global.get / global.set.
//!
//! Zone 2 (`src/engine/codegen/arm64/`). Pure relocation per
//! ADR-0021 sub-deliverable b chunk 10; bytes / assertions
//! identical to the pre-split `emit_test.zig`.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const prologue = @import("prologue.zig");
const regalloc = @import("../shared/regalloc.zig");
const emit = @import("emit.zig");

const ZirFunc = zir.ZirFunc;
const compile = emit.compile;
const deinit = emit.deinit;

const testing = std.testing;

test "compile: i32.load — emits zero-extend + bounds-check + LDR W reg-offset + trap stub" {
    // (i32.const 8) (i32.load offset=4) end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // addr
            .{ .def_pc = 1, .last_use_pc = 2 }, // load result
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // After MOVZ-W9 (body+0..4), spec-strict load sequence at body+4:
    //  ORR W16, WZR, W9 / ADD X16,X16,#4 / ADD X17,X16,#4 / CMP X17,X27
    //  / B.HI trap / LDR W9,[X28,X16].
    try testing.expectEqual(@as(u32, inst.encOrrRegW(16, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddImm12(16, 16, 4)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddImm12(17, 16, 4)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(17, 27)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLdrWReg(9, 28, 16)), std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    // Trap stub: MOVZ W17,#1 (body+40) — sequence is +4 longer than pre-spec-strict (one extra ADD).
    try testing.expectEqual(@as(u32, inst.encMovzImm16(17, 1)), std.mem.readInt(u32, out.bytes[body0 + 40 ..][0..4], .little));
    // B.HI placeholder is patched to point at the trap stub start.
    const bhi_patched = std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little);
    // Verify the cond field is .hi (low 4 bits == 0x8) and the placeholder is a valid B.cond.
    try testing.expectEqual(@as(u32, 0x8), bhi_patched & 0xF);
    try testing.expectEqual(@as(u32, 0x54000000), bhi_patched & 0xFF000010);
}

// §9.7 / 7.9-d-14: 32-bit offset lowering. emcc/clang -O2 array
// indexing with large constant offsets exceeds the d-6 24-bit cap.
// For offsets > 0xFFFFFF, lower via MOVZ X17, low / MOVK X17, mid /
// ADD X16, X16, X17 (offset stays under 2^32 per the Wasm spec, so
// only lanes 0+1 are needed).

test "compile: i32.load offset=0x10000000 — MOVZ/MOVK X17 + ADD reg" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0x10000000 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // 0x10000000 split: low_16 = 0x0000, high_16 = 0x1000.
    // Sequence after ORR W16,WZR,W9: MOVZ X17,#0 / MOVK X17,#0x1000 lsl#16
    // / ADD X16,X16,X17. Then ADD X17,X16,#4 / CMP X17,X27 / B.HI / LDR.
    const movz_x17 = inst.encMovzImm16(17, 0x0000);
    const movk_x17_hi = inst.encMovkImm16(17, 0x1000, 1);
    const add_x16_x17 = inst.encAddReg(16, 16, 17);
    var found_movz: bool = false;
    var found_movk: bool = false;
    var found_add: bool = false;
    var i: usize = 0;
    while (i + 4 <= out.bytes.len) : (i += 4) {
        const w = std.mem.readInt(u32, out.bytes[i..][0..4], .little);
        if (w == movz_x17) found_movz = true;
        if (w == movk_x17_hi) found_movk = true;
        if (w == add_x16_x17) found_add = true;
    }
    try testing.expect(found_movz);
    try testing.expect(found_movk);
    try testing.expect(found_add);
}

test "compile: memory ops dispatch correctly per variant" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const cases = [_]struct { op: zir.ZirOp, want_load_word: u32 }{
        .{ .op = .@"i32.load8_u", .want_load_word = inst.encLdrbWReg(9, 28, 16) },
        .{ .op = .@"i32.load8_s", .want_load_word = inst.encLdrsbWReg(9, 28, 16) },
        .{ .op = .@"i32.load16_u", .want_load_word = inst.encLdrhWReg(9, 28, 16) },
        .{ .op = .@"i32.load16_s", .want_load_word = inst.encLdrshWReg(9, 28, 16) },
        .{ .op = .@"i64.load", .want_load_word = inst.encLdrXReg(9, 28, 16) },
        .{ .op = .@"i64.load8_s", .want_load_word = inst.encLdrsbXReg(9, 28, 16) },
        .{ .op = .@"i64.load16_s", .want_load_word = inst.encLdrshXReg(9, 28, 16) },
        .{ .op = .@"i64.load32_s", .want_load_word = inst.encLdrswXReg(9, 28, 16) },
        .{ .op = .@"i64.load32_u", .want_load_word = inst.encLdrWReg(9, 28, 16) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op, .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u16{ 0, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // After MOVZ W9 + ORR W16 + (no ADD: offset=0) + ADD X17,X16,#size
        // + CMP X17 + B.HI, the LDR sits at body+20 (spec-strict bounds).
        try testing.expectEqual(c.want_load_word, std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    }
}

test "compile: f32.load + f64.load dispatch to S/D-form LDR" {
    const sig_s: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    const sig_d: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    const cases = [_]struct { op: zir.ZirOp, sig: zir.FuncType, want_load_word: u32 }{
        .{ .op = .@"f32.load", .sig = sig_s, .want_load_word = inst.encLdrSReg(16, 28, 16) },
        .{ .op = .@"f64.load", .sig = sig_d, .want_load_word = inst.encLdrDReg(16, 28, 16) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, c.sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op, .payload = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u16{ 0, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // Spec-strict bounds adds ADD X17,X16,#size before CMP/B.HI → +4 byte offset.
        try testing.expectEqual(c.want_load_word, std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    }
}

test "compile: memory.size emits LSR W_dest, W27, #16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.size" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // LSR at body+0.
    try testing.expectEqual(@as(u32, inst.encLsrImmW(9, 27, 16)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
}

test "compile: memory.grow emits MOVN W_dest, #0 (skeleton return -1)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 }); // delta
    try f.instrs.append(testing.allocator, .{ .op = .@"memory.grow" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // MOVZ W9 #1 (body+0) + MOVN W9 at body+4.
    try testing.expectEqual(@as(u32, inst.encMovnImmW(9, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: i32.store — emits bounds-check + STR W reg-offset" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 }); // addr
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 }); // value
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store", .payload = 0 }); // offset = 0
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
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
    // After MOVZ #8 + MOVZ #42 (body+0..8): ORR / ADD X17,X16,#4 / CMP X17 / B.HI / STR.
    try testing.expectEqual(@as(u32, inst.encOrrRegW(16, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddImm12(17, 16, 4)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encCmpRegX(17, 27)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encStrWReg(10, 28, 16)), std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
}

test "compile: global.get 0 (i32) — emits LDR W from [X23 + 0]" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"global.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(false);
    // ADR-0027 prescan adds 1 extra prologue word (LDR X23 ← globals_base)
    // so the first body insn shifts by +4 bytes.
    const expected_ldr = inst.encLdrImmW(9, 23, 0); // LDR W9, [X23, #0]
    try testing.expectEqual(expected_ldr, std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: (i32.const 99) global.set 1 (i32) — emits STR W to [X23 + 8]" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{});
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(false);
    // [body0 + 0]: extra LDR X23 prologue word (prescan added)
    // [body0 + 4]: MOVZ W9, #99
    // [body0 + 8]: STR W9, [X23, #8]
    const expected_str = inst.encStrImmW(9, 23, 8);
    try testing.expectEqual(expected_str, std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}
