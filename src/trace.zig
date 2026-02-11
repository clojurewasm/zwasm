// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Debug trace/dump infrastructure for JIT, RegIR, and execution analysis.
//!
//! Zero-cost when disabled: Vm.trace == null means a single null check per call.
//! Usage: `zwasm run --trace=jit,exec --dump-regir=5 --dump-jit=5 module.wasm`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const regalloc_mod = @import("regalloc.zig");
const RegFunc = regalloc_mod.RegFunc;
const RegInstr = regalloc_mod.RegInstr;

/// Trace category bitmask for O(1) enable check.
pub const TraceCategory = enum(u3) {
    jit = 0,
    regir = 1,
    exec = 2,
    mem = 3,
    call = 4,
};

/// Configuration for trace/dump output. Lives on the stack in CLI, Vm holds a pointer.
pub const TraceConfig = struct {
    categories: u8 = 0,
    dump_regir_func: ?u32 = null,
    dump_jit_func: ?u32 = null,

    pub fn isEnabled(self: TraceConfig, cat: TraceCategory) bool {
        return (self.categories & (@as(u8, 1) << @intFromEnum(cat))) != 0;
    }
};

/// Parse comma-separated category names into bitmask.
/// Returns 0 on empty input. Unknown names are ignored.
pub fn parseCategories(input: []const u8) u8 {
    if (input.len == 0) return 0;
    var result: u8 = 0;
    var iter = std.mem.splitScalar(u8, input, ',');
    while (iter.next()) |name| {
        if (std.mem.eql(u8, name, "jit")) {
            result |= 1 << @intFromEnum(TraceCategory.jit);
        } else if (std.mem.eql(u8, name, "regir")) {
            result |= 1 << @intFromEnum(TraceCategory.regir);
        } else if (std.mem.eql(u8, name, "exec")) {
            result |= 1 << @intFromEnum(TraceCategory.exec);
        } else if (std.mem.eql(u8, name, "mem")) {
            result |= 1 << @intFromEnum(TraceCategory.mem);
        } else if (std.mem.eql(u8, name, "call")) {
            result |= 1 << @intFromEnum(TraceCategory.call);
        }
    }
    return result;
}

// ================================================================
// Trace event functions — all write to stderr
// ================================================================

fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

pub fn traceJitCompile(tc: *const TraceConfig, func_idx: u32, ir_count: u32, code_size: u32) void {
    if (!tc.isEnabled(.jit)) return;
    stderrPrint("[trace:jit] func#{d}: compiled {d} IR instrs -> {d} bytes\n", .{ func_idx, ir_count, code_size });
}

pub fn traceJitBail(tc: *const TraceConfig, func_idx: u32, reason: []const u8) void {
    if (!tc.isEnabled(.jit)) return;
    stderrPrint("[trace:jit] func#{d}: bail — {s}\n", .{ func_idx, reason });
}

pub fn traceRegirConvert(tc: *const TraceConfig, func_idx: u32, pre_count: u32, reg_count: u16, n_regs: u16) void {
    if (!tc.isEnabled(.regir)) return;
    stderrPrint("[trace:regir] func#{d}: {d} pre-instrs -> {d} reg-instrs, {d} regs\n", .{ func_idx, pre_count, reg_count, n_regs });
}

pub fn traceRegirBail(tc: *const TraceConfig, func_idx: u32, reason: []const u8) void {
    if (!tc.isEnabled(.regir)) return;
    stderrPrint("[trace:regir] func#{d}: bail — {s}\n", .{ func_idx, reason });
}

pub fn traceExecTier(tc: *const TraceConfig, func_idx: u32, tier: []const u8, call_count: u32) void {
    if (!tc.isEnabled(.exec)) return;
    stderrPrint("[trace:exec] func#{d}: {s} (calls={d})\n", .{ func_idx, tier, call_count });
}

pub fn traceMemGrow(tc: *const TraceConfig, old_pages: u32, delta: u32, result: i32) void {
    if (!tc.isEnabled(.mem)) return;
    stderrPrint("[trace:mem] memory.grow: {d} pages + {d} delta -> result={d}\n", .{ old_pages, delta, result });
}

pub fn traceJitBackEdge(tc: *const TraceConfig, func_idx: u32, ir_count: u32, code_size: u32) void {
    if (!tc.isEnabled(.jit)) return;
    stderrPrint("[trace:jit] func#{d}: back-edge JIT compiled {d} IR instrs -> {d} bytes\n", .{ func_idx, ir_count, code_size });
}

pub fn traceJitRestart(tc: *const TraceConfig, func_idx: u32) void {
    if (!tc.isEnabled(.exec)) return;
    stderrPrint("[trace:exec] func#{d}: jit (back-edge restart)\n", .{func_idx});
}

pub fn traceCall(tc: *const TraceConfig, caller_idx: u32, callee_idx: u32) void {
    if (!tc.isEnabled(.call)) return;
    stderrPrint("[trace:call] func#{d} -> func#{d}\n", .{ caller_idx, callee_idx });
}

// ================================================================
// RegIR opcode name table
// ================================================================

pub fn regirOpName(op: u16) []const u8 {
    // Extended register IR ops
    return switch (op) {
        // Immediate-fused ops (0xD0-0xDF)
        regalloc_mod.OP_ADDI32 => "addi32",
        regalloc_mod.OP_SUBI32 => "subi32",
        regalloc_mod.OP_LE_S_I32 => "le_s_i32",
        regalloc_mod.OP_GE_S_I32 => "ge_s_i32",
        regalloc_mod.OP_LT_S_I32 => "lt_s_i32",
        regalloc_mod.OP_GT_S_I32 => "gt_s_i32",
        regalloc_mod.OP_EQ_I32 => "eq_i32",
        regalloc_mod.OP_NE_I32 => "ne_i32",
        regalloc_mod.OP_MULI32 => "muli32",
        regalloc_mod.OP_ANDI32 => "andi32",
        regalloc_mod.OP_ORI32 => "ori32",
        regalloc_mod.OP_XORI32 => "xori32",
        regalloc_mod.OP_SHLI32 => "shli32",
        regalloc_mod.OP_LT_U_I32 => "lt_u_i32",
        regalloc_mod.OP_GE_U_I32 => "ge_u_i32",
        regalloc_mod.OP_BR_TABLE => "br_table",
        // Extended ops (0xE0-0xE2)
        regalloc_mod.OP_CALL_INDIRECT => "call_indirect",
        regalloc_mod.OP_MEMORY_FILL => "memory.fill",
        regalloc_mod.OP_MEMORY_COPY => "memory.copy",
        // Control flow (0xF0-0xFB)
        regalloc_mod.OP_MOV => "mov",
        regalloc_mod.OP_CONST32 => "const32",
        regalloc_mod.OP_CONST64 => "const64",
        regalloc_mod.OP_BR => "br",
        regalloc_mod.OP_BR_IF => "br_if",
        regalloc_mod.OP_BR_IF_NOT => "br_if_not",
        regalloc_mod.OP_RETURN => "return",
        regalloc_mod.OP_RETURN_VOID => "return_void",
        regalloc_mod.OP_CALL => "call",
        regalloc_mod.OP_NOP => "nop",
        regalloc_mod.OP_BLOCK_END => "block_end",
        regalloc_mod.OP_DELETED => "deleted",
        // Wasm MVP opcodes (used directly in register IR)
        0x00 => "unreachable",
        0x1A => "drop",
        0x1B => "select",
        0x20 => "local.get",
        0x21 => "local.set",
        0x22 => "local.tee",
        0x23 => "global.get",
        0x24 => "global.set",
        0x28 => "i32.load",
        0x29 => "i64.load",
        0x2A => "f32.load",
        0x2B => "f64.load",
        0x2C => "i32.load8_s",
        0x2D => "i32.load8_u",
        0x2E => "i32.load16_s",
        0x2F => "i32.load16_u",
        0x30 => "i64.load8_s",
        0x31 => "i64.load8_u",
        0x32 => "i64.load16_s",
        0x33 => "i64.load16_u",
        0x34 => "i64.load32_s",
        0x35 => "i64.load32_u",
        0x36 => "i32.store",
        0x37 => "i64.store",
        0x38 => "f32.store",
        0x39 => "f64.store",
        0x3A => "i32.store8",
        0x3B => "i32.store16",
        0x3C => "i64.store8",
        0x3D => "i64.store16",
        0x3E => "i64.store32",
        0x3F => "memory.size",
        0x40 => "memory.grow",
        0x41 => "i32.const",
        0x42 => "i64.const",
        0x43 => "f32.const",
        0x44 => "f64.const",
        0x45 => "i32.eqz",
        0x46 => "i32.eq",
        0x47 => "i32.ne",
        0x48 => "i32.lt_s",
        0x49 => "i32.lt_u",
        0x4A => "i32.gt_s",
        0x4B => "i32.gt_u",
        0x4C => "i32.le_s",
        0x4D => "i32.le_u",
        0x4E => "i32.ge_s",
        0x4F => "i32.ge_u",
        0x50 => "i64.eqz",
        0x51 => "i64.eq",
        0x52 => "i64.ne",
        0x53 => "i64.lt_s",
        0x54 => "i64.lt_u",
        0x55 => "i64.gt_s",
        0x56 => "i64.gt_u",
        0x57 => "i64.le_s",
        0x58 => "i64.le_u",
        0x59 => "i64.ge_s",
        0x5A => "i64.ge_u",
        0x5B => "f32.eq",
        0x5C => "f32.ne",
        0x5D => "f32.lt",
        0x5E => "f32.gt",
        0x5F => "f32.le",
        0x60 => "f32.ge",
        0x61 => "f64.eq",
        0x62 => "f64.ne",
        0x63 => "f64.lt",
        0x64 => "f64.gt",
        0x65 => "f64.le",
        0x66 => "f64.ge",
        0x67 => "i32.clz",
        0x68 => "i32.ctz",
        0x69 => "i32.popcnt",
        0x6A => "i32.add",
        0x6B => "i32.sub",
        0x6C => "i32.mul",
        0x6D => "i32.div_s",
        0x6E => "i32.div_u",
        0x6F => "i32.rem_s",
        0x70 => "i32.rem_u",
        0x71 => "i32.and",
        0x72 => "i32.or",
        0x73 => "i32.xor",
        0x74 => "i32.shl",
        0x75 => "i32.shr_s",
        0x76 => "i32.shr_u",
        0x77 => "i32.rotl",
        0x78 => "i32.rotr",
        0x79 => "i64.clz",
        0x7A => "i64.ctz",
        0x7B => "i64.popcnt",
        0x7C => "i64.add",
        0x7D => "i64.sub",
        0x7E => "i64.mul",
        0x7F => "i64.div_s",
        0x80 => "i64.div_u",
        0x81 => "i64.rem_s",
        0x82 => "i64.rem_u",
        0x83 => "i64.and",
        0x84 => "i64.or",
        0x85 => "i64.xor",
        0x86 => "i64.shl",
        0x87 => "i64.shr_s",
        0x88 => "i64.shr_u",
        0x89 => "i64.rotl",
        0x8A => "i64.rotr",
        0x8B => "f32.abs",
        0x8C => "f32.neg",
        0x8D => "f32.ceil",
        0x8E => "f32.floor",
        0x8F => "f32.trunc",
        0x90 => "f32.nearest",
        0x91 => "f32.sqrt",
        0x92 => "f32.add",
        0x93 => "f32.sub",
        0x94 => "f32.mul",
        0x95 => "f32.div",
        0x96 => "f32.min",
        0x97 => "f32.max",
        0x98 => "f32.copysign",
        0x99 => "f64.abs",
        0x9A => "f64.neg",
        0x9B => "f64.ceil",
        0x9C => "f64.floor",
        0x9D => "f64.trunc",
        0x9E => "f64.nearest",
        0x9F => "f64.sqrt",
        0xA0 => "f64.add",
        0xA1 => "f64.sub",
        0xA2 => "f64.mul",
        0xA3 => "f64.div",
        0xA4 => "f64.min",
        0xA5 => "f64.max",
        0xA6 => "f64.copysign",
        0xA7 => "i32.wrap_i64",
        0xA8 => "i32.trunc_f32_s",
        0xA9 => "i32.trunc_f32_u",
        0xAA => "i32.trunc_f64_s",
        0xAB => "i32.trunc_f64_u",
        0xAC => "i64.extend_i32_s",
        0xAD => "i64.extend_i32_u",
        0xAE => "i64.trunc_f32_s",
        0xAF => "i64.trunc_f32_u",
        0xB0 => "i64.trunc_f64_s",
        0xB1 => "i64.trunc_f64_u",
        0xB2 => "f32.convert_i32_s",
        0xB3 => "f32.convert_i32_u",
        0xB4 => "f32.convert_i64_s",
        0xB5 => "f32.convert_i64_u",
        0xB6 => "f32.demote_f64",
        0xB7 => "f64.convert_i32_s",
        0xB8 => "f64.convert_i32_u",
        0xB9 => "f64.convert_i64_s",
        0xBA => "f64.convert_i64_u",
        0xBB => "f64.promote_f32",
        0xBC => "i32.reinterpret_f32",
        0xBD => "i64.reinterpret_f64",
        0xBE => "f32.reinterpret_i32",
        0xBF => "f64.reinterpret_i64",
        0xC0 => "i32.extend8_s",
        0xC1 => "i32.extend16_s",
        0xC2 => "i64.extend8_s",
        0xC3 => "i64.extend16_s",
        0xC4 => "i64.extend32_s",
        else => "unknown",
    };
}

// ================================================================
// RegIR dump
// ================================================================

/// Dump human-readable RegIR for a function to the given writer.
pub fn dumpRegIR(w: *std.Io.Writer, reg_func: *const RegFunc, pool64: []const u64, func_idx: u32) void {
    w.print("\n=== RegIR: func#{d} ({d} regs, {d} locals, {d} instrs) ===\n", .{
        func_idx, reg_func.reg_count, reg_func.local_count, reg_func.code.len,
    }) catch {};

    for (reg_func.code, 0..) |instr, i| {
        const name = regirOpName(instr.op);
        w.print("[{d:0>3}] {s:<16}", .{ i, name }) catch {};

        switch (instr.op) {
            regalloc_mod.OP_CONST32 => {
                w.print("r{d} = {d}", .{ instr.rd, instr.operand }) catch {};
            },
            regalloc_mod.OP_CONST64 => {
                const val: u64 = if (instr.operand < pool64.len) pool64[instr.operand] else 0;
                w.print("r{d} = pool[{d}] (0x{X})", .{ instr.rd, instr.operand, val }) catch {};
            },
            regalloc_mod.OP_MOV => {
                w.print("r{d} = r{d}", .{ instr.rd, instr.rs1 }) catch {};
            },
            regalloc_mod.OP_BR => {
                w.print("-> pc={d}", .{instr.operand}) catch {};
            },
            regalloc_mod.OP_BR_IF, regalloc_mod.OP_BR_IF_NOT => {
                w.print("r{d} -> pc={d}", .{ instr.rd, instr.operand }) catch {};
            },
            regalloc_mod.OP_RETURN => {
                w.print("r{d}", .{instr.rd}) catch {};
            },
            regalloc_mod.OP_RETURN_VOID, regalloc_mod.OP_DELETED => {},
            regalloc_mod.OP_NOP => {
                if (instr.operand != 0) w.print("-> pc={d}", .{instr.operand}) catch {};
            },
            regalloc_mod.OP_CALL => {
                w.print("r{d} = func#{d}(r{d}..)", .{ instr.rd, instr.operand, instr.rs1 }) catch {};
            },
            regalloc_mod.OP_CALL_INDIRECT => {
                w.print("r{d} = table[r{d}] type={d}", .{ instr.rd, instr.rs1, instr.operand }) catch {};
            },
            regalloc_mod.OP_BLOCK_END => {
                w.print("end_pc={d}", .{instr.operand}) catch {};
            },
            regalloc_mod.OP_BR_TABLE => {
                w.print("r{d} count={d}", .{ instr.rd, instr.operand }) catch {};
            },
            regalloc_mod.OP_MEMORY_FILL => {
                w.print("r{d} val=r{d} n=r{d}", .{ instr.rd, instr.rs1, instr.rs2() }) catch {};
            },
            regalloc_mod.OP_MEMORY_COPY => {
                w.print("r{d} src=r{d} n=r{d}", .{ instr.rd, instr.rs1, instr.rs2() }) catch {};
            },
            // Immediate-fused ops
            regalloc_mod.OP_ADDI32, regalloc_mod.OP_SUBI32, regalloc_mod.OP_MULI32,
            regalloc_mod.OP_ANDI32, regalloc_mod.OP_ORI32, regalloc_mod.OP_XORI32,
            regalloc_mod.OP_SHLI32,
            => {
                w.print("r{d} = r{d} op {d}", .{ instr.rd, instr.rs1, instr.operand }) catch {};
            },
            regalloc_mod.OP_LE_S_I32, regalloc_mod.OP_GE_S_I32, regalloc_mod.OP_LT_S_I32,
            regalloc_mod.OP_GT_S_I32, regalloc_mod.OP_EQ_I32, regalloc_mod.OP_NE_I32,
            regalloc_mod.OP_LT_U_I32, regalloc_mod.OP_GE_U_I32,
            => {
                w.print("r{d} = r{d} cmp {d}", .{ instr.rd, instr.rs1, instr.operand }) catch {};
            },
            else => {
                // Standard 2-register ops (binops, unops, loads, stores, etc.)
                if (instr.rd != 0 or instr.rs1 != 0) {
                    w.print("r{d} = r{d}", .{ instr.rd, instr.rs1 }) catch {};
                    if (instr.rs2() != 0 or instr.operand > 255) {
                        w.print(", r{d}", .{instr.rs2()}) catch {};
                    }
                    if (instr.operand > 255) {
                        w.print("  (off={d})", .{instr.operand >> 8}) catch {};
                    }
                }
            },
        }

        w.print("\n", .{}) catch {};
    }
    w.print("=== end RegIR func#{d} ===\n\n", .{func_idx}) catch {};
    w.flush() catch {};
}

// ================================================================
// JIT code dump
// ================================================================

/// Dump JIT-compiled ARM64 code for a function.
/// Writes raw binary to /tmp, attempts llvm-objdump, falls back to hex.
pub fn dumpJitCode(
    alloc: Allocator,
    code_items: []const u32,
    pc_map_items: []const u32,
    func_idx: u32,
) void {
    var buf: [4096]u8 = undefined;
    var ew = std.fs.File.stderr().writer(&buf);
    const w = &ew.interface;

    const code_bytes = code_items.len * 4;
    w.print("\n=== JIT: func#{d} ({d} ARM64 instrs, {d} bytes) ===\n", .{
        func_idx, code_items.len, code_bytes,
    }) catch {};

    // Write raw binary to /tmp
    var path_buf: [64]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&path_buf, "/tmp/zwasm_jit_{d}.bin", .{func_idx}) catch {
        w.print("  (failed to format path)\n", .{}) catch {};
        w.flush() catch {};
        return;
    };

    const file = std.fs.cwd().createFile(bin_path, .{}) catch {
        w.print("  (failed to create {s})\n", .{bin_path}) catch {};
        w.flush() catch {};
        return;
    };
    file.writeAll(std.mem.sliceAsBytes(code_items)) catch {
        file.close();
        w.print("  (failed to write {s})\n", .{bin_path}) catch {};
        w.flush() catch {};
        return;
    };
    file.close();

    w.print("  raw binary: {s}\n", .{bin_path}) catch {};

    // Try llvm-objdump, then objdump
    const tried = tryObjdump(alloc, bin_path, w);
    if (!tried) {
        // Fallback: hex dump
        w.print("  (objdump not available — hex dump)\n", .{}) catch {};
        const max_show = @min(code_items.len, 32);
        for (code_items[0..max_show], 0..) |word, i| {
            w.print("  {X:0>4}: {X:0>8}\n", .{ i * 4, word }) catch {};
        }
        if (code_items.len > max_show) {
            w.print("  ... ({d} more instructions)\n", .{code_items.len - max_show}) catch {};
        }
    }

    // Print pc_map
    w.print("\n  pc_map (RegIR PC -> ARM64 offset):\n", .{}) catch {};
    for (pc_map_items, 0..) |arm_idx, pc| {
        // Only print entries where something maps
        if (pc > 0 and arm_idx == pc_map_items[pc - 1]) continue;
        w.print("    pc={d} -> 0x{X}\n", .{ pc, @as(usize, arm_idx) * 4 }) catch {};
    }

    w.print("=== end JIT func#{d} ===\n\n", .{func_idx}) catch {};
    w.flush() catch {};
}

fn tryObjdump(alloc: Allocator, bin_path: []const u8, w: *std.Io.Writer) bool {
    _ = alloc;
    // Try llvm-objdump first, then objdump
    const tool_configs = [_]struct { name: []const u8, args: []const []const u8 }{
        .{ .name = "llvm-objdump", .args = &.{ "llvm-objdump", "-d", "--triple=aarch64", "-b", "binary", "-m", "aarch64", bin_path } },
        .{ .name = "objdump", .args = &.{ "objdump", "-d", "-b", "binary", "-m", "aarch64", bin_path } },
    };

    for (tool_configs) |tool| {
        var child = std.process.Child.init(tool.args, std.heap.page_allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch continue;

        // Read stdout in chunks
        var out_buf: [32768]u8 = undefined;
        var read_buf: [4096]u8 = undefined;
        var child_reader = child.stdout.?.reader(&read_buf);
        const reader = &child_reader.interface;
        var total: usize = 0;
        while (total < out_buf.len) {
            const chunk = reader.readSliceShort(out_buf[total..]) catch break;
            if (chunk == 0) break;
            total += chunk;
        }
        _ = child.wait() catch continue;

        if (total > 0) {
            w.print("  disassembly ({s}):\n", .{tool.name}) catch {};
            w.print("{s}", .{out_buf[0..total]}) catch {};
            return true;
        }
    }
    return false;
}

// ================================================================
// Tests
// ================================================================

const testing = std.testing;

test "parseCategories: single category" {
    try testing.expectEqual(@as(u8, 1), parseCategories("jit"));
    try testing.expectEqual(@as(u8, 2), parseCategories("regir"));
    try testing.expectEqual(@as(u8, 4), parseCategories("exec"));
    try testing.expectEqual(@as(u8, 8), parseCategories("mem"));
    try testing.expectEqual(@as(u8, 16), parseCategories("call"));
}

test "parseCategories: multiple categories" {
    const mask = parseCategories("jit,exec,call");
    try testing.expect(mask & 1 != 0); // jit
    try testing.expect(mask & 4 != 0); // exec
    try testing.expect(mask & 16 != 0); // call
    try testing.expect(mask & 2 == 0); // regir off
    try testing.expect(mask & 8 == 0); // mem off
}

test "parseCategories: empty and unknown" {
    try testing.expectEqual(@as(u8, 0), parseCategories(""));
    try testing.expectEqual(@as(u8, 0), parseCategories("bogus"));
    try testing.expectEqual(@as(u8, 1), parseCategories("jit,bogus"));
}

test "TraceConfig.isEnabled" {
    const tc = TraceConfig{ .categories = parseCategories("jit,exec") };
    try testing.expect(tc.isEnabled(.jit));
    try testing.expect(tc.isEnabled(.exec));
    try testing.expect(!tc.isEnabled(.regir));
    try testing.expect(!tc.isEnabled(.mem));
    try testing.expect(!tc.isEnabled(.call));
}

test "regirOpName: known ops" {
    try testing.expectEqualStrings("mov", regirOpName(regalloc_mod.OP_MOV));
    try testing.expectEqualStrings("const32", regirOpName(regalloc_mod.OP_CONST32));
    try testing.expectEqualStrings("call", regirOpName(regalloc_mod.OP_CALL));
    try testing.expectEqualStrings("call_indirect", regirOpName(regalloc_mod.OP_CALL_INDIRECT));
    try testing.expectEqualStrings("addi32", regirOpName(regalloc_mod.OP_ADDI32));
    try testing.expectEqualStrings("br_table", regirOpName(regalloc_mod.OP_BR_TABLE));
    try testing.expectEqualStrings("memory.fill", regirOpName(regalloc_mod.OP_MEMORY_FILL));
    try testing.expectEqualStrings("memory.copy", regirOpName(regalloc_mod.OP_MEMORY_COPY));
}

test "regirOpName: wasm ops" {
    try testing.expectEqualStrings("i32.add", regirOpName(0x6A));
    try testing.expectEqualStrings("i64.mul", regirOpName(0x7E));
    try testing.expectEqualStrings("f64.add", regirOpName(0xA0));
    try testing.expectEqualStrings("i32.load", regirOpName(0x28));
    try testing.expectEqualStrings("i32.store", regirOpName(0x36));
}

test "regirOpName: unknown" {
    try testing.expectEqualStrings("unknown", regirOpName(0xFF));
}

test "dumpRegIR: basic output" {
    // Build a small RegFunc
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 2, .rs1 = 0, .operand = 42 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = testing.allocator,
    };

    // Write to stderr (verifies no crash, output format tested manually)
    var err_buf: [4096]u8 = undefined;
    var ew = std.fs.File.stderr().writer(&err_buf);
    dumpRegIR(&ew.interface, &reg_func, &.{}, 5);
}
