//! JIT module linker (sub-7.4b).
//!
//! Composes per-function `EmitOutput`s into a single contiguous
//! `JitBlock`, then patches every `BL` placeholder via the
//! `call_fixups` list using each callee's now-known body offset.
//!
//! The linker takes immutable per-function bytes (the emit pass's
//! product) + their call_fixup tables and produces a runnable
//! `JitModule`. Memory layout: function bodies are concatenated
//! at 4-byte boundaries (their natural ARM64 instruction
//! alignment) starting at the JitBlock origin; offsets recorded
//! per-function in `func_offsets`.
//!
//! Zone 2 (`src/engine/codegen/shared/`) — shared across per-arch backends because
//! the BL displacement encoding (imm26 word offset) is uniform on
//! ARM64 and the linker is arch-neutral except for the
//! placeholder-patching step (which currently assumes ARM64 BL;
//! Phase 8 / x86_64 emit will introduce arch dispatch).

const std = @import("std");
const Allocator = std.mem.Allocator;

const jit_mem = @import("../../../platform/jit_mem.zig");
const emit = @import("../arm64/emit.zig");
const inst = @import("../arm64/inst.zig");

pub const Error = error{
    /// A call_fixup names a target_func_idx outside `func_bodies`.
    UnknownCallTarget,
    /// BL displacement out of imm26 range (±128 MiB). Trips when
    /// the linked module is enormous; not expected in any
    /// realistic Wasm corpus.
    DisplacementOverflow,
} || jit_mem.Error || Allocator.Error;

/// Per-function input to the linker. `bytes` and `call_fixups`
/// come straight out of `emit.compile`; the linker takes
/// references (does not own).
pub const FuncBody = struct {
    bytes: []const u8,
    call_fixups: []const emit.CallFixup,
};

pub const JitModule = struct {
    block: jit_mem.JitBlock,
    /// `func_offsets[i]` = byte offset of function `i`'s entry
    /// within `block.bytes`. Allocator-owned.
    func_offsets: []const u32,

    pub fn deinit(self: *JitModule, allocator: Allocator) void {
        allocator.free(self.func_offsets);
        jit_mem.free(self.block);
    }

    /// Cast function `idx`'s entry to a function pointer of the
    /// given signature. Caller is responsible for matching the
    /// emitted body's signature.
    pub fn entry(self: JitModule, idx: u32, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.block.bytes.ptr + self.func_offsets[idx]));
    }
};

/// Lay out and link `func_bodies` into a freshly-allocated
/// `JitBlock`. The block returns in the executable state (caller
/// can immediately invoke entry pointers).
pub fn link(allocator: Allocator, func_bodies: []const FuncBody) Error!JitModule {
    var total_size: usize = 0;
    var offsets = try allocator.alloc(u32, func_bodies.len);
    errdefer allocator.free(offsets);
    for (func_bodies, 0..) |body, i| {
        offsets[i] = @intCast(total_size);
        total_size += body.bytes.len;
        // Bodies emit only word-aligned content; no padding needed.
    }
    if (total_size == 0) return Error.AllocationFailed;

    var block = try jit_mem.alloc(total_size);
    errdefer jit_mem.free(block);

    try jit_mem.setWritable(block);
    for (func_bodies, 0..) |body, i| {
        const off = offsets[i];
        @memcpy(block.bytes[off..][0..body.bytes.len], body.bytes);
    }

    // Patch every BL placeholder. Each fixup's byte_offset is
    // function-local; add the function's own base offset to get
    // its absolute byte position.
    for (func_bodies, 0..) |body, i| {
        const base = offsets[i];
        for (body.call_fixups) |fx| {
            if (fx.target_func_idx >= func_bodies.len) return Error.UnknownCallTarget;
            const fixup_abs: i64 = @as(i64, base) + @as(i64, fx.byte_offset);
            const target_abs: i64 = offsets[fx.target_func_idx];
            const disp_bytes = target_abs - fixup_abs;
            if (@rem(disp_bytes, 4) != 0) return Error.DisplacementOverflow;
            const disp_words = @divExact(disp_bytes, 4);
            // imm26 signed range: ±2^25 words = ±128 MiB.
            if (disp_words < -(1 << 25) or disp_words >= (1 << 25)) {
                return Error.DisplacementOverflow;
            }
            const new_word = inst.encBL(@intCast(disp_words));
            std.mem.writeInt(u32, block.bytes[@intCast(fixup_abs)..][0..4], new_word, .little);
        }
    }

    try jit_mem.setExecutable(block);
    return .{ .block = block, .func_offsets = offsets };
}

// ============================================================
// Tests
// ============================================================

const builtin = @import("builtin");
const testing = std.testing;
const zir = @import("../../../ir/zir.zig");
const ZirFunc = zir.ZirFunc;
const regalloc = @import("regalloc.zig");

test "link: 2-function module — fn0 calls fn1, returns 7" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    const sigs = [_]zir.FuncType{
        .{ .params = &.{}, .results = &.{ .i32 } }, // fn0
        .{ .params = &.{}, .results = &.{ .i32 } }, // fn1
    };

    // fn0: () → i32  { call 1 ; end }
    var fn0 = ZirFunc.init(0, sigs[0], &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 1 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const fn0_slots = [_]u8{0};
    const fn0_alloc: regalloc.Allocation = .{ .slots = &fn0_slots, .n_slots = 1 };

    // fn1: () → i32  { i32.const 7 ; end }
    var fn1 = ZirFunc.init(1, sigs[1], &.{});
    defer fn1.deinit(testing.allocator);
    try fn1.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn1.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn1.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const fn1_slots = [_]u8{0};
    const fn1_alloc: regalloc.Allocation = .{ .slots = &fn1_slots, .n_slots = 1 };

    const out0 = try emit.compile(testing.allocator, &fn0, fn0_alloc, &sigs, &.{});
    defer emit.deinit(testing.allocator, out0);
    const out1 = try emit.compile(testing.allocator, &fn1, fn1_alloc, &sigs, &.{});
    defer emit.deinit(testing.allocator, out1);

    const bodies = [_]FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
        .{ .bytes = out1.bytes, .call_fixups = out1.call_fixups },
    };
    var module = try link(testing.allocator, &bodies);
    defer module.deinit(testing.allocator);

    const Fn = *const fn () callconv(.c) u32;
    const f = module.entry(0, Fn);
    try testing.expectEqual(@as(u32, 7), f());
}
