//! arm64 emit pass — control-flow tests.
//!
//! Family scope: block / loop / if / else / end, br / br_if /
//! br_table forward + backward fixups.
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

test "compile: block + br 0 + end — forward unconditional branch fixup" {
    // (block (i32.const 7) (br 0) (i32.const 99) end (i32.const 1) end)
    // The br skips the second i32.const; the third lands as the
    // returned value (just to keep the func valid). For sub-e1
    // skeleton, just check the bytes — no execution.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .br, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 1, .last_use_pc = 5 }, // dropped at br but tracked
            .{ .def_pc = 4, .last_use_pc = 5 },
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .loop });
    try f.instrs.append(testing.allocator, .{ .op = .br, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 3, .last_use_pc = 4 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // closes if
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // closes function
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // cond
            .{ .def_pc = 2, .last_use_pc = 3 }, // then-body's const
            .{ .def_pc = 4, .last_use_pc = 5 }, // post-if
        },
    };
    const slots = [_]u16{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"else" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // closes if
    try f.instrs.append(testing.allocator, .{ .op = .end }); // closes function
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // cond
            .{ .def_pc = 2, .last_use_pc = 3 }, // then-body
            .{ .def_pc = 4, .last_use_pc = 6 }, // else-body
        },
    };
    const slots = [_]u16{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32);
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
    const cbz = std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little);
    const b = std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little);
    try testing.expectEqual(@as(u32, inst.encCbzW(9, 3)), cbz);
    try testing.expectEqual(@as(u32, inst.encB(2)), b);
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Build branch_targets: [0, 1] — case 0 → 0, default → 1.
    try f.branch_targets.append(testing.allocator, 0);
    try f.branch_targets.append(testing.allocator, 1);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .br_table, .payload = 1, .extra = 0 }); // count=1, start=0
    try f.instrs.append(testing.allocator, .{ .op = .end }); // inner block end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // outer block end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // func end
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 2, .last_use_pc = 3 }, // index
            .{ .def_pc = 5, .last_use_pc = 6 }, // post-inner block
            .{ .def_pc = 7, .last_use_pc = 8 }, // post-outer block
        },
    };
    const slots = [_]u16{ 0, 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32);
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
    try testing.expectEqual(@as(u32, inst.encCmpImmW(9, 0)), std.mem.readInt(u32, out.bytes[body0 + 4 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encBCond(.ne, 2)), std.mem.readInt(u32, out.bytes[body0 + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encB(2)), std.mem.readInt(u32, out.bytes[body0 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, inst.encB(2)), std.mem.readInt(u32, out.bytes[body0 + 16 ..][0..4], .little));
}

test "compile: br_if 0 — forward CBNZ fixup" {
    // (block (i32.const 0) (br_if 0) (i32.const 7) end (i32.const 1) end)
    // br_if 0 reads the cond (0 → no branch, continues to const 7).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .br_if, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 3, .last_use_pc = 5 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32);
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
