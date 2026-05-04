//! JIT entry frame (ADR-0017).
//!
//! Bridge from a Zig caller into a JIT-emitted Wasm function.
//! Per ADR-0017, the JIT body's prologue loads X28..X24 from
//! `*X0 = *const JitRuntime`, so the entry frame collapses to
//! a standard AAPCS64 / System V function-pointer call passing
//! `&runtime` as the first argument. No inline asm; no clobber
//! list; same source compiles for both backends (Phase 7.6+).
//!
//! Argument marshalling for entry signatures with non-trivial
//! parameters (`callI32_i32i32`, etc.) lands in follow-up sub-
//! rows; this entry path covers the no-arg + i32-result shape.
//!
//! Zone 2 (`src/jit/`).

const std = @import("std");
const builtin = @import("builtin");

const linker = @import("linker.zig");
const jit_abi = @import("../runtime/jit_abi.zig");

pub const JitRuntime = jit_abi.JitRuntime;

/// Call a no-argument JIT function returning i32.
///
/// Per ADR-0017, X0 carries the runtime pointer; the body's
/// prologue does `LDR X28, [X0, #0]` etc. to materialise the
/// invariants. The native function-pointer call lowers to
/// `mov x0, <rt>; blr fn` automatically.
pub fn callI32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *const JitRuntime,
) u32 {
    const Fn = *const fn (rt: *const JitRuntime) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    return f(rt);
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
    const rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
    };
    const result = callI32NoArgs(module, 0, &rt);
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
    const rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
    };
    const result = callI32NoArgs(module, 0, &rt);
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
    const rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
    };
    const result = callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 42), result);
}
