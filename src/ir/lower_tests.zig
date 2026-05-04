//! Tests for `src/frontend/lowerer.zig` (§9.5 / 5.2 carve-out
//! to keep the lowerer under §A2's 1000-line soft cap; the
//! per-feature lowerer split mirroring ROADMAP §A12 stays
//! queued for §9.1 / 1.7).
//!
//! Tests reach the lowerer only through its public API
//! (`lowerFunctionBody`, `Error`).

const std = @import("std");

const lowerer = @import("lower.zig");
const zir = @import("zir.zig");

const lowerFunctionBody = lowerer.lowerFunctionBody;
const Error = lowerer.Error;
const ValType = zir.ValType;
const FuncType = zir.FuncType;
const BlockKind = zir.BlockKind;
const BlockInfo = zir.BlockInfo;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;

const testing = std.testing;

const empty_sig: FuncType = .{ .params = &.{}, .results = &.{} };
const i32_arr = [_]ValType{.i32};
const i32_result_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };

fn newFunc(sig: FuncType) ZirFunc {
    return ZirFunc.init(0, sig, &.{});
}

test "lower: bare end emits a single .end instr and no blocks" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    try lowerFunctionBody(testing.allocator, &[_]u8{0x0B}, &f, &.{});

    try testing.expectEqual(@as(usize, 1), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"end", f.instrs.items[0].op);
    try testing.expectEqual(@as(usize, 0), f.blocks.items.len);
}

test "lower: i32.const + drop + end packs sleb128 value into payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // i32.const -1 (sleb 0x7F), drop, end
    try lowerFunctionBody(testing.allocator, &[_]u8{ 0x41, 0x7F, 0x1A, 0x0B }, &f, &.{});

    try testing.expectEqual(@as(usize, 3), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), f.instrs.items[0].payload);
    try testing.expectEqual(ZirOp.@"drop", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"end", f.instrs.items[2].op);
}

test "lower: i64.const splits low32/high32 across payload+extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // i64.const -1 → sleb128 0x7F → bitcast u64 = 0xFFFF_FFFF_FFFF_FFFF
    try lowerFunctionBody(testing.allocator, &[_]u8{ 0x42, 0x7F, 0x1A, 0x0B }, &f, &.{});

    const inst = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"i64.const", inst.op);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), inst.payload);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), inst.extra);
}

test "lower: f32.const stores raw little-endian bits in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // f32.const 1.0  -> bits 0x3F800000 little-endian: 0x00 0x00 0x80 0x3F
    const body = [_]u8{ 0x43, 0x00, 0x00, 0x80, 0x3F, 0x1A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    try testing.expectEqual(ZirOp.@"f32.const", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 0x3F800000), f.instrs.items[0].payload);
}

test "lower: f64.const splits raw bits across payload+extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // f64.const 1.0 -> bits 0x3FF0_0000_0000_0000 little-endian
    const body = [_]u8{
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F,
        0x1A, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    const inst = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"f64.const", inst.op);
    try testing.expectEqual(@as(u32, 0x0000_0000), inst.payload);
    try testing.expectEqual(@as(u32, 0x3FF0_0000), inst.extra);
}

test "lower: nested block records BlockInfo with patched end_inst" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);

    // (block (result i32) i32.const 7) end_block end_fn
    const body = [_]u8{ 0x02, 0x7F, 0x41, 0x07, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    try testing.expectEqual(@as(usize, 1), f.blocks.items.len);
    const blk = f.blocks.items[0];
    try testing.expectEqual(BlockKind.block, blk.kind);
    try testing.expectEqual(@as(u32, 0), blk.start_inst);
    try testing.expectEqual(@as(u32, 2), blk.end_inst);

    const open = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"block", open.op);
    try testing.expectEqual(@as(u32, 0), open.payload);
    // extra = arity (chunk-3 encoding switch); 0x7F was a single
    // valtype, so arity = 1.
    try testing.expectEqual(@as(u32, 1), open.extra);

    const close = f.instrs.items[2];
    try testing.expectEqual(ZirOp.@"end", close.op);
    try testing.expectEqual(@as(u32, 0), close.payload);
}

test "lower: br carries depth in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // block { br 0 } end_fn
    const body = [_]u8{ 0x02, 0x40, 0x0C, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    const br = f.instrs.items[1];
    try testing.expectEqual(ZirOp.@"br", br.op);
    try testing.expectEqual(@as(u32, 0), br.payload);
}

test "lower: local.{get,set,tee} carry index in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // local.get 3 ; local.set 1 ; local.tee 2 ; end
    const body = [_]u8{ 0x20, 0x03, 0x21, 0x01, 0x22, 0x02, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    try testing.expectEqual(ZirOp.@"local.get", f.instrs.items[0].op);
    try testing.expectEqual(@as(u32, 3), f.instrs.items[0].payload);
    try testing.expectEqual(ZirOp.@"local.set", f.instrs.items[1].op);
    try testing.expectEqual(@as(u32, 1), f.instrs.items[1].payload);
    try testing.expectEqual(ZirOp.@"local.tee", f.instrs.items[2].op);
    try testing.expectEqual(@as(u32, 2), f.instrs.items[2].payload);
}

test "lower: if/else updates block kind to else_open" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // i32.const 1 ; if (empty) ; else ; end ; end_fn
    const body = [_]u8{ 0x41, 0x01, 0x04, 0x40, 0x05, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    try testing.expectEqual(@as(usize, 1), f.blocks.items.len);
    try testing.expectEqual(BlockKind.else_open, f.blocks.items[0].kind);

    // Verify the emitted ops in order: i32.const, if, else, end (block), end (fn)
    try testing.expectEqual(ZirOp.@"i32.const", f.instrs.items[0].op);
    try testing.expectEqual(ZirOp.@"if", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"else", f.instrs.items[2].op);
    try testing.expectEqual(ZirOp.@"end", f.instrs.items[3].op);
    try testing.expectEqual(ZirOp.@"end", f.instrs.items[4].op);
}

test "lower: NotImplemented for unknown opcode" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0xFF, 0x0B }, &f, &.{});
    try testing.expectError(Error.NotImplemented, r);
}

test "lower: trailing bytes after function-level end fail" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0x0B, 0x00 }, &f, &.{});
    try testing.expectError(Error.TrailingBytes, r);
}

test "lower: bad blocktype rejected" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0x02 (block) followed by 0x60 (not a valid blocktype byte for MVP)
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0x02, 0x60, 0x0B, 0x0B }, &f, &.{});
    try testing.expectError(Error.BadBlockType, r);
}

test "lower: i32.add binop produces a single instr with no payload" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);
    // i32.const 1 ; i32.const 2 ; i32.add ; end
    const body = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    try testing.expectEqual(@as(usize, 4), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.add", f.instrs.items[2].op);
    try testing.expectEqual(@as(u32, 0), f.instrs.items[2].payload);
}

test "lower: Wasm 2.0 sat-trunc 0xFC 0..7 emit matching ZirOps" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // Eight (f-const, 0xFC <sub>, drop) triplets, then end.
    // Pattern repeats f32.const for sub-ops 0,1,4,5 and f64.const
    // for 2,3,6,7.
    const body = [_]u8{
        0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x1A,
        0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x01, 0x1A,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x02, 0x1A,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x03, 0x1A,
        0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x04, 0x1A,
        0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x05, 0x1A,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x06, 0x1A,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x07, 0x1A,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    // Each triplet emits 3 instrs (const, sat-trunc, drop); 8 triplets
    // + final end instr → 25 instrs total.
    try testing.expectEqual(@as(usize, 25), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.trunc_sat_f32_s", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"i32.trunc_sat_f32_u", f.instrs.items[4].op);
    try testing.expectEqual(ZirOp.@"i32.trunc_sat_f64_s", f.instrs.items[7].op);
    try testing.expectEqual(ZirOp.@"i32.trunc_sat_f64_u", f.instrs.items[10].op);
    try testing.expectEqual(ZirOp.@"i64.trunc_sat_f32_s", f.instrs.items[13].op);
    try testing.expectEqual(ZirOp.@"i64.trunc_sat_f32_u", f.instrs.items[16].op);
    try testing.expectEqual(ZirOp.@"i64.trunc_sat_f64_s", f.instrs.items[19].op);
    try testing.expectEqual(ZirOp.@"i64.trunc_sat_f64_u", f.instrs.items[22].op);
}

test "lower: memory.copy (0xFC 10) emits ZirOp.memory.copy" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; memory.copy ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0A, 0x00, 0x00,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    try testing.expectEqual(ZirOp.@"memory.copy", f.instrs.items[3].op);
}

test "lower: memory.fill (0xFC 11) emits ZirOp.memory.fill" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0B, 0x00,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    try testing.expectEqual(ZirOp.@"memory.fill", f.instrs.items[3].op);
}

test "lower: memory.init (0xFC 8) emits ZirOp.memory.init with dataidx payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x08, 0x05, 0x00,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const init = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"memory.init", init.op);
    try testing.expectEqual(@as(u32, 5), init.payload);
}

test "lower: table.get / table.set / table.size carry tableidx in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.const 0 ; table.get 3 ; drop ; ref.null funcref ; i32.const 0 ;
    // ref.null funcref ; table.set 4 ; table.size 5 ; drop ; end
    const body = [_]u8{
        0x41, 0x00, 0x25, 0x03, 0x1A,
        0x41, 0x00, 0xD0, 0x70, 0x26, 0x04,
        0xFC, 0x10, 0x05, 0x1A,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    try testing.expectEqual(ZirOp.@"table.get", f.instrs.items[1].op);
    try testing.expectEqual(@as(u32, 3), f.instrs.items[1].payload);
    try testing.expectEqual(ZirOp.@"table.set", f.instrs.items[5].op);
    try testing.expectEqual(@as(u32, 4), f.instrs.items[5].payload);
    try testing.expectEqual(ZirOp.@"table.size", f.instrs.items[6].op);
    try testing.expectEqual(@as(u32, 5), f.instrs.items[6].payload);
}

test "lower: table.grow / table.fill carry tableidx in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // ref.null funcref ; i32.const 1 ; table.grow 7 ; drop ; end
    const body = [_]u8{
        0xD0, 0x70, 0x41, 0x01, 0xFC, 0x0F, 0x07, 0x1A, 0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const grow = f.instrs.items[2];
    try testing.expectEqual(ZirOp.@"table.grow", grow.op);
    try testing.expectEqual(@as(u32, 7), grow.payload);
}

test "lower: table.init carries elemidx in payload, tableidx in extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0C, 0x02, 0x07,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const init_op = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"table.init", init_op.op);
    try testing.expectEqual(@as(u32, 2), init_op.payload);
    try testing.expectEqual(@as(u32, 7), init_op.extra);
}

test "lower: elem.drop carries elemidx in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFC, 0x0D, 0x05, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const drop = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"elem.drop", drop.op);
    try testing.expectEqual(@as(u32, 5), drop.payload);
}

test "lower: table.copy carries dst-tableidx in payload, src in extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; table.copy 3 5 ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0E, 0x03, 0x05,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const cp = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"table.copy", cp.op);
    try testing.expectEqual(@as(u32, 3), cp.payload);
    try testing.expectEqual(@as(u32, 5), cp.extra);
}

test "lower: table.fill emits table.fill with tableidx" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00, 0xD0, 0x70, 0x41, 0x00,
        0xFC, 0x11, 0x09,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const fill = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"table.fill", fill.op);
    try testing.expectEqual(@as(u32, 9), fill.payload);
}

test "lower: select_typed (0x1C 01 0x7F) emits select_typed with reftype byte in extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{
        0x41, 0x00,
        0x41, 0x00,
        0x41, 0x00,
        0x1C, 0x01, 0x7F,
        0x1A,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const sel = f.instrs.items[3];
    try testing.expectEqual(ZirOp.@"select_typed", sel.op);
    try testing.expectEqual(@as(u32, 0x7F), sel.extra);
}

test "lower: select_typed with count != 1 → UnexpectedOpcode" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0x1C, 0x02, 0x7F, 0x7F, 0x0B };
    const r = lowerFunctionBody(testing.allocator, &body, &f, &.{});
    try testing.expectError(Error.UnexpectedOpcode, r);
}

test "lower: ref.null (0xD0 0x70) emits ZirOp.ref.null with reftype byte in extra" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xD0, 0x70, 0x1A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const rn = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"ref.null", rn.op);
    try testing.expectEqual(@as(u32, 0x70), rn.extra);
}

test "lower: ref.is_null (0xD1) emits a no-immediate instr" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xD0, 0x70, 0xD1, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    try testing.expectEqual(ZirOp.@"ref.is_null", f.instrs.items[1].op);
}

test "lower: ref.func (0xD2) carries funcidx in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xD2, 0x09, 0x1A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const rf = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"ref.func", rf.op);
    try testing.expectEqual(@as(u32, 9), rf.payload);
}

test "lower: ref.null with bad reftype byte → BadBlockType" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xD0, 0x55, 0x0B };
    const r = lowerFunctionBody(testing.allocator, &body, &f, &.{});
    try testing.expectError(Error.BadBlockType, r);
}

test "lower: data.drop (0xFC 9) emits ZirOp.data.drop with dataidx payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFC, 0x09, 0x07, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});
    const drop = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"data.drop", drop.op);
    try testing.expectEqual(@as(u32, 7), drop.payload);
}

test "lower: memory.copy with non-zero reserved byte → BadBlockType" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFC, 0x0A, 0x00, 0x01, 0x0B };
    const r = lowerFunctionBody(testing.allocator, &body, &f, &.{});
    try testing.expectError(Error.BadBlockType, r);
}

test "lower: 0xFC unknown sub-opcode → NotImplemented" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const body = [_]u8{ 0xFC, 0xFF, 0x01, 0x0B };
    const r = lowerFunctionBody(testing.allocator, &body, &f, &.{});
    try testing.expectError(Error.NotImplemented, r);
}

test "lower: Wasm 2.0 sign-ext opcodes 0xC0..0xC4 emit matching ZirOps" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // i32.const 0 ; i32.extend8_s ; drop
    // i32.const 0 ; i32.extend16_s ; drop
    // i64.const 0 ; i64.extend8_s ; drop
    // i64.const 0 ; i64.extend16_s ; drop
    // i64.const 0 ; i64.extend32_s ; drop
    // end
    const body = [_]u8{
        0x41, 0x00, 0xC0, 0x1A,
        0x41, 0x00, 0xC1, 0x1A,
        0x42, 0x00, 0xC2, 0x1A,
        0x42, 0x00, 0xC3, 0x1A,
        0x42, 0x00, 0xC4, 0x1A,
        0x0B,
    };
    try lowerFunctionBody(testing.allocator, &body, &f, &.{});

    try testing.expectEqual(ZirOp.@"i32.extend8_s", f.instrs.items[1].op);
    try testing.expectEqual(ZirOp.@"i32.extend16_s", f.instrs.items[4].op);
    try testing.expectEqual(ZirOp.@"i64.extend8_s", f.instrs.items[7].op);
    try testing.expectEqual(ZirOp.@"i64.extend16_s", f.instrs.items[10].op);
    try testing.expectEqual(ZirOp.@"i64.extend32_s", f.instrs.items[13].op);
}

test "lower: multivalue block via s33 typeidx — extra = arity (#results)" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // module_types[0] = ([] -> [i32, i32, i32])
    const empty_arr = [_]ValType{};
    const triple = [_]ValType{ .i32, .i32, .i32 };
    const types = [_]FuncType{.{ .params = &empty_arr, .results = &triple }};
    // block (typeidx 0) ; end ; end
    const body = [_]u8{ 0x02, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f, &types);

    const open = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"block", open.op);
    try testing.expectEqual(@as(u32, 3), open.extra);
}

test "lower: multivalue block typeidx with non-empty params → BadBlockType" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const i32_arr_local = [_]ValType{.i32};
    const types = [_]FuncType{.{ .params = &i32_arr_local, .results = &i32_arr_local }};
    const body = [_]u8{ 0x02, 0x00, 0x0B, 0x0B };
    const r = lowerFunctionBody(testing.allocator, &body, &f, &types);
    try testing.expectError(Error.BadBlockType, r);
}
