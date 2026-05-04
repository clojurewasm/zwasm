//! JIT entry frame (sub-7.4c).
//!
//! Bridge from a Zig caller into a JIT-emitted Wasm function.
//! Materialises the caller-supplied invariants (X24..X28 per
//! `jit_arm64/abi.zig`) from a `RuntimeInvariants` struct, then
//! `BLR`s the JIT entry pointer.
//!
//! Implementation: a single inline-asm block on Mac aarch64.
//! The clobber list names every caller-saved GPR + V register
//! the JIT body may touch, plus the callee-saved X24..X28 that
//! THIS shim writes (so Zig doesn't assume they're preserved).
//!
//! Argument marshalling for entry signatures with non-trivial
//! parameters (`callI32_i32i32`, etc.) lands in follow-up sub-
//! rows; this sub-7.4c starts with the no-arg + i32-result
//! shape, sufficient to exercise X28 / X27 (linear-memory
//! invariants) end-to-end.
//!
//! Zone 2 (`src/jit/`).

const std = @import("std");
const builtin = @import("builtin");

const linker = @import("linker.zig");

pub const RuntimeInvariants = struct {
    /// X28 — linear-memory base pointer.
    vm_base: [*]u8,
    /// X27 — linear-memory size in bytes (W27 used for the bounds
    /// check; full X27 sufficient since W-write semantics ignore
    /// upper 32).
    mem_limit: usize,
    /// X26 — table-0 funcptr array base (each entry u64).
    funcptr_base: [*]const u64,
    /// X25 — table-0 size (W25 used by call_indirect bounds check).
    table_size: u32,
    /// X24 — table-0 typeidx array base (each entry u32; same
    /// indexing as funcptr_base).
    typeidx_base: [*]const u32,
};

/// Call a no-argument JIT function returning i32.
pub fn callI32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: RuntimeInvariants,
) u32 {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        @panic("JIT entry-frame currently Mac aarch64 only (Phase 8 / x86_64 emit follow-up)");
    }
    const fn_ptr = module.entry(func_idx, *const fn () callconv(.c) u32);

    return asm volatile (
        \\mov x28, %[vm_base]
        \\mov x27, %[mem_limit]
        \\mov x26, %[fp_base]
        \\mov x25, %[t_size]
        \\mov x24, %[ti_base]
        \\blr %[fn_p]
        : [_] "={w0}" (-> u32),
        : [vm_base] "r" (rt.vm_base),
          [mem_limit] "r" (rt.mem_limit),
          [fp_base] "r" (rt.funcptr_base),
          [t_size] "r" (rt.table_size),
          [ti_base] "r" (rt.typeidx_base),
          [fn_p] "r" (fn_ptr),
        : .{
            // Caller-saved GPRs the JIT body may freely clobber.
            .x0 = true, .x1 = true, .x2 = true, .x3 = true,
            .x4 = true, .x5 = true, .x6 = true, .x7 = true,
            .x8 = true, .x9 = true, .x10 = true, .x11 = true,
            .x12 = true, .x13 = true, .x14 = true, .x15 = true,
            .x16 = true, .x17 = true,
            // Callee-saved that this shim itself writes.
            .x24 = true, .x25 = true, .x26 = true, .x27 = true, .x28 = true,
            // Link register set by BLR.
            .lr = true,
            // V registers the JIT body may touch.
            .v0 = true, .v1 = true, .v2 = true, .v3 = true,
            .v4 = true, .v5 = true, .v6 = true, .v7 = true,
            .v16 = true, .v17 = true, .v18 = true, .v19 = true,
            .v20 = true, .v21 = true, .v22 = true, .v23 = true,
            .v24 = true, .v25 = true, .v26 = true, .v27 = true,
            .v28 = true, .v29 = true, .v30 = true, .v31 = true,
            .nzcv = true,
            .memory = true,
        });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const zir = @import("../ir/zir.zig");
const ZirFunc = zir.ZirFunc;
const regalloc = @import("regalloc.zig");
const emit = @import("../jit_arm64/emit.zig");

test "entry: i32.load offset=0 reads memory[0..4] through X28 vm_base" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    // (i32.const 0) (i32.load offset=0) end
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{});
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies);
    defer module.deinit(testing.allocator);

    // Stage 16 bytes; the Wasm body reads memory[0..4] little-endian.
    var memory: [16]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const result = callI32NoArgs(module, 0, .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
    });
    try testing.expectEqual(@as(u32, 0xEFBEADDE), result);
}

test "entry: ADR-0018 sub-1c — spilled i32.const returns 42 via STR/LDR round-trip" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // Force vreg 0 into spill territory (slot 10). The JIT body's
    // prologue extends frame by 8 + 16-align = 16 bytes; i32.const
    // emits MOVZ X14,#42 + STR X14,[SP]; end emits LDR X14,[SP] +
    // MOV X0,X14. Calling via the entry-frame returns 42.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{10};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .max_reg_slots = 10,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{});
    defer emit.deinit(testing.allocator, out);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    const result = callI32NoArgs(module, 0, .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
    });
    try testing.expectEqual(@as(u32, 42), result);
}

test "entry: pure constant function returns 42 (sanity — no memory access)" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{});
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    const result = callI32NoArgs(module, 0, .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
    });
    try testing.expectEqual(@as(u32, 42), result);
}
