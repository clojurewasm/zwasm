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
const builtin_arch = @import("builtin");
const Allocator = std.mem.Allocator;

const jit_mem = @import("../../../platform/jit_mem.zig");
/// 7.5-close-d042 / §9.7 / 7.8 prep: comptime arch dispatch
/// matching `compile.zig` (commit `0925134`). Both backends
/// expose `CallFixup` with the same
/// `{byte_offset: u32, target_func_idx: u32}` shape.
const emit = switch (builtin_arch.target.cpu.arch) {
    .aarch64 => @import("../arm64/emit.zig"),
    .x86_64 => @import("../x86_64/emit.zig"),
    else => @compileError("unsupported host arch for linker"),
};
const inst = switch (builtin_arch.target.cpu.arch) {
    .aarch64 => @import("../arm64/inst.zig"),
    .x86_64 => @import("../x86_64/inst.zig"),
    else => @compileError("unsupported host arch for linker"),
};

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
    ///
    /// §9.7 / 7.10-l defensive guard: the realworld_run_jit run-
    /// stage SEGV investigation surfaced this site as a possible
    /// out-of-bounds read path (idx ≥ func_offsets.len would walk
    /// into garbage and produce a wildly invalid function pointer,
    /// then the JIT prologue's first LDR would deref NULL and
    /// trigger a recursive panic in the unwinder). Surface the
    /// out-of-range case explicitly via @panic so future SEGVs
    /// land with a useful message instead of silent NULL deref.
    /// Also reject the IMPORT_SENTINEL_OFFSET path — the run-stage
    /// caller MUST resolve imports through the host_dispatch_base
    /// table, never through entry().
    pub fn entry(self: JitModule, idx: u32, comptime Fn: type) Fn {
        if (idx >= self.func_offsets.len) {
            std.debug.panic(
                "JitModule.entry: idx {d} >= func_offsets.len {d}",
                .{ idx, self.func_offsets.len },
            );
        }
        const off = self.func_offsets[idx];
        if (off == IMPORT_SENTINEL_OFFSET) {
            std.debug.panic(
                "JitModule.entry: idx {d} resolves to IMPORT_SENTINEL_OFFSET — caller routed an import through entry() instead of host_dispatch_base",
                .{idx},
            );
        }
        return @ptrCast(@alignCast(self.block.bytes.ptr + off));
    }
};

/// Sentinel value stored in `func_offsets` for import slots. The
/// JIT-emit pass routes import calls to the function-local trap
/// stub directly (not through the linker's call_fixups), so this
/// value is never read by any executable path. A reader that
/// observes it (e.g. external tooling that unpacks JitModule)
/// should treat it as "no body — call would trap".
pub const IMPORT_SENTINEL_OFFSET: u32 = 0xFFFF_FFFF;

/// Lay out and link `func_bodies` into a freshly-allocated
/// `JitBlock`. The block returns in the executable state (caller
/// can immediately invoke entry pointers).
///
/// `num_imports` shifts the wasm-space function-index origin:
/// `func_offsets` is sized `num_imports + func_bodies.len` and
/// the first `num_imports` entries hold `IMPORT_SENTINEL_OFFSET`.
/// Defined-function K is laid out at byte offset
/// `func_offsets[num_imports + K]`. CallFixup `target_func_idx`
/// values are wasm-space indices; the linker patches them by
/// looking up `func_offsets[target_func_idx]` (which must NOT be
/// the sentinel — emit-pass invariant: import calls never produce
/// a CallFixup; import-as-trap branches go through the per-
/// function bounds_fixups / unreach_fixups list).
pub fn link(allocator: Allocator, func_bodies: []const FuncBody, num_imports: u32) Error!JitModule {
    const total_funcs: usize = @as(usize, num_imports) + func_bodies.len;
    // Empty module (Wasm spec allows zero defined functions):
    // skip the jit_mem allocation entirely — there is no
    // executable code to publish. Caller still receives a
    // structurally valid JitModule whose bytes slice is empty
    // and whose entry() must not be invoked. Import-only modules
    // (defined_count == 0, num_imports > 0) hit the same path:
    // every wasm-idx-based entry() lookup hits a sentinel.
    if (func_bodies.len == 0) {
        const offsets = try allocator.alloc(u32, total_funcs);
        @memset(offsets, IMPORT_SENTINEL_OFFSET);
        return .{
            .block = .{ .bytes = &[_:0]u8{} },
            .func_offsets = offsets,
        };
    }

    var total_size: usize = 0;
    var offsets = try allocator.alloc(u32, total_funcs);
    errdefer allocator.free(offsets);
    // Imports occupy slots [0..num_imports); fill with sentinel.
    @memset(offsets[0..num_imports], IMPORT_SENTINEL_OFFSET);
    for (func_bodies, 0..) |body, i| {
        offsets[num_imports + i] = @intCast(total_size);
        total_size += body.bytes.len;
        // Bodies emit only word-aligned content; no padding needed.
    }
    if (total_size == 0) return Error.AllocationFailed;

    var block = try jit_mem.alloc(total_size);
    errdefer jit_mem.free(block);

    try jit_mem.setWritable(block);
    for (func_bodies, 0..) |body, i| {
        const off = offsets[num_imports + i];
        @memcpy(block.bytes[off..][0..body.bytes.len], body.bytes);
    }

    // Patch every CALL/BL placeholder. Each fixup's byte_offset
    // is function-local; add the function's own base offset to
    // get its absolute byte position. The encoding differs per
    // arch (BL imm26 on ARM64; CALL rel32 on x86_64) — comptime
    // switch picks the right path with no runtime cost.
    for (func_bodies, 0..) |body, i| {
        const base = offsets[num_imports + i];
        for (body.call_fixups) |fx| {
            // CallFixups carry wasm-space indices. Imports are
            // routed via the trap stub by the emit pass — they
            // must never appear here. A sentinel target is a
            // structural emit-pass bug (post-chunk-b invariant).
            if (fx.target_func_idx >= total_funcs) return Error.UnknownCallTarget;
            if (fx.target_func_idx < num_imports) return Error.UnknownCallTarget;
            const fixup_abs: i64 = @as(i64, base) + @as(i64, fx.byte_offset);
            const target_abs: i64 = offsets[fx.target_func_idx];
            switch (builtin_arch.target.cpu.arch) {
                .aarch64 => {
                    const disp_bytes = target_abs - fixup_abs;
                    if (@rem(disp_bytes, 4) != 0) return Error.DisplacementOverflow;
                    const disp_words = @divExact(disp_bytes, 4);
                    // imm26 signed range: ±2^25 words = ±128 MiB.
                    if (disp_words < -(1 << 25) or disp_words >= (1 << 25)) {
                        return Error.DisplacementOverflow;
                    }
                    const new_word = inst.encBL(@intCast(disp_words));
                    std.mem.writeInt(u32, block.bytes[@intCast(fixup_abs)..][0..4], new_word, .little);
                },
                .x86_64 => {
                    // CALL rel32: 5-byte instruction (0xE8 +
                    // disp32). disp = target - (at + 5). i32
                    // signed range = ±2 GiB; flag overflow.
                    const disp_bytes = target_abs - fixup_abs - 5;
                    if (disp_bytes < std.math.minInt(i32) or disp_bytes > std.math.maxInt(i32)) {
                        return Error.DisplacementOverflow;
                    }
                    inst.patchRel32(block.bytes, @intCast(fixup_abs), 5, @intCast(disp_bytes));
                },
                else => @compileError("unsupported host arch for linker patch loop"),
            }
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
const jit_abi = @import("jit_abi.zig");
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
    const fn0_slots = [_]u16{0};
    const fn0_alloc: regalloc.Allocation = .{ .slots = &fn0_slots, .n_slots = 1 };

    // fn1: () → i32  { i32.const 7 ; end }
    var fn1 = ZirFunc.init(1, sigs[1], &.{});
    defer fn1.deinit(testing.allocator);
    try fn1.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn1.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn1.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const fn1_slots = [_]u16{0};
    const fn1_alloc: regalloc.Allocation = .{ .slots = &fn1_slots, .n_slots = 1 };

    const out0 = try emit.compile(testing.allocator, &fn0, fn0_alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out0);
    const out1 = try emit.compile(testing.allocator, &fn1, fn1_alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out1);

    const bodies = [_]FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
        .{ .bytes = out1.bytes, .call_fixups = out1.call_fixups },
    };
    var module = try link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    // §9.8a / 8a.2: ADR-0034 sentinel store mandates a valid
    // JitRuntime ptr in X0 (was tolerable garbage pre-sentinel
    // because the existing prologue LDRs read but never wrote
    // through X0; the new STR W17, [X19, #flag_off] requires
    // a real backing store).
    var memory: [0]u8 = .{};
    var rt: jit_abi.JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const Fn = *const fn (rt: *jit_abi.JitRuntime) callconv(.c) u32;
    const f = module.entry(0, Fn);
    try testing.expectEqual(@as(u32, 7), f(&rt));
    try testing.expect(rt.jit_executed_flag != 0);
}
