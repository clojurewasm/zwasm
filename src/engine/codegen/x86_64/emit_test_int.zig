// FILE-SIZE-EXEMPT: per-op JIT-emit test catalog; P2 pure-data dominance (test blocks) (per ADR-0099)
//! x86_64 emit pass — i32/i64 + control/memory/calls test family
//! (D-051 follow-up split per ADR-0030). Tests for floating-point
//! ops live in the sibling `emit_test_float.zig`. Both files are
//! discovered by the runner via `emit_test.zig`'s aggregator.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const prologue = @import("prologue.zig");

const emit = @import("emit.zig");
const compile = emit.compile;
const deinit = emit.deinit;
const Error = emit.Error;
const localDisp = emit.localDisp;

const ZirFunc = zir.ZirFunc;
const Allocator = std.mem.Allocator;
const testing = std.testing;

test "compile: empty body without liveness errors AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false));
}

test "compile: empty function (no instrs) emits prologue only" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // Prologue only: 55 48 89 E5 = 4 bytes (push rbp + mov rbp, rsp).
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x48, 0x89, 0xE5 }, out.bytes);
}

test "compile: (i32.const 42) end → 13 bytes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream (slot 0 = RBX after pool shrink — chunk 13b):
    //   55                       PUSH RBP
    //   48 89 E5                 MOV RBP, RSP
    //   BB 2A 00 00 00           MOV EBX, #42 (slot 0 = RBX)
    //   89 D8                    MOV EAX, EBX (return marshalling)
    //   5D                       POP RBP
    //   C3                       RET
    // Total: 1 + 3 + 5 + 2 + 1 + 1 = 13 bytes.
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x2A,
        0x00,
        0x00,
        0x00,
        0x89,
        0xD8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 0xDEADBEEF) end — little-endian imm32" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // Differs from the 42 case only at the imm32 bytes. The imm32 follows the
    // 4-byte prologue + 1-byte MOV-EBX opcode (0xBB) → starts at offset 5.
    try testing.expectEqual(@as(usize, 13), out.bytes.len);
    // D-055 migration: imm32 = body_start (4) + 1-byte MOV-EBX opcode (0xBB).
    const imm32_off = prologue.body_start_offset(false, 0) + 1;
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, out.bytes[imm32_off .. imm32_off + 4]);
}

test "compile: void function with `end` only emits prologue + epilogue" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // 55 48 89 E5 5D C3 = 6 bytes (prologue + pop + ret; no return marshalling).
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x48, 0x89, 0xE5, 0x5D, 0xC3 }, out.bytes);
}

test "compile: function with 1 local + (i32.const 42) (local.set 0) (local.get 0) end" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &[_]zir.ValType{.i32});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // const
            .{ .def_pc = 2, .last_use_pc = 3 }, // local.get result
        },
    };
    const slots = [_]u16{ 0, 1 }; // R10D, R11D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream (slot 0 = RBX, slot 1 = R12 after pool shrink — chunk 13b):
    //   55 48 89 E5                    PUSH RBP ; MOV RBP, RSP
    //   48 83 EC 10                    SUB RSP, 16            (1 local → 16 aligned)
    //   BB 2A 00 00 00                 MOV EBX, #42           (const, slot 0 = RBX)
    //   89 5D F8                       MOV [RBP-8], EBX       (local.set 0)
    //   44 8B 65 F8                    MOV R12D, [RBP-8]      (local.get 0; slot 1 = R12)
    //   31 C0                          XOR EAX, EAX        (zero-init §4.5.3.1)
    //   48 89 45 F8                    MOV [RBP-8], RAX    (zero local 0)
    //   BB 2A 00 00 00                 MOV EBX, 42
    //   89 5D F8                       MOV [RBP-8], EBX
    //   44 8B 65 F8                    MOV R12D, [RBP-8]
    //   44 89 E0                       MOV EAX, R12D
    //   48 83 C4 10                    ADD RSP, 16
    //   5D                             POP RBP
    //   C3                             RET
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0x48,
        0x83,
        0xEC,
        0x10,
        0x31,
        0xC0,
        0x48,
        0x89,
        0x45,
        0xF8,
        0xBB,
        0x2A,
        0x00,
        0x00,
        0x00,
        0x89,
        0x5D,
        0xF8,
        0x44,
        0x8B,
        0x65,
        0xF8,
        0x44,
        0x89,
        0xE0,
        0x48,
        0x83,
        0xC4,
        0x10,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: local.tee preserves stack — uses top vreg without popping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &[_]zir.ValType{.i32});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.tee", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    } };
    const slots = [_]u16{0}; // R10D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // local.tee writes [RBP-8] but doesn't pop, so the top vreg
    // (slot 0 = RBX after chunk 13b pool shrink) is still on the stack
    // for the `end` to marshal into EAX.
    // Expected: prologue(4) + SUB(4) + zero-init(6) + MOV EBX #7 (5)
    // + MOV [RBP-8] EBX (3) + MOV EAX EBX (2) + ADD RSP + POP RBP + RET.
    // Spot-check: STORE [RBP-8] EBX = 89 5D F8 at offset 19..22,
    // followed by MOV EAX, EBX = 89 D8 at 22..24.
    // D-055 migration: prologue size sourced from body_start_offset()
    // (false, 8) → 8; + zero-init (6) + MOV EBX (5) = 19.
    const body_start = prologue.body_start_offset(false, 8);
    const store_off = body_start + 6 + 5;
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x5D, 0xF8 }, out.bytes[store_off .. store_off + 3]);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0xD8 }, out.bytes[store_off + 3 .. store_off + 5]);
}

test "compile: (block (br 0) end) end — forward br with end-patch" {
    // Empty block with br to its own end. Then function-end.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .br, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // intra: closes block
    try f.instrs.append(testing.allocator, .{ .op = .end }); // function-level
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                    prologue (no SUB RSP — no locals)
    //   E9 00 00 00 00                 JMP rel32, patched to disp=0 (target = next byte)
    //   5D                             POP RBP (function-level end)
    //   C3                             RET
    // The JMP's disp is 0 because the patch site is at offset 4
    // (after prologue) + insn_size 5 → next instruction at offset 9,
    // which IS the block's end target. Disp = 9 - 9 = 0.
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xE9,
        0x00,
        0x00,
        0x00,
        0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (loop (br 0) end) end — backward br with concrete disp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .loop });
    try f.instrs.append(testing.allocator, .{ .op = .br, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end }); // intra: closes loop (no patch)
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // loop captures byte_offset = 4 (post-prologue). br at offset 4
    // emits JMP with disp = 4 - 4 - 5 = -5. So bytes:
    //   55 48 89 E5                    prologue
    //   E9 FB FF FF FF                 JMP -5 (back to loop entry — infinite loop)
    //   5D C3                          POP RBP ; RET (unreachable but emitted)
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xE9,
        0xFB,
        0xFF,
        0xFF,
        0xFF,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 1) (if) (i32.const 7) (end) end — single-arm if; JE patched" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected layout (slot 0 = RBX, slot 1 = R12 after chunk 13b pool shrink):
    //   55 48 89 E5                    prologue              [0..4]
    //   BB 01 00 00 00                 MOV EBX, #1           [4..9]
    //   85 DB                          TEST EBX, EBX         [9..11]
    //   0F 84 06 00 00 00              JE +6 (skip then-body) [11..17]
    //   41 BC 07 00 00 00              MOV R12D, #7          [17..23]
    //   5D                             POP RBP               [23]
    //   C3                             RET                   [24]
    // JE disp = 23 - 17 = 6 (skip from after JE to past then-body's
    // i32.const 7). Then-body is 6 bytes (MOV R12D #7).
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x01,
        0x00,
        0x00,
        0x00,
        0x85,
        0xDB,
        0x0F,
        0x84,
        0x06,
        0x00,
        0x00,
        0x00,
        0x41,
        0xBC,
        0x07,
        0x00,
        0x00,
        0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (block (i32.const 0) (br_if 0) end) end — Jcc forward fixup" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .br_if, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected (slot 0 = RBX after chunk 13b pool shrink):
    //   55 48 89 E5                    prologue              [0..4]
    //   BB 00 00 00 00                 MOV EBX, #0           [4..9]
    //   85 DB                          TEST EBX, EBX         [9..11]
    //   0F 85 00 00 00 00              JNE +0 (block-end)    [11..17] disp = 17-17 = 0
    //   5D C3                          POP RBP ; RET         [17..19]
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x00,
        0x00,
        0x00,
        0x00,
        0x85,
        0xDB,
        0x0F,
        0x85,
        0x00,
        0x00,
        0x00,
        0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (loop (i32.const 0) (br_if 0) end) end — Jcc backward concrete disp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .loop });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .br_if, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // loop entry at offset 4 (post-prologue). After chunk 13b pool shrink,
    // br_if Jcc at offset 11; disp = 4 - 11 - 6 = -13 = 0xFFFFFFF3.
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x00,
        0x00,
        0x00,
        0x00,
        0x85,
        0xDB,
        0x0F,
        0x85,
        0xF3,
        0xFF,
        0xFF,
        0xFF,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: br_table — single case + default both → block end" {
    // (block (i32.const 0) (br_table 1 0 0) end) end
    // count=1, case 0 → block (depth 0), default → block (depth 0).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.branch_targets.append(testing.allocator, 0); // case 0 depth
    try f.branch_targets.append(testing.allocator, 0); // default depth
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .br_table, .payload = 1, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream (slot 0 = RBX after chunk 13b pool shrink):
    //   55 48 89 E5                    prologue              [0..4]
    //   BB 00 00 00 00                 MOV EBX, #0           [4..9]
    //   83 FB 00                       CMP EBX, 0            [9..12]
    //   75 05                          JNE +5 (skip JMP)     [12..14]
    //   E9 05 00 00 00                 JMP case-0 → block end (forward fixup; patched to disp=5) [14..19]
    //   E9 00 00 00 00                 JMP default → block end (forward fixup; patched to disp=0) [19..24]
    //   5D C3                          POP RBP ; RET         [24..26]
    // Block end target = 24. case JMP at 14 → disp=24-14-5=5. default JMP at 19 → disp=24-19-5=0.
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x00,
        0x00,
        0x00,
        0x00,
        0x83,
        0xFB,
        0x00,
        0x75,
        0x05,
        0xE9,
        0x05,
        0x00,
        0x00,
        0x00,
        0xE9,
        0x00,
        0x00,
        0x00,
        0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: br_table count > 127 — wide case path (rel32 / imm32) compiles" {
    // §9.9 / 9.9-l-1b-d093-d45 (D-118): pre-d-45 the x86_64
    // emitBrTable rejected `count > 127` outright (CMP imm8 / JNE
    // rel8 limits). br_table.wast `large` declares 16149 targets;
    // d-45 dispatches per-case on `i ≤ 127`: small cases keep the
    // imm8/rel8 fast path, large cases use `CMP r32, imm32` +
    // `Jcc rel32`. Test confirms the wide path compiles.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < 129) : (i += 1) try f.branch_targets.append(testing.allocator, 0);
    try f.instrs.append(testing.allocator, .{ .op = .block });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .br_table, .payload = 128, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer testing.allocator.free(out.bytes);
    try testing.expect(out.bytes.len > 0);
}

test "compile: (i32.const 0) i32.load offset=0 end — ADR-0026 prologue + bounds check + load" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // const → idx
            .{ .def_pc = 1, .last_use_pc = 2 }, // load result
        },
    };
    const slots = [_]u16{ 0, 1 }; // R10D, R11D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // ADR-0026 prologue (uses_runtime_ptr=true):
    //   55                          PUSH RBP                          [0]
    //   41 57                       PUSH R15                          [1..3]
    //   48 89 E5                    MOV RBP, RSP                      [3..6]
    //   49 89 FF                    MOV R15, RDI                      [6..9]
    //   48 83 EC 08                 SUB RSP, 8 (locals=0 → frame=8)   [9..13]
    // Body (slot 0 = RBX, slot 1 = R12 after chunk 13b pool shrink):
    //   BB 00 00 00 00              MOV EBX, #0   (idx vreg 0)        [13..18]
    //   49 8B 87 00 00 00 00        MOV RAX, [R15 + 0] (vm_base)      [18..25]
    //   89 DA                       MOV EDX, EBX (zero-extend idx)    [25..27]
    //   48 8D 4A 04                 LEA RCX, [RDX + 4] (ea + size=4)  [27..31]
    //   49 3B 8F 08 00 00 00        CMP RCX, [R15 + 8]                [31..38]
    //   0F 87 ?? ?? ?? ??           JA trap_stub (placeholder)        [38..44]
    //   44 8B 24 10                 MOV R12D, [RAX + RDX]             [44..48]
    //   44 89 E0                    MOV EAX, R12D (return marshalling)[48..51]
    // Epilogue:
    //   48 83 C4 08                 ADD RSP, 8                        [51..55]
    //   41 5F                       POP R15                           [55..57]
    //   5D                          POP RBP                           [57]
    //   C3                          RET                               [58]
    // Bounds-check trap stub (kind=1) — UNCHANGED by D-165 cycle 4.
    // The D-165 INC is added to the SEPARATE stack-probe trap stub
    // (kind=4) which is appended AFTER this bounds stub.
    //
    //   41 C7 87 28 00 00 00 01 00 00 00   MOV [R15+40], 1            [59..70]
    //   ...
    //
    // Total length: 132 (pre-D-165) + 7 (INC in kind=4 stub) = 139.
    try testing.expectEqual(@as(usize, 139), out.bytes.len);
    // Spot-check the prologue (verifies ADR-0026 + ADR-0105 structure).
    // The MOV R15, <entry_arg0> byte differs by Cc; derive the
    // expected sequence dynamically so this works on both SysV
    // and Win64 builds. The ADR-0105 D2 probe inserts CMP+JBE
    // between mov_r15_arg0 and the sentinel; the JBE's disp32
    // gets patched to the stack-overflow trap stub at function
    // close so we assert the opcode prefix only (the 4 disp32
    // bytes are exercised by the trap-stub patch test below).
    const exp_push_rbp = inst.encPushR(.rbp);
    const exp_push_r15 = inst.encPushR(.r15);
    const exp_mov_rbp_rsp = inst.encMovRR(.q, .rbp, .rsp);
    const exp_mov_r15_arg0 = inst.encMovRR(.q, abi.current.runtime_ptr_save_gpr, abi.current.entry_arg0_gpr);
    const exp_probe_cmp = inst.encCmpR64MemDisp32(.rsp, .r15, @import("../shared/jit_abi.zig").stack_limit_off);
    const exp_sentinel = inst.encMovMemDisp32Imm32(.r15, @import("../shared/jit_abi.zig").jit_executed_flag_off, 1);
    const exp_sub_rsp_8 = inst.encSubRSpImm8(8);
    // Pre-probe block (push_rbp + push_r15 + mov_rbp_rsp + mov_r15_arg0 + probe_cmp).
    var pre_probe: [16]u8 = undefined;
    var off: usize = 0;
    @memcpy(pre_probe[off .. off + exp_push_rbp.len], exp_push_rbp.slice());
    off += exp_push_rbp.len;
    @memcpy(pre_probe[off .. off + exp_push_r15.len], exp_push_r15.slice());
    off += exp_push_r15.len;
    @memcpy(pre_probe[off .. off + exp_mov_rbp_rsp.len], exp_mov_rbp_rsp.slice());
    off += exp_mov_rbp_rsp.len;
    @memcpy(pre_probe[off .. off + exp_mov_r15_arg0.len], exp_mov_r15_arg0.slice());
    off += exp_mov_r15_arg0.len;
    @memcpy(pre_probe[off .. off + exp_probe_cmp.len], exp_probe_cmp.slice());
    off += exp_probe_cmp.len;
    try testing.expectEqual(@as(usize, 16), off);
    try testing.expectEqualSlices(u8, &pre_probe, out.bytes[0..16]);
    // JBE rel32 opcode prefix at bytes [16..18]; disp32 [18..22] patched.
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x86 }, out.bytes[16..18]);
    // Post-probe block (sentinel + sub_rsp_8) at [22..body_start].
    var post_probe: [15]u8 = undefined;
    off = 0;
    @memcpy(post_probe[off .. off + exp_sentinel.len], exp_sentinel.slice());
    off += exp_sentinel.len;
    @memcpy(post_probe[off .. off + exp_sub_rsp_8.len], exp_sub_rsp_8.slice());
    off += exp_sub_rsp_8.len;
    try testing.expectEqual(@as(usize, 15), off);
    const body_start = prologue.body_start_offset(true, 8);
    try testing.expectEqualSlices(u8, &post_probe, out.bytes[22..body_start]);
    // JA placeholder = body_start + 25 (after const + memory-load + LEA bytes per layout comment).
    const ja_off = body_start + 25;
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x87, 0x0F, 0x00, 0x00, 0x00 }, out.bytes[ja_off .. ja_off + 6]);
    // Bounds-check trap stub starts at body_start + 46 (body 38 bytes
    // + epilogue 8 bytes). UNCHANGED by D-165 cycle 4 — the INC was
    // added to the separate kind=4 stack-probe stub.
    const trap_off = body_start + 46;
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xC7, 0x87, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }, out.bytes[trap_off .. trap_off + 11]);
    // D-165 cycle 4 — verify the kind=4 stack-probe stub at the tail
    // begins with INC DWORD PTR [R15 + trap_stub_entry_count_off=232].
    // The tail stub is the last 35 bytes: 7 (INC) + 11 (MOV trap_flag)
    // + 11 (MOV trap_kind) + 2 (XOR) + 2 (POP R15) + 1 (POP RBP) +
    // 1 (RET).
    const kind4_off: usize = out.bytes.len - 35;
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xFF, 0x87, 0xE8, 0x00, 0x00, 0x00 }, out.bytes[kind4_off .. kind4_off + 7]);
}

test "compile: i32.load with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false));
}

test "compile: (i32.const 0)(i32.const 99) i32.store offset=0 — store path" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 }); // idx
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 }); // value
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 }, // idx (R10D)
            .{ .def_pc = 1, .last_use_pc = 2 }, // value (R11D)
        },
    };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Prologue: 13 bytes (PUSH RBP / PUSH R15 / MOV RBP,RSP / MOV R15,RDI / SUB RSP,8)
    // Body (slot 0 = RBX, slot 1 = R12 after chunk 13b pool shrink):
    //   BB 00 00 00 00                 MOV EBX, 0   (idx)             5 bytes
    //   41 BC 63 00 00 00              MOV R12D, 99 (value)           6
    //   49 8B 87 00 00 00 00           MOV RAX, [R15 + 0]             7
    //   89 DA                          MOV EDX, EBX                   2
    //   48 8D 4A 04                    LEA RCX, [RDX + 4]             4
    //   49 3B 8F 08 00 00 00           CMP RCX, [R15 + 8]             7
    //   0F 87 ?? ?? ?? ??              JA trap_stub (placeholder)     6
    //   44 89 24 10                    MOV [RAX + RDX], R12D          4
    //   (no return marshalling — sig.results.len == 0)
    // Epilogue: ADD RSP,8 / POP R15 / POP RBP / RET                  8
    // Trap stub: 21 bytes
    // D-055 migration: prologue size sourced from body_start_offset().
    const body_start = prologue.body_start_offset(true, 8);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x24, 0x10 }, out.bytes[body_start + 5 + 6 + 7 + 2 + 4 + 7 + 6 ..][0..4]);
    // Verify the JA was patched (disp != 0); JA = 0x0F 0x87
    const ja_at = body_start + 5 + 6 + 7 + 2 + 4 + 7;
    try testing.expect(out.bytes[ja_at] == 0x0F and out.bytes[ja_at + 1] == 0x87);
    const disp = std.mem.readInt(i32, out.bytes[ja_at + 2 ..][0..4], .little);
    try testing.expect(disp > 0); // forward to trap stub
}

test "compile: (i32.const 0) i32.load8_u → MOVZX r8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load8_u" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Find MOVZX r32, byte ptr [RAX + RDX]: REX.R + 0F B6 24 10
    // dst is R12D (slot 1 after chunk 13b pool shrink) → REX = 0x44, then 0F B6 24 10
    const expected = [_]u8{ 0x44, 0x0F, 0xB6, 0x24, 0x10 };
    // The load is the last body insn before return marshalling (MOV EAX, R11D).
    // Search; not asserting the exact offset to avoid coupling to prologue width.
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 0) i32.load16_s → MOVSX r16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load16_s" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // MOVSX r32, word ptr [RAX + RDX] for R12D (slot 1 after chunk 13b pool shrink):
    // REX.R + 0F BF 24 10
    const expected = [_]u8{ 0x44, 0x0F, 0xBF, 0x24, 0x10 };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 0)(i32.const 7) i32.store8 → MOV r8 store" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store8" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // MOV [RAX + RDX], R12B (8-bit; slot 1 = R12 after chunk 13b pool shrink):
    // REX.R for R12 → 44 88 24 10
    const expected = [_]u8{ 0x44, 0x88, 0x24, 0x10 };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.store with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store" }); // needs 2 vregs, has 1
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false));
}

test "compile: global.get 0 — emits ADR-0027 reload-from-runtime-ptr (i32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"global.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0}; // R10D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Body should contain the 2-instruction global.get sequence:
    //   MOV RAX, [R15 + globals_base_off=48] →  49 8B 87 30 00 00 00
    //   MOV EBX, [RAX + 0]                   →  8B 98 00 00 00 00
    // (slot 0 = RBX after chunk 13b pool shrink — no REX prefix needed.)
    const expected = [_]u8{
        0x49, 0x8B, 0x87, 0x30, 0x00, 0x00, 0x00, // MOV RAX, [R15 + 48]
        0x8B, 0x98, 0x00, 0x00, 0x00, 0x00, // MOV EBX, [RAX + 0]
    };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 42) global.set 1 — emits ADR-0027 reload + store (i32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Body should contain the global.set sequence:
    //   MOV RAX, [R15 + 48]                  →  49 8B 87 30 00 00 00
    //   MOV [RAX + 16], EBX  (idx=1, byte_off=16; post-ADR-0110
    //   fallback stride is *16) →  89 98 10 00 00 00
    // (slot 0 = RBX after chunk 13b pool shrink — no REX prefix needed.)
    const expected = [_]u8{
        0x49, 0x8B, 0x87, 0x30, 0x00, 0x00, 0x00,
        0x89, 0x98, 0x10, 0x00, 0x00, 0x00,
    };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: global.set with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false));
}

test "compile: br with depth strictly above labels.len → UnsupportedOp" {
    // §9.7 / 7.10-h: depth == labels.len is the function-return
    // path (compiles to inline epilogue). depth > labels.len is
    // still malformed and surfaces UnsupportedOp.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .br, .payload = 1 }); // labels.len = 0; 1 > 0 ⇒ malformed
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false));
}

test "compile: function with 16 locals compiles (§9.7 / 7.10-g lifts the i8 cap)" {
    // Pre-7.10-g this surfaced UnsupportedOp[total_locals>15];
    // the disp32 form widening lifts the cap to ~268M slots.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const sixteen_locals = [_]zir.ValType{.i32} ** 16;
    var f = ZirFunc.init(0, sig, &sixteen_locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
}

test "compile: function with v128 param → SysV compile-success (§9.9 / 9.9-e-2)" {
    // §9.9-e-2 lifts the SysV v128 param rejection: v128 args
    // arrive in XMM0..XMM7 and stash via MOVUPS [RBP+disp_v128].
    // Win64 v128 stays UnsupportedOp (passed by hidden pointer
    // per Microsoft x64 ABI §"Argument Passing"); enforced
    // separately by `abi.current_cc == .win64`.
    if (abi.current_cc == .win64) return;
    const sig: zir.FuncType = .{ .params = &[_]zir.ValType{.v128}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
}

test "compile: i32 param + local.get + end — params marshal MOV [rbp-8], esi" {
    // §9.7 / 7.8-x86-params smoke test. (param i32) → i32 returns
    // the param value via local.get 0. SysV: arg_gprs[1] = RSI.
    const sig: zir.FuncType = .{ .params = &[_]zir.ValType{.i32}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // The marshalled MOV [rbp-8], <argreg> appears between the
    // SUB RSP and the body's local.get. SysV's user int arg 0 is
    // RSI; Win64's user int arg 0 is RDX. Either way it goes to
    // [rbp-8] (no uses_runtime_ptr; first local at offset -8).
    const expected = inst.encStoreR32MemRBP(-8, abi.current.arg_gprs[1]);
    // Search the prologue range for the marshal byte sequence.
    const prologue_end: usize = 12; // PUSH RBP + MOV RBP,RSP + SUB RSP,16
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= prologue_end + expected.len) : (i += 1) {
        if (i + expected.len > out.bytes.len) break;
        if (std.mem.eql(u8, expected.slice(), out.bytes[i .. i + expected.len])) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 7) (i32.const 5) i32.add end — verifies ADD is emitted" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 }; // RBX, R12D, R13D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55                       PUSH RBP
    //   48 89 E5                 MOV RBP, RSP
    //   BB 07 00 00 00           MOV EBX, #7   (vreg 0 → slot 0 → RBX)
    //   41 BC 05 00 00 00        MOV R12D, #5  (vreg 1 → slot 1 → R12)
    //   41 89 DD                 MOV R13D, EBX (vreg 2 → slot 2 → R13, lhs lift)
    //   45 01 E5                 ADD R13D, R12D (rhs add)
    //   44 89 E8                 MOV EAX, R13D (return marshalling)
    //   5D                       POP RBP
    //   C3                       RET
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x07,
        0x00,
        0x00,
        0x00,
        0x41,
        0xBC,
        0x05,
        0x00,
        0x00,
        0x00,
        0x41,
        0x89,
        0xDD,
        0x45,
        0x01,
        0xE5,
        0x44,
        0x89,
        0xE8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

// §9.7 / 7.10-b: parallel-move for ALU when dst==rhs (D-029).
// With realworld regalloc, result and rhs can share a slot when
// rhs dies at this op and result is born here. The naive
// `MOV dst, lhs ; OP dst, rhs` clobbers rhs before the OP reads
// it — the prior reject path (commit `e0212ec` diag) returned
// UnsupportedOp. Fix: commute commutative ops; use a scratch for
// non-commutative sub.

test "compile: i32.add when dst==rhs slot — commute path emits ADD dst, lhs (no MOV)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Force result and rhs into the SAME slot (slot 1 = R12).
    // dst_r == rhs_r → without commute, MOV dst,lhs clobbers rhs;
    // with commute, emit ADD dst, lhs (1 instr) directly.
    const slots = [_]u16{ 0, 1, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // Look for ADD R12D, EBX (commuted: dst==R12, lhs==EBX). Encoding:
    //   41 01 DC                 ADD R12D, EBX
    const expected = [_]u8{ 0x41, 0x01, 0xDC };
    var found: bool = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 8) (i32.const 3) i32.sub end — SUB opcode 29" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 3 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.sub" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // Spot-check (slot 2 = R13, slot 1 = R12 after chunk 13b pool shrink):
    // SUB R13D, R12D = 45 29 E5 lives at offset 18..21.
    // D-055 migration: prologue size sourced from body_start_offset().
    const sub_off = prologue.body_start_offset(false, 0) + 14;
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x29, 0xE5 }, out.bytes[sub_off .. sub_off + 3]);
}

test "compile: (i32.const 6) (i32.const 7) i32.mul end — IMUL 0F AF" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 6 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.mul" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // IMUL r9, r/m9 has flipped REX semantics (slot 2 = R13, slot 1 = R12 after
    // chunk 13b pool shrink). dst=R13D (R=1), src=R12D (B=1) → REX = 0x45.
    // ModR/M: mod=11, reg=101 (r13), rm=100 (r12) → 11 101 100 = EC.
    // So 45 0F AF EC at offset 18..22.
    // D-055 migration: prologue size sourced from body_start_offset().
    const imul_off = prologue.body_start_offset(false, 0) + 14;
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0xAF, 0xEC }, out.bytes[imul_off .. imul_off + 4]);
}

test "compile: (i32.const 7) (i32.const 5) i32.eq end — CMP+SETE+MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eq" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 }; // RBX, R12D, R13D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   BB 07 00 00 00                  MOV EBX, #7
    //   41 BC 05 00 00 00               MOV R12D, #5
    //   44 39 E3                        CMP EBX, R12D
    //   41 0F 94 C5                     SETE R13B
    //   45 0F B6 ED                     MOVZX R13D, R13B
    //   44 89 E8                        MOV EAX, R13D
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x07,
        0x00,
        0x00,
        0x00,
        0x41,
        0xBC,
        0x05,
        0x00,
        0x00,
        0x00,
        0x44,
        0x39,
        0xE3,
        0x41,
        0x0F,
        0x94,
        0xC5,
        0x45,
        0x0F,
        0xB6,
        0xED,
        0x44,
        0x89,
        0xE8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.lt_s vs i32.lt_u — different cc codes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{ .{ .op = .@"i32.lt_s", .cc = @as(u8, 0x9C) }, .{ .op = .@"i32.lt_u", .cc = @as(u8, 0x92) } }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 2 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 2 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
        defer deinit(testing.allocator, out);
        // SETcc opcode byte (slot 0 = RBX, slot 1 = R12 after chunk 13b pool shrink).
        // Layout: [prologue 4][movimm-EBX 5][movimm-R12D 6][cmp 3] = 18,
        // then SETcc REX(41) at 18, 0x0F at 19, opcode at 20.
        try testing.expectEqual(case.cc, out.bytes[20]);
    }
}

test "compile: (i32.const 0) i32.eqz end — TEST+SETE+MOVZX" {
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
    const slots = [_]u16{ 0, 1 }; // RBX, R12D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   BB 00 00 00 00                  MOV EBX, #0
    //   85 DB                           TEST EBX, EBX
    //   41 0F 94 C4                     SETE R12B   (REX.B for r12)
    //   45 0F B6 E4                     MOVZX R12D, R12B
    //   44 89 E0                        MOV EAX, R12D
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x00,
        0x00,
        0x00,
        0x00,
        0x85,
        0xDB,
        0x41,
        0x0F,
        0x94,
        0xC4,
        0x45,
        0x0F,
        0xB6,
        0xE4,
        0x44,
        0x89,
        0xE0,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 1) (i32.const 4) i32.shl end — MOV CL + MOV dst + SHL CL" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.shl" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 }; // RBX, R12D, R13D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   BB 01 00 00 00                  MOV EBX, #1     (vreg 0 = lhs)
    //   41 BC 04 00 00 00               MOV R12D, #4    (vreg 1 = rhs)
    //   44 89 E1                        MOV ECX, R12D   (rhs → CL count)
    //   41 89 DD                        MOV R13D, EBX   (lhs → dst)
    //   41 D3 E5                        SHL R13D, CL
    //   44 89 E8                        MOV EAX, R13D
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x01,
        0x00,
        0x00,
        0x00,
        0x41,
        0xBC,
        0x04,
        0x00,
        0x00,
        0x00,
        0x44,
        0x89,
        0xE1,
        0x41,
        0x89,
        0xDD,
        0x41,
        0xD3,
        0xE5,
        0x44,
        0x89,
        0xE8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.shr_s vs i32.shr_u — kind byte differs (sar 41 D3 fd vs shr 41 D3 ed)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{
        .{ .op = .@"i32.shr_s", .modrm = @as(u8, 0xFD) },
        .{ .op = .@"i32.shr_u", .modrm = @as(u8, 0xED) },
    }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 100 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 2 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u16{ 0, 1, 2 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
        defer deinit(testing.allocator, out);
        // Layout (slot 0=RBX, slot 1=R12, slot 2=R13 after chunk 13b pool shrink):
        // 4 prologue + 5 mov-EBX + 6 mov-R12D + 3 mov-ECX + 3 mov-R13D = 21,
        // then REX 0x41 at 21, D3 at 22, ModR/M at 23.
        try testing.expectEqual(@as(u8, 0xD3), out.bytes[22]);
        try testing.expectEqual(case.modrm, out.bytes[23]);
    }
}

test "compile: (i32.const 8) i32.clz end — LZCNT" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 }; // RBX, R12D after chunk 13b pool shrink
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                    prologue
    //   BB 08 00 00 00                 MOV EBX, #8
    //   F3 44 0F BD E3                 LZCNT R12D, EBX (dst=R12 reg, src=EBX r/m)
    //   44 89 E0                       MOV EAX, R12D
    //   5D C3                          POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48,
        0x89,
        0xE5,
        0xBB,
        0x08,
        0x00,
        0x00,
        0x00,
        0xF3,
        0x44,
        0x0F,
        0xBD,
        0xE3,
        0x44,
        0x89,
        0xE0,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.clz vs i32.ctz vs i32.popcnt — opcode byte differs" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{
        .{ .op = .@"i32.clz", .opcode = @as(u8, 0xBD) },
        .{ .op = .@"i32.ctz", .opcode = @as(u8, 0xBC) },
        .{ .op = .@"i32.popcnt", .opcode = @as(u8, 0xB8) },
    }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .end });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u16{ 0, 1 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
        defer deinit(testing.allocator, out);
        // Layout (slot 0 = RBX after chunk 13b pool shrink):
        // 4 prologue + 5 mov-EBX-imm32 = 9. Then F3 at 9, REX at 10 (0x44),
        // 0x0F at 11, opcode at 12.
        try testing.expectEqual(@as(u8, 0xF3), out.bytes[9]);
        try testing.expectEqual(@as(u8, 0x0F), out.bytes[11]);
        try testing.expectEqual(case.opcode, out.bytes[12]);
    }
}

test "compile: i32.eqz with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" }); // no operand on stack
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false));
}

test "compile: i32.wrap_i64 emits MOV r32_dst, r32_src (self-MOV zero-extends)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // x86_64 doesn't yet have i64.const; use i32.const as the i64-typed
    // source stand-in (emit pass doesn't validate types).
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xCAFE });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // Both vregs in slot 0 → RBX (after chunk 13b pool shrink). wrap-op
    // materialises as self-MOV (still issued: the 32-bit write zeroes the
    // upper half).
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);
    // Layout: 4 prologue + 5 mov-EBX-imm32 = 9. Then MOV EBX, EBX = 2 bytes.
    // D-055 migration: prologue size sourced from body_start_offset().
    const off = prologue.body_start_offset(false, 0) + 5;
    const expected = inst.encMovRR(.d, .rbx, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[off .. off + expected.len]);
}

test "compile: i64.extend_i32_u emits MOV r32_dst, r32_src" {
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
    // Layout (slot 0 = RBX after chunk 13b pool shrink):
    // 4 prologue + 5 mov-EBX-imm32 = 9. Then MOV EBX, EBX = 2 bytes.
    // D-055 migration: prologue size sourced from body_start_offset().
    const off = prologue.body_start_offset(false, 0) + 5;
    const expected = inst.encMovRR(.d, .rbx, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[off .. off + expected.len]);
}

test "compile: i64.extend_i32_s emits MOVSXD r64_dst, r32_src" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Sign-bit set source — extend_i32_s should produce a negative i64.
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
    // Layout (slot 0 = RBX after chunk 13b pool shrink):
    // 4 prologue + 5 mov-EBX-imm32 = 9. Then MOVSXD RBX, EBX = 3 bytes.
    // D-055 migration: prologue size sourced from body_start_offset().
    const off = prologue.body_start_offset(false, 0) + 5;
    const expected = inst.encMovsxdR64R32(.rbx, .rbx);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[off .. off + expected.len]);
}

test "compile: call N — 0 args, void return — emits MOV RDI,R15 + CALL + fixup" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };

    const slots = [_]u16{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Prologue (uses_runtime_ptr=true since `call` triggers prescan):
    //   PUSH RBP        55              (1 byte)
    //   PUSH R15        41 57           (2 bytes) → 3
    //   MOV RBP, RSP    48 89 e5        (3 bytes) → 6
    //   MOV R15, RDI    49 89 fd        (3 bytes) → 9
    //   SUB RSP, K      48 83 ec K      (4 bytes) → 13
    // §9.7 / 7.10-f folds shadow space into the prologue's
    // outgoing region, so SUB RSP encoding length stays 4 bytes
    // on both Cc (frame_bytes = 8 on SysV; 40 on Win64 — both
    // fit in imm8). Body starts at byte 13.
    //   MOV <arg0>, R15  3 bytes        → 16
    //   CALL rel32       5 bytes        → 21
    // No per-call SUB RSP, 32 / ADD RSP, 32 on Win64 anymore —
    // outgoing_max_bytes>0 makes emitShadowAlloc/Free no-op.
    // D-055 migration: prologue size sourced from body_start_offset().
    // Both SysV (frame=8) and Win64 (frame=40) fit in imm8 → body_start = 13 today.
    const body_start = prologue.body_start_offset(true, 8);
    const expected_mov = inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.current.runtime_ptr_save_gpr);
    try testing.expectEqualSlices(u8, expected_mov.slice(), out.bytes[body_start .. body_start + expected_mov.len]);
    // CALL byte offset = post-prologue + MOV <arg0>, R15 (3 bytes).
    const call_off: u32 = body_start + 3;
    const expected_call = inst.encCallRel32(0);
    try testing.expectEqualSlices(u8, expected_call.slice(), out.bytes[call_off .. call_off + expected_call.len]);

    try testing.expectEqual(@as(usize, 1), out.call_fixups.len);
    try testing.expectEqual(call_off, out.call_fixups[0].byte_offset);
    try testing.expectEqual(@as(u32, 1), out.call_fixups[0].target_func_idx);
}

test "compile: call N — 0 args, i32 return — captures EAX into result vreg" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u16{0}; // result vreg → RBX (after chunk 13b pool shrink)
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Body layout (post-prologue at 13). §9.7 / 7.10-f folded
    // Win64 shadow space into the prologue, so capture-result
    // offset is the same on both Cc:
    //   13                   post-prologue
    //   + 3                  MOV <arg0>, R15 (runtime_ptr restore)
    //   + 5                  CALL rel32
    //   = 21
    // D-055 migration: prologue size sourced from body_start_offset().
    const capture_off: u32 = prologue.body_start_offset(true, 8) + 3 + 5;
    const expected_capture = inst.encMovRR(.d, .rbx, .rax);
    try testing.expectEqualSlices(u8, expected_capture.slice(), out.bytes[capture_off .. capture_off + expected_capture.len]);
}

test "compile: call N — 1 i32 arg — marshals top-of-stack into arg_gprs[1] (RSI on SysV, RDX on Win64)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{.i32}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u16{0}; // arg vreg → RBX (after chunk 13b pool shrink)
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Body layout (post-prologue at 13). Cc-pivot derives the
    // marshalling target from `abi.current.arg_gprs[1]`.
    //   MOV EBX, 42                      (5 bytes) → 18
    //   MOV <arg1>, EBX                  (2-3 bytes; varies by arch) → marshal
    //   MOV <arg0>, R15                  (3 bytes) → runtime_ptr restore
    //   CALL rel32                       (5 bytes)
    // D-055 migration: prologue size sourced from body_start_offset() + i32.const 5 bytes.
    const marshal_off: u32 = prologue.body_start_offset(true, 8) + 5;
    const expected_marshal = inst.encMovRR(.d, abi.current.arg_gprs[1], .rbx);
    try testing.expectEqualSlices(u8, expected_marshal.slice(), out.bytes[marshal_off .. marshal_off + expected_marshal.len]);
}

test "compile: call_indirect — bounds + sig (JAE+JNE → trap stub) + CALL RAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const module_types = [_]zir.FuncType{callee_sig};

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .call_indirect, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u16{0}; // idx vreg → RBX (after chunk 13b pool shrink)
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &module_types, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Body starts at byte 13 (uses_runtime_ptr=true prologue).
    // Slot 0 = RBX → no REX.R/B for the idx; encodings shrink vs the
    // pre-13b R10 layout.
    //   [13..18]  MOV EBX, 5              (i32.const, 5 bytes)
    //   [18..25]  MOV EAX, [R15 + 24]     (load table_size, 7 bytes)
    //   [25..27]  CMP EBX, EAX            (bounds compare, 2 bytes)
    //   [27..33]  JAE rel32 placeholder   (bounds fixup, 6 bytes)
    //   [33..40]  MOV RAX, [R15 + 32]     (load typeidx_base, 7 bytes)
    //   [40..43]  MOV EAX, [RAX + RBX*4]  (load expected typeidx, 3 bytes)
    //   [43..49]  CMP EAX, 0              (sig compare to type_idx=0, 6 bytes)
    //   [49..55]  JNE rel32 placeholder   (sig fixup, 6 bytes)
    //   [55..62]  MOV RAX, [R15 + 16]     (load funcptr_base, 7 bytes)
    //   [62..66]  MOV RAX, [RAX + RBX*8]  (load funcptr, 4 bytes)
    //   [66..69]  MOV RDI, R15            (restore runtime_ptr, 3 bytes)
    //   [69..71]  CALL RAX                (indirect)
    // D-055 migration: all assertions use body_start_offset() so they survive
    // future +7 prologue shift from JIT-execution sentinel injection.
    const body_start = prologue.body_start_offset(true, 8);
    const expected_table_size_load = inst.encMovR32FromMemDisp32(.rax, .r15, 24);
    const table_size_off = body_start + 5;
    try testing.expectEqualSlices(u8, expected_table_size_load.slice(), out.bytes[table_size_off .. table_size_off + expected_table_size_load.len]);
    // JAE/JNE rel32 disp32 is patched at function-tail to point at the
    // trap stub; assert only the opcode bytes (0F 83 / 0F 85).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 14]);
    try testing.expectEqual(@as(u8, 0x83), out.bytes[body_start + 15]);
    const expected_typeidx_load = inst.encMovR32FromBaseIdxLsl2(.rax, .rax, .rbx);
    const typeidx_off = body_start + 27;
    try testing.expectEqualSlices(u8, expected_typeidx_load.slice(), out.bytes[typeidx_off .. typeidx_off + expected_typeidx_load.len]);
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[body_start + 36]);
    try testing.expectEqual(@as(u8, 0x85), out.bytes[body_start + 37]);
    const expected_funcptr_load = inst.encMovR64FromBaseIdxLsl3(.rax, .rax, .rbx);
    const funcptr_off = body_start + 49;
    try testing.expectEqualSlices(u8, expected_funcptr_load.slice(), out.bytes[funcptr_off .. funcptr_off + expected_funcptr_load.len]);
    // §9.7 / 7.10-f: per-call SUB RSP, 32 on Win64 is gone — the
    // shadow lives in the prologue's outgoing region. CALL RAX
    // offset is the same on both Cc.
    const call_off: u32 = body_start + 56;
    const expected_call = inst.encCallReg(.rax);
    try testing.expectEqualSlices(u8, expected_call.slice(), out.bytes[call_off .. call_off + expected_call.len]);
}

test "compile: self-recursive (call 0) emits JBE with patched disp32 pointing at trap stub (R3)" {
    // ADR-0105 D2/D3 probe wiring end-to-end check. Asserts that
    // for a self-recursive `(call 0)` body the prologue's JBE
    // rel32 placeholder gets PATCHED at function-close to a
    // non-zero disp that lands on the stack-overflow trap stub's
    // first byte. R3 cycle 5 introduced after windowsmini evidence
    // showed the probe never fires despite sane stack_limit — the
    // only remaining hypothesis is patch / encoding drift. If this
    // test passes on Mac (SysV) + Win64 (via run_remote_windows),
    // the patch is correct; if it fails on either, the patch is
    // the bug.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const slots = [_]u16{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    // compile(alloc, func, alloc, func_sigs, module_types, num_imports, globals_offsets, globals_valtypes).
    // func_sigs[0] = self's sig so `call 0` resolves to a valid sig.
    const out = try compile(testing.allocator, &f, alloc, &.{sig}, &.{sig}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Locate JBE rel32 (0F 86) — emitted in the prologue right
    // after `CMP RSP, [R15+stack_limit_off]`. Cc-agnostic search
    // since prologue layout differs only by the `MOV R15, <arg0>`
    // dest byte (SysV RDI vs Win64 RCX), not by stride.
    var jbe_off: ?usize = null;
    var i: usize = 0;
    while (i + 1 < out.bytes.len) : (i += 1) {
        if (out.bytes[i] == 0x0F and out.bytes[i + 1] == 0x86) {
            jbe_off = i;
            break;
        }
    }
    try testing.expect(jbe_off != null);
    const off = jbe_off.?;
    // Patch ran → disp32 ≠ 0.
    const disp32: i32 = std.mem.readInt(i32, out.bytes[off + 2 ..][0..4], .little);
    try testing.expect(disp32 != 0);
    // Disp32 points to trap-stub-start (first byte = REX.B byte
    // for `MOV [R15+disp], imm32` = 0x41).
    const jbe_end: i64 = @as(i64, @intCast(off)) + 6;
    const stub_abs: i64 = jbe_end + @as(i64, disp32);
    try testing.expect(stub_abs >= 0 and stub_abs < @as(i64, @intCast(out.bytes.len)));
    try testing.expectEqual(@as(u8, 0x41), out.bytes[@intCast(stub_abs)]);
}

test "compile: self-recursive (i64)->i64 — probe + i64-result marshal (D-165 cycle 2)" {
    // D-165 spike cycle 2 — sibling of the R3 ()->() test above for
    // the fac-rec shape `(func (param i64) (result i64))` that hangs
    // on Win64 with `assert_exhaustion fac-rec i64:1073741824`.
    //
    // Body: `local.get 0; call 0; end` — minimal valid shape that
    // exercises (a) i64 param marshal into local slot, (b) the
    // prologue stack-probe, (c) i64-arg pass to recursive call,
    // (d) i64-result capture from RAX into a vreg, (e) end's
    // marshal of the result vreg back into RAX.
    //
    // Cycle 2's H3 says: a Win64-specific marshal regression from
    // the recent R1/R2/R3 diff. The byte-shape assertions below
    // hold on both SysV (Mac host native) and Win64 (cross-compile
    // / windowsmini reconcile). FAIL on either platform localises
    // H3 to a byte-encoding bug.
    const sig: zir.FuncType = .{ .params = &[_]zir.ValType{.i64}, .results = &[_]zir.ValType{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .call, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // local.get → consumed by call as arg
            .{ .def_pc = 1, .last_use_pc = 2 }, // call result → consumed by end
        },
    };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{sig}, &.{sig}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // Assertion 1: JBE rel32 patched (probe wired). Sibling of the
    // R3 test's check; the property must hold for i64-shape too.
    var jbe_off: ?usize = null;
    var i: usize = 0;
    while (i + 1 < out.bytes.len) : (i += 1) {
        if (out.bytes[i] == 0x0F and out.bytes[i + 1] == 0x86) {
            jbe_off = i;
            break;
        }
    }
    try testing.expect(jbe_off != null);
    const jbe = jbe_off.?;
    const disp32: i32 = std.mem.readInt(i32, out.bytes[jbe + 2 ..][0..4], .little);
    try testing.expect(disp32 != 0);
    const stub_abs: i64 = @as(i64, @intCast(jbe)) + 6 + @as(i64, disp32);
    try testing.expect(stub_abs >= 0 and stub_abs < @as(i64, @intCast(out.bytes.len)));
    try testing.expectEqual(@as(u8, 0x41), out.bytes[@intCast(stub_abs)]);

    // Assertion 2: SUB RSP, imm with imm > 0 — fac-rec MUST allocate
    // frame for the i64 param slot (8 bytes) + spill region. Probe
    // gating doesn't require this (probe fires before SUB RSP), but
    // if frame_bytes were 0 the recursion would still grow stack by
    // 8 bytes per CALL (RIP push) — slower probe-fire, possibly
    // missed timing.
    //
    // Encoding: imm8 form `48 83 EC ib` (4 bytes); imm32 form
    // `48 81 EC id` (7 bytes). Both have prefix `48 8? EC`.
    var sub_rsp_imm: ?u32 = null;
    i = 0;
    while (i + 3 < out.bytes.len) : (i += 1) {
        if (out.bytes[i] == 0x48 and out.bytes[i + 2] == 0xEC) {
            if (out.bytes[i + 1] == 0x83) {
                sub_rsp_imm = out.bytes[i + 3];
                break;
            } else if (out.bytes[i + 1] == 0x81 and i + 6 < out.bytes.len) {
                sub_rsp_imm = std.mem.readInt(u32, out.bytes[i + 3 ..][0..4], .little);
                break;
            }
        }
    }
    try testing.expect(sub_rsp_imm != null);
    try testing.expect(sub_rsp_imm.? > 0);
    // On SysV (Mac native): frame_bytes covers locals(8) + spill +
    // r15_save(8) + alignment → ≥ 16. On Win64: + shadow space (32)
    // → ≥ 48.  Use platform-aware floor.
    const min_frame: u32 = if (abi.current_cc == .win64) 48 else 16;
    try testing.expect(sub_rsp_imm.? >= min_frame);

    // Assertion 3: i64 result capture after CALL — must be 64-bit
    // form `MOV r64, RAX` (REX.W set). Look for the byte sequence
    // produced by `inst.encMovRR(.q, <vreg_reg>, .rax)` right after
    // the CALL rel32 (E8 disp32 = 5 bytes).
    var call_off: ?usize = null;
    i = 0;
    while (i < out.bytes.len) : (i += 1) {
        if (out.bytes[i] == 0xE8) {
            call_off = i;
            break;
        }
    }
    try testing.expect(call_off != null);
    const post_call: usize = call_off.? + 5;
    try testing.expect(post_call + 3 <= out.bytes.len);
    // MOV r64, RAX encoding: REX.W (0x48 or 0x49) + 0x89 + ModR/M.
    // Source = RAX (reg field = 0), so ModR/M = 0xC0 | (dst_low3 << 3).
    // We only care that the result-capture is the 64-bit width form
    // (REX.W set), not 32-bit (REX.B alone). The 32-bit form would
    // truncate the upper i64 bits — a regression vs ADR-0026 i64
    // marshal contract.
    const rex = out.bytes[post_call];
    try testing.expect(rex == 0x48 or rex == 0x49); // REX.W = 1
    try testing.expectEqual(@as(u8, 0x89), out.bytes[post_call + 1]);

    // Assertion 4 (D-165 cycle 3): i64 arg marshal to the per-Cc
    // first user-int-arg reg right BEFORE the CALL. SysV puts the
    // recursive callee's a0 in RSI (arg_gprs[1]; RDI = runtime_ptr);
    // Win64 puts it in RDX (arg_gprs[1]; RCX = runtime_ptr). The
    // local.get 0's vreg must be loaded into that reg via a 64-bit
    // MOV. We can't predict the exact source reg (regalloc-chosen),
    // but the pattern `48|4? 89 <modrm>` where modrm.reg == arg_gprs[1]
    // OR `48|4? 8B <modrm>` (reverse direction MOV r64, r/m64)
    // both qualify. Easier check: scan the bytes BEFORE the CALL for
    // a byte equal to abi.current.arg_gprs[1]'s register encoding
    // appearing as either source or destination of a REX.W MOV.
    //
    // Simpler structural check: between SUB RSP (end) and CALL
    // (start), there MUST be a `MOV rt_arg, R15` (3 bytes:
    // 0x48|0x49, 0x89, modrm) AND a load of the i64 arg into
    // arg_gprs[1]. We assert the former is present (rt restore
    // is a known site).
    const rt_arg = abi.current.entry_arg0_gpr;
    const rt_save = abi.runtime_ptr_save_gpr;
    const expected_rt_restore = inst.encMovRR(.q, rt_arg, rt_save);
    var rt_restore_found = false;
    i = 0;
    while (i + expected_rt_restore.len <= out.bytes.len) : (i += 1) {
        if (i >= call_off.?) break;
        if (std.mem.eql(u8, expected_rt_restore.slice(), out.bytes[i .. i + expected_rt_restore.len])) {
            rt_restore_found = true;
            break;
        }
    }
    try testing.expect(rt_restore_found);
}

test "compile: try_table emit populates EmitOutput.exception_handlers (IT-2)" {
    // Mirror of arm64 sibling IT-2 test.
    const exception_table = @import("../shared/exception_table.zig");
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    // Wrap try_table in an enclosing block so catch_all label_idx=0
    // resolves to a real outer label (Wasm 3.0 EH spec — catch
    // clause labels are evaluated against the surrounding context,
    // not the try_table itself). Structure:
    //   block; try_table; end (try_table); end (block); end (fn).
    try f.instrs.append(testing.allocator, .{ .op = .block, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    try f.instrs.append(testing.allocator, .{ .op = .end });

    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };

    f.eh_landing_pads = try testing.allocator.dupe(zir.LandingPad, &[_]zir.LandingPad{
        .{ .block_idx = 0, .catches_start = 0, .catches_end = 2 },
    });
    f.eh_catch_entries = try testing.allocator.dupe(zir.CatchEntry, &[_]zir.CatchEntry{
        .{ .kind = .catch_all, .tag_idx = 0, .label_idx = 0 },
        .{ .kind = .catch_, .tag_idx = 7, .label_idx = 0 },
    });

    const alloc: regalloc.Allocation = .{ .slots = &[_]u16{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    try testing.expectEqual(@as(usize, 2), out.exception_handlers.len);
    try testing.expectEqual(exception_table.CatchKind.catch_all, out.exception_handlers[0].kind);
    try testing.expectEqual(@as(?u32, null), out.exception_handlers[0].tag_idx);
    try testing.expectEqual(exception_table.CatchKind.catch_, out.exception_handlers[1].kind);
    try testing.expectEqual(@as(?u32, 7), out.exception_handlers[1].tag_idx);
    try testing.expectEqual(out.exception_handlers[0].pc_start, out.exception_handlers[1].pc_start);
    try testing.expectEqual(out.exception_handlers[0].pc_start, out.exception_handlers[0].pc_end);
    // landing_pad_pc patched to the buf offset right after the
    // enclosing block's `end` op (no inner instructions → equals
    // pc_end here since try_table's end and the outer block's end
    // both emit zero net bytes for a void-arity fixture).
    try testing.expectEqual(out.exception_handlers[0].pc_end, out.exception_handlers[0].landing_pad_pc);
    try testing.expectEqual(out.exception_handlers[1].pc_end, out.exception_handlers[1].landing_pad_pc);
}

test "compile: throw emits JMP rel32 placeholder + appends unreach_fixup (IT-3 trap-path)" {
    // Mirror of arm64 IT-3 sibling — see that test for rationale.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);

    try f.instrs.append(testing.allocator, .{ .op = .throw, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });

    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const alloc: regalloc.Allocation = .{ .slots = &[_]u16{}, .n_slots = 0 };

    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false);
    defer deinit(testing.allocator, out);

    // JMP rel32 is 5 bytes; prologue + trap stub adds more.
    try testing.expect(out.bytes.len >= 5);
    try testing.expectEqual(@as(usize, 0), out.exception_handlers.len);
}

test "compile: try_table reaches per-op emit with ExceptionTable.Builder wired (IT-1)" {
    // Phase 10 EH integration IT-1 — compile() detects `.try_table`
    // ops in func.instrs and allocates a per-function
    // `ExceptionTable.Builder`. Per-op stub's
    // `std.debug.assert(builder != null)` would panic if the
    // wiring regressed; here we just confirm the dispatcher
    // reaches the stub and returns `UnsupportedOp` cleanly.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .try_table, .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const alloc: regalloc.Allocation = .{ .slots = &[_]u16{}, .n_slots = 0 };
    try testing.expectError(
        Error.UnsupportedOp,
        compile(testing.allocator, &f, alloc, &.{}, &.{}, 0, &.{}, &.{}, .i32, &.{}, false),
    );
}
