//! Wasm function-body **lowerer** — wasm opcode → ZirOp emission
//! into a pre-initialised `ZirFunc` (Phase 1 / §9.1 / 1.6).
//!
//! Single pass over the validated body bytes. The validator (§9.1 /
//! 1.5) is the structural gate; the lowerer trusts the byte stream
//! and only enforces what the encoding itself dictates (LEB128
//! truncation, blocktype byte, length of float immediates, function
//! frame closure). Per ROADMAP §P3 (cold-start) and §P6
//! (single-pass) this lowers without intermediate buffers; the only
//! allocation is the caller-provided `ZirFunc.instrs` /
//! `ZirFunc.blocks` ArrayLists.
//!
//! Immediate packing into the fixed `ZirInstr { op, payload: u32,
//! extra: u32 }` record:
//!   - `i32.const N`               → payload = bitcast(N: i32)
//!   - `i64.const N`               → payload = low32(N), extra = high32(N)
//!   - `f32.const x`               → payload = raw 4-byte LE bits
//!   - `f64.const x`               → payload = low32(bits), extra = high32(bits)
//!   - `local.{get,set,tee} K`     → payload = K
//!   - `br N`                      → payload = depth N
//!   - `block` / `loop` / `if`     → payload = block index into out.blocks,
//!                                   extra = raw blocktype byte (0x40 / valtype)
//!   - `else` / `end` (block-end)  → payload = block index of the matching frame
//!   - `end` (function frame)      → payload = 0, terminates the lowering walk
//!
//! Scope tracks the validator's MVP smoke set 1:1; opcodes outside
//! that subset return `Error.NotImplemented` until §9.1 / 1.7 wires
//! per-feature handlers via `DispatchTable` per ROADMAP §A12.
//!
//! Zone 1 (`src/frontend/`) — may import Zone 0 (`src/util/leb128.zig`)
//! and Zone 1 (`src/ir/`). No upward imports.

const std = @import("std");

const leb128 = @import("../util/leb128.zig");
const zir = @import("../ir/zir.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;
const FuncType = zir.FuncType;
const BlockKind = zir.BlockKind;
const BlockInfo = zir.BlockInfo;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;

pub const Error = error{
    UnexpectedEnd,
    UnexpectedOpcode,
    BadBlockType,
    ControlStackOverflow,
    TrailingBytes,
    NotImplemented,
    OutOfMemory,
} || leb128.Error;

pub const max_control_stack: usize = 256;

/// Lower the body bytes into `out`. `out` must be initialised
/// (typically via `ZirFunc.init`); lowering appends to its
/// `instrs` and `blocks` lists. The caller retains ownership and
/// must call `out.deinit(alloc)` when done.
pub fn lowerFunctionBody(
    alloc: Allocator,
    body: []const u8,
    out: *ZirFunc,
) Error!void {
    var lo = Lowerer{ .alloc = alloc, .body = body, .out = out, .pos = 0 };
    try lo.run();
}

const Lowerer = struct {
    alloc: Allocator,
    body: []const u8,
    out: *ZirFunc,
    pos: usize,

    block_stack: [max_control_stack]u32 = undefined,
    block_stack_len: usize = 0,

    fn run(self: *Lowerer) Error!void {
        var fn_done = false;
        while (!fn_done) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const op = self.body[self.pos];
            self.pos += 1;
            try self.dispatch(op, &fn_done);
        }
        if (self.pos != self.body.len) return Error.TrailingBytes;
    }

    fn dispatch(self: *Lowerer, op: u8, fn_done: *bool) Error!void {
        switch (op) {
            0x00 => try self.emit(.@"unreachable", 0, 0),
            0x01 => try self.emit(.nop, 0, 0),
            0x02 => try self.openBlock(.block, .@"block"),
            0x03 => try self.openBlock(.loop, .@"loop"),
            0x04 => try self.openBlock(.if_then, .@"if"),
            0x05 => try self.emitElse(),
            0x0B => {
                if (self.block_stack_len == 0) {
                    try self.emit(.@"end", 0, 0);
                    fn_done.* = true;
                } else {
                    try self.closeBlock();
                }
            },
            0x0C => {
                const depth = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"br", depth, 0);
            },
            0x0F => try self.emit(.@"return", 0, 0),
            0x1A => try self.emit(.@"drop", 0, 0),
            0x20 => try self.emitLocalIndexed(.@"local.get"),
            0x21 => try self.emitLocalIndexed(.@"local.set"),
            0x22 => try self.emitLocalIndexed(.@"local.tee"),
            0x41 => {
                const v = try leb128.readSleb128(i32, self.body, &self.pos);
                const bits: u32 = @bitCast(v);
                try self.emit(.@"i32.const", bits, 0);
            },
            0x42 => {
                const v = try leb128.readSleb128(i64, self.body, &self.pos);
                const u: u64 = @bitCast(v);
                const lo: u32 = @truncate(u);
                const hi: u32 = @truncate(u >> 32);
                try self.emit(.@"i64.const", lo, hi);
            },
            0x43 => {
                if (self.body.len - self.pos < 4) return Error.UnexpectedEnd;
                const bits = std.mem.readInt(u32, self.body[self.pos..][0..4], .little);
                self.pos += 4;
                try self.emit(.@"f32.const", bits, 0);
            },
            0x44 => {
                if (self.body.len - self.pos < 8) return Error.UnexpectedEnd;
                const lo = std.mem.readInt(u32, self.body[self.pos..][0..4], .little);
                const hi = std.mem.readInt(u32, self.body[self.pos..][4..8], .little);
                self.pos += 8;
                try self.emit(.@"f64.const", lo, hi);
            },
            0x45 => try self.emit(.@"i32.eqz", 0, 0),
            0x6A => try self.emit(.@"i32.add", 0, 0),
            0x6B => try self.emit(.@"i32.sub", 0, 0),
            0x6C => try self.emit(.@"i32.mul", 0, 0),
            else => return Error.NotImplemented,
        }
    }

    fn emit(self: *Lowerer, op: ZirOp, payload: u32, extra: u32) Error!void {
        try self.out.instrs.append(self.alloc, .{ .op = op, .payload = payload, .extra = extra });
    }

    fn emitLocalIndexed(self: *Lowerer, op: ZirOp) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(op, idx, 0);
    }

    fn openBlock(self: *Lowerer, kind: BlockKind, op: ZirOp) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const bt = self.body[self.pos];
        self.pos += 1;
        switch (bt) {
            0x40, 0x7F, 0x7E, 0x7D, 0x7C => {},
            else => return Error.BadBlockType,
        }
        if (self.block_stack_len == max_control_stack) return Error.ControlStackOverflow;

        const block_idx: u32 = @intCast(self.out.blocks.items.len);
        const start_inst: u32 = @intCast(self.out.instrs.items.len);
        try self.out.blocks.append(self.alloc, .{
            .kind = kind,
            .start_inst = start_inst,
            .end_inst = 0,
        });
        try self.emit(op, block_idx, bt);

        self.block_stack[self.block_stack_len] = block_idx;
        self.block_stack_len += 1;
    }

    fn closeBlock(self: *Lowerer) Error!void {
        const block_idx = self.block_stack[self.block_stack_len - 1];
        self.block_stack_len -= 1;
        const end_inst: u32 = @intCast(self.out.instrs.items.len);
        try self.emit(.@"end", block_idx, 0);
        self.out.blocks.items[block_idx].end_inst = end_inst;
    }

    fn emitElse(self: *Lowerer) Error!void {
        if (self.block_stack_len == 0) return Error.UnexpectedOpcode;
        const block_idx = self.block_stack[self.block_stack_len - 1];
        self.out.blocks.items[block_idx].kind = .else_open;
        try self.emit(.@"else", block_idx, 0);
    }
};

// ============================================================
// Tests
// ============================================================

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

    try lowerFunctionBody(testing.allocator, &[_]u8{0x0B}, &f);

    try testing.expectEqual(@as(usize, 1), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"end", f.instrs.items[0].op);
    try testing.expectEqual(@as(usize, 0), f.blocks.items.len);
}

test "lower: i32.const + drop + end packs sleb128 value into payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // i32.const -1 (sleb 0x7F), drop, end
    try lowerFunctionBody(testing.allocator, &[_]u8{ 0x41, 0x7F, 0x1A, 0x0B }, &f);

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
    try lowerFunctionBody(testing.allocator, &[_]u8{ 0x42, 0x7F, 0x1A, 0x0B }, &f);

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
    try lowerFunctionBody(testing.allocator, &body, &f);

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
    try lowerFunctionBody(testing.allocator, &body, &f);

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
    try lowerFunctionBody(testing.allocator, &body, &f);

    try testing.expectEqual(@as(usize, 1), f.blocks.items.len);
    const blk = f.blocks.items[0];
    try testing.expectEqual(BlockKind.block, blk.kind);
    try testing.expectEqual(@as(u32, 0), blk.start_inst);
    try testing.expectEqual(@as(u32, 2), blk.end_inst);

    const open = f.instrs.items[0];
    try testing.expectEqual(ZirOp.@"block", open.op);
    try testing.expectEqual(@as(u32, 0), open.payload);
    try testing.expectEqual(@as(u32, 0x7F), open.extra);

    const close = f.instrs.items[2];
    try testing.expectEqual(ZirOp.@"end", close.op);
    try testing.expectEqual(@as(u32, 0), close.payload);
}

test "lower: br carries depth in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // block { br 0 } end_fn
    const body = [_]u8{ 0x02, 0x40, 0x0C, 0x00, 0x0B, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f);

    const br = f.instrs.items[1];
    try testing.expectEqual(ZirOp.@"br", br.op);
    try testing.expectEqual(@as(u32, 0), br.payload);
}

test "lower: local.{get,set,tee} carry index in payload" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);

    // local.get 3 ; local.set 1 ; local.tee 2 ; end
    const body = [_]u8{ 0x20, 0x03, 0x21, 0x01, 0x22, 0x02, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f);

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
    try lowerFunctionBody(testing.allocator, &body, &f);

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
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0xFF, 0x0B }, &f);
    try testing.expectError(Error.NotImplemented, r);
}

test "lower: trailing bytes after function-level end fail" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0x0B, 0x00 }, &f);
    try testing.expectError(Error.TrailingBytes, r);
}

test "lower: bad blocktype rejected" {
    var f = newFunc(empty_sig);
    defer f.deinit(testing.allocator);
    // 0x02 (block) followed by 0x60 (not a valid blocktype byte for MVP)
    const r = lowerFunctionBody(testing.allocator, &[_]u8{ 0x02, 0x60, 0x0B, 0x0B }, &f);
    try testing.expectError(Error.BadBlockType, r);
}

test "lower: i32.add binop produces a single instr with no payload" {
    var f = newFunc(i32_result_sig);
    defer f.deinit(testing.allocator);
    // i32.const 1 ; i32.const 2 ; i32.add ; end
    const body = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6A, 0x0B };
    try lowerFunctionBody(testing.allocator, &body, &f);

    try testing.expectEqual(@as(usize, 4), f.instrs.items.len);
    try testing.expectEqual(ZirOp.@"i32.add", f.instrs.items[2].op);
    try testing.expectEqual(@as(u32, 0), f.instrs.items[2].payload);
}
