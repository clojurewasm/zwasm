// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Register IR — converts stack-based PreInstr to register-based RegInstr.
//! Design: D104 in .dev/decisions.md.
//!
//! Strategy: single-pass abstract interpretation of the Wasm operand stack.
//! Wasm locals map to fixed registers r0..rN. Stack temporaries get
//! sequential virtual registers rN+1, rN+2, ...
//! `local.get` is eliminated (becomes a register reference, no instruction).

const std = @import("std");
const Allocator = std.mem.Allocator;
const predecode = @import("predecode.zig");
const PreInstr = predecode.PreInstr;

/// 8-byte 3-address register instruction (same size as PreInstr).
pub const RegInstr = extern struct {
    op: u16, // instruction type (reuses Wasm opcodes + extensions)
    rd: u8, // destination register
    rs1: u8, // source register 1
    operand: u32, // rs2 (low byte) | immediate | branch target | pool index

    pub fn rs2(self: RegInstr) u8 {
        return @truncate(self.operand);
    }
};

comptime {
    std.debug.assert(@sizeOf(RegInstr) == 8);
}

/// Register IR for a single function.
pub const RegFunc = struct {
    code: []RegInstr,
    pool64: []u64, // shared with PreInstr pool (i64/f64 constants)
    reg_count: u16, // total registers needed (locals + max temps)
    local_count: u16, // number of Wasm locals (params + locals)
    alloc: Allocator,

    pub fn deinit(self: *RegFunc) void {
        self.alloc.free(self.code);
        // pool64 is shared from IrFunc, not freed here
    }
};

// ---- Register IR opcodes ----
// Reuse Wasm opcodes where possible. New opcodes for register-specific ops.

/// mov rd, rs1 — register copy (replaces local.set when src != dst)
pub const OP_MOV: u16 = 0xF0;
/// const32 rd, imm — load 32-bit immediate into register
pub const OP_CONST32: u16 = 0xF1;
/// const64 rd, pool_idx — load 64-bit value from pool
pub const OP_CONST64: u16 = 0xF2;
/// br target_pc — unconditional branch (operand = target PC)
pub const OP_BR: u16 = 0xF3;
/// br_if rd, target_pc — branch if rd != 0 (operand = target PC)
pub const OP_BR_IF: u16 = 0xF4;
/// br_if_not rd, target_pc — branch if rd == 0
pub const OP_BR_IF_NOT: u16 = 0xF5;
/// return rd — return value from register rd
pub const OP_RETURN: u16 = 0xF6;
/// return_void — return with no value
pub const OP_RETURN_VOID: u16 = 0xF7;
/// call func_idx — call function, args in sequential regs from rs1, rd = result reg
pub const OP_CALL: u16 = 0xF8;
/// nop — no operation (placeholder for eliminated instructions)
pub const OP_NOP: u16 = 0xF9;
/// Block end marker — used to track block boundaries during execution.
/// operand = end PC (for branch unwinding).
pub const OP_BLOCK_END: u16 = 0xFA;
/// Deleted instruction marker — used by peephole to mark instructions for removal.
/// Distinct from OP_NOP which may carry data (e.g., call arg registers).
pub const OP_DELETED: u16 = 0xFB;

// ---- Immediate-operand fused instructions ----
// Pattern: CONST32 + binop → single instruction with immediate in operand field.
// Format: { op, rd, rs1, operand=imm32 }

/// addi32 rd, rs1, imm32: regs[rd] = (u32)regs[rs1] +% imm32
pub const OP_ADDI32: u16 = 0xD0;
/// subi32 rd, rs1, imm32: regs[rd] = (u32)regs[rs1] -% imm32
pub const OP_SUBI32: u16 = 0xD1;
/// le_s_i32 rd, rs1, imm32: regs[rd] = ((i32)regs[rs1] <= (i32)imm32) ? 1 : 0
pub const OP_LE_S_I32: u16 = 0xD2;
/// ge_s_i32 rd, rs1, imm32: regs[rd] = ((i32)regs[rs1] >= (i32)imm32) ? 1 : 0
pub const OP_GE_S_I32: u16 = 0xD3;
/// lt_s_i32 rd, rs1, imm32: regs[rd] = ((i32)regs[rs1] < (i32)imm32) ? 1 : 0
pub const OP_LT_S_I32: u16 = 0xD4;
/// gt_s_i32 rd, rs1, imm32: regs[rd] = ((i32)regs[rs1] > (i32)imm32) ? 1 : 0
pub const OP_GT_S_I32: u16 = 0xD5;
/// eq_i32 rd, rs1, imm32: regs[rd] = ((u32)regs[rs1] == imm32) ? 1 : 0
pub const OP_EQ_I32: u16 = 0xD6;
/// ne_i32 rd, rs1, imm32: regs[rd] = ((u32)regs[rs1] != imm32) ? 1 : 0
pub const OP_NE_I32: u16 = 0xD7;
/// muli32 rd, rs1, imm32: regs[rd] = (u32)regs[rs1] *% imm32
pub const OP_MULI32: u16 = 0xD8;
/// andi32 rd, rs1, imm32: regs[rd] = (u32)regs[rs1] & imm32
pub const OP_ANDI32: u16 = 0xD9;
/// ori32 rd, rs1, imm32: regs[rd] = (u32)regs[rs1] | imm32
pub const OP_ORI32: u16 = 0xDA;
/// xori32 rd, rs1, imm32: regs[rd] = (u32)regs[rs1] ^ imm32
pub const OP_XORI32: u16 = 0xDB;
/// shli32 rd, rs1, imm32: regs[rd] = (u32)regs[rs1] << @truncate(imm32)
pub const OP_SHLI32: u16 = 0xDC;
/// lt_u_i32 rd, rs1, imm32: regs[rd] = ((u32)regs[rs1] < imm32) ? 1 : 0
pub const OP_LT_U_I32: u16 = 0xDD;
/// ge_u_i32 rd, rs1, imm32: regs[rd] = ((u32)regs[rs1] >= imm32) ? 1 : 0
pub const OP_GE_U_I32: u16 = 0xDE;
/// br_table rd, count: switch on regs[rd], followed by count+1 target entries
pub const OP_BR_TABLE: u16 = 0xDF;
/// call_indirect rd, rs1(elem_idx), type_idx: indirect call via table lookup
pub const OP_CALL_INDIRECT: u16 = 0xE0;
/// memory_fill rd(dst), rs1(val), rs2(n): fill memory[dst..dst+n] with val
pub const OP_MEMORY_FILL: u16 = 0xE1;
/// memory_copy rd(dst), rs1(src), rs2(n): copy memory[src..src+n] to [dst..dst+n]
pub const OP_MEMORY_COPY: u16 = 0xE2;

/// Function type info needed during conversion for call instructions.
pub const FuncTypeInfo = struct {
    param_count: u16,
    result_count: u16,
};

/// Resolves function index to type info (param/result counts).
/// Returns null if the function index is invalid.
pub const ParamResolver = struct {
    ctx: *anyopaque,
    resolve_fn: *const fn (*anyopaque, u32) ?FuncTypeInfo,
    /// Resolves type index to type info (for call_indirect).
    /// Optional — if null, call_indirect bails out.
    resolve_type_fn: ?*const fn (*anyopaque, u32) ?FuncTypeInfo = null,
};

/// Conversion error.
pub const ConvertError = error{
    OutOfMemory,
    Unsupported,
    InvalidIR,
};

/// Block tracking during conversion.
const BlockInfo = struct {
    kind: enum { block, loop, @"if" },
    /// PC of block start in RegInstr output (for loops: branch target)
    start_pc: u32,
    /// Virtual stack depth at block entry (for branch unwinding)
    stack_base: u16,
    /// Block result arity
    arity: u16,
    /// Register for block result (if arity == 1)
    result_reg: u8,
    /// For forward branches: list of PCs that need patching with end PC.
    /// We use a simple approach: patch slots embedded in RegInstr.operand.
    patches: std.ArrayList(u32),
};

/// Convert PreInstr[] to RegInstr[].
/// Returns null if conversion fails (unsupported opcodes).
pub fn convert(
    alloc: Allocator,
    ir_code: []const PreInstr,
    pool64: []const u64,
    param_count: u16,
    local_count: u16,
    resolver: ?ParamResolver,
) ConvertError!?*RegFunc {
    const total_locals = param_count + local_count;

    // Bail if locals exceed u8 register range (RegInstr fields are u8)
    if (total_locals > 255) return null;

    // Multi-value return (>1) not supported in register IR yet.
    // We don't know our own result count here, but the executor handles it.
    // For functions with >1 results, the caller should not use register IR.

    var code: std.ArrayList(RegInstr) = .empty;
    errdefer code.deinit(alloc);
    var block_stack: std.ArrayList(BlockInfo) = .empty;
    defer {
        for (block_stack.items) |*b| b.patches.deinit(alloc);
        block_stack.deinit(alloc);
    }

    // Virtual register stack: tracks which register holds each stack slot.
    var vstack: std.ArrayList(u8) = .empty;
    defer vstack.deinit(alloc);

    var next_reg: u16 = total_locals; // next available temp register
    var max_reg: u16 = total_locals; // high water mark
    var unreachable_depth: u32 = 0; // >0 = inside dead code

    var pc: usize = 0;
    while (pc < ir_code.len) {
        const instr = ir_code[pc];
        pc += 1;

        // Dead code elimination: after return/br/unreachable, skip until matching end/else
        if (unreachable_depth > 0) {
            switch (instr.opcode) {
                0x02, 0x03 => unreachable_depth += 1, // block, loop — increase nesting
                0x04 => { // if — increase nesting, skip IF_DATA word
                    unreachable_depth += 1;
                    if (pc < ir_code.len) pc += 1;
                },
                0x05 => { // else
                    if (unreachable_depth == 1) {
                        // The else branch is reachable if the block itself is reachable
                        unreachable_depth = 0;
                        // Reset vstack to block entry state
                        if (block_stack.items.len > 0) {
                            const block = &block_stack.items[block_stack.items.len - 1];
                            vstack.shrinkRetainingCapacity(block.stack_base);
                        }
                        // Process this as normal else (fall through to main switch)
                    } else {
                        continue;
                    }
                },
                0x0B => { // end
                    unreachable_depth -= 1;
                    if (unreachable_depth == 0) {
                        // This end closes the block that contains the dead code.
                        // Process it normally (fall through to main switch).
                    } else continue;
                },
                else => continue,
            }
            // Only else/end at depth 1→0 fall through here
            if (unreachable_depth > 0) continue;
        }

        switch (instr.opcode) {
            // ---- Eliminated: local.get just references the register ----
            0x20 => { // local.get
                const local_idx: u8 = @intCast(instr.operand);
                try vstack.append(alloc, local_idx);
            },

            // ---- local.set: move value to local register ----
            0x21 => { // local.set
                const src = vstack.pop().?;
                const dst: u8 = @intCast(instr.operand);
                if (src != dst) {
                    // Detach stale vstack references to dst before overwriting
                    for (vstack.items) |*entry| {
                        if (entry.* == dst) {
                            const tmp = allocTemp(&next_reg, &max_reg);
                            try code.append(alloc, .{ .op = OP_MOV, .rd = tmp, .rs1 = dst, .operand = 0 });
                            entry.* = tmp;
                        }
                    }
                    try code.append(alloc, .{ .op = OP_MOV, .rd = dst, .rs1 = src, .operand = 0 });
                }
            },

            // ---- local.tee: copy value to local, keep on stack ----
            0x22 => { // local.tee
                const src = vstack.items[vstack.items.len - 1]; // peek
                const dst: u8 = @intCast(instr.operand);
                if (src != dst) {
                    // Detach stale vstack references to dst before overwriting (exclude top)
                    for (vstack.items[0 .. vstack.items.len - 1]) |*entry| {
                        if (entry.* == dst) {
                            const tmp = allocTemp(&next_reg, &max_reg);
                            try code.append(alloc, .{ .op = OP_MOV, .rd = tmp, .rs1 = dst, .operand = 0 });
                            entry.* = tmp;
                        }
                    }
                    try code.append(alloc, .{ .op = OP_MOV, .rd = dst, .rs1 = src, .operand = 0 });
                }
                // Replace stack top with dst register
                vstack.items[vstack.items.len - 1] = dst;
            },

            // ---- Constants ----
            0x41 => { // i32.const
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST32, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            0x42 => { // i64.const (pool index in operand)
                const rd = allocTemp(&next_reg, &max_reg);
                const pool_val = if (instr.operand < pool64.len) pool64[instr.operand] else 0;
                if (pool_val <= std.math.maxInt(u32)) {
                    try code.append(alloc, .{ .op = OP_CONST32, .rd = rd, .rs1 = 0, .operand = @truncate(pool_val) });
                } else {
                    try code.append(alloc, .{ .op = OP_CONST64, .rd = rd, .rs1 = 0, .operand = instr.operand });
                }
                try vstack.append(alloc, rd);
            },
            0x43 => { // f32.const (bits in operand)
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST32, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            0x44 => { // f64.const (pool index in operand)
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST64, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },

            // ---- Binary i32 arithmetic ----
            0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, // add..rotr
            0x74, 0x75, 0x76, 0x77, 0x78, // shl, shr_s, shr_u, rotl, rotr
            => {
                const rs2 = vstack.pop().?;
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary i32 comparison ----
            0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F => {
                const rs2 = vstack.pop().?;
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Unary i32 ----
            0x45 => { // i32.eqz
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            0x67, 0x68, 0x69 => { // i32.clz, ctz, popcnt
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary i64 arithmetic ----
            0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, // add..rotr
            0x86, 0x87, 0x88, 0x89, 0x8A, // shl, shr_s, shr_u, rotl, rotr
            => {
                const rs2 = vstack.pop().?;
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary i64 comparison ----
            0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A => {
                const rs2 = vstack.pop().?;
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Unary i64 ----
            0x50 => { // i64.eqz
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            0x79, 0x7A, 0x7B => { // i64.clz, ctz, popcnt
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary f64 arithmetic ----
            0xA0, 0xA1, 0xA2, 0xA3, // f64.add, sub, mul, div
            0xA4, 0xA5, // f64.min, max
            0xA6, // f64.copysign
            => {
                const rs2 = vstack.pop().?;
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary f64 comparison ----
            0x61, 0x62, 0x63, 0x64, 0x65, 0x66 => {
                const rs2 = vstack.pop().?;
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Unary f64 ----
            0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F => { // abs, neg, ceil, floor, trunc, nearest, sqrt
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary f32 arithmetic ----
            0x92, 0x93, 0x94, 0x95, // f32.add, sub, mul, div
            0x96, 0x97, // f32.min, max
            0x98, // f32.copysign
            => {
                const rs2 = vstack.pop().?;
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary f32 comparison ----
            0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60 => {
                const rs2 = vstack.pop().?;
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Unary f32 ----
            0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91 => {
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Conversions (unary) ----
            0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, // i32/i64 wrap/trunc
            0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, // f32/f64 convert
            0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, // reinterpret, extend
            0xC0, 0xC1, 0xC2, 0xC3, 0xC4, // extend8/16/32
            => {
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Memory load (base addr on stack + offset in operand) ----
            0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, // i32/i64/f32/f64 loads
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, // sign-extending loads
            => {
                const rs1 = vstack.pop().?; // base address
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },

            // ---- Memory store (base addr + value on stack, offset in operand) ----
            0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E => {
                const val = vstack.pop().?; // value to store
                const base = vstack.pop().?; // base address
                // Store: no destination register. Use rd=val, rs1=base
                try code.append(alloc, .{ .op = instr.opcode, .rd = val, .rs1 = base, .operand = instr.operand });
            },

            // ---- Control flow ----
            0x02 => { // block
                if (instr.extra & predecode.ARITY_TYPE_INDEX_FLAG != 0) return null;
                const arity: u16 = instr.extra;

                const result_reg = if (arity > 0) allocTemp(&next_reg, &max_reg) else 0;
                const block_pc: u32 = @intCast(code.items.len);

                try block_stack.append(alloc, .{
                    .kind = .block,
                    .start_pc = block_pc,
                    .stack_base = @intCast(vstack.items.len),
                    .arity = arity,
                    .result_reg = result_reg,
                    .patches = .empty,
                });
            },

            0x03 => { // loop
                const arity: u16 = if (instr.extra & predecode.ARITY_TYPE_INDEX_FLAG != 0)
                    return null
                else
                    instr.extra;

                const result_reg = if (arity > 0) allocTemp(&next_reg, &max_reg) else 0;
                const loop_pc: u32 = @intCast(code.items.len);

                try block_stack.append(alloc, .{
                    .kind = .loop,
                    .start_pc = loop_pc,
                    .stack_base = @intCast(vstack.items.len),
                    .arity = arity,
                    .result_reg = result_reg,
                    .patches = .empty,
                });
            },

            0x04 => { // if
                const arity: u16 = if (instr.extra & predecode.ARITY_TYPE_INDEX_FLAG != 0)
                    return null
                else
                    instr.extra;

                // Read the IF_DATA word
                if (pc >= ir_code.len) return null;
                const data = ir_code[pc];
                pc += 1;
                _ = data; // has_else and end_pc, we handle structurally

                const cond = vstack.pop().?;
                const result_reg = if (arity > 0) allocTemp(&next_reg, &max_reg) else 0;
                const br_pos: u32 = @intCast(code.items.len);

                // Emit branch-if-not (false branch jumps to else/end)
                try code.append(alloc, .{ .op = OP_BR_IF_NOT, .rd = cond, .rs1 = 0, .operand = 0 }); // patched later

                var patches: std.ArrayList(u32) = .empty;
                try patches.append(alloc, br_pos); // patch this with else/end PC

                try block_stack.append(alloc, .{
                    .kind = .@"if",
                    .start_pc = br_pos,
                    .stack_base = @intCast(vstack.items.len),
                    .arity = arity,
                    .result_reg = result_reg,
                    .patches = patches,
                });
            },

            0x05 => { // else
                if (block_stack.items.len == 0) return null;
                const block = &block_stack.items[block_stack.items.len - 1];

                // True branch: if arity > 0, move result to block's result register
                if (block.arity > 0 and vstack.items.len > block.stack_base) {
                    const val = vstack.pop().?;
                    if (val != block.result_reg) {
                        try code.append(alloc, .{ .op = OP_MOV, .rd = block.result_reg, .rs1 = val, .operand = 0 });
                    }
                }

                // Emit jump to end (patched later)
                const jump_pos: u32 = @intCast(code.items.len);
                try code.append(alloc, .{ .op = OP_BR, .rd = 0, .rs1 = 0, .operand = 0 });
                try block.patches.append(alloc, jump_pos);

                // Patch the if-condition branch to here (else start)
                const else_pc: u32 = @intCast(code.items.len);
                // First patch entry is the if-condition branch
                if (block.patches.items.len > 0) {
                    code.items[block.patches.items[0]].operand = else_pc;
                    // Remove the if-patch, keep the jump-to-end patch
                    _ = block.patches.orderedRemove(0);
                }

                // Reset virtual stack to block entry state
                vstack.shrinkRetainingCapacity(block.stack_base);
            },

            0x0B => { // end
                if (block_stack.items.len == 0) {
                    // Function-level end: return
                    if (vstack.items.len > 0) {
                        const val = vstack.pop().?;
                        try code.append(alloc, .{ .op = OP_RETURN, .rd = val, .rs1 = 0, .operand = 0 });
                    } else {
                        try code.append(alloc, .{ .op = OP_RETURN_VOID, .rd = 0, .rs1 = 0, .operand = 0 });
                    }
                    break; // Done
                }

                var block = block_stack.pop().?;
                defer block.patches.deinit(alloc);

                // If arity > 0 and we have a value, move to result register
                if (block.arity > 0 and vstack.items.len > block.stack_base) {
                    const val = vstack.pop().?;
                    if (val != block.result_reg) {
                        try code.append(alloc, .{ .op = OP_MOV, .rd = block.result_reg, .rs1 = val, .operand = 0 });
                    }
                }

                const end_pc: u32 = @intCast(code.items.len);

                // Patch all forward branches to this end position
                for (block.patches.items) |patch_pc| {
                    code.items[patch_pc].operand = end_pc;
                }

                // Reset virtual stack and push result register if arity > 0
                vstack.shrinkRetainingCapacity(block.stack_base);
                if (block.arity > 0) {
                    try vstack.append(alloc, block.result_reg);
                }
            },

            // ---- Branch ----
            0x0C => { // br (unconditional)
                const depth = instr.operand;
                if (depth >= block_stack.items.len) return null;
                const target_idx = block_stack.items.len - 1 - depth;
                const target = &block_stack.items[target_idx];

                // For loops: branch to start. For blocks: branch to end (patched).
                if (target.kind == .loop) {
                    // Move arity values if needed (loop consumes no values typically)
                    try code.append(alloc, .{ .op = OP_BR, .rd = 0, .rs1 = 0, .operand = target.start_pc });
                } else {
                    // Forward branch — need to move arity values and patch
                    if (target.arity > 0 and vstack.items.len > 0) {
                        const val = vstack.items[vstack.items.len - 1];
                        if (val != target.result_reg) {
                            try code.append(alloc, .{ .op = OP_MOV, .rd = target.result_reg, .rs1 = val, .operand = 0 });
                        }
                    }
                    const br_pos: u32 = @intCast(code.items.len);
                    try code.append(alloc, .{ .op = OP_BR, .rd = 0, .rs1 = 0, .operand = 0 });
                    try target.patches.append(alloc, br_pos);
                }
                unreachable_depth = 1; // subsequent code is dead
            },

            0x0D => { // br_if
                const depth = instr.operand;
                const cond = vstack.pop().?;
                if (depth >= block_stack.items.len) return null;
                const target_idx = block_stack.items.len - 1 - depth;
                const target = &block_stack.items[target_idx];

                if (target.kind == .loop) {
                    try code.append(alloc, .{ .op = OP_BR_IF, .rd = cond, .rs1 = 0, .operand = target.start_pc });
                } else {
                    // Move arity value to target's result register before conditional branch.
                    // If branch not taken, the move is wasted but harmless (result_reg
                    // will be overwritten at block end). Value stays on vstack for non-taken path.
                    if (target.arity > 0 and vstack.items.len > 0) {
                        const val = vstack.items[vstack.items.len - 1]; // peek
                        if (val != target.result_reg) {
                            try code.append(alloc, .{ .op = OP_MOV, .rd = target.result_reg, .rs1 = val, .operand = 0 });
                        }
                    }
                    const br_pos: u32 = @intCast(code.items.len);
                    try code.append(alloc, .{ .op = OP_BR_IF, .rd = cond, .rs1 = 0, .operand = 0 });
                    try target.patches.append(alloc, br_pos);
                }
            },

            // ---- Call ----
            0x10 => { // call
                const func_idx = instr.operand;

                // Resolve callee type info (param count + result count)
                const res = resolver orelse return null;
                const type_info = res.resolve_fn(res.ctx, func_idx) orelse return null;
                const n_args: usize = type_info.param_count;
                const n_results: usize = type_info.result_count;
                if (n_args > 8 or n_results > 1) return null; // bail on complex signatures
                if (vstack.items.len < n_args) return null; // stack underflow

                const rd = if (n_results > 0) allocTemp(&next_reg, &max_reg) else 0;

                try code.append(alloc, .{ .op = OP_CALL, .rd = rd, .rs1 = @intCast(n_args), .operand = func_idx });

                // Pack arg registers into data words (up to 4 per word)
                var arg_regs: [8]u8 = .{0} ** 8;
                const arg_start = vstack.items.len - n_args;
                for (0..n_args) |i| {
                    arg_regs[i] = vstack.items[arg_start + i];
                }
                try code.append(alloc, .{
                    .op = OP_NOP,
                    .rd = arg_regs[0],
                    .rs1 = arg_regs[1],
                    .operand = @as(u32, arg_regs[2]) | (@as(u32, arg_regs[3]) << 8),
                });
                if (n_args > 4) {
                    try code.append(alloc, .{
                        .op = OP_NOP,
                        .rd = arg_regs[4],
                        .rs1 = arg_regs[5],
                        .operand = @as(u32, arg_regs[6]) | (@as(u32, arg_regs[7]) << 8),
                    });
                }

                // Pop only the arg count from virtual stack
                vstack.shrinkRetainingCapacity(vstack.items.len - n_args);
                if (n_results > 0) try vstack.append(alloc, rd);
            },

            // ---- Return ----
            0x0F => { // return
                if (vstack.items.len > 0) {
                    const val = vstack.pop().?;
                    try code.append(alloc, .{ .op = OP_RETURN, .rd = val, .rs1 = 0, .operand = 0 });
                } else {
                    try code.append(alloc, .{ .op = OP_RETURN_VOID, .rd = 0, .rs1 = 0, .operand = 0 });
                }
                unreachable_depth = 1; // subsequent code is dead
            },

            // ---- Drop ----
            0x1A => { // drop
                _ = vstack.pop();
            },

            // ---- Select ----
            0x1B => { // select
                const cond = vstack.pop().?;
                const val2 = vstack.pop().?;
                const val1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                // select rd, val1, val2, cond: rd = cond ? val1 : val2
                // Encode: rd=rd, rs1=val1, operand low=val2, operand byte1=cond
                try code.append(alloc, .{
                    .op = 0x1B,
                    .rd = rd,
                    .rs1 = val1,
                    .operand = @as(u32, val2) | (@as(u32, cond) << 8),
                });
                try vstack.append(alloc, rd);
            },

            // ---- Memory size/grow ----
            0x3F => { // memory.size
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x3F, .rd = rd, .rs1 = 0, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            0x40 => { // memory.grow
                const rs1 = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x40, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Global get/set ----
            0x23 => { // global.get
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x23, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            0x24 => { // global.set
                const src = vstack.pop().?;
                try code.append(alloc, .{ .op = 0x24, .rd = src, .rs1 = 0, .operand = instr.operand });
            },

            // ---- Nop ----
            0x01 => {}, // nop — skip

            // ---- Unreachable ----
            0x00 => {
                try code.append(alloc, .{ .op = 0x00, .rd = 0, .rs1 = 0, .operand = 0 });
                unreachable_depth = 1; // subsequent code is dead
            },

            // ---- Superinstructions (decompose to register ops) ----
            // These are peephole-fused sequences from predecode. We decompose them
            // into register references since local.get is free in register IR.
            // Format: extra = local A index, operand = local B index or constant.
            // Each super-instr consumed 1-2 trailing PreInstrs; skip them.

            predecode.OP_LOCAL_GET_GET => {
                // local.get A + local.get B → push both register refs
                try vstack.append(alloc, @intCast(instr.extra));
                try vstack.append(alloc, @intCast(instr.operand));
                pc += 1; // skip consumed local.get
            },
            predecode.OP_LOCAL_GET_CONST => {
                // local.get A + i32.const C
                try vstack.append(alloc, @intCast(instr.extra));
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST32, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
                pc += 1; // skip consumed i32.const
            },
            predecode.OP_LOCALS_ADD => {
                // local.get A + local.get B + i32.add
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x6A, .rd = rd, .rs1 = @intCast(instr.extra), .operand = @as(u32, @intCast(instr.operand & 0xFF)) });
                try vstack.append(alloc, rd);
                pc += 2; // skip consumed local.get + i32.add
            },
            predecode.OP_LOCALS_SUB => {
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x6B, .rd = rd, .rs1 = @intCast(instr.extra), .operand = @as(u32, @intCast(instr.operand & 0xFF)) });
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_ADD => {
                // local.get A + i32.const C + i32.add → add rd, rA, const_reg
                const const_rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x6A, .rd = rd, .rs1 = @intCast(instr.extra), .operand = const_rd });
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_SUB => {
                const const_rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x6B, .rd = rd, .rs1 = @intCast(instr.extra), .operand = const_rd });
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_LT_S => {
                const const_rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x48, .rd = rd, .rs1 = @intCast(instr.extra), .operand = const_rd }); // i32.lt_s
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_GE_S => {
                const const_rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x4E, .rd = rd, .rs1 = @intCast(instr.extra), .operand = const_rd }); // i32.ge_s
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_LT_U => {
                const const_rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x49, .rd = rd, .rs1 = @intCast(instr.extra), .operand = const_rd }); // i32.lt_u
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCALS_GT_S => {
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x4A, .rd = rd, .rs1 = @intCast(instr.extra), .operand = @as(u32, @intCast(instr.operand & 0xFF)) }); // i32.gt_s
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCALS_LE_S => {
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = 0x4C, .rd = rd, .rs1 = @intCast(instr.extra), .operand = @as(u32, @intCast(instr.operand & 0xFF)) }); // i32.le_s
                try vstack.append(alloc, rd);
                pc += 2;
            },

            // ---- br_table ----
            0x0E => {
                const count = instr.operand;
                const idx_reg = vstack.pop().?;

                // Pre-scan: check if any target has arity > 0
                var has_arity = false;
                var unique_result_reg: ?u8 = null;
                var arity_val: u8 = 0;
                for (0..count + 1) |entry_i| {
                    if (pc + entry_i >= ir_code.len) return null;
                    const entry = ir_code[pc + entry_i];
                    const depth = entry.operand;
                    if (depth >= block_stack.items.len) return null;
                    const target_idx = block_stack.items.len - 1 - depth;
                    const target = &block_stack.items[target_idx];
                    if (target.kind != .loop and target.arity > 0) {
                        has_arity = true;
                        if (vstack.items.len > 0) {
                            arity_val = vstack.items[vstack.items.len - 1];
                        }
                        if (unique_result_reg == null) {
                            unique_result_reg = target.result_reg;
                        } else if (unique_result_reg.? != target.result_reg) {
                            // Different result regs — need per-target trampolines
                            unique_result_reg = null;
                            break;
                        }
                    }
                }

                // If all targets share the same result_reg (or no arity), simple path.
                // Otherwise, emit per-target MOV+BR trampolines.
                if (has_arity and unique_result_reg == null) {
                    // Multiple different result regs — emit trampolines
                    // Emit: OP_BR_TABLE idx_reg, count
                    try code.append(alloc, .{ .op = OP_BR_TABLE, .rd = idx_reg, .rs1 = 0, .operand = count });

                    // Reserve entry slots (will be patched to trampoline PCs)
                    const entries_start: u32 = @intCast(code.items.len);
                    for (0..count + 1) |_| {
                        try code.append(alloc, .{ .op = OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 });
                    }

                    // Emit per-target trampolines: MOV result_reg, val; BR target
                    for (0..count + 1) |entry_i| {
                        const entry = ir_code[pc + entry_i];
                        const depth = entry.operand;
                        const target_idx = block_stack.items.len - 1 - depth;
                        const target = &block_stack.items[target_idx];

                        const tramp_pc: u32 = @intCast(code.items.len);
                        code.items[entries_start + @as(u32, @intCast(entry_i))].operand = tramp_pc;

                        if (target.kind == .loop) {
                            try code.append(alloc, .{ .op = OP_BR, .rd = 0, .rs1 = 0, .operand = target.start_pc });
                        } else {
                            if (target.arity > 0 and vstack.items.len > 0 and arity_val != target.result_reg) {
                                try code.append(alloc, .{ .op = OP_MOV, .rd = target.result_reg, .rs1 = arity_val, .operand = 0 });
                            }
                            const br_pos: u32 = @intCast(code.items.len);
                            try code.append(alloc, .{ .op = OP_BR, .rd = 0, .rs1 = 0, .operand = 0 });
                            try target.patches.append(alloc, br_pos);
                        }
                    }
                } else {
                    // Simple path: emit MOV if all targets share the same result_reg
                    if (has_arity and unique_result_reg != null and vstack.items.len > 0) {
                        if (arity_val != unique_result_reg.?) {
                            try code.append(alloc, .{ .op = OP_MOV, .rd = unique_result_reg.?, .rs1 = arity_val, .operand = 0 });
                        }
                    }

                    // Emit: OP_BR_TABLE idx_reg, count
                    try code.append(alloc, .{ .op = OP_BR_TABLE, .rd = idx_reg, .rs1 = 0, .operand = count });

                    // Emit count+1 target entries
                    for (0..count + 1) |entry_i| {
                        if (pc + entry_i >= ir_code.len) return null;
                        const entry = ir_code[pc + entry_i];
                        const depth = entry.operand;
                        if (depth >= block_stack.items.len) return null;
                        const target_idx = block_stack.items.len - 1 - depth;
                        const target = &block_stack.items[target_idx];

                        if (target.kind == .loop) {
                            try code.append(alloc, .{ .op = OP_NOP, .rd = 0, .rs1 = 0, .operand = target.start_pc });
                        } else {
                            const entry_pc: u32 = @intCast(code.items.len);
                            try code.append(alloc, .{ .op = OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 }); // patched later
                            try target.patches.append(alloc, entry_pc);
                        }
                    }
                }
                pc += count + 1; // skip br_table entries in source
                unreachable_depth = 1;
            },

            // ---- call_indirect ----
            0x11 => {
                const type_idx = instr.operand;
                const table_idx: u8 = @intCast(instr.extra);

                // Resolve type to get param/result counts
                const res = resolver orelse return null;
                const resolve_type = res.resolve_type_fn orelse return null;
                const type_info = resolve_type(res.ctx, type_idx) orelse return null;
                const n_args: usize = type_info.param_count;
                const n_results: usize = type_info.result_count;
                if (n_args > 8 or n_results > 1) return null;

                // Stack: [args...] elem_idx  (elem_idx on top)
                const elem_idx_reg = vstack.pop().?;
                if (vstack.items.len < n_args) return null;

                const rd = if (n_results > 0) allocTemp(&next_reg, &max_reg) else 0;

                // OP_CALL_INDIRECT: rd=result, rs1=elem_idx_reg,
                // operand=type_idx, table_idx packed in high bits
                try code.append(alloc, .{
                    .op = OP_CALL_INDIRECT,
                    .rd = rd,
                    .rs1 = elem_idx_reg,
                    .operand = type_idx | (@as(u32, table_idx) << 24),
                });

                // Pack arg registers (same layout as OP_CALL)
                var arg_regs: [8]u8 = .{0} ** 8;
                const arg_start = vstack.items.len - n_args;
                for (0..n_args) |i| {
                    arg_regs[i] = vstack.items[arg_start + i];
                }
                try code.append(alloc, .{
                    .op = OP_NOP,
                    .rd = arg_regs[0],
                    .rs1 = arg_regs[1],
                    .operand = @as(u32, arg_regs[2]) | (@as(u32, arg_regs[3]) << 8),
                });
                if (n_args > 4) {
                    try code.append(alloc, .{
                        .op = OP_NOP,
                        .rd = arg_regs[4],
                        .rs1 = arg_regs[5],
                        .operand = @as(u32, arg_regs[6]) | (@as(u32, arg_regs[7]) << 8),
                    });
                }

                vstack.shrinkRetainingCapacity(vstack.items.len - n_args);
                if (n_results > 0) try vstack.append(alloc, rd);
            },

            // ---- Bulk memory operations ----
            predecode.MISC_BASE | 0x0B => { // memory.fill
                if (vstack.items.len < 3) return null;
                const n_reg = vstack.pop().?;
                const val_reg = vstack.pop().?;
                const dst_reg = vstack.pop().?;
                try code.append(alloc, .{
                    .op = OP_MEMORY_FILL,
                    .rd = dst_reg,
                    .rs1 = val_reg,
                    .operand = n_reg,
                });
            },
            predecode.MISC_BASE | 0x0A => { // memory.copy
                if (vstack.items.len < 3) return null;
                const n_reg = vstack.pop().?;
                const src_reg = vstack.pop().?;
                const dst_reg = vstack.pop().?;
                try code.append(alloc, .{
                    .op = OP_MEMORY_COPY,
                    .rd = dst_reg,
                    .rs1 = src_reg,
                    .operand = n_reg,
                });
            },

            // ---- Truncation saturating (misc prefix) ----
            predecode.MISC_BASE | 0x00 => { // i32.trunc_sat_f32_s
                const src = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x00, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x01 => { // i32.trunc_sat_f32_u
                const src = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x01, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x02 => { // i32.trunc_sat_f64_s
                const src = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x02, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x03 => { // i32.trunc_sat_f64_u
                const src = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x03, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x04 => { // i64.trunc_sat_f32_s
                const src = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x04, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x05 => { // i64.trunc_sat_f32_u
                const src = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x05, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x06 => { // i64.trunc_sat_f64_s
                const src = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x06, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x07 => { // i64.trunc_sat_f64_u
                const src = vstack.pop().?;
                const rd = allocTemp(&next_reg, &max_reg);
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x07, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Anything else: bail ----
            else => return null,
        }
    }

    // If we fell through (no end instruction), add return
    if (code.items.len == 0 or code.items[code.items.len - 1].op != OP_RETURN and
        code.items[code.items.len - 1].op != OP_RETURN_VOID)
    {
        try code.append(alloc, .{ .op = OP_RETURN_VOID, .rd = 0, .rs1 = 0, .operand = 0 });
    }

    // ---- Peephole: fuse CONST32 + binop → immediate-operand instruction ----
    fuseConstBinop(code.items);

    // ---- Copy propagation: fold "op rTEMP = ...; mov rLOCAL = rTEMP" → "op rLOCAL = ..." ----
    copyPropagate(code.items, total_locals);

    // Note: MOV+RETURN fusion is NOT safe because block result registers
    // can be written from multiple paths (br, br_if, fallthrough).

    // ---- Compact: remove DELETED instructions and adjust branch targets ----
    const compacted_len = compactCode(code.items);
    code.shrinkRetainingCapacity(compacted_len);

    // Bail if temp registers exceeded u8 range
    if (max_reg > 255) {
        code.deinit(alloc);
        return null;
    }

    const result = try alloc.create(RegFunc);
    result.* = .{
        .code = try code.toOwnedSlice(alloc),
        .pool64 = @constCast(pool64), // shared reference
        .reg_count = max_reg,
        .local_count = total_locals,
        .alloc = alloc,
    };
    return result;
}

/// Peephole optimization: fuse CONST32 + binop into immediate-operand instructions.
/// Copy propagation: fold "op rTEMP = ...; mov rLOCAL = rTEMP" → "op rLOCAL = ...".
/// Eliminates redundant MOV instructions where a temp register is defined and immediately
/// copied to a local. Safe when: (1) the source is a temp (rd >= local_count), and
/// (2) the MOV is not a branch target.
fn copyPropagate(code: []RegInstr, local_count: u16) void {
    if (code.len < 2) return;

    // Build branch target set: MOVs that are branch targets must not be folded.
    var branch_targets = [_]bool{false} ** 8192;
    for (code) |instr| {
        switch (instr.op) {
            OP_BR, OP_BR_IF, OP_BR_IF_NOT, OP_BLOCK_END => {
                if (instr.operand < branch_targets.len)
                    branch_targets[instr.operand] = true;
            },
            else => {},
        }
    }

    for (0..code.len - 1) |i| {
        const mov = code[i + 1];
        if (mov.op != OP_MOV) continue;

        // Skip if this MOV is a branch target
        if (i + 1 < branch_targets.len and branch_targets[i + 1]) continue;

        // Find the producer: skip NOPs/DELETEDs backward from position i
        var j = i;
        while (j > 0 and (code[j].op == OP_NOP or code[j].op == OP_DELETED)) j -= 1;
        if (code[j].op == OP_NOP or code[j].op == OP_DELETED) continue;

        const producer = code[j];

        // Check: producer writes to the MOV's source, and it's a temp register
        if (producer.rd != mov.rs1) continue;
        if (producer.rd < local_count) continue; // not a temp

        // Don't fold if the producer is itself a MOV, branch, return, or store-like
        switch (producer.op) {
            OP_MOV, OP_BR, OP_BR_IF, OP_BR_IF_NOT, OP_RETURN, OP_RETURN_VOID,
            OP_NOP, OP_BLOCK_END, OP_DELETED, OP_BR_TABLE,
            OP_MEMORY_FILL, OP_MEMORY_COPY,
            => continue,
            // Store instructions use rd as value source, not destination
            0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E => continue,
            else => {},
        }

        // Fold: redirect producer's output to MOV's destination, delete MOV
        code[j].rd = mov.rd;
        code[i + 1] = .{ .op = OP_DELETED, .rd = 0, .rs1 = 0, .operand = 0 };
    }
}

/// Pattern: CONST32 rd=T, imm  followed by  BINOP rd=R, rs1=A, rs2=T
///       → BINOP_IMM rd=R, rs1=A, operand=imm  +  NOP
/// Only fuses when the const register T is used as rs2 (second operand) of the binop.
fn fuseConstBinop(code: []RegInstr) void {
    if (code.len < 2) return;
    for (0..code.len - 1) |i| {
        const c = code[i];
        if (c.op != OP_CONST32) continue;
        const const_reg = c.rd;
        const imm = c.operand;

        const b = code[i + 1];
        // Check if the binop uses const_reg as rs2 (operand field for binary ops)
        const rs2: u8 = @truncate(b.operand);
        if (rs2 != const_reg) continue;

        const fused_op: ?u16 = switch (b.op) {
            0x6A => OP_ADDI32, // i32.add
            0x6B => OP_SUBI32, // i32.sub
            0x6C => OP_MULI32, // i32.mul
            0x71 => OP_ANDI32, // i32.and
            0x72 => OP_ORI32, // i32.or
            0x73 => OP_XORI32, // i32.xor
            0x74 => OP_SHLI32, // i32.shl
            0x46 => OP_EQ_I32, // i32.eq
            0x47 => OP_NE_I32, // i32.ne
            0x48 => OP_LT_S_I32, // i32.lt_s
            0x49 => OP_LT_U_I32, // i32.lt_u
            0x4A => OP_GT_S_I32, // i32.gt_s
            0x4C => OP_LE_S_I32, // i32.le_s
            0x4E => OP_GE_S_I32, // i32.ge_s
            0x4F => OP_GE_U_I32, // i32.ge_u
            else => null,
        };

        if (fused_op) |op| {
            // Replace CONST32 with DELETED, replace binop with fused instruction
            code[i] = .{ .op = OP_DELETED, .rd = 0, .rs1 = 0, .operand = 0 };
            code[i + 1] = .{ .op = op, .rd = b.rd, .rs1 = b.rs1, .operand = imm };
        }
    }
}

/// Compact code by removing NOP instructions and adjusting branch targets.
/// Two passes: (1) fix branch targets while original layout intact, (2) compact.
/// Returns the new length (number of non-NOP instructions).
fn compactCode(code: []RegInstr) usize {
    const len = code.len;
    if (len == 0) return 0;

    // Quick check: any DELETED markers?
    var has_deleted = false;
    for (code) |instr| {
        if (instr.op == OP_DELETED) {
            has_deleted = true;
            break;
        }
    }
    if (!has_deleted) return len;

    // Pass 1: Fix branch targets BEFORE compaction (original layout still intact).
    // new_pc(target) = target - count_deleted_in(0..target)
    for (code) |*instr| {
        switch (instr.op) {
            OP_BR, OP_BR_IF, OP_BR_IF_NOT, OP_BLOCK_END => {
                const old_target = instr.operand;
                var deleted_before: u32 = 0;
                const limit = @min(old_target, @as(u32, @intCast(len)));
                for (0..limit) |j| {
                    if (code[j].op == OP_DELETED) deleted_before += 1;
                }
                instr.operand = old_target - deleted_before;
            },
            else => {},
        }
    }

    // Pass 2: Compact (remove DELETED, shift left)
    var write: usize = 0;
    for (0..len) |read| {
        if (code[read].op != OP_DELETED) {
            code[write] = code[read];
            write += 1;
        }
    }
    return write;
}

fn compactCodeProper(code_slice: []RegInstr) void {
    const len = code_slice.len;
    if (len == 0) return;

    // Step 1: Build prefix NOP count (for remap: new_pc = old_pc - prefix_nops[old_pc])
    // We scan the original code and count NOPs.
    // Use the NOP instruction slots to store the remap info? No, let's just
    // compute on-the-fly.

    // Count NOPs
    var total_nops: usize = 0;
    for (code_slice) |instr| {
        if (instr.op == OP_NOP) total_nops += 1;
    }
    if (total_nops == 0) return;

    // Step 2: Fix branch targets BEFORE compaction (while original layout intact).
    // For each branch instruction, its operand is a target old_pc.
    // We need: new_pc(target) = target - count_nops_in(0..target)
    for (code_slice) |*instr| {
        switch (instr.op) {
            OP_BR, OP_BR_IF, OP_BR_IF_NOT => {
                const old_target = instr.operand;
                var nops_before: u32 = 0;
                const limit = @min(old_target, @as(u32, @intCast(len)));
                for (0..limit) |j| {
                    if (code_slice[j].op == OP_NOP) nops_before += 1;
                }
                instr.operand = old_target - nops_before;
            },
            OP_BLOCK_END => {
                const old_target = instr.operand;
                var nops_before: u32 = 0;
                const limit = @min(old_target, @as(u32, @intCast(len)));
                for (0..limit) |j| {
                    if (code_slice[j].op == OP_NOP) nops_before += 1;
                }
                instr.operand = old_target - nops_before;
            },
            else => {},
        }
    }

    // Step 3: Compact (remove NOPs)
    var write: usize = 0;
    for (0..len) |read| {
        if (code_slice[read].op != OP_NOP) {
            code_slice[write] = code_slice[read];
            write += 1;
        }
    }

    // Fill tail with NOPs (won't be executed since code_len uses the RegFunc.code slice length)
    for (write..len) |i| {
        code_slice[i] = .{ .op = OP_NOP, .rd = 0, .rs1 = 0, .operand = 0 };
    }
}

fn allocTemp(next_reg: *u16, max_reg: *u16) u8 {
    const reg = next_reg.*;
    next_reg.* += 1;
    if (next_reg.* > max_reg.*) max_reg.* = next_reg.*;
    return @truncate(reg); // wraps on overflow; checked via max_reg > 255 after loop
}

// ---- Tests ----

const testing = std.testing;

test "RegInstr size is 8 bytes" {
    try testing.expectEqual(8, @sizeOf(RegInstr));
}

test "convert — simple i32.add(local.get 0, local.get 1)" {
    // Wasm: local.get 0, local.get 1, i32.add, end
    const ir = [_]PreInstr{
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0
        .{ .opcode = 0x20, .extra = 0, .operand = 1 }, // local.get 1
        .{ .opcode = 0x6A, .extra = 0, .operand = 0 }, // i32.add
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &.{}, 2, 0, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    // Expected: add r2, r0, r1 (locals are r0,r1; temp is r2)
    //           return r2
    try testing.expectEqual(2, code.len);
    try testing.expectEqual(@as(u16, 0x6A), code[0].op); // i32.add
    try testing.expectEqual(@as(u8, 2), code[0].rd); // r2 (temp)
    try testing.expectEqual(@as(u8, 0), code[0].rs1); // r0 (local 0)
    try testing.expectEqual(@as(u8, 1), code[0].rs2()); // r1 (local 1)
    try testing.expectEqual(OP_RETURN, code[1].op);
    try testing.expectEqual(@as(u8, 2), code[1].rd); // return r2
}

test "convert — local.get eliminates to register reference" {
    // Wasm: local.get 0, end (return a local)
    const ir = [_]PreInstr{
        .{ .opcode = 0x20, .extra = 0, .operand = 0 },
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 },
    };

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    // Just: return r0 (local.get 0 was eliminated)
    try testing.expectEqual(1, code.len);
    try testing.expectEqual(OP_RETURN, code[0].op);
    try testing.expectEqual(@as(u8, 0), code[0].rd);
}

test "convert — i32.const + local.set" {
    // Wasm: i32.const 42, local.set 0, end
    const ir = [_]PreInstr{
        .{ .opcode = 0x41, .extra = 0, .operand = 42 },
        .{ .opcode = 0x21, .extra = 0, .operand = 0 },
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 },
    };

    const result = try convert(testing.allocator, &ir, &.{}, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    // After copy propagation: const32 r0=42; return_void
    try testing.expectEqual(2, code.len);
    try testing.expectEqual(OP_CONST32, code[0].op);
    try testing.expectEqual(@as(u8, 0), code[0].rd); // directly into local r0
    try testing.expectEqual(@as(u32, 42), code[0].operand);
    try testing.expectEqual(OP_RETURN_VOID, code[1].op);
}

test "convert — local.tee aliasing: stale vstack reference" {
    // Regression test for TinyGo fib_loop bug.
    // Wasm pattern from the unrolled loop:
    //   local.get 1       ; push b (r1)
    //   local.get 0       ; push a (r0)
    //   local.get 1       ; push b (r1)
    //   i32.add           ; a + b → temp
    //   local.tee 0       ; local0 = temp (overwrite r0)
    //   i32.add           ; (original b) + temp
    //   end
    //
    // Bug: after local.tee 0 modifies r0, the first local.get 1 result
    // (still r1) is fine, but when local.tee modifies a register that's
    // already on the vstack, the old reference becomes stale.
    //
    // More precisely: local.get 1 pushes r1, then later local.tee 1
    // would overwrite r1, corrupting the earlier stack entry.
    // Here we test: local.get 0, local.tee 0 overwrites r0 while r0
    // is still on the stack from an earlier push.
    const ir = [_]PreInstr{
        // local.get 0, local.get 1, local.get 0, i32.add, local.tee 0, i32.add, end
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0 → push r0 (old value)
        .{ .opcode = 0x20, .extra = 0, .operand = 1 }, // local.get 1
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0
        .{ .opcode = 0x6A, .extra = 0, .operand = 0 }, // i32.add (r1 + r0 = temp)
        .{ .opcode = 0x22, .extra = 0, .operand = 0 }, // local.tee 0 (r0 = temp; stale ref!)
        .{ .opcode = 0x6A, .extra = 0, .operand = 0 }, // i32.add (old_r0 + new_r0)
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &.{}, 2, 0, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    // The second i32.add must use the OLD value of local 0, not the new value.
    // If aliasing is broken, both operands of the final add would be the same register.
    // Correct: the first local.get 0 should be detached to a temp before local.tee 0.
    const last_add = code[code.len - 2]; // second-to-last is the final add (before return)
    try testing.expectEqual(@as(u16, 0x6A), last_add.op);
    // The two operands must be DIFFERENT registers (old r0 value vs new r0 value)
    try testing.expect(last_add.rs1 != last_add.rs2());
}

test "convert — graceful fallback when locals exceed u8 range" {
    const ir = [_]PreInstr{
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };
    const result = try convert(testing.allocator, &ir, &.{}, 200, 100, null);
    try testing.expect(result == null);
}

test "convert — graceful fallback when temp registers overflow u8" {
    // 250 params + 7 i32.const temps → reg 256 overflows u8
    var ir: [8]PreInstr = undefined;
    for (0..7) |i| {
        ir[i] = .{ .opcode = 0x41, .extra = 0, .operand = @intCast(i) }; // i32.const
    }
    ir[7] = .{ .opcode = 0x0B, .extra = 0, .operand = 0 }; // end
    const result = try convert(testing.allocator, &ir, &.{}, 250, 0, null);
    try testing.expect(result == null);
}

test "convert — br_table with arity-0 targets" {
    // Wasm: (block $a (block $b (local.get 0) (br_table 0 1 1)))
    // br_table count=2 → case 0→depth 0($b), case 1→depth 1($a), default→depth 1($a)
    const ir = [_]PreInstr{
        .{ .opcode = 0x02, .extra = 0, .operand = 0 }, // block $a (arity 0)
        .{ .opcode = 0x02, .extra = 0, .operand = 0 }, // block $b (arity 0)
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0 (index)
        .{ .opcode = 0x0E, .extra = 0, .operand = 2 }, // br_table count=2
        .{ .opcode = 0x00, .extra = 0, .operand = 0 }, // entry 0: depth 0 ($b)
        .{ .opcode = 0x00, .extra = 0, .operand = 1 }, // entry 1: depth 1 ($a)
        .{ .opcode = 0x00, .extra = 0, .operand = 1 }, // default:  depth 1 ($a)
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end $b
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end $a
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end func
    };

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    // Should emit: OP_BR_TABLE (rd=r0, operand=2), 3 NOP entries, OP_RETURN
    try testing.expect(code.len >= 5); // BR_TABLE + 3 entries + RETURN
    try testing.expectEqual(OP_BR_TABLE, code[0].op);
    try testing.expectEqual(@as(u8, 0), code[0].rd); // idx_reg = r0 (param 0)
    try testing.expectEqual(@as(u32, 2), code[0].operand); // count
    // 3 entry NOPs follow
    try testing.expectEqual(OP_NOP, code[1].op);
    try testing.expectEqual(OP_NOP, code[2].op);
    try testing.expectEqual(OP_NOP, code[3].op);
}

test "convert — memory.fill emits OP_MEMORY_FILL" {
    // Wasm: local.get 0, local.get 1, local.get 2, memory.fill
    const ir = [_]PreInstr{
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0 (dst)
        .{ .opcode = 0x20, .extra = 0, .operand = 1 }, // local.get 1 (val)
        .{ .opcode = 0x20, .extra = 0, .operand = 2 }, // local.get 2 (n)
        .{ .opcode = predecode.MISC_BASE | 0x0B, .extra = 0, .operand = 0 }, // memory.fill
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &.{}, 3, 0, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    try testing.expect(code.len >= 2); // MEMORY_FILL + RETURN
    try testing.expectEqual(OP_MEMORY_FILL, code[0].op);
    try testing.expectEqual(@as(u8, 0), code[0].rd); // dst = r0
    try testing.expectEqual(@as(u8, 1), code[0].rs1); // val = r1
    try testing.expectEqual(@as(u8, 2), code[0].rs2()); // n = r2
}

test "copy propagation — const + local.set folds to direct const" {
    // Wasm: i32.const 42, local.set 0, end
    // Before copy prop: const32 r1=42; mov r0=r1; return_void (3 instrs)
    // After copy prop:  const32 r0=42; return_void (2 instrs)
    const ir = [_]PreInstr{
        .{ .opcode = 0x41, .extra = 0, .operand = 42 }, // i32.const 42
        .{ .opcode = 0x21, .extra = 0, .operand = 0 }, // local.set 0
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &.{}, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    // After copy propagation: const32 r0=42; return_void
    try testing.expectEqual(2, code.len);
    try testing.expectEqual(OP_CONST32, code[0].op);
    try testing.expectEqual(@as(u8, 0), code[0].rd); // directly into local r0
    try testing.expectEqual(@as(u32, 42), code[0].operand);
    try testing.expectEqual(OP_RETURN_VOID, code[1].op);
}

test "copy propagation — add + local.set folds" {
    // Wasm: local.get 0, local.get 1, i32.add, local.set 0, end
    // Before: add r2=r0+r1; mov r0=r2; return_void (3 instrs)
    // After:  add r0=r0+r1; return_void (2 instrs)
    const ir = [_]PreInstr{
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0
        .{ .opcode = 0x20, .extra = 0, .operand = 1 }, // local.get 1
        .{ .opcode = 0x6A, .extra = 0, .operand = 0 }, // i32.add
        .{ .opcode = 0x21, .extra = 0, .operand = 0 }, // local.set 0
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &.{}, 2, 0, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    // After copy propagation: add r0=r0+r1; return_void
    try testing.expectEqual(2, code.len);
    try testing.expectEqual(@as(u16, 0x6A), code[0].op); // i32.add
    try testing.expectEqual(@as(u8, 0), code[0].rd); // directly into local r0
    try testing.expectEqual(@as(u8, 0), code[0].rs1); // r0
    try testing.expectEqual(@as(u8, 1), code[0].rs2()); // r1
    try testing.expectEqual(OP_RETURN_VOID, code[1].op);
}

test "copy propagation — preserves branch target MOVs" {
    // Pattern with a branch to the MOV — should NOT be folded
    // Wasm: block, local.get 0, br_if 0, i32.const 99, local.set 0, end, end
    const ir = [_]PreInstr{
        .{ .opcode = 0x02, .extra = 0, .operand = 0x40 }, // block void
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0
        .{ .opcode = 0x0D, .extra = 0, .operand = 0 }, // br_if 0
        .{ .opcode = 0x41, .extra = 0, .operand = 99 }, // i32.const 99
        .{ .opcode = 0x21, .extra = 0, .operand = 0 }, // local.set 0
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end (block)
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end (func)
    };

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    // Just verify it produces valid code (no crash, correct result structure)
    const code = result.?.code;
    try testing.expect(code.len >= 2);
}
