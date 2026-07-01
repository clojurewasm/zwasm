//! arm64 emit pass — memory load/store + memory.* + global tests.
//!
//! Family scope: i32/i64/f32/f64 .load / .load{8,16,32}_{s,u} /
//! .store / .store{8,16,32}, memory.size / memory.grow,
//! global.get / global.set.
//!
//! Zone 2 (`src/engine/codegen/arm64/`). Pure relocation per
//! ADR-0021 sub-deliverable b; bytes / assertions
//! identical to the pre-split `emit_test.zig`.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const prologue = @import("prologue.zig");
const regalloc = @import("../shared/regalloc.zig");
const jit_abi = @import("../shared/jit_abi.zig");
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
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

// 32-bit offset lowering. emcc/clang -O2 array
// indexing with large constant offsets exceeds the d-6 24-bit cap.
// For offsets > 0xFFFFFF, lower via MOVZ X17, low / MOVK X17, mid /
// ADD X16, X16, X17 (offset stays under 2^32 per the Wasm spec, so
// only lanes 0+1 are needed).

test "compile: memory64 i32.load — X-form addr load (encOrrReg, not encOrrRegW) per ADR-0111 D4" {
    // Same Wasm op (i32.load) as the i32-idx_type test above, but
    // compiled with memory0_idx_type=.i64 → emit dispatches to
    // emitMemOpI64 which uses encOrrReg (X-form, full 64-bit copy)
    // for the address load, vs encOrrRegW (W-form, zero-extends
    // u32) in the i32 fast path. The bounds bytes diverge from the
    // i32 path: ADD imm12 (offset), ADDS imm12 (access_size, sets
    // carry), B.HS wrap-trap, CMP X17,X27, B.HI trap, LDR W reg-offset.
    // (The i32 path can't overflow 64-bit so it keeps the plain ADD.)
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i64, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // body+4: ORR X16, XZR, X9 (X-form, encOrrReg) — i64 path
    // DIVERGENCE from the i32 path's encOrrRegW.
    try testing.expectEqual(@as(u32, inst.encOrrReg(16, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    // body+8: ADD X16,X16,#4 (offset) — same as i32 path.
    try testing.expectEqual(@as(u32, inst.encAddImm12(16, 16, 4)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    // body+12: ADDS X17,X16,#4 (access_size, flag-setting — memory64 wrap check).
    try testing.expectEqual(@as(u32, inst.encAddsImm12(17, 16, 4)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    // body+16: B.HS → oob (carry = ea+size wrapped past 2^64). Not asserted:
    // its disp19 is patched to the trap stub by the fixup pass (same reason
    // the B.HI at body+24 isn't asserted).
    // body+20: CMP X17,X27 (vs mem_limit).
    try testing.expectEqual(@as(u32, inst.encCmpRegX(17, 27)), std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    // body+28: LDR W9, [X28, X16] (the load is W-form regardless of
    // address space; the result is an i32). +4 vs the i32 path: the
    // extra B.HS wrap-trap word.
    try testing.expectEqual(@as(u32, inst.encLdrWReg(9, 28, 16)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
}

test "compile: memory64 i64.load offset=0x100000000 — 4-lane MOVZ+MOVK for u64 offset" {
    // memory64 allows u64 memarg offsets. Offset 2^32 needs lane 2
    // (bits 32..47). i32 path's 2-lane materialise can't reach.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.load", .payload = 0x100000000 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i64, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // body+4: ORR X16, XZR, X<addr> (X-form)
    // Then: offset > 0xFFFFFF → MOVZ + MOVK + ADD sequence.
    // For offset 0x100000000: lane0=0, lane1=0, lane2=1, lane3=0.
    // → MOVZ X17, #0 / MOVK X17, #1 lsl #32 / ADD X16, X16, X17.
    // lane1 == 0 skipped per the `if (lane1 != 0)` guard.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(17, 0)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(17, 1, 2)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encAddReg(16, 16, 17)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
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
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
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
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
        defer deinit(testing.allocator, out);
        const body0 = prologue.body_start_offset(false);
        // Spec-strict bounds adds ADD X17,X16,#size before CMP/B.HI → +4 byte offset.
        try testing.expectEqual(c.want_load_word, std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    }
}

test "compile: memory.size emits LDR page_size_log2 + LSRV W_dest, W27 (custom-page-sizes, ADR-0168 v0.2)" {
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // LDR W16, [X19, #page_size_log2_off] at body+0; LSRV W_dest, W27, W16 at body+4.
    try testing.expectEqual(@as(u32, inst.encLdrImmW(16, abi.runtime_ptr_save_gpr, jit_abi.mem0_page_size_log2_off)), std.mem.readInt(u32, out.bytes[body0..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLsrvRegW(9, 27, 16)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: memory.grow emits BLR-via-memory_grow_fn + X28/X27 reload (ADR-0059)" {
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    const body0 = prologue.body_start_offset(false);
    // Stream from body+0:
    //   MOVZ W9, #1                  ; delta = 1 (i32.const)
    //   ORR W1, WZR, W9              ; marshal W1 ← delta
    //   ORR X0, XZR, X19             ; restore X0 = runtime_ptr
    //   LDR X16, [X19, #memory_grow_fn_off]
    //   BLR X16
    //   LDR X28, [X19, #vm_base_off]
    //   LDR X27, [X19, #mem_limit_off]
    //   ORR W9, WZR, W0              ; capture result vreg ← W0
    try testing.expectEqual(@as(u32, inst.encOrrRegW(1, 31, 9)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.memory_grow_fn_off)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBLR(16)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLdrImm(28, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off)), std.mem.readInt(u32, out.bytes[body0 + 20 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encLdrImm(27, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off)), std.mem.readInt(u32, out.bytes[body0 + 24 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encOrrRegW(9, 31, 0)), std.mem.readInt(u32, out.bytes[body0 + 28 ..][0..4], .little));
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(false);
    // ADR-0027 prescan adds 1 extra prologue word (LDR X23 ← globals_base)
    // so the first body insn shifts by +4 bytes.
    const expected_ldr = inst.encLdrImmW(9, 23, 0); // LDR W9, [X23, #0]
    try testing.expectEqual(expected_ldr, std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
}

test "compile: (i32.const 99) global.set 1 (i32) — emits STR W to [X23 + 16] (post-ADR-0110 stride)" {
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
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    const body0 = prologue.body_start_offset(false);
    // [body0 + 0]: extra LDR X23 prologue word (prescan added)
    // [body0 + 4]: MOVZ W9, #99
    // [body0 + 8]: STR W9, [X23, #16] (fallback stride is *16
    // post-ADR-0110; idx=1 → 16)
    const expected_str = inst.encStrImmW(9, 23, 16);
    try testing.expectEqual(expected_str, std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
}
