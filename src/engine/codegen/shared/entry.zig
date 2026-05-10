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
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");
const builtin = @import("builtin");

const linker = @import("linker.zig");
const jit_abi = @import("jit_abi.zig");

pub const JitRuntime = jit_abi.JitRuntime;

pub const Error = error{
    /// The JIT body trapped — its trap stub stored 1 to
    /// `runtime.trap_flag` before unwinding. Sub-7.5b-ii
    /// detection is single-bit; Diagnostic M3 (D-022) widens
    /// this to per-trap-kind reasons.
    Trap,
};

/// Call a no-argument JIT function returning i32.
///
/// Per ADR-0017, X0 carries the runtime pointer; the body's
/// prologue does `LDR X28, [X0, #0]` etc. to materialise the
/// invariants. The native function-pointer call lowers to
/// `mov x0, <rt>; blr fn` automatically.
///
/// Sub-7.5b-ii: takes `*JitRuntime` (mutable) so the trap stub
/// can write `rt.trap_flag = 1` on trap. This fn zeroes
/// `trap_flag` before each call and returns `Error.Trap` if it
/// was set after the call.
pub fn callI32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a single-i32-argument JIT function returning i32.
/// Per AAPCS64 / SysV the ABI puts `rt` in X0 / RDI and `a0` in
/// X1 / RSI; the JIT body's prologue snapshots X1 (W1) into the
/// param-0 local slot. Used by §9.7 / 7.5 spec-assertion-driver
/// to invoke `assert_return` actions whose action.args is one i32.
pub fn callI32_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u32) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a two-i32-argument JIT function returning i32. ABI puts
/// `rt`, `a0`, `a1` in X0, X1, X2 (AAPCS64) / RDI, RSI, RDX (SysV);
/// the prologue stores W1 → [SP, #0] and W2 → [SP, #8].
pub fn callI32_i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u32, a1: u32) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a no-argument void-returning JIT function (results.len == 0).
/// The JIT body's function-level `end` handler skips result
/// marshalling when `func.sig.results.len == 0`; the epilogue
/// runs as POP RBP / RET (x86_64) or LDP / RET (ARM64). Used by
/// §9.7 / 7.5-close-c1 spec_assert dispatch for `local.set` /
/// `global.set` / store-style assertions whose `(invoke ...)`
/// has empty `expected`. Trap detection mirrors `callI32NoArgs`.
pub fn callVoidNoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!void {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt);
    if (rt.trap_flag != 0) return Error.Trap;
}

/// Call a single-i32-argument void-returning JIT function.
pub fn callVoid_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!void {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u32) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
}

/// Call a two-i32-argument void-returning JIT function.
pub fn callVoid_i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: u32,
) Error!void {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u32, a1: u32) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, a0, a1);
    if (rt.trap_flag != 0) return Error.Trap;
}

/// Call a single-i64-argument void-returning JIT function.
pub fn callVoid_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!void {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
}

/// Call a single-f32-argument void-returning JIT function.
/// Used by spec_assert local_set fixtures whose param is f32.
pub fn callVoid_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!void {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
}

/// 5-arg helpers for the `(i64 f32 f64 i32 i32)` family that
/// covers the upstream `local_get`/`local_set` mixed-type
/// fixtures (`type-mixed`, `read`, `write`). Per AAPCS64 / SysV
/// the FP args go in V0/V1 (S0/D1) and the int args go in
/// X0..X4 / RDI..R8 in declaration order; the `callconv(.c)`
/// function pointer matches that ABI by construction.
pub fn callVoid_i64f32f64i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: f32,
    a2: f64,
    a3: u32,
    a4: u32,
) Error!void {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64, a1: f32, a2: f64, a3: u32, a4: u32) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, a0, a1, a2, a3, a4);
    if (rt.trap_flag != 0) return Error.Trap;
}

pub fn callI64_i64f32f64i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: f32,
    a2: f64,
    a3: u32,
    a4: u32,
) Error!u64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64, a1: f32, a2: f64, a3: u32, a4: u32) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1, a2, a3, a4);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

pub fn callF64_i64f32f64i32i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: f32,
    a2: f64,
    a3: u32,
    a4: u32,
) Error!f64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64, a1: f32, a2: f64, a3: u32, a4: u32) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1, a2, a3, a4);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a single-f64-argument void-returning JIT function.
pub fn callVoid_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!void {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f64) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
}

/// Call a no-argument JIT function returning i64. ARM64 epilogue
/// MOV X0, X<vreg> (64-bit form) for results[0] == .i64 — landed
/// under §9.7 / 7.7-fp-end-fix.
pub fn callI64NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!u64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a single-i32-argument JIT function returning i64.
pub fn callI64_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!u64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u32) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a single-i64-argument JIT function returning i64.
pub fn callI64_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!u64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a no-argument JIT function returning f32.
pub fn callF32NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!f32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime) callconv(.c) f32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a single-f32-argument JIT function returning f32.
pub fn callF32_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!f32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32) callconv(.c) f32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a no-argument JIT function returning f64.
pub fn callF64NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error!f64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Call a single-f64-argument JIT function returning f64.
pub fn callF64_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!f64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f64) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 (function invocation, v128 result) — call a no-
/// argument JIT function returning v128. Per ADR-0046, both backends
/// emit the v128 result through the SIMD return register (ARM64 V0,
/// x86_64 XMM0). `@Vector(16, u8)` lowers to that register on both
/// AAPCS64 and SysV; we then bit-cast to a flat byte array so callers
/// (notably `simd_assert_runner`) can compare against manifest hex
/// tokens directly.
///
/// Used by §9.9 / 9.9-c spec-assertion-driver to invoke `()→v128`
/// fixtures (simd_address / simd_align / simd_const). v128 PARAM
/// marshal is a separate follow-up (§9.9-e).
pub fn callV128NoArgs(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i32) → v128` invocation. The i32 arg follows
/// the established W1 / ESI ABI (per `callI32_i32`); the v128 result
/// uses the SIMD return register (per `callV128NoArgs`).
pub fn callV128_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: u32) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128) → v128` invocation. §9.9 / 9.9-f-4
/// scope expansion: enables FP / int unop fixtures
/// (simd_f32x4_arith neg / sqrt, simd_i32x4_arith neg / abs,
/// etc.). a0 lowers to V0/XMM0; result also V0/XMM0.
pub fn callV128_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0));
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, v128) → v128` invocation. §9.9 / 9.9-f
/// scope expansion: enables FP arith / int arith / bitwise binop
/// fixtures (simd_bitwise, simd_f32x4_arith, simd_i32x4_arith,
/// etc.). Per ADR-0046 + 9.9-e-1/-2 v128 PARAM marshal: a0 lowers
/// to V0/XMM0, a1 to V1/XMM1; result is V0/XMM0.
pub fn callV128_v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: Vec) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), @bitCast(a1));
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const zir = @import("../../../ir/zir.zig");
const ZirFunc = zir.ZirFunc;
const regalloc = @import("regalloc.zig");
const emit = @import("../arm64/emit.zig");

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
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    // Stage 16 bytes; the Wasm body reads memory[0..4] little-endian.
    var memory: [16]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = memory.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const result = try callI32NoArgs(module, 0, &rt);
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
    const slots = [_]u16{10};
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .max_reg_slots_gpr = 10,
    };
    const sigs = [_]zir.FuncType{sig};
    const out = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out.bytes, .call_fixups = out.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
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
    const result = try callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 42), result);
}

test "entry: ADR-0027 — global.set 0 then global.get 0 (i32) round-trips through JitRuntime.globals_base" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }

    const Value = @import("../../../runtime/value.zig").Value;
    // (i32.const 7) (global.set 0) (global.get 0) end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"global.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 }, // const → set
        .{ .def_pc = 2, .last_use_pc = 3 }, // get → end
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};
    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out0);
    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    // Pre-populate globals[0] with a sentinel so we can prove the
    // global.set actually overwrites it (rather than the function
    // happening to return the initial value).
    var globals = [_]Value{ Value.fromI32(0xDEAD), Value.fromI32(0xBEEF) };
    var rt: JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = &globals,
        .globals_count = globals.len,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    const result = try callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 7), result);
    // global slot 0 was actually overwritten by `global.set 0 (=7)`.
    try testing.expectEqual(@as(i32, 7), globals[0].i32);
    // global slot 1 untouched.
    try testing.expectEqual(@as(i32, 0xBEEF), globals[1].i32);
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
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
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
    const result = try callI32NoArgs(module, 0, &rt);
    try testing.expectEqual(@as(u32, 42), result);
}

test "entry: callI32_i32i32 — 2 i32 params summed via i32.add" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // (param i32 i32) (result i32) — body: local.get 0; local.get 1; i32.add; end
    const sig: zir.FuncType = .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 1 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
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
    try testing.expectEqual(@as(u32, 7), try callI32_i32i32(module, 0, &rt, 3, 4));
    try testing.expectEqual(@as(u32, 0), try callI32_i32i32(module, 0, &rt, 0, 0));
}

test "entry: callI32_i32 — 1 i32 param echoed through W1 → SP slot 0 → result" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    const sig: zir.FuncType = .{ .params = &.{.i32}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
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
    try testing.expectEqual(@as(u32, 0xCAFEBABE), try callI32_i32(module, 0, &rt, 0xCAFEBABE));
    try testing.expectEqual(@as(u32, 42), try callI32_i32(module, 0, &rt, 42));
}

test "entry: f32 local round-trip — local.get 0 of f32 param via V0" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // (param f32) (result f32) — body: local.get 0; end
    // The prologue STR S0, [SP, #0] (multi-arg-entry FP path);
    // local.get 0 must LDR S<vd>, [SP, #0] (D-NNN FP-local fix);
    // end MOVs into V0 / S0 for return.
    const sig: zir.FuncType = .{ .params = &.{.f32}, .results = &.{.f32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
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
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32) callconv(.c) f32;
    const f = module.entry(0, Fn);
    try testing.expectEqual(@as(f32, 3.5), f(&rt, 3.5));
    try testing.expectEqual(@as(f32, -1.25), f(&rt, -1.25));
}

test "entry: callI64NoArgs — i64.const 0xDEADBEEFCAFE returns full 64-bit" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // (result i64) — body: i64.const 0xDEADBEEFCAFE; end
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    // i64.const 0xDEADBEEFCAFE → low32 = 0xBEEFCAFE, high32 = 0xDEAD.
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xBEEFCAFE, .extra = 0xDEAD });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"end" });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0);
    defer emit.deinit(testing.allocator, out0);

    const bodies = [_]linker.FuncBody{
        .{ .bytes = out0.bytes, .call_fixups = out0.call_fixups },
    };
    var module = try linker.link(testing.allocator, &bodies, 0);
    defer module.deinit(testing.allocator);

    var memory: [0]u8 = .{};
    var rt: JitRuntime = .{
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
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFE), try callI64NoArgs(module, 0, &rt));
}
