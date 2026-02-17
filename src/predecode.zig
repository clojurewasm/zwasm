// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Wasm bytecode predecoder — converts variable-width bytecode to fixed-width
//! 8-byte instructions at module load time. Eliminates LEB128 decode and
//! bounds checks at dispatch time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const leb128 = @import("leb128.zig");
const Reader = leb128.Reader;

/// Fixed-width 8-byte predecoded instruction.
pub const PreInstr = extern struct {
    opcode: u16,
    extra: u16,
    operand: u32,
};

comptime {
    std.debug.assert(@sizeOf(PreInstr) == 8);
}

/// Predecoded function IR — code array + constant pool.
pub const IrFunc = struct {
    code: []PreInstr,
    pool64: []u64, // i64.const, f64.const values
    alloc: Allocator,

    pub fn deinit(self: *IrFunc) void {
        self.alloc.free(self.code);
        if (self.pool64.len > 0) self.alloc.free(self.pool64);
    }
};

// Internal marker opcodes for data words
pub const OP_IF_DATA: u16 = 0xFF00;
pub const OP_BR_TABLE_ENTRY: u16 = 0xFF01;

// Prefix bases for flattened opcodes
pub const MISC_BASE: u16 = 0xFC00;
pub const SIMD_BASE: u16 = 0xFD00;

/// Block arity encoding in extra field:
/// - bits 14:0 = arity value (0 or 1 for simple cases)
/// - bit 15 = 1 if value is a type_index (resolve arity at runtime)
pub const ARITY_TYPE_INDEX_FLAG: u16 = 0x8000;

// Fused superinstruction opcodes (0xE0-0xEF).
// Peephole pass replaces common multi-instruction patterns with single dispatches.
// Consumed instructions remain in-place (skipped by handler via pc += N).
pub const OP_LOCAL_GET_GET: u16 = 0xE0; // local.get A + local.get B
pub const OP_LOCAL_GET_CONST: u16 = 0xE1; // local.get A + i32.const C
pub const OP_LOCALS_ADD: u16 = 0xE2; // local.get A + local.get B + i32.add
pub const OP_LOCALS_SUB: u16 = 0xE3; // local.get A + local.get B + i32.sub
pub const OP_LOCAL_CONST_ADD: u16 = 0xE4; // local.get A + i32.const C + i32.add
pub const OP_LOCAL_CONST_SUB: u16 = 0xE5; // local.get A + i32.const C + i32.sub
pub const OP_LOCAL_CONST_LT_S: u16 = 0xE6; // local.get A + i32.const C + i32.lt_s
pub const OP_LOCAL_CONST_GE_S: u16 = 0xE7; // local.get A + i32.const C + i32.ge_s
pub const OP_LOCAL_CONST_LT_U: u16 = 0xE8; // local.get A + i32.const C + i32.lt_u
pub const OP_LOCALS_GT_S: u16 = 0xE9; // local.get A + local.get B + i32.gt_s
pub const OP_LOCALS_LE_S: u16 = 0xEA; // local.get A + local.get B + i32.le_s

pub const PredecodeError = error{
    UnsupportedSimd,
    OutOfMemory,
    InvalidWasm,
};

const BlockEntry = struct {
    kind: enum { block, loop, @"if" },
    ir_pos: u32,
    has_else: bool = false,
    else_ir_pos: u32 = 0,
};

/// Predecode wasm bytecode into fixed-width IR.
/// Returns null if the function contains unsupported opcodes (e.g., SIMD).
pub fn predecode(alloc: Allocator, bytecode: []const u8) PredecodeError!?*IrFunc {
    var code: std.ArrayList(PreInstr) = .empty;
    errdefer code.deinit(alloc);
    var pool64: std.ArrayList(u64) = .empty;
    errdefer pool64.deinit(alloc);
    var block_stack: std.ArrayList(BlockEntry) = .empty;
    defer block_stack.deinit(alloc);

    var reader = Reader.init(bytecode);

    while (reader.hasMore()) {
        const byte = reader.readByte() catch break;

        switch (byte) {
            // -- Block structure --
            0x02 => { // block
                const arity_enc = readBlockTypeEncoded(&reader) catch return error.InvalidWasm;
                const pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .opcode = 0x02, .extra = arity_enc, .operand = 0 });
                try block_stack.append(alloc, .{ .kind = .block, .ir_pos = pos });
            },
            0x03 => { // loop
                const arity_enc = readBlockTypeEncoded(&reader) catch return error.InvalidWasm;
                const pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .opcode = 0x03, .extra = arity_enc, .operand = pos + 1 });
                try block_stack.append(alloc, .{ .kind = .loop, .ir_pos = pos });
            },
            // Exception handling — bail to bytecode interpreter
            0x08, 0x0A, 0x1F => {
                code.deinit(alloc);
                pool64.deinit(alloc);
                return null;
            },
            // Tail call
            0x12 => { // return_call
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x12, .extra = 0, .operand = idx });
            },
            0x13 => { // return_call_indirect
                const type_idx = reader.readU32() catch return error.InvalidWasm;
                const table_idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x13, .extra = @intCast(table_idx), .operand = type_idx });
            },
            0x04 => { // if
                const arity_enc = readBlockTypeEncoded(&reader) catch return error.InvalidWasm;
                const pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .opcode = 0x04, .extra = arity_enc, .operand = 0 });
                try code.append(alloc, .{ .opcode = OP_IF_DATA, .extra = 0, .operand = 0 });
                try block_stack.append(alloc, .{ .kind = .@"if", .ir_pos = pos });
            },
            0x05 => { // else
                if (block_stack.items.len > 0) {
                    const top = &block_stack.items[block_stack.items.len - 1];
                    const else_pos: u32 = @intCast(code.items.len);
                    try code.append(alloc, .{ .opcode = 0x05, .extra = 0, .operand = 0 });
                    code.items[top.ir_pos].operand = else_pos + 1;
                    top.has_else = true;
                    top.else_ir_pos = else_pos;
                }
            },
            0x0B => { // end
                const end_pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .opcode = 0x0B, .extra = 0, .operand = 0 });
                if (block_stack.pop()) |entry| {
                    const after_end = end_pos + 1;
                    switch (entry.kind) {
                        .block => {
                            code.items[entry.ir_pos].operand = after_end;
                        },
                        .loop => {},
                        .@"if" => {
                            if (entry.has_else) {
                                code.items[entry.else_ir_pos].operand = after_end;
                                code.items[entry.ir_pos + 1].operand = after_end;
                                code.items[entry.ir_pos + 1].extra = 1;
                            } else {
                                code.items[entry.ir_pos].operand = after_end;
                                code.items[entry.ir_pos + 1].operand = after_end;
                                code.items[entry.ir_pos + 1].extra = 0;
                            }
                        },
                    }
                }
            },

            // -- Branch --
            0x0C => { // br
                const depth = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x0C, .extra = 0, .operand = depth });
            },
            0x0D => { // br_if
                const depth = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x0D, .extra = 0, .operand = depth });
            },
            0x0E => { // br_table
                const count = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x0E, .extra = 0, .operand = count });
                for (0..count + 1) |_| {
                    const depth = reader.readU32() catch return error.InvalidWasm;
                    try code.append(alloc, .{ .opcode = OP_BR_TABLE_ENTRY, .extra = 0, .operand = depth });
                }
            },

            // -- Call --
            0x10 => { // call
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x10, .extra = 0, .operand = idx });
            },
            0x11 => { // call_indirect
                const type_idx = reader.readU32() catch return error.InvalidWasm;
                const table_idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x11, .extra = @intCast(table_idx), .operand = type_idx });
            },

            // -- Simple control --
            0x00 => try emit0(alloc, &code, 0x00), // unreachable
            0x01 => try emit0(alloc, &code, 0x01), // nop
            0x0F => try emit0(alloc, &code, 0x0F), // return

            // -- Parametric --
            0x1A => try emit0(alloc, &code, 0x1A), // drop
            0x1B => try emit0(alloc, &code, 0x1B), // select
            0x1C => { // select_t
                const n = reader.readU32() catch return error.InvalidWasm;
                for (0..n) |_| _ = reader.readByte() catch return error.InvalidWasm;
                try emit0(alloc, &code, 0x1B);
            },

            // -- Variable access --
            0x20, 0x21, 0x22, 0x23, 0x24 => {
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = @intCast(byte), .extra = 0, .operand = idx });
            },

            // -- Table access --
            0x25, 0x26 => {
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = @intCast(byte), .extra = 0, .operand = idx });
            },

            // -- Memory load/store (alignment [+ memidx] + offset) --
            0x28...0x3E => {
                const align_val = reader.readU32() catch return error.InvalidWasm;
                const memidx: u16 = if (align_val & 0x40 != 0)
                    @intCast(reader.readU32() catch return error.InvalidWasm)
                else
                    0;
                const offset = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = @intCast(byte), .extra = memidx, .operand = offset });
            },

            // -- Memory misc (memidx) --
            0x3F, 0x40 => {
                const memidx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = @intCast(byte), .extra = @intCast(memidx), .operand = 0 });
            },

            // -- Constants --
            0x41 => { // i32.const
                const val = reader.readI32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0x41, .extra = 0, .operand = @bitCast(val) });
            },
            0x42 => { // i64.const
                const val = reader.readI64() catch return error.InvalidWasm;
                const pool_idx: u32 = @intCast(pool64.items.len);
                try pool64.append(alloc, @bitCast(val));
                try code.append(alloc, .{ .opcode = 0x42, .extra = 0, .operand = pool_idx });
            },
            0x43 => { // f32.const
                const bytes = reader.readBytes(4) catch return error.InvalidWasm;
                const val = std.mem.readInt(u32, bytes[0..4], .little);
                try code.append(alloc, .{ .opcode = 0x43, .extra = 0, .operand = val });
            },
            0x44 => { // f64.const
                const bytes = reader.readBytes(8) catch return error.InvalidWasm;
                const val = std.mem.readInt(u64, bytes[0..8], .little);
                const pool_idx: u32 = @intCast(pool64.items.len);
                try pool64.append(alloc, val);
                try code.append(alloc, .{ .opcode = 0x44, .extra = 0, .operand = pool_idx });
            },

            // -- No-operand opcodes (comparison, arithmetic, conversion, sign extension) --
            0x45...0xC4 => try emit0(alloc, &code, @intCast(byte)),

            // -- Reference types --
            0xD0 => { // ref_null (heap type as S33 LEB128)
                _ = reader.readI33() catch return error.InvalidWasm;
                try emit0(alloc, &code, 0xD0);
            },
            0xD1 => try emit0(alloc, &code, 0xD1), // ref_is_null
            0xD2 => { // ref_func
                const idx = reader.readU32() catch return error.InvalidWasm;
                try code.append(alloc, .{ .opcode = 0xD2, .extra = 0, .operand = idx });
            },

            // -- Function references (bail to bytecode interpreter) --
            0x14, 0x15, 0xD4, 0xD5, 0xD6 => {
                code.deinit(alloc);
                pool64.deinit(alloc);
                return null;
            },

            // -- Misc prefix (0xFC) --
            0xFC => {
                if (!try predecodeMisc(alloc, &code, &reader)) return error.InvalidWasm;
            },

            // -- GC prefix (0xFB) — not supported, fall back --
            0xFB => {
                code.deinit(alloc);
                pool64.deinit(alloc);
                return null;
            },

            // -- SIMD prefix (0xFD) --
            0xFD => {
                if (!try predecodeSimd(alloc, &code, &pool64, &reader)) return error.InvalidWasm;
            },

            // -- Atomic prefix (0xFE) — not supported in predecode, fall back --
            0xFE => {
                code.deinit(alloc);
                pool64.deinit(alloc);
                return null;
            },

            else => try emit0(alloc, &code, @intCast(byte)),
        }
    }

    // Peephole: fuse common patterns before finalizing
    fusePass(code.items);

    const ir = try alloc.create(IrFunc);
    ir.* = .{
        .code = try code.toOwnedSlice(alloc),
        .pool64 = if (pool64.items.len > 0) try pool64.toOwnedSlice(alloc) else &.{},
        .alloc = alloc,
    };
    return ir;
}

fn emit0(alloc: Allocator, code: *std.ArrayList(PreInstr), op: u16) !void {
    try code.append(alloc, .{ .opcode = op, .extra = 0, .operand = 0 });
}

fn readBlockTypeEncoded(reader: *Reader) !u16 {
    if (reader.pos >= reader.bytes.len) return error.EndOfStream;
    const byte = reader.bytes[reader.pos];
    if (byte == 0x40) {
        reader.pos += 1;
        return 0; // void block
    }
    // Single-byte value types: MVP (0x7B-0x7F) + GC/EH shorthands (0x69-0x74)
    if (byte >= 0x69 and byte <= 0x7F) {
        reader.pos += 1;
        return 1;
    }
    // ref type encoding: 0x63 = (ref null ht), 0x64 = (ref ht)
    if (byte == 0x63 or byte == 0x64) {
        reader.pos += 1; // consume 0x63/0x64
        _ = try reader.readI33(); // consume heap type
        return 1; // single ref type result
    }
    const idx = try reader.readI33();
    return ARITY_TYPE_INDEX_FLAG | @as(u16, @intCast(@as(u32, @intCast(idx))));
}

fn predecodeMisc(alloc: Allocator, code: *std.ArrayList(PreInstr), reader: *Reader) !bool {
    const sub = reader.readU32() catch return false;
    const ir_op: u16 = MISC_BASE | @as(u16, @intCast(sub & 0xFF));
    switch (sub) {
        // trunc_sat ops (no immediate)
        0x00...0x07 => try emit0(alloc, code, ir_op),
        // memory.copy (dst_memidx + src_memidx)
        0x0A => {
            const dst = reader.readU32() catch return false;
            const src = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = @intCast(dst), .operand = src });
        },
        // memory.fill (memidx)
        0x0B => {
            const memidx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = memidx });
        },
        // memory.init (data_idx + memidx)
        0x08 => {
            const data_idx = reader.readU32() catch return false;
            const memidx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = @intCast(memidx), .operand = data_idx });
        },
        // data.drop
        0x09 => {
            const data_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = data_idx });
        },
        // table.init 0x0C (elem_idx + table_idx)
        0x0C => {
            const elem_idx = reader.readU32() catch return false;
            const table_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = @intCast(table_idx), .operand = elem_idx });
        },
        // elem.drop 0x0D (elem_idx)
        0x0D => {
            const elem_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = elem_idx });
        },
        // table.copy 0x0E (dst_table + src_table)
        0x0E => {
            const dst = reader.readU32() catch return false;
            const src = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = @intCast(dst), .operand = src });
        },
        // table.grow 0x0F, table.size 0x10 (table_idx)
        0x0F, 0x10 => {
            const table_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = table_idx });
        },
        // table.fill 0x11 (table_idx)
        0x11 => {
            const table_idx = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = table_idx });
        },
        else => try emit0(alloc, code, ir_op),
    }
    return true;
}

fn predecodeSimd(alloc: Allocator, code: *std.ArrayList(PreInstr), pool64: *std.ArrayList(u64), reader: *Reader) !bool {
    const sub = reader.readU32() catch return false;
    if (sub > 0x113) return false; // unknown SIMD sub-opcode
    const ir_op: u16 = SIMD_BASE + @as(u16, @intCast(sub));
    switch (sub) {
        // Memory ops: memarg (align [+ memidx] + offset)
        // v128.load (0x00) through v128.store (0x0B), v128.load32_zero (0x5C), v128.load64_zero (0x5D)
        0x00...0x0B, 0x5C, 0x5D => {
            const align_val = reader.readU32() catch return false;
            const memidx: u16 = if (align_val & 0x40 != 0)
                @intCast(reader.readU32() catch return false)
            else
                0;
            const offset = reader.readU32() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = memidx, .operand = offset });
        },
        // v128.const (0x0C): 16 raw bytes → store as 2 pool64 entries
        0x0C => {
            const bytes = reader.readBytes(16) catch return false;
            const pool_idx: u32 = @intCast(pool64.items.len);
            const lo = std.mem.readInt(u64, bytes[0..8], .little);
            const hi = std.mem.readInt(u64, bytes[8..16], .little);
            try pool64.append(alloc, lo);
            try pool64.append(alloc, hi);
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = pool_idx });
        },
        // i8x16.shuffle (0x0D): 16 lane bytes → store as 2 pool64 entries
        0x0D => {
            const bytes = reader.readBytes(16) catch return false;
            const pool_idx: u32 = @intCast(pool64.items.len);
            const lo = std.mem.readInt(u64, bytes[0..8], .little);
            const hi = std.mem.readInt(u64, bytes[8..16], .little);
            try pool64.append(alloc, lo);
            try pool64.append(alloc, hi);
            try code.append(alloc, .{ .opcode = ir_op, .extra = 0, .operand = pool_idx });
        },
        // Extract/replace lane (0x15-0x22): 1 byte lane index
        0x15...0x22 => {
            const lane = reader.readByte() catch return false;
            try code.append(alloc, .{ .opcode = ir_op, .extra = lane, .operand = 0 });
        },
        // Lane load/store (0x54-0x5B): memarg + 1 byte lane
        0x54...0x5B => {
            const align_val = reader.readU32() catch return false;
            const memidx: u16 = if (align_val & 0x40 != 0)
                @intCast(reader.readU32() catch return false)
            else
                0;
            const offset = reader.readU32() catch return false;
            const lane = reader.readByte() catch return false;
            // Pack lane into extra high byte, memidx into extra low byte
            try code.append(alloc, .{ .opcode = ir_op, .extra = (@as(u16, lane) << 8) | memidx, .operand = offset });
        },
        // All other SIMD ops: no immediates
        else => try emit0(alloc, code, ir_op),
    }
    return true;
}

/// Peephole fusion pass: replace common instruction sequences with single
/// fused opcodes. Operates in-place; consumed instructions are skipped by
/// fused handlers (pc += N). Does not change code length or branch targets.
pub fn fusePass(code: []PreInstr) void {
    const n = code.len;
    if (n < 2) return;

    // Pass 1: Collect branch target positions. Fusing across these is unsafe.
    var targets: [65536]bool = .{false} ** 65536;
    for (code) |instr| {
        switch (instr.opcode) {
            0x02 => if (instr.operand < 65536) { targets[instr.operand] = true; }, // block forward
            0x03 => if (instr.operand < 65536) { targets[instr.operand] = true; }, // loop start
            0x04 => if (instr.operand < 65536) { targets[instr.operand] = true; }, // if → else
            OP_IF_DATA => if (instr.operand < 65536) { targets[instr.operand] = true; }, // if → end
            0x05 => if (instr.operand < 65536) { targets[instr.operand] = true; }, // else → end
            else => {},
        }
    }

    // Pass 2: Scan for fuseable patterns (3-instr first, then 2-instr).
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = code[i];

        // 3-instruction patterns (need i+1 and i+2 not to be targets)
        if (i + 2 < n and !targets[i + 1] and !targets[i + 2]) {
            const b = code[i + 1];
            const c = code[i + 2];

            // local.get A + local.get B + i32.op
            if (a.opcode == 0x20 and b.opcode == 0x20 and a.operand <= 0xFFFF and b.operand <= 0xFFFF) {
                const fused: ?u16 = switch (c.opcode) {
                    0x6A => OP_LOCALS_ADD,
                    0x6B => OP_LOCALS_SUB,
                    0x4A => OP_LOCALS_GT_S,
                    0x4C => OP_LOCALS_LE_S,
                    else => null,
                };
                if (fused) |op| {
                    code[i] = .{ .opcode = op, .extra = @intCast(a.operand), .operand = b.operand };
                    i += 2;
                    continue;
                }
            }

            // local.get A + i32.const C + i32.op
            if (a.opcode == 0x20 and b.opcode == 0x41 and a.operand <= 0xFFFF) {
                const fused: ?u16 = switch (c.opcode) {
                    0x6A => OP_LOCAL_CONST_ADD,
                    0x6B => OP_LOCAL_CONST_SUB,
                    0x48 => OP_LOCAL_CONST_LT_S,
                    0x4E => OP_LOCAL_CONST_GE_S,
                    0x49 => OP_LOCAL_CONST_LT_U,
                    else => null,
                };
                if (fused) |op| {
                    code[i] = .{ .opcode = op, .extra = @intCast(a.operand), .operand = b.operand };
                    i += 2;
                    continue;
                }
            }
        }

        // 2-instruction patterns (need i+1 not to be a target)
        if (i + 1 < n and !targets[i + 1]) {
            const b = code[i + 1];

            if (a.opcode == 0x20 and b.opcode == 0x20 and a.operand <= 0xFFFF and b.operand <= 0xFFFF) {
                code[i] = .{ .opcode = OP_LOCAL_GET_GET, .extra = @intCast(a.operand), .operand = b.operand };
                i += 1;
                continue;
            }

            if (a.opcode == 0x20 and b.opcode == 0x41 and a.operand <= 0xFFFF) {
                code[i] = .{ .opcode = OP_LOCAL_GET_CONST, .extra = @intCast(a.operand), .operand = b.operand };
                i += 1;
                continue;
            }
        }
    }
}

/// Resolve block arity from encoded extra field.
pub fn resolveArity(extra: u16, types: anytype) usize {
    if (extra & ARITY_TYPE_INDEX_FLAG != 0) {
        const idx = extra & ~ARITY_TYPE_INDEX_FLAG;
        if (idx < types.len) return types[idx].results.len;
        return 0;
    }
    return extra;
}

const testing = std.testing;

test "predecode return_call does not bail" {
    // Function body: return_call func_idx=0, end
    const bytecode = [_]u8{
        0x12, 0x00, // return_call 0
        0x0B, // end
    };
    const ir = try predecode(testing.allocator, &bytecode);
    try testing.expect(ir != null);
    defer {
        ir.?.deinit();
        testing.allocator.destroy(ir.?);
    }
    // Should have 2 instructions: return_call + end
    try testing.expectEqual(@as(usize, 2), ir.?.code.len);
    try testing.expectEqual(@as(u16, 0x12), ir.?.code[0].opcode);
    try testing.expectEqual(@as(u32, 0), ir.?.code[0].operand);
}

test "predecode return_call_indirect does not bail" {
    // Function body: return_call_indirect type_idx=0 table_idx=0, end
    const bytecode = [_]u8{
        0x13, 0x00, 0x00, // return_call_indirect type=0 table=0
        0x0B, // end
    };
    const ir = try predecode(testing.allocator, &bytecode);
    try testing.expect(ir != null);
    defer {
        ir.?.deinit();
        testing.allocator.destroy(ir.?);
    }
    try testing.expectEqual(@as(usize, 2), ir.?.code.len);
    try testing.expectEqual(@as(u16, 0x13), ir.?.code[0].opcode);
    try testing.expectEqual(@as(u32, 0), ir.?.code[0].operand);
    try testing.expectEqual(@as(u16, 0), ir.?.code[0].extra);
}

test "predecode SIMD basic ops" {
    // Function body: v128.const + f32x4.splat + f32x4.add + v128.store + end
    // v128.const (0xFD 0x0C) + 16 bytes
    // f32x4.splat (0xFD 0x13) — no immediates
    // f32x4.add (0xFD 0xE4 0x01) — LEB128 for 0xE4 is 0xE4 0x01
    // v128.store (0xFD 0x0B) + memarg(align=4, offset=0)
    const bytecode = [_]u8{
        0xFD, 0x0C, // v128.const
        0x00, 0x00, 0x80, 0x3F, // 1.0f32 (little-endian)
        0x00, 0x00, 0x80, 0x3F,
        0x00, 0x00, 0x80, 0x3F,
        0x00, 0x00, 0x80, 0x3F,
        0xFD, 0x13, // f32x4.splat
        0xFD, 0xE4, 0x01, // f32x4.add (sub_opcode = 228 = 0xE4, LEB128 = 0xE4 0x01)
        0xFD, 0x0B, 0x04, 0x00, // v128.store align=4 offset=0
        0x0B, // end
    };
    const ir = try predecode(testing.allocator, &bytecode);
    try testing.expect(ir != null);
    defer {
        ir.?.deinit();
        testing.allocator.destroy(ir.?);
    }
    // v128.const → SIMD_BASE + 0x0C
    try testing.expectEqual(SIMD_BASE + 0x0C, ir.?.code[0].opcode);
    // f32x4.splat → SIMD_BASE + 0x13
    try testing.expectEqual(SIMD_BASE + 0x13, ir.?.code[1].opcode);
    // f32x4.add → SIMD_BASE + 0xE4
    try testing.expectEqual(SIMD_BASE + 0xE4, ir.?.code[2].opcode);
    // v128.store → SIMD_BASE + 0x0B, operand=offset(0)
    try testing.expectEqual(SIMD_BASE + 0x0B, ir.?.code[3].opcode);
    try testing.expectEqual(@as(u32, 0), ir.?.code[3].operand); // offset = 0
    // end
    try testing.expectEqual(@as(u16, 0x0B), ir.?.code[4].opcode);
}

test "predecode SIMD relaxed ops (sub >= 0x100)" {
    // i8x16.relaxed_swizzle sub=0x100, LEB128 = 0x80 0x02
    // i32x4.relaxed_trunc_f32x4_s sub=0x101, LEB128 = 0x81 0x02
    // i16x8.relaxed_dot_i8x16_i7x16_s sub=0x10F, LEB128 = 0x8F 0x02
    const bytecode = [_]u8{
        0xFD, 0x80, 0x02, // i8x16.relaxed_swizzle (0x100)
        0xFD, 0x81, 0x02, // i32x4.relaxed_trunc_f32x4_s (0x101)
        0xFD, 0x8F, 0x02, // i16x8.relaxed_dot_i8x16_i7x16_s (0x10F)
        0x0B, // end
    };
    const ir = try predecode(testing.allocator, &bytecode);
    try testing.expect(ir != null);
    defer {
        ir.?.deinit();
        testing.allocator.destroy(ir.?);
    }
    // Relaxed ops must use SIMD_BASE + sub (not |) to avoid bit collision
    try testing.expectEqual(SIMD_BASE + 0x100, ir.?.code[0].opcode);
    try testing.expectEqual(SIMD_BASE + 0x101, ir.?.code[1].opcode);
    try testing.expectEqual(SIMD_BASE + 0x10F, ir.?.code[2].opcode);
    // Verify they are distinct from sub=0x00 (v128.load) and sub=0x01 (v128.load8x8_s)
    try testing.expect(ir.?.code[0].opcode != SIMD_BASE + 0x00);
    try testing.expect(ir.?.code[1].opcode != SIMD_BASE + 0x01);
}
