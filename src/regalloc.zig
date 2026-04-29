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
    rd: u16, // destination register
    rs1: u16, // source register 1
    rs2_field: u16 = 0, // source register 2 (for binary ops)
    operand: u32 = 0, // immediate | branch target | pool index

    pub fn rs2(self: RegInstr) u16 {
        return self.rs2_field;
    }
};

comptime {
    std.debug.assert(@sizeOf(RegInstr) == 12);
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
/// return_multi rd, rs1, operand=count — return multiple values.
/// rd = first result vreg, rs1 = second result vreg.
/// If count > 2, following NOP instructions carry additional vregs (rd, rs1 per NOP).
pub const OP_RETURN_MULTI: u16 = 0xFC;

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
/// ref_null rd, type: regs[rd] = 0 (null ref of given type)
pub const OP_REF_NULL: u16 = 0xE3;
/// ref_is_null rd, rs1: regs[rd] = (regs[rs1] == 0) ? 1 : 0
pub const OP_REF_IS_NULL: u16 = 0xE4;

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
    /// Resolves GC type index to struct field count (for struct.new).
    /// Optional — if null, struct.new bails out.
    resolve_gc_field_count_fn: ?*const fn (*anyopaque, u32) ?u16 = null,
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
    result_reg: u16,
    /// For forward branches: list of PCs that need patching with end PC.
    /// We use a simple approach: patch slots embedded in RegInstr.operand.
    patches: std.ArrayList(u32),
};

/// Temp register allocator with free list for register reuse.
/// When stack temps are consumed (popped from vstack), their indices are recycled
/// for future allocations, keeping max_reg low and avoiding >255 bailout.
const TempAlloc = struct {
    next_reg: u16,
    max_reg: u16,
    free_count: u16 = 0,
    free_regs: [512]u16 = undefined,
    total_locals: u16,

    fn init(total_locals: u16) TempAlloc {
        return .{
            .next_reg = total_locals,
            .max_reg = total_locals,
            .total_locals = total_locals,
        };
    }

    fn alloc(self: *TempAlloc) u16 {
        if (self.free_count > 0) {
            self.free_count -= 1;
            return self.free_regs[self.free_count];
        }
        const reg = self.next_reg;
        self.next_reg += 1;
        if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
        return reg;
    }

    fn free(self: *TempAlloc, reg: u16) void {
        if (reg < self.total_locals) return;
        if (self.free_count < 512) {
            self.free_regs[self.free_count] = reg;
            self.free_count += 1;
        }
    }

    /// Pop from vstack and free if temp register.
    fn popFree(self: *TempAlloc, vs: *std.ArrayList(u16)) ?u16 {
        const reg = vs.pop() orelse return null;
        self.free(reg);
        return reg;
    }

    /// Shrink vstack and free discarded temp registers.
    fn shrinkFree(self: *TempAlloc, vs: *std.ArrayList(u16), new_len: usize) void {
        for (vs.items[new_len..]) |reg| self.free(reg);
        vs.shrinkRetainingCapacity(new_len);
    }
};

/// SIMD opcode stack effect: how many values are popped/pushed.
/// Returns null for unknown sub-opcodes (bail).
///
/// Classification based on wasm SIMD spec stack signatures.
/// Default for unrecognized-but-in-range: binary (pop 2, push 1).
pub fn simdStackEffect(sub: u32) ?struct { pop: u8, push: u8 } {
    return switch (sub) {
        // --- Memory loads: pop 1 addr, push 1 v128 ---
        0x00...0x0A, 0x5C, 0x5D => .{ .pop = 1, .push = 1 },
        // --- v128.store: pop v128 + addr ---
        0x0B => .{ .pop = 2, .push = 0 },
        // --- v128.const: push 1 ---
        0x0C => .{ .pop = 0, .push = 1 },
        // --- shuffle, swizzle: pop 2, push 1 ---
        0x0D, 0x0E => .{ .pop = 2, .push = 1 },
        // --- splat: pop 1 scalar, push 1 v128 ---
        0x0F...0x14 => .{ .pop = 1, .push = 1 },
        // --- extract_lane / replace_lane (interleaved) ---
        0x15, 0x16 => .{ .pop = 1, .push = 1 }, // i8x16 extract s/u
        0x17 => .{ .pop = 2, .push = 1 }, // i8x16 replace
        0x18, 0x19 => .{ .pop = 1, .push = 1 }, // i16x8 extract s/u
        0x1A => .{ .pop = 2, .push = 1 }, // i16x8 replace
        0x1B => .{ .pop = 1, .push = 1 }, // i32x4 extract
        0x1C => .{ .pop = 2, .push = 1 }, // i32x4 replace
        0x1D => .{ .pop = 1, .push = 1 }, // i64x2 extract
        0x1E => .{ .pop = 2, .push = 1 }, // i64x2 replace
        0x1F => .{ .pop = 1, .push = 1 }, // f32x4 extract
        0x20 => .{ .pop = 2, .push = 1 }, // f32x4 replace
        0x21 => .{ .pop = 1, .push = 1 }, // f64x2 extract
        0x22 => .{ .pop = 2, .push = 1 }, // f64x2 replace
        // --- comparison (all binary): pop 2, push 1 ---
        0x23...0x4C => .{ .pop = 2, .push = 1 },
        // --- v128 bitwise ---
        0x4D => .{ .pop = 1, .push = 1 }, // not (unary)
        0x4E...0x51 => .{ .pop = 2, .push = 1 }, // and, andnot, or, xor
        // --- v128.bitselect: pop 3, push 1 ---
        0x52 => .{ .pop = 3, .push = 1 },
        // --- v128.any_true: unary ---
        0x53 => .{ .pop = 1, .push = 1 },
        // --- lane load/store ---
        0x54...0x57 => .{ .pop = 2, .push = 1 }, // lane load
        0x58...0x5B => .{ .pop = 2, .push = 0 }, // lane store
        // --- float conversion (unary) ---
        0x5E, 0x5F => .{ .pop = 1, .push = 1 },
        // --- i8x16 ops ---
        0x60, 0x61, 0x62 => .{ .pop = 1, .push = 1 }, // abs, neg, popcnt
        0x63, 0x64 => .{ .pop = 1, .push = 1 }, // all_true, bitmask
        0x65, 0x66 => .{ .pop = 2, .push = 1 }, // narrow (BINARY!)
        0x67, 0x68, 0x69, 0x6A => .{ .pop = 1, .push = 1 }, // f32x4 ceil/floor/trunc/nearest
        0x6B, 0x6C, 0x6D => .{ .pop = 2, .push = 1 }, // shl, shr_s, shr_u (v128+i32)
        0x6E...0x73 => .{ .pop = 2, .push = 1 }, // add, add_sat, sub, sub_sat
        0x74, 0x75 => .{ .pop = 1, .push = 1 }, // f64x2 ceil, floor
        0x76...0x79 => .{ .pop = 2, .push = 1 }, // min_s/u, max_s/u
        0x7A => .{ .pop = 1, .push = 1 }, // f64x2 trunc
        0x7B => .{ .pop = 2, .push = 1 }, // avgr_u
        0x7C...0x7F => .{ .pop = 1, .push = 1 }, // extadd_pairwise (unary)
        // --- i16x8 ops ---
        0x80, 0x81 => .{ .pop = 1, .push = 1 }, // abs, neg
        0x82 => .{ .pop = 2, .push = 1 }, // q15mulr_sat_s (binary)
        0x83, 0x84 => .{ .pop = 1, .push = 1 }, // all_true, bitmask
        0x85, 0x86 => .{ .pop = 2, .push = 1 }, // narrow (BINARY!)
        0x87...0x8A => .{ .pop = 1, .push = 1 }, // extend low/high (unary)
        0x8B, 0x8C, 0x8D => .{ .pop = 2, .push = 1 }, // shl, shr_s, shr_u
        0x8E...0x93 => .{ .pop = 2, .push = 1 }, // add, add_sat, sub, sub_sat
        0x94 => .{ .pop = 1, .push = 1 }, // f64x2 nearest
        0x95...0x99 => .{ .pop = 2, .push = 1 }, // mul, min, max
        0x9B...0x9F => .{ .pop = 2, .push = 1 }, // avgr_u, extmul
        // --- i32x4 ops ---
        0xA0, 0xA1 => .{ .pop = 1, .push = 1 }, // abs, neg
        0xA3, 0xA4 => .{ .pop = 1, .push = 1 }, // all_true, bitmask
        0xA7...0xAA => .{ .pop = 1, .push = 1 }, // extend low/high (unary)
        0xAB, 0xAC, 0xAD => .{ .pop = 2, .push = 1 }, // shl, shr_s, shr_u
        0xAE => .{ .pop = 2, .push = 1 }, // add
        0xB1 => .{ .pop = 2, .push = 1 }, // sub
        0xB5...0xBF => .{ .pop = 2, .push = 1 }, // mul, min, max, dot, extmul
        // --- i64x2 ops ---
        0xC0, 0xC1 => .{ .pop = 1, .push = 1 }, // abs, neg
        0xC3, 0xC4 => .{ .pop = 1, .push = 1 }, // all_true, bitmask
        0xC7...0xCA => .{ .pop = 1, .push = 1 }, // extend low/high (unary)
        0xCB, 0xCC, 0xCD => .{ .pop = 2, .push = 1 }, // shl, shr_s, shr_u
        0xCE => .{ .pop = 2, .push = 1 }, // add
        0xD1 => .{ .pop = 2, .push = 1 }, // sub
        0xD5 => .{ .pop = 2, .push = 1 }, // mul
        0xD6...0xDB => .{ .pop = 2, .push = 1 }, // comparison (binary)
        0xDC...0xDF => .{ .pop = 2, .push = 1 }, // extmul
        // --- f32x4 arithmetic ---
        0xE0, 0xE1 => .{ .pop = 1, .push = 1 }, // abs, neg
        0xE3 => .{ .pop = 1, .push = 1 }, // sqrt
        0xE4...0xEB => .{ .pop = 2, .push = 1 }, // add, sub, mul, div, min, max, pmin, pmax
        // --- f64x2 arithmetic ---
        0xEC, 0xED => .{ .pop = 1, .push = 1 }, // abs, neg
        0xEF => .{ .pop = 1, .push = 1 }, // sqrt
        0xF0...0xF7 => .{ .pop = 2, .push = 1 }, // add, sub, mul, div, min, max, pmin, pmax
        // --- Conversion (all unary) ---
        0xF8...0xFF => .{ .pop = 1, .push = 1 },
        // --- Relaxed SIMD ---
        0x100 => .{ .pop = 2, .push = 1 }, // relaxed_swizzle (binary)
        0x101...0x104 => .{ .pop = 1, .push = 1 }, // relaxed_trunc (unary)
        0x105...0x108 => .{ .pop = 3, .push = 1 }, // relaxed madd/nmadd (ternary)
        0x109...0x10C => .{ .pop = 3, .push = 1 }, // relaxed laneselect (ternary)
        0x10D...0x110 => .{ .pop = 2, .push = 1 }, // relaxed min/max (binary)
        0x111 => .{ .pop = 2, .push = 1 }, // relaxed_q15mulr_s
        0x112 => .{ .pop = 2, .push = 1 }, // relaxed_dot
        0x113 => .{ .pop = 3, .push = 1 }, // relaxed_dot_add (ternary)
        else => null,
    };
}

/// Convert PreInstr[] to RegInstr[].
/// Returns null if conversion fails (unsupported opcodes).
pub fn convert(
    alloc: Allocator,
    ir_code: []const PreInstr,
    pool64: []const u64,
    param_count: u16,
    local_count: u16,
    result_count: u16,
    resolver: ?ParamResolver,
) ConvertError!?*RegFunc {
    const total_locals = param_count + local_count;

    // Bail if locals exceed u8 register range (RegInstr fields are u8)
    if (total_locals > 255) return null;

    // Bail if result count exceeds encoding capacity (8 results max)
    if (result_count > 8) return null;

    var code: std.ArrayList(RegInstr) = .empty;
    var code_transferred = false;
    defer if (!code_transferred) code.deinit(alloc);
    var block_stack: std.ArrayList(BlockInfo) = .empty;
    defer {
        for (block_stack.items) |*b| b.patches.deinit(alloc);
        block_stack.deinit(alloc);
    }

    // Virtual register stack: tracks which register holds each stack slot.
    var vstack: std.ArrayList(u16) = .empty;
    defer vstack.deinit(alloc);

    var temps = TempAlloc.init(total_locals);
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
                            temps.shrinkFree(&vstack, block.stack_base);
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
                const src = temps.popFree(&vstack).?;
                const dst: u8 = @intCast(instr.operand);
                if (src != dst) {
                    // Detach stale vstack references to dst before overwriting
                    for (vstack.items) |*entry| {
                        if (entry.* == dst) {
                            const tmp = temps.alloc();
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
                            const tmp = temps.alloc();
                            try code.append(alloc, .{ .op = OP_MOV, .rd = tmp, .rs1 = dst, .operand = 0 });
                            entry.* = tmp;
                        }
                    }
                    try code.append(alloc, .{ .op = OP_MOV, .rd = dst, .rs1 = src, .operand = 0 });
                }
                // Replace stack top with dst register; free old src if temp
                vstack.items[vstack.items.len - 1] = dst;
                temps.free(src);
            },

            // ---- Constants ----
            0x41 => { // i32.const
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST32, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            0x42 => { // i64.const (pool index in operand)
                const rd = temps.alloc();
                const pool_val = if (instr.operand < pool64.len) pool64[instr.operand] else 0;
                if (pool_val <= std.math.maxInt(u32)) {
                    try code.append(alloc, .{ .op = OP_CONST32, .rd = rd, .rs1 = 0, .operand = @truncate(pool_val) });
                } else {
                    try code.append(alloc, .{ .op = OP_CONST64, .rd = rd, .rs1 = 0, .operand = instr.operand });
                }
                try vstack.append(alloc, rd);
            },
            0x43 => { // f32.const (bits in operand)
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST32, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            0x44 => { // f64.const (pool index in operand)
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST64, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },

            // ---- Binary i32 arithmetic ----
            0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, // add..rotr
            0x74, 0x75, 0x76, 0x77, 0x78, // shl, shr_s, shr_u, rotl, rotr
            => {
                const rs2 = temps.popFree(&vstack).?;
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary i32 comparison ----
            0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F => {
                const rs2 = temps.popFree(&vstack).?;
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Unary i32 ----
            0x45 => { // i32.eqz
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            0x67, 0x68, 0x69 => { // i32.clz, ctz, popcnt
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary i64 arithmetic ----
            0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, // add..rotr
            0x86, 0x87, 0x88, 0x89, 0x8A, // shl, shr_s, shr_u, rotl, rotr
            => {
                const rs2 = temps.popFree(&vstack).?;
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary i64 comparison ----
            0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A => {
                const rs2 = temps.popFree(&vstack).?;
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Unary i64 ----
            0x50 => { // i64.eqz
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            0x79, 0x7A, 0x7B => { // i64.clz, ctz, popcnt
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary f64 arithmetic ----
            0xA0, 0xA1, 0xA2, 0xA3, // f64.add, sub, mul, div
            0xA4, 0xA5, // f64.min, max
            0xA6, // f64.copysign
            => {
                const rs2 = temps.popFree(&vstack).?;
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary f64 comparison ----
            0x61, 0x62, 0x63, 0x64, 0x65, 0x66 => {
                const rs2 = temps.popFree(&vstack).?;
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Unary f64 ----
            0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F => { // abs, neg, ceil, floor, trunc, nearest, sqrt
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary f32 arithmetic ----
            0x92, 0x93, 0x94, 0x95, // f32.add, sub, mul, div
            0x96, 0x97, // f32.min, max
            0x98, // f32.copysign
            => {
                const rs2 = temps.popFree(&vstack).?;
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Binary f32 comparison ----
            0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60 => {
                const rs2 = temps.popFree(&vstack).?;
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2 });
                try vstack.append(alloc, rd);
            },

            // ---- Unary f32 ----
            0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91 => {
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Conversions (unary) ----
            0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF, // i32/i64 wrap/trunc
            0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, // f32/f64 convert
            0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF, // reinterpret, extend
            0xC0, 0xC1, 0xC2, 0xC3, 0xC4, // extend8/16/32
            => {
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Memory load (base addr on stack + offset in operand) ----
            0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, // i32/i64/f32/f64 loads
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, // sign-extending loads
            => {
                if (instr.extra != 0) return null; // multi-memory: bail to predecode IR
                const rs1 = temps.popFree(&vstack).?; // base address
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },

            // ---- Memory store (base addr + value on stack, offset in operand) ----
            0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E => {
                if (instr.extra != 0) return null; // multi-memory: bail to predecode IR
                const val = temps.popFree(&vstack).?; // value to store
                const base = temps.popFree(&vstack).?; // base address
                // Store: no destination register. Use rd=val, rs1=base
                try code.append(alloc, .{ .op = instr.opcode, .rd = val, .rs1 = base, .operand = instr.operand });
            },

            // ---- Control flow ----
            0x02 => { // block
                if (instr.extra & predecode.ARITY_TYPE_INDEX_FLAG != 0) return null;
                const arity: u16 = instr.extra;

                const result_reg = if (arity > 0) temps.alloc() else 0;
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

                const result_reg = if (arity > 0) temps.alloc() else 0;
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

                const cond = temps.popFree(&vstack).?;
                const result_reg = if (arity > 0) temps.alloc() else 0;
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
                    const val = temps.popFree(&vstack).?;
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
                temps.shrinkFree(&vstack, block.stack_base);
            },

            0x0B => { // end
                if (block_stack.items.len == 0) {
                    // Function-level end: return
                    if (result_count > 1 and vstack.items.len >= result_count) {
                        // Multi-value return: pop results in reverse order
                        // Stack top = last result, bottom = first result
                        var result_vregs: [8]u16 = undefined;
                        var i: u16 = result_count;
                        while (i > 0) : (i -= 1) {
                            result_vregs[i - 1] = temps.popFree(&vstack).?;
                        }
                        // Encode: rd=first, rs1=second, operand=count
                        try code.append(alloc, .{
                            .op = OP_RETURN_MULTI,
                            .rd = result_vregs[0],
                            .rs1 = result_vregs[1],
                            .operand = result_count,
                        });
                        // Additional results in following NOP instructions
                        var j: u16 = 2;
                        while (j < result_count) : (j += 2) {
                            const r0 = result_vregs[j];
                            const r1 = if (j + 1 < result_count) result_vregs[j + 1] else 0;
                            try code.append(alloc, .{ .op = OP_NOP, .rd = r0, .rs1 = r1, .operand = 0 });
                        }
                    } else if (vstack.items.len > 0) {
                        const val = temps.popFree(&vstack).?;
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
                    const val = temps.popFree(&vstack).?;
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
                temps.shrinkFree(&vstack, block.stack_base);
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
                const cond = temps.popFree(&vstack).?;
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

                const rd = if (n_results > 0) temps.alloc() else 0;

                try code.append(alloc, .{ .op = OP_CALL, .rd = rd, .rs1 = @intCast(n_args), .rs2_field = @intCast(n_results), .operand = func_idx });

                // Pack arg registers into data words (up to 4 per word)
                var arg_regs: [8]u16 = .{0} ** 8;
                const arg_start = vstack.items.len - n_args;
                for (0..n_args) |i| {
                    arg_regs[i] = vstack.items[arg_start + i];
                }
                try code.append(alloc, .{
                    .op = OP_NOP,
                    .rd = arg_regs[0],
                    .rs1 = arg_regs[1],
                    .rs2_field = arg_regs[2],
                    .operand = arg_regs[3],
                });
                if (n_args > 4) {
                    try code.append(alloc, .{
                        .op = OP_NOP,
                        .rd = arg_regs[4],
                        .rs1 = arg_regs[5],
                        .rs2_field = arg_regs[6],
                        .operand = arg_regs[7],
                    });
                }

                // Pop only the arg count from virtual stack
                temps.shrinkFree(&vstack, vstack.items.len - n_args);
                if (n_results > 0) try vstack.append(alloc, rd);
            },

            // ---- Return ----
            0x0F => { // return
                if (result_count > 1 and vstack.items.len >= result_count) {
                    var result_vregs: [8]u16 = undefined;
                    var ri: u16 = result_count;
                    while (ri > 0) : (ri -= 1) {
                        result_vregs[ri - 1] = temps.popFree(&vstack).?;
                    }
                    try code.append(alloc, .{
                        .op = OP_RETURN_MULTI,
                        .rd = result_vregs[0],
                        .rs1 = result_vregs[1],
                        .operand = result_count,
                    });
                    var rj: u16 = 2;
                    while (rj < result_count) : (rj += 2) {
                        const r0 = result_vregs[rj];
                        const r1 = if (rj + 1 < result_count) result_vregs[rj + 1] else 0;
                        try code.append(alloc, .{ .op = OP_NOP, .rd = r0, .rs1 = r1, .operand = 0 });
                    }
                } else if (vstack.items.len > 0) {
                    const val = temps.popFree(&vstack).?;
                    try code.append(alloc, .{ .op = OP_RETURN, .rd = val, .rs1 = 0, .operand = 0 });
                } else {
                    try code.append(alloc, .{ .op = OP_RETURN_VOID, .rd = 0, .rs1 = 0, .operand = 0 });
                }
                unreachable_depth = 1; // subsequent code is dead
            },

            // ---- Drop ----
            0x1A => { // drop
                _ = temps.popFree(&vstack);
            },

            // ---- Select ----
            0x1B => { // select
                const cond = temps.popFree(&vstack).?;
                const val2 = temps.popFree(&vstack).?;
                const val1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                // select rd, val1, val2, cond: rd = cond ? val1 : val2
                // Encode: rd=rd, rs1=val1, rs2_field=val2, operand=cond
                try code.append(alloc, .{
                    .op = 0x1B,
                    .rd = rd,
                    .rs1 = val1,
                    .rs2_field = val2,
                    .operand = cond,
                });
                try vstack.append(alloc, rd);
            },

            // ---- Memory size/grow ----
            0x3F => { // memory.size
                if (instr.extra != 0) return null; // multi-memory: bail to predecode IR
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x3F, .rd = rd, .rs1 = 0, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            0x40 => { // memory.grow
                if (instr.extra != 0) return null; // multi-memory: bail to predecode IR
                const rs1 = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x40, .rd = rd, .rs1 = rs1, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- Global get/set ----
            0x23 => { // global.get
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x23, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            0x24 => { // global.set
                const src = temps.popFree(&vstack).?;
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
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST32, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
                pc += 1; // skip consumed i32.const
            },
            predecode.OP_LOCALS_ADD => {
                // local.get A + local.get B + i32.add
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x6A, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = @intCast(instr.operand & 0xFF) });
                try vstack.append(alloc, rd);
                pc += 2; // skip consumed local.get + i32.add
            },
            predecode.OP_LOCALS_SUB => {
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x6B, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = @intCast(instr.operand & 0xFF) });
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_ADD => {
                // local.get A + i32.const C + i32.add → add rd, rA, const_reg
                const const_rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x6A, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = const_rd });
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_SUB => {
                const const_rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x6B, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = const_rd });
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_LT_S => {
                const const_rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x48, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = const_rd }); // i32.lt_s
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_GE_S => {
                const const_rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x4E, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = const_rd }); // i32.ge_s
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCAL_CONST_LT_U => {
                const const_rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_CONST32, .rd = const_rd, .rs1 = 0, .operand = instr.operand });
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x49, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = const_rd }); // i32.lt_u
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCALS_GT_S => {
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x4A, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = @intCast(instr.operand & 0xFF) }); // i32.gt_s
                try vstack.append(alloc, rd);
                pc += 2;
            },
            predecode.OP_LOCALS_LE_S => {
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = 0x4C, .rd = rd, .rs1 = @intCast(instr.extra), .rs2_field = @intCast(instr.operand & 0xFF) }); // i32.le_s
                try vstack.append(alloc, rd);
                pc += 2;
            },

            // ---- br_table ----
            0x0E => {
                const count = instr.operand;
                const idx_reg = temps.popFree(&vstack).?;

                // Pre-scan: check if any target has arity > 0
                var has_arity = false;
                var unique_result_reg: ?u16 = null;
                var arity_val: u16 = 0;
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
                const elem_idx_reg = temps.popFree(&vstack).?;
                if (vstack.items.len < n_args) return null;

                const rd = if (n_results > 0) temps.alloc() else 0;

                // OP_CALL_INDIRECT: rd=result, rs1=elem_idx_reg,
                // operand=type_idx, table_idx packed in high bits
                try code.append(alloc, .{
                    .op = OP_CALL_INDIRECT,
                    .rd = rd,
                    .rs1 = elem_idx_reg,
                    .rs2_field = @intCast(n_results),
                    .operand = type_idx | (@as(u32, table_idx) << 24),
                });

                // Pack arg registers (same layout as OP_CALL)
                var arg_regs: [8]u16 = .{0} ** 8;
                const arg_start = vstack.items.len - n_args;
                for (0..n_args) |i| {
                    arg_regs[i] = vstack.items[arg_start + i];
                }
                try code.append(alloc, .{
                    .op = OP_NOP,
                    .rd = arg_regs[0],
                    .rs1 = arg_regs[1],
                    .rs2_field = arg_regs[2],
                    .operand = arg_regs[3],
                });
                if (n_args > 4) {
                    try code.append(alloc, .{
                        .op = OP_NOP,
                        .rd = arg_regs[4],
                        .rs1 = arg_regs[5],
                        .rs2_field = arg_regs[6],
                        .operand = arg_regs[7],
                    });
                }

                temps.shrinkFree(&vstack, vstack.items.len - n_args);
                if (n_results > 0) try vstack.append(alloc, rd);
            },

            // ---- Bulk memory operations ----
            predecode.MISC_BASE | 0x0B => { // memory.fill
                if (instr.operand != 0) return null; // multi-memory: bail
                if (vstack.items.len < 3) return null;
                const n_reg = temps.popFree(&vstack).?;
                const val_reg = temps.popFree(&vstack).?;
                const dst_reg = temps.popFree(&vstack).?;
                try code.append(alloc, .{
                    .op = OP_MEMORY_FILL,
                    .rd = dst_reg,
                    .rs1 = val_reg,
                    .rs2_field = n_reg,
                });
            },
            predecode.MISC_BASE | 0x0A => { // memory.copy
                if (instr.extra != 0 or instr.operand != 0) return null; // multi-memory: bail
                if (vstack.items.len < 3) return null;
                const n_reg = temps.popFree(&vstack).?;
                const src_reg = temps.popFree(&vstack).?;
                const dst_reg = temps.popFree(&vstack).?;
                try code.append(alloc, .{
                    .op = OP_MEMORY_COPY,
                    .rd = dst_reg,
                    .rs1 = src_reg,
                    .rs2_field = n_reg,
                });
            },

            // ---- Truncation saturating (misc prefix) ----
            predecode.MISC_BASE | 0x00 => { // i32.trunc_sat_f32_s
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x00, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x01 => { // i32.trunc_sat_f32_u
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x01, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x02 => { // i32.trunc_sat_f64_s
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x02, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x03 => { // i32.trunc_sat_f64_u
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x03, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x04 => { // i64.trunc_sat_f32_s
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x04, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x05 => { // i64.trunc_sat_f32_u
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x05, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x06 => { // i64.trunc_sat_f64_s
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x06, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },
            predecode.MISC_BASE | 0x07 => { // i64.trunc_sat_f64_u
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.MISC_BASE | 0x07, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- GC struct operations ----
            predecode.GC_BASE | 0x00 => { // struct.new: pop N fields, push ref
                const type_idx = instr.operand;
                const res = resolver orelse return null;
                const resolve_gc = res.resolve_gc_field_count_fn orelse return null;
                const n_fields: usize = resolve_gc(res.ctx, type_idx) orelse return null;
                if (n_fields > 8 or vstack.items.len < n_fields) return null;

                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.GC_BASE | 0x00, .rd = rd, .rs1 = @intCast(n_fields), .operand = type_idx });

                // Pack field registers into NOP data words (same as OP_CALL)
                var arg_regs: [8]u16 = .{0} ** 8;
                const arg_start = vstack.items.len - n_fields;
                for (0..n_fields) |i| {
                    arg_regs[i] = vstack.items[arg_start + i];
                }
                try code.append(alloc, .{
                    .op = OP_NOP,
                    .rd = arg_regs[0],
                    .rs1 = arg_regs[1],
                    .rs2_field = arg_regs[2],
                    .operand = arg_regs[3],
                });
                if (n_fields > 4) {
                    try code.append(alloc, .{
                        .op = OP_NOP,
                        .rd = arg_regs[4],
                        .rs1 = arg_regs[5],
                        .rs2_field = arg_regs[6],
                        .operand = arg_regs[7],
                    });
                }

                temps.shrinkFree(&vstack, vstack.items.len - n_fields);
                try vstack.append(alloc, rd);
            },
            predecode.GC_BASE | 0x01 => { // struct.new_default: push ref (no pops)
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = predecode.GC_BASE | 0x01, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            predecode.GC_BASE | 0x02, // struct.get
            predecode.GC_BASE | 0x03, // struct.get_s
            predecode.GC_BASE | 0x04, // struct.get_u
            => { // pop ref, push value
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = src, .rs2_field = @intCast(instr.extra), .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            predecode.GC_BASE | 0x05 => { // struct.set: pop val + ref
                if (vstack.items.len < 2) return null;
                const val_reg = temps.popFree(&vstack).?;
                const ref_reg = temps.popFree(&vstack).?;
                try code.append(alloc, .{ .op = predecode.GC_BASE | 0x05, .rd = ref_reg, .rs1 = val_reg, .rs2_field = @intCast(instr.extra), .operand = instr.operand });
            },

            // ---- ref.null / ref.is_null ----
            // Note: wasm 0xD0/0xD1 collide with OP_ADDI32/OP_SUBI32 in RegIR space,
            // so we remap to OP_REF_NULL/OP_REF_IS_NULL.
            0xD0 => { // ref.null — push null ref
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_REF_NULL, .rd = rd, .rs1 = 0, .operand = instr.operand });
                try vstack.append(alloc, rd);
            },
            0xD1 => { // ref.is_null — pop ref, push i32
                const src = temps.popFree(&vstack).?;
                const rd = temps.alloc();
                try code.append(alloc, .{ .op = OP_REF_IS_NULL, .rd = rd, .rs1 = src, .operand = 0 });
                try vstack.append(alloc, rd);
            },

            // ---- SIMD opcodes: pass through with stack effect ----
            // Encoding: main instr has rd/rs1/rs2_field/operand.
            // Extra metadata (lane index, memidx) carried in trailing NOP:
            //   NOP.rd = extra_data, NOP.rs1 = third operand (for 3-input ops).
            // Adapter reads NOP to reconstruct PreInstr.extra for stack interpreter.
            predecode.SIMD_BASE...predecode.SIMD_BASE + 0x113 => {
                const sub = instr.opcode - predecode.SIMD_BASE;
                const effect = simdStackEffect(sub) orelse return null;
                const has_extra = instr.extra != 0;

                if (vstack.items.len < effect.pop) return null;

                if (effect.pop == 3) {
                    // 3-input ops (bitselect): pop c, b, a → op(a, b, c)
                    const c_reg = temps.popFree(&vstack).?;
                    const b_reg = temps.popFree(&vstack).?;
                    const a_reg = temps.popFree(&vstack).?;
                    const rd = temps.alloc();
                    try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = a_reg, .rs2_field = b_reg, .operand = instr.operand });
                    try code.append(alloc, .{ .op = OP_NOP, .rd = c_reg, .rs1 = @intCast(instr.extra), .operand = 0 });
                    try vstack.append(alloc, rd);
                } else if (effect.push == 0) {
                    // Store ops: pop value + addr
                    const val_reg = temps.popFree(&vstack).?;
                    const addr_reg = if (effect.pop >= 2) temps.popFree(&vstack).? else 0;
                    try code.append(alloc, .{ .op = instr.opcode, .rd = val_reg, .rs1 = addr_reg, .operand = instr.operand });
                    if (has_extra) try code.append(alloc, .{ .op = OP_NOP, .rd = @intCast(instr.extra), .rs1 = 0, .operand = 0 });
                } else if (effect.pop == 0) {
                    // v128.const: push result
                    const rd = temps.alloc();
                    try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = 0, .operand = instr.operand });
                    if (has_extra) try code.append(alloc, .{ .op = OP_NOP, .rd = @intCast(instr.extra), .rs1 = 0, .operand = 0 });
                    try vstack.append(alloc, rd);
                } else if (effect.pop == 1) {
                    // Unary: pop 1, push 1
                    const src = temps.popFree(&vstack).?;
                    const rd = temps.alloc();
                    try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = src, .operand = instr.operand });
                    if (has_extra) try code.append(alloc, .{ .op = OP_NOP, .rd = @intCast(instr.extra), .rs1 = 0, .operand = 0 });
                    try vstack.append(alloc, rd);
                } else {
                    // Binary: pop 2, push 1
                    const rs2 = temps.popFree(&vstack).?;
                    const rs1 = temps.popFree(&vstack).?;
                    const rd = temps.alloc();
                    try code.append(alloc, .{ .op = instr.opcode, .rd = rd, .rs1 = rs1, .rs2_field = rs2, .operand = instr.operand });
                    if (has_extra) try code.append(alloc, .{ .op = OP_NOP, .rd = @intCast(instr.extra), .rs1 = 0, .operand = 0 });
                    try vstack.append(alloc, rd);
                }
            },

            // ---- Anything else: bail ----
            else => return null,
        }
    }

    // If we fell through (no end instruction), add return
    if (code.items.len == 0 or (code.items[code.items.len - 1].op != OP_RETURN and
        code.items[code.items.len - 1].op != OP_RETURN_MULTI and
        code.items[code.items.len - 1].op != OP_RETURN_VOID))
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

    // Bail if temp registers exceeded u16 range
    if (temps.max_reg > 65535) return null;

    const result = try alloc.create(RegFunc);
    const owned_code = try code.toOwnedSlice(alloc);
    code_transferred = true;
    result.* = .{
        .code = owned_code,
        .pool64 = @constCast(pool64), // shared reference
        .reg_count = temps.max_reg,
        .local_count = total_locals,
        .alloc = alloc,
    };
    return result;
}

/// True iff this opcode writes a fresh value into rd. Stores treat rd as
/// a source, conditional branches and RETURN read it but don't redefine it,
/// no-vreg ops have no destination at all. Shared with `loop_info.zig`.
pub fn opWritesRd(op: u16) bool {
    return switch (op) {
        OP_BR, OP_BR_IF, OP_BR_IF_NOT, OP_BR_TABLE, OP_BLOCK_END,
        OP_NOP, OP_DELETED, OP_RETURN, OP_RETURN_VOID, OP_RETURN_MULTI,
        OP_MEMORY_FILL, OP_MEMORY_COPY,
        // Wasm stores: rd is the value source, rs1 is the address.
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
        => false,
        else => true,
    };
}

/// True iff rd is a SOURCE (read) rather than destination — stores and
/// conditional branches use rd as the value/condition input.
pub fn opUsesRdAsSource(op: u16) bool {
    return switch (op) {
        OP_BR_IF, OP_BR_IF_NOT, OP_RETURN, OP_RETURN_MULTI,
        // Wasm stores: rd is the value source.
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
        => true,
        else => false,
    };
}

/// True iff this opcode reads rs1 as a vreg.
pub fn opUsesRs1AsSource(op: u16) bool {
    return switch (op) {
        OP_BR, OP_BR_IF, OP_BR_IF_NOT, OP_BLOCK_END,
        OP_NOP, OP_DELETED, OP_CONST32, OP_CONST64,
        OP_RETURN, OP_RETURN_VOID,
        => false,
        else => true,
    };
}

/// True iff this opcode reads rs2_field as a vreg. Conservative: defaults
/// to "yes" for binop-shaped ops; explicit exclusions cover unary / mov /
/// const / control flow where rs2_field defaults to 0 and would otherwise
/// spuriously update last-use[0].
pub fn opUsesRs2AsSource(op: u16) bool {
    return switch (op) {
        OP_BR, OP_BR_IF, OP_BR_IF_NOT, OP_BLOCK_END,
        OP_NOP, OP_DELETED, OP_CONST32, OP_CONST64,
        OP_RETURN, OP_RETURN_VOID, OP_RETURN_MULTI,
        OP_MOV, OP_BR_TABLE,
        => false,
        else => true,
    };
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
            OP_MOV, OP_BR, OP_BR_IF, OP_BR_IF_NOT, OP_RETURN, OP_RETURN_MULTI, OP_RETURN_VOID,
            OP_NOP, OP_BLOCK_END, OP_DELETED, OP_BR_TABLE,
            OP_MEMORY_FILL, OP_MEMORY_COPY,
            => continue,
            // Store instructions use rd as value source, not destination
            0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E => continue,
            // GC struct.set: rd = ref_reg (a use, not a destination)
            predecode.GC_BASE | 0x05 => continue,
            else => {},
        }

        // The old temp's lifetime ends at the MOV — UNLESS some later
        // instruction reads it before any redefinition. The forward scan
        // honours that: stop at the first re-write of old_reg (its old
        // value is dead from then on); on a read of old_reg before that
        // write, bail out as "still in use".
        //
        // Branch targets in the scan path are treated conservatively: a
        // join point may import a live use of old_reg from another
        // predecessor we haven't analysed.
        // Don't fold if the old temp register is still referenced as a
        // source elsewhere. The scan can stop at the first redefinition of
        // old_reg ONLY if the redef is unconditionally executed on every
        // path from the MOV. Without dominator analysis, the safe proxy is
        // "no control-flow op exists between the MOV and the redef" — any
        // branch could bypass the redef and leave a path that still reads
        // old_reg's old value.
        //
        // We also bail on:
        //   - branch targets (a join may import a live use from another
        //     predecessor we haven't analysed),
        //   - multi-source ops whose hidden source vregs (CALL args at
        //     rs1+0, rs1+1, ...; BR_TABLE NOP entries; memory.fill/copy
        //     operand packing) would not be detected by rs1/rs2/rd alone.
        const old_reg = producer.rd;
        var still_used = false;
        var k: usize = i + 2;
        while (k < code.len) : (k += 1) {
            const later = code[k];
            if (later.op == OP_DELETED or later.op == OP_NOP) continue;
            if (k < branch_targets.len and branch_targets[k]) {
                still_used = true;
                break;
            }
            switch (later.op) {
                // Multi-source ops: bail conservatively (hidden vreg reads).
                OP_CALL, OP_CALL_INDIRECT, OP_BR_TABLE, OP_RETURN_MULTI,
                OP_MEMORY_FILL, OP_MEMORY_COPY,
                // Branches: a forward branch may bypass a downstream redef
                // of old_reg and reach a use that still expects the
                // producer's value. Without dominator info we treat ANY
                // branch as bypassing. RETURN/RETURN_VOID don't bypass —
                // they terminate, and any rd source they read is caught
                // by opUsesRdAsSource. BLOCK_END is a target marker
                // already handled by the branch_targets[k] check above.
                OP_BR, OP_BR_IF, OP_BR_IF_NOT,
                => {
                    still_used = true;
                    break;
                },
                else => {},
            }
            if ((opUsesRs1AsSource(later.op) and later.rs1 == old_reg) or
                (opUsesRs2AsSource(later.op) and later.rs2() == old_reg) or
                (opUsesRdAsSource(later.op) and later.rd == old_reg))
            {
                still_used = true;
                break;
            }
            // A redefinition ends the old value's lifetime; everything
            // beyond reads the NEW old_reg, not the producer's value.
            if (opWritesRd(later.op) and later.rd == old_reg) break;
        }
        if (still_used) continue;

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
    for (code, 0..) |*instr, idx| {
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
            OP_BR_TABLE => {
                // Adjust operands of the following count+1 NOP entries (br_table jump targets)
                const count = instr.operand;
                var k: usize = 1;
                while (k <= count + 1 and idx + k < len) : (k += 1) {
                    const entry = &code[idx + k];
                    if (entry.op != OP_NOP) break;
                    const old_target = entry.operand;
                    var deleted_before: u32 = 0;
                    const limit = @min(old_target, @as(u32, @intCast(len)));
                    for (0..limit) |j| {
                        if (code[j].op == OP_DELETED) deleted_before += 1;
                    }
                    entry.operand = old_target - deleted_before;
                }
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

// ---- Tests ----

const testing = std.testing;

test "RegInstr size is 8 bytes" {
    try testing.expectEqual(12, @sizeOf(RegInstr));
}

test "convert — simple i32.add(local.get 0, local.get 1)" {
    // Wasm: local.get 0, local.get 1, i32.add, end
    const ir = [_]PreInstr{
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0
        .{ .opcode = 0x20, .extra = 0, .operand = 1 }, // local.get 1
        .{ .opcode = 0x6A, .extra = 0, .operand = 0 }, // i32.add
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &.{}, 2, 0, 1, null);
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

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, 1, null);
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

    const result = try convert(testing.allocator, &ir, &.{}, 0, 1, 1, null);
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

    const result = try convert(testing.allocator, &ir, &.{}, 2, 0, 1, null);
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
    const result = try convert(testing.allocator, &ir, &.{}, 200, 100, 1, null);
    try testing.expect(result == null);
}

test "convert — large register count succeeds with u16 regs" {
    // 250 params + 7 i32.const temps → reg 256, now fits u16
    var ir: [8]PreInstr = undefined;
    for (0..7) |i| {
        ir[i] = .{ .opcode = 0x41, .extra = 0, .operand = @intCast(i) }; // i32.const
    }
    ir[7] = .{ .opcode = 0x0B, .extra = 0, .operand = 0 }; // end
    const result = try convert(testing.allocator, &ir, &.{}, 250, 0, 1, null);
    try testing.expect(result != null);
    if (result) |r| {
        var rf = r;
        rf.deinit();
        testing.allocator.destroy(r);
    }
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

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, 1, null);
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

    const result = try convert(testing.allocator, &ir, &.{}, 3, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    try testing.expect(code.len >= 2); // MEMORY_FILL + RETURN
    try testing.expectEqual(OP_MEMORY_FILL, code[0].op);
    try testing.expectEqual(@as(u16, 0), code[0].rd); // dst = r0
    try testing.expectEqual(@as(u16, 1), code[0].rs1); // val = r1
    try testing.expectEqual(@as(u16, 2), code[0].rs2()); // n = r2
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

    const result = try convert(testing.allocator, &ir, &.{}, 0, 1, 1, null);
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

    const result = try convert(testing.allocator, &ir, &.{}, 2, 0, 1, null);
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

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, 1, null);
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

test "copy propagation — does not fold when temp used by block-end MOV" {
    // Pattern: block i32, call void, call void, i32.const 11, local.get 0, br_if 0, end, end
    // The const+MOV pair (for br_if taken path) should NOT be folded because
    // the same temp register is also referenced by the block-end MOV.
    const ir = [_]PreInstr{
        .{ .opcode = 0x02, .extra = 1, .operand = 0 }, // block i32 (arity=1)
        .{ .opcode = 0x41, .extra = 0, .operand = 11 }, // i32.const 11
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0
        .{ .opcode = 0x0D, .extra = 0, .operand = 0 }, // br_if 0
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end (block)
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end (func)
    };

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    // Verify the const writes to the temp register (r2), NOT to the result register (r1).
    // The block-end MOV must copy r2→r1, and both MOVs must reference valid r2.
    const code = result.?.code;
    var found_const = false;
    var const_rd: u16 = 0;
    for (code) |instr| {
        if (instr.op == OP_CONST32 and instr.operand == 11) {
            found_const = true;
            const_rd = instr.rd;
        }
    }
    try testing.expect(found_const);
    // The const must write to r2 (temp), not r1 (result_reg).
    // If copy propagation incorrectly folded, const_rd would be 1.
    try testing.expectEqual(@as(u8, 2), const_rd);
}

test "convert — temp register reuse reduces reg_count" {
    // 0 params, 0 locals → total_locals = 0, temps start at r0.
    // Pattern: (i32.const 1) (i32.const 2) i32.add (i32.const 3) (i32.const 4) i32.add i32.add
    // Without reuse: 7 temp regs (r0..r6).
    // With reuse: max 3 temp regs (r0, r1, r2 recycled).
    const ir = [_]PreInstr{
        .{ .opcode = 0x41, .extra = 0, .operand = 1 }, // i32.const 1
        .{ .opcode = 0x41, .extra = 0, .operand = 2 }, // i32.const 2
        .{ .opcode = 0x6A, .extra = 0, .operand = 0 }, // i32.add
        .{ .opcode = 0x41, .extra = 0, .operand = 3 }, // i32.const 3
        .{ .opcode = 0x41, .extra = 0, .operand = 4 }, // i32.const 4
        .{ .opcode = 0x6A, .extra = 0, .operand = 0 }, // i32.add
        .{ .opcode = 0x6A, .extra = 0, .operand = 0 }, // i32.add
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &.{}, 0, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    // With register reuse, should need at most 3 temp registers (not 7)
    try testing.expect(result.?.reg_count <= 3);
}

test "convert — temp reuse rescues >255 reg bailout" {
    // 250 params + 7 i32.const, each immediately consumed by drop.
    // Without reuse: 257 regs → bail (null).
    // With reuse: temps recycled, max stays well under 256 → succeeds.
    var ir: [15]PreInstr = undefined;
    for (0..7) |i| {
        ir[i * 2] = .{ .opcode = 0x41, .extra = 0, .operand = @intCast(i) }; // i32.const
        ir[i * 2 + 1] = .{ .opcode = 0x1A, .extra = 0, .operand = 0 }; // drop
    }
    ir[14] = .{ .opcode = 0x0B, .extra = 0, .operand = 0 }; // end
    const result = try convert(testing.allocator, &ir, &.{}, 250, 0, 1, null);
    // With reuse, drop frees the temp immediately → only 1 temp needed, max = 251
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }
    try testing.expect(result.?.reg_count <= 252); // 250 locals + small number of temps
}

test "compactCode — br_table NOP targets adjusted on DELETED removal" {
    // Regression: copy propagation creates DELETED instructions, but compactCode
    // didn't adjust br_table NOP entry operands (target PCs), causing jumps to
    // wrong addresses.
    //
    // Pattern: i32.const 42, local.set 0, block $a, block $b, local.get 0,
    //          br_table 0 1, end $b, end $a, end
    // Copy propagation folds const+MOV into CONST32 r0 + DELETED.
    // The br_table NOP entries must have their target PCs adjusted.
    const ir = [_]PreInstr{
        .{ .opcode = 0x41, .extra = 0, .operand = 42 }, // i32.const 42
        .{ .opcode = 0x21, .extra = 0, .operand = 0 }, // local.set 0
        .{ .opcode = 0x02, .extra = 0, .operand = 0 }, // block $a (arity 0)
        .{ .opcode = 0x02, .extra = 0, .operand = 0 }, // block $b (arity 0)
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0
        .{ .opcode = 0x0E, .extra = 0, .operand = 1 }, // br_table count=1
        .{ .opcode = 0x00, .extra = 0, .operand = 0 }, // entry 0: depth 0 ($b)
        .{ .opcode = 0x00, .extra = 0, .operand = 1 }, // default:  depth 1 ($a)
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end $b
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end $a
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end func
    };

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    // Find the BR_TABLE instruction
    var br_table_idx: ?usize = null;
    for (code, 0..) |instr, i| {
        if (instr.op == OP_BR_TABLE) {
            br_table_idx = i;
            break;
        }
    }
    try testing.expect(br_table_idx != null);
    const bt = br_table_idx.?;

    // Both NOP entry targets must point within the code bounds
    const entry0 = code[bt + 1]; // entry 0: depth 0 ($b)
    const entry1 = code[bt + 2]; // default: depth 1 ($a)
    try testing.expectEqual(OP_NOP, entry0.op);
    try testing.expectEqual(OP_NOP, entry1.op);
    try testing.expect(entry0.operand < code.len); // target must be in bounds
    try testing.expect(entry1.operand < code.len); // target must be in bounds
    // The two targets should be different (entry 0→$b end, default→$a end)
    // $a's end is >= $b's end since $a contains $b
    try testing.expect(entry1.operand >= entry0.operand);
}

test "convert — GC struct.new uses call-like arg packing" {
    // struct.new type_idx=0 (2 fields): pop 2 values, push 1 ref
    // Pattern: i32.const 10, i32.const 20, struct.new 0, return
    const ir = [_]PreInstr{
        .{ .opcode = 0x41, .extra = 0, .operand = 10 }, // i32.const 10
        .{ .opcode = 0x41, .extra = 0, .operand = 20 }, // i32.const 20
        .{ .opcode = predecode.GC_BASE | 0x00, .extra = 0, .operand = 0 }, // struct.new type_idx=0
        .{ .opcode = 0x0F, .extra = 0, .operand = 0 }, // return
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    // Mock resolver: type_idx 0 → 2 fields
    const MockCtx = struct {
        fn resolveGcFieldCount(_: *anyopaque, type_idx: u32) ?u16 {
            return if (type_idx == 0) 2 else null;
        }
        fn resolveFn(_: *anyopaque, _: u32) ?FuncTypeInfo {
            return null;
        }
    };
    var dummy: u8 = 0;
    const resolver = ParamResolver{
        .ctx = @ptrCast(&dummy),
        .resolve_fn = MockCtx.resolveFn,
        .resolve_gc_field_count_fn = MockCtx.resolveGcFieldCount,
    };

    const result = try convert(testing.allocator, &ir, &.{}, 0, 0, 1, resolver);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }
    const code = result.?.code;

    // Find struct.new instruction
    var found = false;
    for (code, 0..) |c, i| {
        if (c.op == predecode.GC_BASE | 0x00) {
            try testing.expectEqual(@as(u16, 2), c.rs1); // n_fields = 2
            try testing.expectEqual(@as(u32, 0), c.operand); // type_idx = 0
            // Next instruction should be NOP with packed arg regs
            try testing.expectEqual(OP_NOP, code[i + 1].op);
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "convert — GC struct.get produces unary register op" {
    // struct.get type_idx=0 field_idx=1: pop 1 ref, push 1 value
    // Pattern: local.get 0, struct.get 0/1, return
    const ir = [_]PreInstr{
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0
        .{ .opcode = predecode.GC_BASE | 0x02, .extra = 1, .operand = 0 }, // struct.get type=0 field=1
        .{ .opcode = 0x0F, .extra = 0, .operand = 0 }, // return
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &.{}, 1, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }
    const code = result.?.code;

    // Find struct.get instruction
    var found = false;
    for (code) |c| {
        if (c.op == predecode.GC_BASE | 0x02) {
            try testing.expectEqual(@as(u16, 0), c.rs1); // ref from r0 (local.get 0)
            try testing.expectEqual(@as(u16, 1), c.rs2_field); // field_idx = 1
            try testing.expectEqual(@as(u32, 0), c.operand); // type_idx = 0
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "simdStackEffect — correct stack effects for key opcodes" {
    // v128.load: pop 1 addr, push 1 v128
    try testing.expectEqual(@as(u8, 1), simdStackEffect(0x00).?.pop);
    try testing.expectEqual(@as(u8, 1), simdStackEffect(0x00).?.push);
    // v128.store: pop 2, push 0
    try testing.expectEqual(@as(u8, 2), simdStackEffect(0x0B).?.pop);
    try testing.expectEqual(@as(u8, 0), simdStackEffect(0x0B).?.push);
    // v128.const: pop 0, push 1
    try testing.expectEqual(@as(u8, 0), simdStackEffect(0x0C).?.pop);
    try testing.expectEqual(@as(u8, 1), simdStackEffect(0x0C).?.push);
    // shuffle: pop 2, push 1
    try testing.expectEqual(@as(u8, 2), simdStackEffect(0x0D).?.pop);
    // splat: pop 1, push 1
    try testing.expectEqual(@as(u8, 1), simdStackEffect(0x0F).?.pop);
    // extract_lane: pop 1, push 1
    try testing.expectEqual(@as(u8, 1), simdStackEffect(0x15).?.pop);
    // replace_lane (i32x4_replace_lane = 0x1C): pop 2, push 1
    try testing.expectEqual(@as(u8, 2), simdStackEffect(0x1C).?.pop);
    // i64x2_extract_lane (0x1D): pop 1, push 1
    try testing.expectEqual(@as(u8, 1), simdStackEffect(0x1D).?.pop);
    // bitselect: pop 3, push 1
    try testing.expectEqual(@as(u8, 3), simdStackEffect(0x52).?.pop);
    try testing.expectEqual(@as(u8, 1), simdStackEffect(0x52).?.push);
    // lane store: pop 2, push 0
    try testing.expectEqual(@as(u8, 2), simdStackEffect(0x58).?.pop);
    try testing.expectEqual(@as(u8, 0), simdStackEffect(0x58).?.push);
    // i32x4.add (0x6E in binary range): default binary — pop 2, push 1
    try testing.expectEqual(@as(u8, 2), simdStackEffect(0x6E).?.pop);
    try testing.expectEqual(@as(u8, 1), simdStackEffect(0x6E).?.push);
    // Out of range: null
    try testing.expect(simdStackEffect(0x114) == null);
}

test "convert — v128.const + v128.store passes through regalloc" {
    const SIMD_BASE = predecode.SIMD_BASE;
    const pool = [_]u64{ 0x0102030405060708, 0x090A0B0C0D0E0F10 };
    const ir = [_]PreInstr{
        .{ .opcode = SIMD_BASE + 0x0C, .extra = 0, .operand = 0 }, // v128.const pool_idx=0
        .{ .opcode = 0x20, .extra = 0, .operand = 0 }, // local.get 0 (i32 addr)
        .{ .opcode = SIMD_BASE + 0x0B, .extra = 0, .operand = 0 }, // v128.store offset=0
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &pool, 1, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    const code = result.?.code;
    var found_const = false;
    var found_store = false;
    for (code) |instr| {
        if (instr.op == SIMD_BASE + 0x0C) found_const = true;
        if (instr.op == SIMD_BASE + 0x0B) found_store = true;
    }
    try testing.expect(found_const);
    try testing.expect(found_store);
}

test "convert — f32x4.add binary passes through regalloc" {
    const SIMD_BASE = predecode.SIMD_BASE;
    const pool = [_]u64{ 0, 0, 0, 0 }; // 2x v128.const
    const ir = [_]PreInstr{
        .{ .opcode = SIMD_BASE + 0x0C, .extra = 0, .operand = 0 }, // v128.const a
        .{ .opcode = SIMD_BASE + 0x0C, .extra = 0, .operand = 2 }, // v128.const b
        .{ .opcode = SIMD_BASE + 0xE4, .extra = 0, .operand = 0 }, // f32x4.add
        .{ .opcode = 0x1A, .extra = 0, .operand = 0 }, // drop
        .{ .opcode = 0x0B, .extra = 0, .operand = 0 }, // end
    };

    const result = try convert(testing.allocator, &ir, &pool, 0, 0, 1, null);
    try testing.expect(result != null);
    defer {
        var r = result.?;
        r.deinit();
        testing.allocator.destroy(r);
    }

    var found_add = false;
    for (result.?.code) |instr| {
        if (instr.op == SIMD_BASE + 0xE4) {
            found_add = true;
        }
    }
    try testing.expect(found_add);
}
