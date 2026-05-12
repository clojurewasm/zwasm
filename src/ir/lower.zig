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
//!                                   extra = arity (count of result values
//!                                   the block leaves on the operand stack;
//!                                   0 for empty, 1 for single valtype, ≥1
//!                                   for typeidx form per Wasm 2.0
//!                                   multivalue)
//!   - `else` / `end` (block-end)  → payload = block index of the matching frame
//!   - `end` (function frame)      → payload = 0, terminates the lowering walk
//!
//! Scope tracks the validator's MVP smoke set 1:1; opcodes outside
//! that subset return `Error.NotImplemented` until §9.1 / 1.7 wires
//! per-feature handlers via `DispatchTable` per ROADMAP §A12.
//!
//! Zone 1 (`src/frontend/`) — may import Zone 0 (`src/support/leb128.zig`)
//! and Zone 1 (`src/ir/`). No upward imports.

const std = @import("std");

const leb128 = @import("../support/leb128.zig");
const zir = @import("zir.zig");

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

pub const max_control_stack: usize = 1024;

/// D-093 (d-1) — sentinel in `block_stack[]` for blocks opened
/// while the lowerer is in dead-code mode. closeBlock detects
/// this and skips `.end` emission + `out.blocks` mutation.
const unreachable_block_sentinel: u32 = std.math.maxInt(u32);

/// Lower the body bytes into `out`. `out` must be initialised
/// (typically via `ZirFunc.init`); lowering appends to its
/// `instrs` and `blocks` lists. The caller retains ownership and
/// must call `out.deinit(alloc)` when done.
///
/// `module_types` is the module's type section. Lowering needs it
/// to resolve s33 typeidx blocktypes (Wasm 2.0 multivalue). Pass
/// an empty slice for standalone-function bodies that never use
/// typeidx blocks.
pub fn lowerFunctionBody(
    alloc: Allocator,
    body: []const u8,
    out: *ZirFunc,
    module_types: []const FuncType,
) Error!void {
    var lo = Lowerer{
        .alloc = alloc,
        .body = body,
        .out = out,
        .pos = 0,
        .module_types = module_types,
    };
    try lo.run();
}

const Lowerer = struct {
    alloc: Allocator,
    body: []const u8,
    out: *ZirFunc,
    pos: usize,
    module_types: []const FuncType,

    block_stack: [max_control_stack]u32 = undefined,
    block_stack_len: usize = 0,

    /// D-093 (d-1) — Wasm spec §3.4 polymorphic-stack tracking.
    /// `null` = reachable; non-null = `block_stack_len` snapshot
    /// at the unconditional terminator (br / return / unreachable
    /// / br_table). While set, `emit()` becomes a no-op so dead
    /// ZirInstrs never reach the downstream regalloc / emit
    /// passes. Cleared at the matching `end` (closeBlock detects
    /// block_stack_len dropping below the saved depth) or at
    /// `else` (else-arm is reachable independent of then-arm's
    /// terminator). Block structure inside the dead region is
    /// still tracked via `block_stack` using the sentinel
    /// `unreachable_block_sentinel` so closeBlock knows whether
    /// to emit `.end` or just bookkeep.
    unreachable_at_depth: ?u32 = null,

    /// SIMD 16-byte const-pool builder (per ADR-0042). Each entry is
    /// the raw immediate of a `v128.const` / `i8x16.shuffle` op.
    /// Producing ops store the array index in `ZirInstr.payload`.
    /// Flushed to `out.simd_consts` at `run()` close.
    simd_consts: std.ArrayList([16]u8) = .empty,

    fn run(self: *Lowerer) Error!void {
        errdefer self.simd_consts.deinit(self.alloc);
        var fn_done = false;
        while (!fn_done) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const op = self.body[self.pos];
            self.pos += 1;
            try self.dispatch(op, &fn_done);
        }
        if (self.pos != self.body.len) return Error.TrailingBytes;
        // Flush SIMD const-pool builder to func.simd_consts (transfer
        // ownership). If empty, leave func.simd_consts null.
        if (self.simd_consts.items.len > 0) {
            self.out.simd_consts = try self.simd_consts.toOwnedSlice(self.alloc);
        } else {
            self.simd_consts.deinit(self.alloc);
        }
    }

    /// Append a 16-byte SIMD constant to the per-function pool;
    /// return the index for `ZirInstr.payload` encoding.
    fn appendSimdConst(self: *Lowerer, bytes: [16]u8) Error!u32 {
        const idx: u32 = @intCast(self.simd_consts.items.len);
        try self.simd_consts.append(self.alloc, bytes);
        return idx;
    }

    fn dispatch(self: *Lowerer, op: u8, fn_done: *bool) Error!void {
        switch (op) {
            0x00 => {
                try self.emit(.@"unreachable", 0, 0);
                self.markUnreachable();
            },
            0x01 => try self.emit(.nop, 0, 0),
            0x02 => try self.openBlock(.block, .block),
            0x03 => try self.openBlock(.loop, .loop),
            0x04 => try self.openBlock(.if_then, .@"if"),
            0x05 => try self.emitElse(),
            0x0B => {
                if (self.block_stack_len == 0) {
                    // D-093 (d-1): function-end is always part
                    // of the canonical IR; clear the dead-region
                    // flag (if set by a top-level br/return/
                    // unreachable) so the `.end` ZirInstr lands.
                    self.unreachable_at_depth = null;
                    try self.emit(.end, 0, 0);
                    fn_done.* = true;
                } else {
                    try self.closeBlock();
                }
            },
            0x0C => {
                const depth = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.br, depth, 0);
                self.markUnreachable();
            },
            0x0F => {
                try self.emit(.@"return", 0, 0);
                self.markUnreachable();
            },
            0x1A => try self.emit(.drop, 0, 0),
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
            0x0D => try self.emitUlebPayload(.br_if),
            0x0E => try self.emitBrTable(),
            0x10 => try self.emitUlebPayload(.call),
            0x11 => try self.emitCallIndirect(),

            // Parametric
            0x1B => try self.emit(.select, 0, 0),
            0x1C => {
                // select_typed: count valtype*. Wasm 2.0 requires
                // count = 1; consume + emit select_typed (runtime
                // semantics identical to select).
                const count = try leb128.readUleb128(u32, self.body, &self.pos);
                if (count != 1) return Error.UnexpectedOpcode;
                if (self.pos >= self.body.len) return Error.UnexpectedEnd;
                const t = self.body[self.pos];
                self.pos += 1;
                switch (t) {
                    0x7F, 0x7E, 0x7D, 0x7C, 0x70, 0x6F => {},
                    else => return Error.BadBlockType,
                }
                try self.emit(.select_typed, 0, t);
            },

            // Globals
            0x23 => try self.emitUlebPayload(.@"global.get"),
            0x24 => try self.emitUlebPayload(.@"global.set"),

            // Tables (Wasm 2.0 §9.2 / 2.3 chunk 5c)
            0x25 => try self.emitUlebPayload(.@"table.get"),
            0x26 => try self.emitUlebPayload(.@"table.set"),

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

            // Wasm 2.0 sign extension
            0xC0 => try self.emit(.@"i32.extend8_s", 0, 0),
            0xC1 => try self.emit(.@"i32.extend16_s", 0, 0),
            0xC2 => try self.emit(.@"i64.extend8_s", 0, 0),
            0xC3 => try self.emit(.@"i64.extend16_s", 0, 0),
            0xC4 => try self.emit(.@"i64.extend32_s", 0, 0),

            // Wasm 2.0 reference types
            0xD0 => {
                if (self.pos >= self.body.len) return Error.UnexpectedEnd;
                const b = self.body[self.pos];
                self.pos += 1;
                if (b != 0x70 and b != 0x6F) return Error.BadBlockType;
                try self.emit(.@"ref.null", 0, b);
            },
            0xD1 => try self.emit(.@"ref.is_null", 0, 0),
            0xD2 => {
                const idx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"ref.func", idx, 0);
            },

            // Wasm 2.0+ prefix opcodes (sat-trunc / bulk-memory / ...)
            0xFC => try self.emitPrefixFC(),

            // Wasm SIMD-128 prefix (§9.9 per ADR-0041).
            // Sub-opcode is uleb32; emit lands the ZirOp + immediate
            // payload mirroring the validator's prefix-0xFD catalogue
            // from §9.9/9.3.
            0xFD => try self.emitPrefixFD(),

            else => return Error.NotImplemented,
        }
    }

    fn emit(self: *Lowerer, op: ZirOp, payload: u32, extra: u32) Error!void {
        // D-093 (d-1): skip ZirInstr emission while in the dead
        // region following an unconditional terminator. Operand
        // bytes are still consumed by the caller (the dispatch
        // arm parses them before calling `emit`), so the lowerer
        // stays positionally correct in `self.body`.
        if (self.unreachable_at_depth != null) return;
        try self.out.instrs.append(self.alloc, .{ .op = op, .payload = payload, .extra = extra });
    }

    /// Wasm 2.0+ prefix-0xFC opcode group. Sub-opcode is uleb32.
    /// Sub-opcodes 0..7 are saturating truncations (§9.2 / 2.3
    /// chunk 2); 10/11 are memory.copy/memory.fill (chunk 4); other
    /// sub-opcodes land in later chunks.
    fn emitPrefixFC(self: *Lowerer) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            0 => try self.emit(.@"i32.trunc_sat_f32_s", 0, 0),
            1 => try self.emit(.@"i32.trunc_sat_f32_u", 0, 0),
            2 => try self.emit(.@"i32.trunc_sat_f64_s", 0, 0),
            3 => try self.emit(.@"i32.trunc_sat_f64_u", 0, 0),
            4 => try self.emit(.@"i64.trunc_sat_f32_s", 0, 0),
            5 => try self.emit(.@"i64.trunc_sat_f32_u", 0, 0),
            6 => try self.emit(.@"i64.trunc_sat_f64_s", 0, 0),
            7 => try self.emit(.@"i64.trunc_sat_f64_u", 0, 0),
            8 => {
                // memory.init: dataidx + reserved 0x00 byte.
                const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
                if (self.pos >= self.body.len) return Error.UnexpectedEnd;
                if (self.body[self.pos] != 0x00) return Error.BadBlockType;
                self.pos += 1;
                try self.emit(.@"memory.init", dataidx, 0);
            },
            9 => {
                // data.drop: dataidx.
                const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"data.drop", dataidx, 0);
            },
            12 => {
                // table.init x y: elemidx + tableidx.
                const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
                const tableidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.init", elemidx, tableidx);
            },
            13 => {
                // elem.drop x: elemidx.
                const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"elem.drop", elemidx, 0);
            },
            14 => {
                // table.copy x y: dst-tableidx + src-tableidx.
                const dst = try leb128.readUleb128(u32, self.body, &self.pos);
                const src = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.copy", dst, src);
            },
            15 => {
                const idx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.grow", idx, 0);
            },
            16 => {
                const idx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.size", idx, 0);
            },
            17 => {
                const idx = try leb128.readUleb128(u32, self.body, &self.pos);
                try self.emit(.@"table.fill", idx, 0);
            },
            10 => {
                // memory.copy: two reserved 0x00 bytes (src/dst memidx).
                if (self.pos + 2 > self.body.len) return Error.UnexpectedEnd;
                if (self.body[self.pos] != 0x00 or self.body[self.pos + 1] != 0x00) {
                    return Error.BadBlockType;
                }
                self.pos += 2;
                try self.emit(.@"memory.copy", 0, 0);
            },
            11 => {
                // memory.fill: one reserved 0x00 byte (memidx).
                if (self.pos >= self.body.len) return Error.UnexpectedEnd;
                if (self.body[self.pos] != 0x00) return Error.BadBlockType;
                self.pos += 1;
                try self.emit(.@"memory.fill", 0, 0);
            },
            else => return Error.NotImplemented,
        }
    }

    /// Wasm SIMD-128 prefix-0xFD opcode group (§9.9 per ADR-0041).
    /// Sub-opcode is uleb32; MVP catalogue mirrors the validator's
    /// 9.3 coverage. The 16-byte v128.const immediate + 16-byte
    /// shuffle lane immediate are stored via the ZirInstr's
    /// `payload`/`extra` fields as offsets into a side-table managed
    /// in 9.5 emit; for the 9.4 lower-pass MVP, we record the
    /// immediate's byte offset within `self.body` so emit can read
    /// the original bytes by position. Per ADR-0041 §"Decision" / 1
    /// (shape-as-variant), each sub-opcode resolves to a single
    /// ZirOp without nested dispatch.
    fn emitPrefixFD(self: *Lowerer) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            0 => try self.emitMemarg(.@"v128.load"),
            1 => try self.emitMemarg(.@"v128.load8x8_s"),
            2 => try self.emitMemarg(.@"v128.load8x8_u"),
            3 => try self.emitMemarg(.@"v128.load16x4_s"),
            4 => try self.emitMemarg(.@"v128.load16x4_u"),
            5 => try self.emitMemarg(.@"v128.load32x2_s"),
            6 => try self.emitMemarg(.@"v128.load32x2_u"),
            7 => try self.emitMemarg(.@"v128.load8_splat"),
            8 => try self.emitMemarg(.@"v128.load16_splat"),
            9 => try self.emitMemarg(.@"v128.load32_splat"),
            10 => try self.emitMemarg(.@"v128.load64_splat"),
            11 => try self.emitMemarg(.@"v128.store"),
            92 => try self.emitMemarg(.@"v128.load32_zero"),
            93 => try self.emitMemarg(.@"v128.load64_zero"),

            // §9.7 / 9.7-ba — load_lane × 4, store_lane × 4. Memarg +
            // 1-byte lane immediate. payload = offset; extra = lane.
            // align is dropped (unused in emit, validator already
            // consumed it for type-stack tracking).
            84 => try self.emitMemargLane(.@"v128.load8_lane"),
            85 => try self.emitMemargLane(.@"v128.load16_lane"),
            86 => try self.emitMemargLane(.@"v128.load32_lane"),
            87 => try self.emitMemargLane(.@"v128.load64_lane"),
            88 => try self.emitMemargLane(.@"v128.store8_lane"),
            89 => try self.emitMemargLane(.@"v128.store16_lane"),
            90 => try self.emitMemargLane(.@"v128.store32_lane"),
            91 => try self.emitMemargLane(.@"v128.store64_lane"),

            12 => {
                // v128.const: 16 immediate bytes. Per ADR-0042, copy
                // into per-function simd_consts pool; payload stores
                // the array index.
                if (self.pos + 16 > self.body.len) return Error.UnexpectedEnd;
                var bytes: [16]u8 = undefined;
                @memcpy(&bytes, self.body[self.pos..][0..16]);
                self.pos += 16;
                const idx = try self.appendSimdConst(bytes);
                try self.emit(.@"v128.const", idx, 0);
            },
            13 => {
                // i8x16.shuffle: 16 immediate lane bytes (each < 32).
                // Per ADR-0042, copy into per-function simd_consts pool;
                // payload stores the array index.
                if (self.pos + 16 > self.body.len) return Error.UnexpectedEnd;
                for (self.body[self.pos..][0..16]) |lane| {
                    if (lane >= 32) return Error.BadBlockType;
                }
                var bytes: [16]u8 = undefined;
                @memcpy(&bytes, self.body[self.pos..][0..16]);
                self.pos += 16;
                const idx = try self.appendSimdConst(bytes);
                try self.emit(.@"i8x16.shuffle", idx, 0);
            },
            14 => try self.emit(.@"i8x16.swizzle", 0, 0),

            // Splats: single ZirOp per shape; no immediate payload.
            15 => try self.emit(.@"i8x16.splat", 0, 0),
            16 => try self.emit(.@"i16x8.splat", 0, 0),
            17 => try self.emit(.@"i32x4.splat", 0, 0),
            18 => try self.emit(.@"i64x2.splat", 0, 0),
            19 => try self.emit(.@"f32x4.splat", 0, 0),
            20 => try self.emit(.@"f64x2.splat", 0, 0),

            // extract_lane / replace_lane: 1-byte lane immediate → payload.
            21 => try self.emitLaneByte(.@"i8x16.extract_lane_s"),
            22 => try self.emitLaneByte(.@"i8x16.extract_lane_u"),
            23 => try self.emitLaneByte(.@"i8x16.replace_lane"),
            24 => try self.emitLaneByte(.@"i16x8.extract_lane_s"),
            25 => try self.emitLaneByte(.@"i16x8.extract_lane_u"),
            26 => try self.emitLaneByte(.@"i16x8.replace_lane"),
            27 => try self.emitLaneByte(.@"i32x4.extract_lane"),
            28 => try self.emitLaneByte(.@"i32x4.replace_lane"),
            29 => try self.emitLaneByte(.@"i64x2.extract_lane"),
            30 => try self.emitLaneByte(.@"i64x2.replace_lane"),
            31 => try self.emitLaneByte(.@"f32x4.extract_lane"),
            32 => try self.emitLaneByte(.@"f32x4.replace_lane"),
            33 => try self.emitLaneByte(.@"f64x2.extract_lane"),
            34 => try self.emitLaneByte(.@"f64x2.replace_lane"),

            // Comparison / bitwise / int-arith / float-arith: full
            // op-by-op catalogue lands in 9.5/9.6 ARM64 emit + 9.7/
            // 9.8 x86_64 emit chunks alongside their lowering. For
            // 9.4 MVP we lower a representative subset (`i32x4.add`,
            // `v128.not`) demonstrating the pattern; remaining
            // sub-opcodes below the validator-accepted ranges return
            // `NotImplemented` here even though the validator
            // accepts them — the lower → emit pipeline closes the
            // gap as the emit chunks land.
            174 => try self.emit(.@"i32x4.add", 0, 0),
            77 => try self.emit(.@"v128.not", 0, 0),
            // §9.9 / 9.9-f-1: bitwise ops 78..82 lower-side wiring.
            // Validator now accepts these (split out of the 35..82
            // binop range); arm64 + x86_64 emit dispatch already
            // handles them via existing op_simd handlers.
            78 => try self.emit(.@"v128.and", 0, 0),
            79 => try self.emit(.@"v128.andnot", 0, 0),
            80 => try self.emit(.@"v128.or", 0, 0),
            81 => try self.emit(.@"v128.xor", 0, 0),
            82 => try self.emit(.@"v128.bitselect", 0, 0),
            // §9.9 / 9.9-f-5: f32x4 / f64x2 arith (sub-opcodes
            // 224..247). Validator already accepts them (binop /
            // unop split landed alongside this commit); emit
            // handlers in arm64/op_simd.zig + x86_64/op_simd.zig
            // are pre-wired in 9.6/9.7. Sub-opcode → ZirOp:
            //   224..235 → f32x4 (abs/neg/_/sqrt + add/sub/mul/
            //   div + min/max/pmin/pmax)
            //   236..247 → f64x2 (abs/neg/_/sqrt + add/sub/mul/
            //   div + min/max/pmin/pmax)
            // 226 + 238 are unused gaps in the spec.
            224 => try self.emit(.@"f32x4.abs", 0, 0),
            225 => try self.emit(.@"f32x4.neg", 0, 0),
            227 => try self.emit(.@"f32x4.sqrt", 0, 0),
            228 => try self.emit(.@"f32x4.add", 0, 0),
            229 => try self.emit(.@"f32x4.sub", 0, 0),
            230 => try self.emit(.@"f32x4.mul", 0, 0),
            231 => try self.emit(.@"f32x4.div", 0, 0),
            232 => try self.emit(.@"f32x4.min", 0, 0),
            233 => try self.emit(.@"f32x4.max", 0, 0),
            234 => try self.emit(.@"f32x4.pmin", 0, 0),
            235 => try self.emit(.@"f32x4.pmax", 0, 0),
            236 => try self.emit(.@"f64x2.abs", 0, 0),
            237 => try self.emit(.@"f64x2.neg", 0, 0),
            239 => try self.emit(.@"f64x2.sqrt", 0, 0),
            240 => try self.emit(.@"f64x2.add", 0, 0),
            241 => try self.emit(.@"f64x2.sub", 0, 0),
            242 => try self.emit(.@"f64x2.mul", 0, 0),
            243 => try self.emit(.@"f64x2.div", 0, 0),
            244 => try self.emit(.@"f64x2.min", 0, 0),
            245 => try self.emit(.@"f64x2.max", 0, 0),
            246 => try self.emit(.@"f64x2.pmin", 0, 0),
            247 => try self.emit(.@"f64x2.pmax", 0, 0),
            // §9.9 / 9.9-f-6: int arith (i8x16 / i16x8 / i32x4 /
            // i64x2). Sub-opcodes per Wasm SIMD spec:
            //   96..98 / 110..113: i8x16 abs/neg/popcnt + add/sub
            //   128..149: i16x8 abs/neg/q15mulr/all_true/bitmask
            //             /extend_*/add/add_sat/sub/sub_sat/mul
            //   160..182: i32x4 abs/neg/all_true/bitmask/extend_*
            //             /add/sub/mul/min/max/dot
            //   192..213: i64x2 abs/neg/all_true/bitmask/extend_*
            //             /shl/shr/add/sub/mul
            // ZirOps + emit handlers exist from 9.5..9.7; this just
            // closes the lower-side dispatch.
            96 => try self.emit(.@"i8x16.abs", 0, 0),
            97 => try self.emit(.@"i8x16.neg", 0, 0),
            98 => try self.emit(.@"i8x16.popcnt", 0, 0),
            110 => try self.emit(.@"i8x16.add", 0, 0),
            113 => try self.emit(.@"i8x16.sub", 0, 0),
            128 => try self.emit(.@"i16x8.abs", 0, 0),
            129 => try self.emit(.@"i16x8.neg", 0, 0),
            142 => try self.emit(.@"i16x8.add", 0, 0),
            145 => try self.emit(.@"i16x8.sub", 0, 0),
            149 => try self.emit(.@"i16x8.mul", 0, 0),
            160 => try self.emit(.@"i32x4.abs", 0, 0),
            161 => try self.emit(.@"i32x4.neg", 0, 0),
            177 => try self.emit(.@"i32x4.sub", 0, 0),
            181 => try self.emit(.@"i32x4.mul", 0, 0),
            192 => try self.emit(.@"i64x2.abs", 0, 0),
            193 => try self.emit(.@"i64x2.neg", 0, 0),
            206 => try self.emit(.@"i64x2.add", 0, 0),
            209 => try self.emit(.@"i64x2.sub", 0, 0),
            213 => try self.emit(.@"i64x2.mul", 0, 0),

            // §9.9 / 9.9-g-10 — int min/max + avgr_u (14 ops, lower-side
            // wiring). Per Wasm SIMD spec sub-op numbering:
            //   118..123: i8x16.{min_s, min_u, max_s, max_u, avgr_u}  (122 unused)
            //   150..155: i16x8.{min_s, min_u, max_s, max_u, avgr_u}  (154 unused)
            //   182..185: i32x4.{min_s, min_u, max_s, max_u}  (no i32x4.avgr_u)
            // Validator already routes these through opSimdBinop (94..211
            // binop fallthrough); ZirOps + per-arch emit handlers landed
            // alongside this chunk for ARM64. x86_64 dispatch pre-existed
            // since §9.7-au.
            118 => try self.emit(.@"i8x16.min_s", 0, 0),
            119 => try self.emit(.@"i8x16.min_u", 0, 0),
            120 => try self.emit(.@"i8x16.max_s", 0, 0),
            121 => try self.emit(.@"i8x16.max_u", 0, 0),
            123 => try self.emit(.@"i8x16.avgr_u", 0, 0),
            150 => try self.emit(.@"i16x8.min_s", 0, 0),
            151 => try self.emit(.@"i16x8.min_u", 0, 0),
            152 => try self.emit(.@"i16x8.max_s", 0, 0),
            153 => try self.emit(.@"i16x8.max_u", 0, 0),
            155 => try self.emit(.@"i16x8.avgr_u", 0, 0),
            182 => try self.emit(.@"i32x4.min_s", 0, 0),
            183 => try self.emit(.@"i32x4.min_u", 0, 0),
            184 => try self.emit(.@"i32x4.max_s", 0, 0),
            185 => try self.emit(.@"i32x4.max_u", 0, 0),

            // §9.9 / 9.9-g-2: SIMD comparison ops. ZirOps + per-arch
            // emit dispatch pre-existed; only the lower-side
            // sub-op→ZirOp wiring was missing. Wasm SIMD spec:
            //   35..44  i8x16.{eq, ne, lt_s, lt_u, gt_s, gt_u,
            //                  le_s, le_u, ge_s, ge_u}
            //   45..54  i16x8.{eq, ne, lt_s, lt_u, gt_s, gt_u,
            //                  le_s, le_u, ge_s, ge_u}
            //   55..64  i32x4.{eq, ne, lt_s, lt_u, gt_s, gt_u,
            //                  le_s, le_u, ge_s, ge_u}
            //   65..70  f32x4.{eq, ne, lt, gt, le, ge}
            //   71..76  f64x2.{eq, ne, lt, gt, le, ge}
            //  214..219 i64x2.{eq, ne, lt_s, gt_s, le_s, ge_s}
            //           — i64x2 only has signed compare per spec
            35 => try self.emit(.@"i8x16.eq", 0, 0),
            36 => try self.emit(.@"i8x16.ne", 0, 0),
            37 => try self.emit(.@"i8x16.lt_s", 0, 0),
            38 => try self.emit(.@"i8x16.lt_u", 0, 0),
            39 => try self.emit(.@"i8x16.gt_s", 0, 0),
            40 => try self.emit(.@"i8x16.gt_u", 0, 0),
            41 => try self.emit(.@"i8x16.le_s", 0, 0),
            42 => try self.emit(.@"i8x16.le_u", 0, 0),
            43 => try self.emit(.@"i8x16.ge_s", 0, 0),
            44 => try self.emit(.@"i8x16.ge_u", 0, 0),
            45 => try self.emit(.@"i16x8.eq", 0, 0),
            46 => try self.emit(.@"i16x8.ne", 0, 0),
            47 => try self.emit(.@"i16x8.lt_s", 0, 0),
            48 => try self.emit(.@"i16x8.lt_u", 0, 0),
            49 => try self.emit(.@"i16x8.gt_s", 0, 0),
            50 => try self.emit(.@"i16x8.gt_u", 0, 0),
            51 => try self.emit(.@"i16x8.le_s", 0, 0),
            52 => try self.emit(.@"i16x8.le_u", 0, 0),
            53 => try self.emit(.@"i16x8.ge_s", 0, 0),
            54 => try self.emit(.@"i16x8.ge_u", 0, 0),
            55 => try self.emit(.@"i32x4.eq", 0, 0),
            56 => try self.emit(.@"i32x4.ne", 0, 0),
            57 => try self.emit(.@"i32x4.lt_s", 0, 0),
            58 => try self.emit(.@"i32x4.lt_u", 0, 0),
            59 => try self.emit(.@"i32x4.gt_s", 0, 0),
            60 => try self.emit(.@"i32x4.gt_u", 0, 0),
            61 => try self.emit(.@"i32x4.le_s", 0, 0),
            62 => try self.emit(.@"i32x4.le_u", 0, 0),
            63 => try self.emit(.@"i32x4.ge_s", 0, 0),
            64 => try self.emit(.@"i32x4.ge_u", 0, 0),
            65 => try self.emit(.@"f32x4.eq", 0, 0),
            66 => try self.emit(.@"f32x4.ne", 0, 0),
            67 => try self.emit(.@"f32x4.lt", 0, 0),
            68 => try self.emit(.@"f32x4.gt", 0, 0),
            69 => try self.emit(.@"f32x4.le", 0, 0),
            70 => try self.emit(.@"f32x4.ge", 0, 0),
            71 => try self.emit(.@"f64x2.eq", 0, 0),
            72 => try self.emit(.@"f64x2.ne", 0, 0),
            73 => try self.emit(.@"f64x2.lt", 0, 0),
            74 => try self.emit(.@"f64x2.gt", 0, 0),
            75 => try self.emit(.@"f64x2.le", 0, 0),
            76 => try self.emit(.@"f64x2.ge", 0, 0),
            214 => try self.emit(.@"i64x2.eq", 0, 0),
            215 => try self.emit(.@"i64x2.ne", 0, 0),
            216 => try self.emit(.@"i64x2.lt_s", 0, 0),
            217 => try self.emit(.@"i64x2.gt_s", 0, 0),
            218 => try self.emit(.@"i64x2.le_s", 0, 0),
            219 => try self.emit(.@"i64x2.ge_s", 0, 0),

            // §9.9 / 9.9-g-3 + 9.9-g-19 — v128 → i32 reductions
            // (any_true, all_true, bitmask). Wasm SIMD spec §4.4
            // (vector reductions). Bitmask family wired per
            // ADR-0051 (arm64 extra_consts infrastructure).
            83 => try self.emit(.@"v128.any_true", 0, 0),
            99 => try self.emit(.@"i8x16.all_true", 0, 0),
            131 => try self.emit(.@"i16x8.all_true", 0, 0),
            163 => try self.emit(.@"i32x4.all_true", 0, 0),
            195 => try self.emit(.@"i64x2.all_true", 0, 0),
            100 => try self.emit(.@"i8x16.bitmask", 0, 0),
            132 => try self.emit(.@"i16x8.bitmask", 0, 0),
            164 => try self.emit(.@"i32x4.bitmask", 0, 0),
            196 => try self.emit(.@"i64x2.bitmask", 0, 0),

            // §9.9 / 9.9-g-6 — int extend ops. Per Wasm SIMD spec
            // (BinarySIMD.md authoritative numbering, NOT the
            // misleading lower.zig comment that misnumbered these
            // 134..137 / 166..169 / 199..202 — verified via
            // `~/Documents/OSS/WebAssembly/simd/proposals/simd/
            // BinarySIMD.md` which gives 0x87..0x8A / 0xA7..0xAA /
            // 0xC7..0xCA).
            //   135..138 i16x8.extend_{low,high}_i8x16_{s,u}
            //   167..170 i32x4.extend_{low,high}_i16x8_{s,u}
            //   199..202 i64x2.extend_{low,high}_i32x4_{s,u}
            135 => try self.emit(.@"i16x8.extend_low_i8x16_s", 0, 0),
            136 => try self.emit(.@"i16x8.extend_high_i8x16_s", 0, 0),
            137 => try self.emit(.@"i16x8.extend_low_i8x16_u", 0, 0),
            138 => try self.emit(.@"i16x8.extend_high_i8x16_u", 0, 0),
            167 => try self.emit(.@"i32x4.extend_low_i16x8_s", 0, 0),
            168 => try self.emit(.@"i32x4.extend_high_i16x8_s", 0, 0),
            169 => try self.emit(.@"i32x4.extend_low_i16x8_u", 0, 0),
            170 => try self.emit(.@"i32x4.extend_high_i16x8_u", 0, 0),
            199 => try self.emit(.@"i64x2.extend_low_i32x4_s", 0, 0),
            200 => try self.emit(.@"i64x2.extend_high_i32x4_s", 0, 0),
            201 => try self.emit(.@"i64x2.extend_low_i32x4_u", 0, 0),
            202 => try self.emit(.@"i64x2.extend_high_i32x4_u", 0, 0),

            // §9.9 / 9.9-g-7 — int shift family. Per spec 0x6B..6D /
            // 0x8B..8D / 0xAB..AD / 0xCB..CD. ARM64 emit currently
            // only handles shl (4 ops); shr_s / shr_u surface as
            // UnsupportedOp at compile until the next chunk lands
            // NEG-then-(U|S)SHL synthesis.
            107 => try self.emit(.@"i8x16.shl", 0, 0),
            108 => try self.emit(.@"i8x16.shr_s", 0, 0),
            109 => try self.emit(.@"i8x16.shr_u", 0, 0),
            139 => try self.emit(.@"i16x8.shl", 0, 0),
            140 => try self.emit(.@"i16x8.shr_s", 0, 0),
            141 => try self.emit(.@"i16x8.shr_u", 0, 0),
            171 => try self.emit(.@"i32x4.shl", 0, 0),
            172 => try self.emit(.@"i32x4.shr_s", 0, 0),
            173 => try self.emit(.@"i32x4.shr_u", 0, 0),
            203 => try self.emit(.@"i64x2.shl", 0, 0),
            204 => try self.emit(.@"i64x2.shr_s", 0, 0),
            205 => try self.emit(.@"i64x2.shr_u", 0, 0),

            else => return Error.NotImplemented,
        }
    }

    /// SIMD lane-byte op: read 1-byte lane immediate → payload.
    fn emitLaneByte(self: *Lowerer, op: ZirOp) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const lane = self.body[self.pos];
        self.pos += 1;
        try self.emit(op, lane, 0);
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

    /// memarg+lane op (load_lane / store_lane): payload = offset,
    /// extra = lane byte. align is dropped (unused in emit; the
    /// validator consumed it for type-stack tracking).
    fn emitMemargLane(self: *Lowerer, op: ZirOp) Error!void {
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // align
        const offset = try leb128.readUleb128(u32, self.body, &self.pos);
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const lane = self.body[self.pos];
        self.pos += 1;
        try self.emit(op, offset, lane);
    }

    /// memory.size / memory.grow: must be followed by reserved 0x00 byte.
    fn emitMemoryReserved(self: *Lowerer, op: ZirOp) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.BadBlockType;
        self.pos += 1;
        try self.emit(op, 0, 0);
    }

    /// call_indirect: type_idx + table_idx (Wasm 2.0). In Wasm 1.0
    /// the table_idx is a single reserved 0x00 byte which decodes
    /// as uleb32(0); reading it as uleb32 is backwards-compatible.
    fn emitCallIndirect(self: *Lowerer) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const table_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.emit(.call_indirect, type_idx, table_idx);
    }

    /// br_table: emit ZirOp.br_table with payload = count of labels.
    /// The label-vec + default ride in `out.branch_targets` (per
    /// `ZirFunc.branch_targets` slot in §4.2 / 1.1). The br_table
    /// instr's `extra` is the start index into branch_targets; payload
    /// is the count (not including default — default is at start+count).
    fn emitBrTable(self: *Lowerer) Error!void {
        // D-093 (d-1): branch_targets is a per-function pool the
        // emit reads via (start, count). In dead code the pool
        // doesn't need new entries (emit skips the .br_table
        // ZirInstr); parse the operands to stay positional, but
        // don't grow `out.branch_targets`.
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        if (self.unreachable_at_depth != null) {
            var i: u32 = 0;
            while (i < count) : (i += 1) _ = try leb128.readUleb128(u32, self.body, &self.pos);
            _ = try leb128.readUleb128(u32, self.body, &self.pos); // default
            // Already in dead region — flag stays set; no
            // markUnreachable needed.
            return;
        }
        const start: u32 = @intCast(self.out.branch_targets.items.len);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const d = try leb128.readUleb128(u32, self.body, &self.pos);
            try self.out.branch_targets.append(self.alloc, d);
        }
        const default = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.out.branch_targets.append(self.alloc, default);
        try self.emit(.br_table, count, start);
        self.markUnreachable();
    }

    /// D-093 (d-1) helper: enter the dead-code region. Records
    /// `block_stack_len` at the terminator's site so the matching
    /// `end` / `else` knows when to clear. Idempotent — repeated
    /// terminators in dead code don't update the depth.
    fn markUnreachable(self: *Lowerer) void {
        if (self.unreachable_at_depth == null) {
            self.unreachable_at_depth = @intCast(self.block_stack_len);
        }
    }

    fn openBlock(self: *Lowerer, kind: BlockKind, op: ZirOp) Error!void {
        const arity = try self.readBlockArity();
        if (self.block_stack_len == max_control_stack) return Error.ControlStackOverflow;

        // D-093 (d-1): block opened inside the dead region —
        // bookkeep depth via the sentinel, skip BlockInfo /
        // ZirInstr allocation. The matching `end` (closeBlock
        // detects the sentinel) just pops.
        if (self.unreachable_at_depth != null) {
            self.block_stack[self.block_stack_len] = unreachable_block_sentinel;
            self.block_stack_len += 1;
            return;
        }

        const block_idx: u32 = @intCast(self.out.blocks.items.len);
        const start_inst: u32 = @intCast(self.out.instrs.items.len);
        try self.out.blocks.append(self.alloc, .{
            .kind = kind,
            .start_inst = start_inst,
            .end_inst = 0,
        });
        try self.emit(op, block_idx, arity);

        self.block_stack[self.block_stack_len] = block_idx;
        self.block_stack_len += 1;
    }

    /// Decode a Wasm blocktype and return its arity (count of result
    /// types the block pushes back at end). Wasm 1.0 forms (single
    /// byte 0x40 / 0x7F..0x7C) yield 0 or 1. Wasm 2.0 multivalue
    /// (s33 typeidx ≥ 0) yields the typeidx'd FuncType's results
    /// length. D-035 chunk-d035-a lifts the previous `params.len !=
    /// 0` rejection — multi-param + multi-result blocks now flow
    /// through. The `arity` slot still communicates only the result
    /// count; param consumption + push-back is handled by the
    /// validator's stack discipline (the operand stack already
    /// carries the params at block entry — emit sees them as
    /// existing vregs).
    fn readBlockArity(self: *Lowerer) Error!u32 {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const sleb = leb128.readSleb128(i32, self.body, &self.pos) catch
            return Error.BadBlockType;
        if (sleb < 0) {
            return switch (sleb) {
                -64 => @as(u32, 0), // 0x40 empty
                // §9.9 / 9.9-f-2: -5 (0x7B) = v128 single valtype
                // (Wasm 2.0 SIMD per spec §5.3.5).
                -1, -2, -3, -4, -5 => @as(u32, 1), // single valtype
                else => Error.BadBlockType,
            };
        }
        const idx: u32 = @intCast(sleb);
        if (idx >= self.module_types.len) return Error.BadBlockType;
        const ft = self.module_types[idx];
        return @intCast(ft.results.len);
    }

    fn closeBlock(self: *Lowerer) Error!void {
        self.block_stack_len -= 1;
        const block_idx = self.block_stack[self.block_stack_len];

        // D-093 (d-1): sentinel marks a block opened entirely
        // inside dead code — pop + return, no ZirInstr / no
        // out.blocks update. The unreachable flag itself stays
        // set (we're still inside the outer dead region).
        if (block_idx == unreachable_block_sentinel) return;

        // If popping this (live) block crosses the depth where
        // the unreachable region started, clear the flag NOW so
        // the `.end` ZirInstr below emits cleanly. The block
        // that "started the unreachable region" is the one that
        // contained the br/return/unreachable; its end is part
        // of the reachable structure.
        if (self.unreachable_at_depth) |d| {
            if (self.block_stack_len < d) {
                self.unreachable_at_depth = null;
            }
        }

        const end_inst: u32 = @intCast(self.out.instrs.items.len);
        try self.emit(.end, block_idx, 0);
        self.out.blocks.items[block_idx].end_inst = end_inst;
    }

    fn emitElse(self: *Lowerer) Error!void {
        if (self.block_stack_len == 0) return Error.UnexpectedOpcode;
        const block_idx = self.block_stack[self.block_stack_len - 1];

        // D-093 (d-1): else of a dead-code if — stays dead.
        if (block_idx == unreachable_block_sentinel) return;

        // If the then-arm's br/return/unreachable made us
        // unreachable AT THIS if-block's depth, the else-arm is
        // reachable independent of the then-arm; clear the flag.
        // Deeper unreachable depths (from nested blocks inside
        // the then-arm) were already cleared at their matching
        // ends per closeBlock's check.
        if (self.unreachable_at_depth) |d| {
            if (self.block_stack_len == d) {
                self.unreachable_at_depth = null;
            }
        }

        const else_pc: u32 = @intCast(self.out.instrs.items.len);
        self.out.blocks.items[block_idx].kind = .else_open;
        self.out.blocks.items[block_idx].else_inst = else_pc;
        try self.emit(.@"else", block_idx, 0);
    }
};
