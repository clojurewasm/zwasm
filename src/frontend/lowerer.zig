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
            // Control flow continued
            0x0D => try self.emitUlebPayload(.@"br_if"),
            0x0E => try self.emitBrTable(),
            0x10 => try self.emitUlebPayload(.@"call"),
            0x11 => try self.emitCallIndirect(),

            // Parametric
            0x1B => try self.emit(.@"select", 0, 0),

            // Globals
            0x23 => try self.emitUlebPayload(.@"global.get"),
            0x24 => try self.emitUlebPayload(.@"global.set"),

            // Loads (memarg → align uleb32 + offset uleb32)
            0x28 => try self.emitMemarg(.@"i32.load"),
            0x29 => try self.emitMemarg(.@"i64.load"),
            0x2A => try self.emitMemarg(.@"f32.load"),
            0x2B => try self.emitMemarg(.@"f64.load"),
            0x2C => try self.emitMemarg(.@"i32.load8_s"),
            0x2D => try self.emitMemarg(.@"i32.load8_u"),
            0x2E => try self.emitMemarg(.@"i32.load16_s"),
            0x2F => try self.emitMemarg(.@"i32.load16_u"),
            0x30 => try self.emitMemarg(.@"i64.load8_s"),
            0x31 => try self.emitMemarg(.@"i64.load8_u"),
            0x32 => try self.emitMemarg(.@"i64.load16_s"),
            0x33 => try self.emitMemarg(.@"i64.load16_u"),
            0x34 => try self.emitMemarg(.@"i64.load32_s"),
            0x35 => try self.emitMemarg(.@"i64.load32_u"),

            // Stores
            0x36 => try self.emitMemarg(.@"i32.store"),
            0x37 => try self.emitMemarg(.@"i64.store"),
            0x38 => try self.emitMemarg(.@"f32.store"),
            0x39 => try self.emitMemarg(.@"f64.store"),
            0x3A => try self.emitMemarg(.@"i32.store8"),
            0x3B => try self.emitMemarg(.@"i32.store16"),
            0x3C => try self.emitMemarg(.@"i64.store8"),
            0x3D => try self.emitMemarg(.@"i64.store16"),
            0x3E => try self.emitMemarg(.@"i64.store32"),

            // Memory
            0x3F => try self.emitMemoryReserved(.@"memory.size"),
            0x40 => try self.emitMemoryReserved(.@"memory.grow"),

            // Numeric: testop / cmp / unop / binop
            0x45 => try self.emit(.@"i32.eqz", 0, 0),
            0x46 => try self.emit(.@"i32.eq", 0, 0),
            0x47 => try self.emit(.@"i32.ne", 0, 0),
            0x48 => try self.emit(.@"i32.lt_s", 0, 0),
            0x49 => try self.emit(.@"i32.lt_u", 0, 0),
            0x4A => try self.emit(.@"i32.gt_s", 0, 0),
            0x4B => try self.emit(.@"i32.gt_u", 0, 0),
            0x4C => try self.emit(.@"i32.le_s", 0, 0),
            0x4D => try self.emit(.@"i32.le_u", 0, 0),
            0x4E => try self.emit(.@"i32.ge_s", 0, 0),
            0x4F => try self.emit(.@"i32.ge_u", 0, 0),

            0x50 => try self.emit(.@"i64.eqz", 0, 0),
            0x51 => try self.emit(.@"i64.eq", 0, 0),
            0x52 => try self.emit(.@"i64.ne", 0, 0),
            0x53 => try self.emit(.@"i64.lt_s", 0, 0),
            0x54 => try self.emit(.@"i64.lt_u", 0, 0),
            0x55 => try self.emit(.@"i64.gt_s", 0, 0),
            0x56 => try self.emit(.@"i64.gt_u", 0, 0),
            0x57 => try self.emit(.@"i64.le_s", 0, 0),
            0x58 => try self.emit(.@"i64.le_u", 0, 0),
            0x59 => try self.emit(.@"i64.ge_s", 0, 0),
            0x5A => try self.emit(.@"i64.ge_u", 0, 0),

            0x5B => try self.emit(.@"f32.eq", 0, 0),
            0x5C => try self.emit(.@"f32.ne", 0, 0),
            0x5D => try self.emit(.@"f32.lt", 0, 0),
            0x5E => try self.emit(.@"f32.gt", 0, 0),
            0x5F => try self.emit(.@"f32.le", 0, 0),
            0x60 => try self.emit(.@"f32.ge", 0, 0),

            0x61 => try self.emit(.@"f64.eq", 0, 0),
            0x62 => try self.emit(.@"f64.ne", 0, 0),
            0x63 => try self.emit(.@"f64.lt", 0, 0),
            0x64 => try self.emit(.@"f64.gt", 0, 0),
            0x65 => try self.emit(.@"f64.le", 0, 0),
            0x66 => try self.emit(.@"f64.ge", 0, 0),

            0x67 => try self.emit(.@"i32.clz", 0, 0),
            0x68 => try self.emit(.@"i32.ctz", 0, 0),
            0x69 => try self.emit(.@"i32.popcnt", 0, 0),
            0x6A => try self.emit(.@"i32.add", 0, 0),
            0x6B => try self.emit(.@"i32.sub", 0, 0),
            0x6C => try self.emit(.@"i32.mul", 0, 0),
            0x6D => try self.emit(.@"i32.div_s", 0, 0),
            0x6E => try self.emit(.@"i32.div_u", 0, 0),
            0x6F => try self.emit(.@"i32.rem_s", 0, 0),
            0x70 => try self.emit(.@"i32.rem_u", 0, 0),
            0x71 => try self.emit(.@"i32.and", 0, 0),
            0x72 => try self.emit(.@"i32.or", 0, 0),
            0x73 => try self.emit(.@"i32.xor", 0, 0),
            0x74 => try self.emit(.@"i32.shl", 0, 0),
            0x75 => try self.emit(.@"i32.shr_s", 0, 0),
            0x76 => try self.emit(.@"i32.shr_u", 0, 0),
            0x77 => try self.emit(.@"i32.rotl", 0, 0),
            0x78 => try self.emit(.@"i32.rotr", 0, 0),

            0x79 => try self.emit(.@"i64.clz", 0, 0),
            0x7A => try self.emit(.@"i64.ctz", 0, 0),
            0x7B => try self.emit(.@"i64.popcnt", 0, 0),
            0x7C => try self.emit(.@"i64.add", 0, 0),
            0x7D => try self.emit(.@"i64.sub", 0, 0),
            0x7E => try self.emit(.@"i64.mul", 0, 0),
            0x7F => try self.emit(.@"i64.div_s", 0, 0),
            0x80 => try self.emit(.@"i64.div_u", 0, 0),
            0x81 => try self.emit(.@"i64.rem_s", 0, 0),
            0x82 => try self.emit(.@"i64.rem_u", 0, 0),
            0x83 => try self.emit(.@"i64.and", 0, 0),
            0x84 => try self.emit(.@"i64.or", 0, 0),
            0x85 => try self.emit(.@"i64.xor", 0, 0),
            0x86 => try self.emit(.@"i64.shl", 0, 0),
            0x87 => try self.emit(.@"i64.shr_s", 0, 0),
            0x88 => try self.emit(.@"i64.shr_u", 0, 0),
            0x89 => try self.emit(.@"i64.rotl", 0, 0),
            0x8A => try self.emit(.@"i64.rotr", 0, 0),

            0x8B => try self.emit(.@"f32.abs", 0, 0),
            0x8C => try self.emit(.@"f32.neg", 0, 0),
            0x8D => try self.emit(.@"f32.ceil", 0, 0),
            0x8E => try self.emit(.@"f32.floor", 0, 0),
            0x8F => try self.emit(.@"f32.trunc", 0, 0),
            0x90 => try self.emit(.@"f32.nearest", 0, 0),
            0x91 => try self.emit(.@"f32.sqrt", 0, 0),
            0x92 => try self.emit(.@"f32.add", 0, 0),
            0x93 => try self.emit(.@"f32.sub", 0, 0),
            0x94 => try self.emit(.@"f32.mul", 0, 0),
            0x95 => try self.emit(.@"f32.div", 0, 0),
            0x96 => try self.emit(.@"f32.min", 0, 0),
            0x97 => try self.emit(.@"f32.max", 0, 0),
            0x98 => try self.emit(.@"f32.copysign", 0, 0),

            0x99 => try self.emit(.@"f64.abs", 0, 0),
            0x9A => try self.emit(.@"f64.neg", 0, 0),
            0x9B => try self.emit(.@"f64.ceil", 0, 0),
            0x9C => try self.emit(.@"f64.floor", 0, 0),
            0x9D => try self.emit(.@"f64.trunc", 0, 0),
            0x9E => try self.emit(.@"f64.nearest", 0, 0),
            0x9F => try self.emit(.@"f64.sqrt", 0, 0),
            0xA0 => try self.emit(.@"f64.add", 0, 0),
            0xA1 => try self.emit(.@"f64.sub", 0, 0),
            0xA2 => try self.emit(.@"f64.mul", 0, 0),
            0xA3 => try self.emit(.@"f64.div", 0, 0),
            0xA4 => try self.emit(.@"f64.min", 0, 0),
            0xA5 => try self.emit(.@"f64.max", 0, 0),
            0xA6 => try self.emit(.@"f64.copysign", 0, 0),

            // Conversions
            0xA7 => try self.emit(.@"i32.wrap_i64", 0, 0),
            0xA8 => try self.emit(.@"i32.trunc_f32_s", 0, 0),
            0xA9 => try self.emit(.@"i32.trunc_f32_u", 0, 0),
            0xAA => try self.emit(.@"i32.trunc_f64_s", 0, 0),
            0xAB => try self.emit(.@"i32.trunc_f64_u", 0, 0),
            0xAC => try self.emit(.@"i64.extend_i32_s", 0, 0),
            0xAD => try self.emit(.@"i64.extend_i32_u", 0, 0),
            0xAE => try self.emit(.@"i64.trunc_f32_s", 0, 0),
            0xAF => try self.emit(.@"i64.trunc_f32_u", 0, 0),
            0xB0 => try self.emit(.@"i64.trunc_f64_s", 0, 0),
            0xB1 => try self.emit(.@"i64.trunc_f64_u", 0, 0),
            0xB2 => try self.emit(.@"f32.convert_i32_s", 0, 0),
            0xB3 => try self.emit(.@"f32.convert_i32_u", 0, 0),
            0xB4 => try self.emit(.@"f32.convert_i64_s", 0, 0),
            0xB5 => try self.emit(.@"f32.convert_i64_u", 0, 0),
            0xB6 => try self.emit(.@"f32.demote_f64", 0, 0),
            0xB7 => try self.emit(.@"f64.convert_i32_s", 0, 0),
            0xB8 => try self.emit(.@"f64.convert_i32_u", 0, 0),
            0xB9 => try self.emit(.@"f64.convert_i64_s", 0, 0),
            0xBA => try self.emit(.@"f64.convert_i64_u", 0, 0),
            0xBB => try self.emit(.@"f64.promote_f32", 0, 0),
            0xBC => try self.emit(.@"i32.reinterpret_f32", 0, 0),
            0xBD => try self.emit(.@"i64.reinterpret_f64", 0, 0),
            0xBE => try self.emit(.@"f32.reinterpret_i32", 0, 0),
            0xBF => try self.emit(.@"f64.reinterpret_i64", 0, 0),

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

    /// br_if / call / global.get / global.set: read uleb32 → payload.
    fn emitUlebPayload(self: *Lowerer, op: ZirOp) Error!void {
        const v = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(op, v, 0);
    }

    /// memarg-bearing op (load*/store*): payload = offset, extra = align.
    fn emitMemarg(self: *Lowerer, op: ZirOp) Error!void {
        const align_arg = try leb128.readUleb128(u32, self.body, &self.pos);
        const offset = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(op, offset, align_arg);
    }

    /// memory.size / memory.grow: must be followed by reserved 0x00 byte.
    fn emitMemoryReserved(self: *Lowerer, op: ZirOp) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.BadBlockType;
        self.pos += 1;
        try self.emit(op, 0, 0);
    }

    /// call_indirect: read type_idx + reserved 0x00 byte (table_idx = 0).
    fn emitCallIndirect(self: *Lowerer) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.BadBlockType;
        self.pos += 1;
        try self.emit(.@"call_indirect", type_idx, 0);
    }

    /// br_table: emit ZirOp.br_table with payload = count of labels.
    /// The label-vec + default ride in `out.branch_targets` (per
    /// `ZirFunc.branch_targets` slot in §4.2 / 1.1). The br_table
    /// instr's `extra` is the start index into branch_targets; payload
    /// is the count (not including default — default is at start+count).
    fn emitBrTable(self: *Lowerer) Error!void {
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        const start: u32 = @intCast(self.out.branch_targets.items.len);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const d = try leb128.readUleb128(u32, self.body, &self.pos);
            try self.out.branch_targets.append(self.alloc, d);
        }
        const default = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.out.branch_targets.append(self.alloc, default);
        try self.emit(.@"br_table", count, start);
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
