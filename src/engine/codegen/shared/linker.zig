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

/// ADR-0106 cycle 3e Phase 2'g — per-function buffer-write
/// wrapper thunk specification. Lists which `func_idx` in
/// `func_bodies` needs a wrapper emitted alongside its body.
/// The wrapper's Zig-side signature is `fn(rt, results, args)
/// callconv(.c) ErrCode` per `entry_buffer_write.BufferWriteFn`.
pub const WrapperSpec = struct {
    /// Function index in the wasm-space (= same indexing as
    /// `func_bodies`, offset by `num_imports`).
    func_idx: u32,
    /// Function signature; used by `wrapper_thunk.emit` to pick
    /// the per-shape wrapper byte sequence.
    sig: @import("../../../ir/zir.zig").FuncType,
};

pub const JitModule = struct {
    block: jit_mem.JitBlock,
    /// `func_offsets[i]` = byte offset of function `i`'s entry
    /// within `block.bytes`. Allocator-owned.
    func_offsets: []const u32,
    /// ADR-0106 cycle 3e Phase 2'f — per-function wrapper thunk
    /// offset. `thunk_offsets[i]` = byte offset of function `i`'s
    /// **buffer-write wrapper thunk** entry within `block.bytes`,
    /// or `NO_THUNK` (= sentinel `0xFFFFFFFF`) when no thunk was
    /// emitted (e.g. function has no multi-result signature, or
    /// arch / shape isn't supported yet).
    ///
    /// Set to an allocator-owned `[]const u32` only when at least
    /// one function in the module has a wrapper thunk. Otherwise
    /// `null` — `entry_buf` panics in that case. The dual storage
    /// (body_offset + thunk_offset) lets the entry helper
    /// (`callI32i32i32NoArgs` etc.) read the thunk address while
    /// intra-module Wasm `call` dispatch still routes to the body
    /// address via `func_offsets[i]` per ADR-0017 / ADR-0066.
    thunk_offsets: ?[]const u32 = null,

    /// Sentinel for `thunk_offsets[i]` when function `i` has no
    /// emitted wrapper thunk (single-result, unsupported shape, or
    /// non-target arch).
    pub const NO_THUNK: u32 = 0xFFFFFFFF;

    pub fn deinit(self: *JitModule, allocator: Allocator) void {
        allocator.free(self.func_offsets);
        if (self.thunk_offsets) |to| allocator.free(to);
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

    /// Return the raw byte address of function `idx`'s entry —
    /// equivalent to `@intFromPtr(entry(idx, fn() callconv(.c) void))`
    /// but without forcing a concrete signature. Used by ADR-0066
    /// cross-module bridge thunks: the thunk's literal pool
    /// embeds the callee's entry address verbatim, and the per-
    /// import slot in `host_dispatch_base` then points at the
    /// thunk (which tail-jumps to this address).
    ///
    /// Same `IMPORT_SENTINEL_OFFSET` guard as `entry` — calling
    /// `entryAddr` for an unresolved import slot is a structural
    /// bug; the resolver must populate `host_dispatch_base[i]`
    /// without ever reaching for the importer's own JIT module's
    /// entry().
    /// ADR-0106 cycle 3e Phase 2'f — fetch the buffer-write wrapper
    /// thunk for function `idx` as a typed function pointer. The
    /// thunk's Zig-side signature is `fn(rt, results, args)
    /// callconv(.c) ErrCode` per `entry_buffer_write.BufferWriteFn`.
    ///
    /// Panics when:
    /// - The module has no `thunk_offsets` array (no wrapper thunks
    ///   were emitted; caller should use `entry()` instead).
    /// - `idx` is out of range.
    /// - `thunk_offsets[idx] == NO_THUNK` (function `idx` has no
    ///   wrapper — sig is single-result OR unsupported shape).
    pub fn entry_buf(self: JitModule, idx: u32, comptime Fn: type) Fn {
        const offsets = self.thunk_offsets orelse std.debug.panic(
            "JitModule.entry_buf: idx {d} — module has no thunk_offsets",
            .{idx},
        );
        if (idx >= offsets.len) {
            std.debug.panic(
                "JitModule.entry_buf: idx {d} >= thunk_offsets.len {d}",
                .{ idx, offsets.len },
            );
        }
        const off = offsets[idx];
        if (off == NO_THUNK) {
            std.debug.panic(
                "JitModule.entry_buf: idx {d} has no wrapper thunk (NO_THUNK sentinel)",
                .{idx},
            );
        }
        return @ptrCast(@alignCast(self.block.bytes.ptr + off));
    }

    pub fn entryAddr(self: JitModule, idx: u32) usize {
        if (idx >= self.func_offsets.len) {
            std.debug.panic(
                "JitModule.entryAddr: idx {d} >= func_offsets.len {d}",
                .{ idx, self.func_offsets.len },
            );
        }
        const off = self.func_offsets[idx];
        if (off == IMPORT_SENTINEL_OFFSET) {
            std.debug.panic(
                "JitModule.entryAddr: idx {d} resolves to IMPORT_SENTINEL_OFFSET — caller asked for an unresolved import's entry address",
                .{idx},
            );
        }
        return @intFromPtr(self.block.bytes.ptr) + off;
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

/// ADR-0106 cycle 3e Phase 2'g — link + emit per-function
/// wrapper thunks alongside the bodies.
///
/// Composes existing `link()` with a Phase 2'-style wrapper
/// emit pass: bodies first (at offset 0..body_size), wrappers
/// appended after (at offset body_size..total_size).
/// `thunk_offsets[func_idx]` records the wrapper's offset, or
/// `NO_THUNK` (0xFFFFFFFF) when no wrapper was emitted.
///
/// When `wrapper_specs.len == 0`, behaves identically to
/// `link()` and returns `thunk_offsets = null`.
/// When ALL specs return `UnsupportedOp` from `wrapper_thunk.
/// emit` (e.g. arch not implemented, shape unsupported), also
/// returns `thunk_offsets = null` — the body link still
/// succeeds.
///
/// Implementation: two-pass. Pass 1 calls `link()` to compute
/// body offsets + a body-only JitBlock. Pass 2 computes
/// wrapper bytes via `wrapper_thunk.emit`, allocates a NEW
/// JitBlock of total size, copies bodies + wrappers,
/// populates `thunk_offsets`. The pass-1 block is freed.
pub fn linkWithThunks(
    allocator: Allocator,
    func_bodies: []const FuncBody,
    num_imports: u32,
    wrapper_specs: []const WrapperSpec,
) Error!JitModule {
    if (wrapper_specs.len == 0) {
        return link(allocator, func_bodies, num_imports);
    }

    var body_module = try link(allocator, func_bodies, num_imports);
    errdefer body_module.deinit(allocator);

    const total_funcs = body_module.func_offsets.len;
    const body_size = body_module.block.bytes.len;

    var wrapper_bytes_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (wrapper_bytes_list.items) |b| allocator.free(b);
        wrapper_bytes_list.deinit(allocator);
    }

    var thunk_offsets = try allocator.alloc(u32, total_funcs);
    errdefer allocator.free(thunk_offsets);
    @memset(thunk_offsets, JitModule.NO_THUNK);

    const wrapper_thunk = @import("wrapper_thunk.zig");
    var wrapper_total: usize = 0;
    for (wrapper_specs) |spec| {
        if (spec.func_idx >= total_funcs) return Error.UnknownCallTarget;
        const body_offset = body_module.func_offsets[spec.func_idx];
        if (body_offset == IMPORT_SENTINEL_OFFSET) return Error.UnknownCallTarget;
        const thunk_offset_usize = body_size + wrapper_total;
        const wrapper_out = wrapper_thunk.emit(allocator, .{
            .sig = spec.sig,
            .body_offset = body_offset,
            .thunk_offset = @intCast(thunk_offset_usize),
        }) catch |err| switch (err) {
            error.UnsupportedOp => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        try wrapper_bytes_list.append(allocator, wrapper_out.bytes);
        thunk_offsets[spec.func_idx] = @intCast(thunk_offset_usize);
        wrapper_total += wrapper_out.bytes.len;
    }

    if (wrapper_total == 0) {
        allocator.free(thunk_offsets);
        return body_module;
    }

    const total_size = body_size + wrapper_total;
    var block = try jit_mem.alloc(total_size);
    errdefer jit_mem.free(block);
    try jit_mem.setWritable(block);
    @memcpy(block.bytes[0..body_size], body_module.block.bytes);
    var off: usize = body_size;
    for (wrapper_bytes_list.items) |w| {
        @memcpy(block.bytes[off..][0..w.len], w);
        off += w.len;
    }
    try jit_mem.setExecutable(block);

    const offsets_copy = try allocator.dupe(u32, body_module.func_offsets);
    errdefer allocator.free(offsets_copy);
    body_module.deinit(allocator);

    return .{
        .block = block,
        .func_offsets = offsets_copy,
        .thunk_offsets = thunk_offsets,
    };
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
        .{ .params = &.{}, .results = &.{.i32} }, // fn0
        .{ .params = &.{}, .results = &.{.i32} }, // fn1
    };

    // fn0: () → i32  { call 1 ; end }
    var fn0 = ZirFunc.init(0, sigs[0], &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .call, .payload = 1 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const fn0_slots = [_]u16{0};
    const fn0_alloc: regalloc.Allocation = .{ .slots = &fn0_slots, .n_slots = 1 };

    // fn1: () → i32  { i32.const 7 ; end }
    var fn1 = ZirFunc.init(1, sigs[1], &.{});
    defer fn1.deinit(testing.allocator);
    try fn1.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn1.instrs.append(testing.allocator, .{ .op = .end });
    fn1.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const fn1_slots = [_]u16{0};
    const fn1_alloc: regalloc.Allocation = .{ .slots = &fn1_slots, .n_slots = 1 };

    const out0 = try emit.compile(testing.allocator, &fn0, fn0_alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32);
    defer emit.deinit(testing.allocator, out0);
    const out1 = try emit.compile(testing.allocator, &fn1, fn1_alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32);
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

    // ADR-0066 (c)-2.3 enabling: `entryAddr` returns the raw byte
    // address of function `idx`'s entry. Cross-module bridge thunks
    // embed this verbatim in their literal pool (the thunk's
    // tail-jump target). Verify parity with `entry()` cast to
    // `usize`: both must point at the same first instruction.
    try testing.expectEqual(@intFromPtr(f), module.entryAddr(0));
    const f1 = module.entry(1, Fn);
    try testing.expectEqual(@intFromPtr(f1), module.entryAddr(1));
    // Distinct functions live at distinct offsets.
    try testing.expect(module.entryAddr(0) != module.entryAddr(1));
}

test "linkWithThunks: single multi-result function — wrapper invocation writes results buffer" {
    if (!(builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos) and
        !(builtin.cpu.arch == .x86_64 and builtin.os.tag != .windows))
    {
        return error.SkipZigTest;
    }
    const entry_buf = @import("entry_buffer_write.zig");

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i32, .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 100 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 200 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 300 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 3 },
        .{ .def_pc = 1, .last_use_pc = 3 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 3,
        .result_abi = .register_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{}, .i32);
    defer emit.deinit(testing.allocator, out);

    const bodies = [_]FuncBody{.{ .bytes = out.bytes, .call_fixups = out.call_fixups }};
    const specs = [_]WrapperSpec{.{ .func_idx = 0, .sig = sig }};

    var module = try linkWithThunks(testing.allocator, &bodies, 0, &specs);
    defer module.deinit(testing.allocator);

    try testing.expect(module.thunk_offsets != null);
    try testing.expect(module.thunk_offsets.?[0] != JitModule.NO_THUNK);

    const fn_ptr = module.entry_buf(0, entry_buf.BufferWriteFn);
    var rt: entry_buf.JitRuntime = .{
        .vm_base = undefined,
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
    var args_buf: [1]u64 = .{0};
    var results_buf: [3]u64 = .{ 0, 0, 0 };
    try entry_buf.invokeBufferWrite(&rt, fn_ptr, &args_buf, &results_buf);
    try testing.expectEqual(@as(u32, 100), @as(u32, @intCast(results_buf[0] & 0xFFFFFFFF)));
    try testing.expectEqual(@as(u32, 200), @as(u32, @intCast(results_buf[1] & 0xFFFFFFFF)));
    try testing.expectEqual(@as(u32, 300), @as(u32, @intCast(results_buf[2] & 0xFFFFFFFF)));
}
