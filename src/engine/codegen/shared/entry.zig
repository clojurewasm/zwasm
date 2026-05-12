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
pub const SegmentSlice = jit_abi.SegmentSlice;
pub const TableSlice = jit_abi.TableSlice;
pub const table_no_max: u32 = jit_abi.table_no_max;
pub const ElemSlice = jit_abi.ElemSlice;

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

// §9.9 / 9.9-l-1b-widen — cross-type scalar entry helpers
// covering `conversions.wast` shapes (trunc / trunc_sat for FP→int,
// convert for int→FP, promote / demote / reinterpret across FP
// widths). One entry pattern per (arg, result) pair so the FFI
// signature `*const fn (...) callconv(.c) <ret>` matches the JIT
// body's calling convention regardless of FP-vs-GPR ABI lane
// assignment.

/// Wasm spec §4.4.1 (i32.trunc_f32_s / _u, i32.trunc_sat_f32_s / _u,
/// i32.reinterpret_f32) — (f32) → i32 entry. Result type is u32
/// because the runner compares bit patterns and Wasm i32 is
/// representation-uninterpreted.
pub fn callI32_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (i32.trunc_f64_s / _u, i32.trunc_sat_f64_s / _u)
/// — (f64) → i32 entry.
pub fn callI32_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f64) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (i64.trunc_f32_s / _u, i64.trunc_sat_f32_s / _u)
/// — (f32) → i64 entry.
pub fn callI64_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!u64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (i32.wrap_i64) — (i64) → i32 entry. The
/// 32-bit wrap is performed inside the JIT body (`AND eax, eax`
/// / equivalent); this entry just adapts the calling convention.
pub fn callI32_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (i64.trunc_f64_s / _u, i64.trunc_sat_f64_s / _u,
/// i64.reinterpret_f64) — (f64) → i64 entry.
pub fn callI64_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!u64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f64) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f32.convert_i32_s / _u, f32.reinterpret_i32)
/// — (i32) → f32 entry.
pub fn callF32_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!f32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u32) callconv(.c) f32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f32.convert_i64_s / _u) — (i64) → f32 entry.
pub fn callF32_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!f32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64) callconv(.c) f32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f64.convert_i32_s / _u) — (i32) → f64 entry.
pub fn callF64_i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
) Error!f64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u32) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f64.convert_i64_s / _u, f64.reinterpret_i64)
/// — (i64) → f64 entry.
pub fn callF64_i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
) Error!f64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f32.demote_f64) — (f64) → f32 entry.
pub fn callF32_f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
) Error!f32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f64) callconv(.c) f32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f64.promote_f32) — (f32) → f64 entry.
pub fn callF64_f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
) Error!f64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

// §9.9 / 9.9-l-1b-binop — 2-arg scalar entry helpers covering the
// i64 / f32 / f64 binop + cmp families exercised by `i64.wast`,
// `f32.wast`, `f64.wast`, `f32_cmp.wast`, `f64_cmp.wast`. Each
// follows the same single-helper template as the 1-arg variants.

/// Wasm spec §4.4.1 (i64.add / sub / mul / and / or / xor /
/// div_s / div_u / rem_s / rem_u / shl / shr_s / shr_u / rotl /
/// rotr) — (i64, i64) → i64 entry.
pub fn callI64_i64i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: u64,
) Error!u64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64, a1: u64) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (i64.eq / ne / lt_s / lt_u / gt_s / gt_u /
/// le_s / le_u / ge_s / ge_u) — (i64, i64) → i32 entry.
pub fn callI32_i64i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u64,
    a1: u64,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: u64, a1: u64) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f32.add / sub / mul / div / min / max /
/// copysign) — (f32, f32) → f32 entry.
pub fn callF32_f32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f32,
) Error!f32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32, a1: f32) callconv(.c) f32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f32.eq / ne / lt / gt / le / ge) —
/// (f32, f32) → i32 entry (FP comparison → i32 boolean).
pub fn callI32_f32f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f32,
    a1: f32,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f32, a1: f32) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f64.add / sub / mul / div / min / max /
/// copysign) — (f64, f64) → f64 entry.
pub fn callF64_f64f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
) Error!f64 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f64, a1: f64) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4.1 (f64.eq / ne / lt / gt / le / ge) —
/// (f64, f64) → i32 entry (FP comparison → i32 boolean).
pub fn callI32_f64f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: f64,
    a1: f64,
) Error!u32 {
    rt.trap_flag = 0;
    const Fn = *const fn (rt: *const JitRuntime, a0: f64, a1: f64) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, a0, a1);
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

/// Wasm spec §4.4 — `(v128) → ()` invocation. §9.9 / 9.9-h-3
/// (D-079 (i) discharge): enables single-v128-param setter
/// fixtures (simd_const `as-global.set_value_$g0` etc.). a0
/// lowers to V0/XMM0; no result. Per ADR-0046's PARAM marshal
/// shape, identical to `callV128_v128` minus the return.
pub fn callVoid_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!void {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, @bitCast(a0));
    if (rt.trap_flag != 0) return Error.Trap;
}

/// Wasm spec §4.4 — `(v128, v128) → ()` invocation. §9.9 / 9.9-h-3
/// (D-079 (i) discharge): two-v128-param setter fixtures
/// (simd_const `as-global.set_value_$g1_$g2` etc.).
pub fn callVoid_v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
) Error!void {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: Vec) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, @bitCast(a0), @bitCast(a1));
    if (rt.trap_flag != 0) return Error.Trap;
}

/// Wasm spec §4.4 — `(v128, v128, v128, v128) → ()` invocation.
/// §9.9 / 9.9-h-3 (D-079 (i) discharge): four-v128-param setter
/// fixtures (simd_const `as-global.set_value_$g0_$g1_$g2_$g3`).
/// Per AAPCS64 / SysV ABI: a0..a3 lower to V0..V3 (ARM64) /
/// XMM0..XMM3 (x86_64); RDI/X0 stays the runtime ptr.
pub fn callVoid_v128v128v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: [16]u8,
    a3: [16]u8,
) Error!void {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: Vec, a2: Vec, a3: Vec) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, @bitCast(a0), @bitCast(a1), @bitCast(a2), @bitCast(a3));
    if (rt.trap_flag != 0) return Error.Trap;
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

/// Wasm spec §4.4 — `(v128, v128, v128) → v128` invocation.
/// §9.9 / 9.9-h-14 (D-070 unblock): enables bitselect / select
/// corpus assertions that take 3 v128 inputs and produce a v128
/// result. a0 → V0/XMM0, a1 → V1/XMM1, a2 → V2/XMM2; result is
/// V0/XMM0. AAPCS64 / SysV register pool covers ≤ 8 v128 args
/// (V0..V7 / XMM0..XMM7).
pub fn callV128_v128v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: [16]u8,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: Vec, a2: Vec) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), @bitCast(a1), @bitCast(a2));
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128) → i32` invocation. §9.9 / 9.9-h-26
/// (v128-param-pending discharge): enables i*x*.all_true /
/// any_true / bitmask / i*x*.extract_lane.{s,u} fixtures whose
/// `(args, results)` is `((v128,), (i32,))`. a0 lowers to
/// V0/XMM0; the i32 result returns in W0/EAX per AAPCS64 / SysV.
pub fn callI32_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!u32 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0));
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128) → f32` invocation. §9.9 / 9.9-h-26
/// (v128-param-pending discharge): enables f32x4.extract_lane
/// fixtures whose `(args, results)` is `((v128,), (f32,))`. a0
/// lowers to V0/XMM0; the f32 result returns in S0/XMM0 per
/// AAPCS64 / SysV.
pub fn callF32_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!f32 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec) callconv(.c) f32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0));
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128) → f64` invocation. §9.9 / 9.9-h-26
/// (v128-param-pending discharge): enables f64x2.extract_lane
/// fixtures whose `(args, results)` is `((v128,), (f64,))`. a0
/// lowers to V0/XMM0; the f64 result returns in D0/XMM0 per
/// AAPCS64 / SysV.
pub fn callF64_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!f64 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0));
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, i32) → v128` invocation. §9.9 /
/// 9.9-h-26 (v128-param-pending discharge): enables i*x*.shl /
/// shr_s / shr_u (shift count = i32) AND i*x*.replace_lane
/// (replacement value = i32, lane index baked into the opcode).
/// Per AAPCS64 / SysV: a0 → V0/XMM0 (vector arg goes to the
/// first FP/vector register), a1 → W1/ESI (i32 arg goes to the
/// first GPR after `rt`); result returns in V0/XMM0.
pub fn callV128_v128i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u32,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: u32) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, f32) → v128` invocation. §9.9 /
/// 9.9-h-26 (v128-param-pending discharge): enables
/// f32x4.replace_lane fixtures (replacement value = f32, lane
/// index baked into the opcode). Per AAPCS64 / SysV: a0 →
/// V0/XMM0, a1 → V1/XMM1 (both FP/vector args use the FP
/// register file in declaration order); result returns in
/// V0/XMM0.
pub fn callV128_v128f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: f32,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: f32) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, f64) → v128` invocation. §9.9 /
/// 9.9-h-26 (v128-param-pending discharge): enables
/// f64x2.replace_lane fixtures (replacement value = f64, lane
/// index baked into the opcode). Per AAPCS64 / SysV: a0 →
/// V0/XMM0, a1 → V1/XMM1; result returns in V0/XMM0.
pub fn callV128_v128f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: f64,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: f64) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128) → i64` invocation. §9.9 / 9.9-h-27
/// (v128-param-pending residual discharge): enables
/// `i64x2.extract_lane` fixtures (lane index baked into the
/// opcode immediate; one v128 input, one i64 result). Per
/// AAPCS64 / SysV: a0 lowers to V0/XMM0 (the FP/vector arg
/// register), result returns in X0/RAX (the first GPR).
pub fn callI64_v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
) Error!u64 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0));
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, i64) → v128` invocation. §9.9 /
/// 9.9-h-27 (v128-param-pending residual discharge): enables
/// `i64x2.replace_lane` (replacement value = i64, lane index
/// baked into the opcode). Per AAPCS64 / SysV: a0 → V0/XMM0
/// (the FP/vector arg register); a1 → X1/RSI (the first GPR
/// after `rt`); result returns in V0/XMM0.
pub fn callV128_v128i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u64,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: u64) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, v128) → i32` invocation. §9.9 /
/// 9.9-h-27 (v128-param-pending residual discharge): enables
/// composite-body fixtures whose Wasm function takes two v128
/// inputs, performs a bitwise op (`and` / `or` / `xor`) between
/// them, and reduces via `i*x*.{all,any}_true` → i32
/// (`simd_boolean` `*_with_v128.{and,or,xor}` /
/// `*_as_i32.*_operand` exports). Per AAPCS64 / SysV: a0 →
/// V0/XMM0, a1 → V1/XMM1; result returns in W0/EAX.
pub fn callI32_v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
) Error!u32 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: Vec) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), @bitCast(a1));
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, v128, i32) → v128` invocation. §9.9
/// / 9.9-h-27 (v128-param-pending residual discharge): enables
/// `select_v128_i32` (Wasm `select` with explicit v128 operands
/// and an i32 selector — `simd_select.wast` `select_v128`).
/// Signature: `v128 v1, v128 v2, i32 cond → v128`. Per
/// AAPCS64 / SysV: a0 → V0/XMM0, a1 → V1/XMM1, a2 → W1/ESI
/// (the first GPR after `rt`); result returns in V0/XMM0.
pub fn callV128_v128v128i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: u32,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: Vec, a2: u32) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), @bitCast(a1), a2);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, v128, v128) → i32` invocation. §9.9 /
/// 9.9-h-28 (v128-param-pending residual discharge): enables the
/// composite `*_with_v128.bitselect` exports from `simd_boolean`
/// whose body is `(any_true|all_true)(bitselect(v0, v1, v2))` and
/// reduces to i32. Per AAPCS64 / SysV: a0 → V0/XMM0, a1 → V1/XMM1,
/// a2 → V2/XMM2; result returns in W0/EAX.
pub fn callI32_v128v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: [16]u8,
) Error!u32 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: Vec, a2: Vec) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), @bitCast(a1), @bitCast(a2));
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, i32) → i32` invocation. §9.9 / 9.9-h-28
/// (v128-param-pending residual discharge): enables `simd_lane`
/// composite exports `i*x*_replace_lane-{s,u}` (replace lane then
/// extract back as i32) and `as-i*x*_any_true-operand` (any_true
/// on `v128 op v128(splat i32 arg)`). Per AAPCS64 / SysV: a0 →
/// V0/XMM0, a1 → W1/ESI (first GPR after `rt`); result returns
/// in W0/EAX.
pub fn callI32_v128i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u32,
) Error!u32 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: u32) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, i64) → i32` invocation. §9.9 / 9.9-h-28
/// (v128-param-pending residual discharge): enables `simd_lane`
/// `as-i32x4_any_true-operand2` whose body takes `(v128, i64)` and
/// returns i32 via `i32x4.any_true ((v128 op v128(splat i64)))`.
/// Per AAPCS64 / SysV: a0 → V0/XMM0, a1 → X1/RSI; result returns
/// in W0/EAX.
pub fn callI32_v128i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u64,
) Error!u32 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: u64) callconv(.c) u32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, i64) → i64` invocation. §9.9 / 9.9-h-28
/// (v128-param-pending residual discharge): enables `simd_lane`
/// composite `i64x2_replace_lane` (replace lane with i64 arg, then
/// `i64x2.extract_lane` it back). Per AAPCS64 / SysV: a0 → V0/XMM0,
/// a1 → X1/RSI; result returns in X0/RAX.
pub fn callI64_v128i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u64,
) Error!u64 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: u64) callconv(.c) u64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, f32) → f32` invocation. §9.9 / 9.9-h-28
/// (v128-param-pending residual discharge): enables `simd_lane`
/// composite `f32x4_replace_lane` (replace lane with f32 arg then
/// extract back). Per AAPCS64 / SysV: a0 → V0/XMM0, a1 → V1/XMM1
/// (both vector / FP args use the FP register file in declaration
/// order); result returns in S0/XMM0.
pub fn callF32_v128f32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: f32,
) Error!f32 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: f32) callconv(.c) f32;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, f64) → f64` invocation. §9.9 / 9.9-h-28
/// (v128-param-pending residual discharge): enables `simd_lane`
/// composite `f64x2_replace_lane`. Per AAPCS64 / SysV: a0 → V0/XMM0,
/// a1 → V1/XMM1; result returns in D0/XMM0.
pub fn callF64_v128f64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: f64,
) Error!f64 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: f64) callconv(.c) f64;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1);
    if (rt.trap_flag != 0) return Error.Trap;
    return result;
}

/// Wasm spec §4.4 — `(v128, v128, v128, v128) → v128` invocation.
/// §9.9 / 9.9-h-28 (v128-param-pending residual discharge): enables
/// `simd_lane` `swizzle-as-i8x16_add-operands` /
/// `shuffle-as-i8x16_sub-operands` which take 4 v128 inputs and
/// produce a v128 result. Per AAPCS64 / SysV the V0..V7 / XMM0..XMM7
/// FP register pool covers ≤ 8 v128 args; a0..a3 → V0..V3 /
/// XMM0..XMM3; result returns in V0/XMM0.
pub fn callV128_v128v128v128v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: [16]u8,
    a2: [16]u8,
    a3: [16]u8,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: Vec, a2: Vec, a3: Vec) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), @bitCast(a1), @bitCast(a2), @bitCast(a3));
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, i32, v128) → v128` invocation. §9.9 /
/// 9.9-h-28 (v128-param-pending residual discharge): enables
/// `simd_lane` `as-v8x16_swizzle-operand` (swizzle takes (v128, v128)
/// but the export wraps it with an i32 arg in the middle threading
/// the lane index). Per AAPCS64 / SysV: a0 → V0/XMM0, a1 → W1/ESI
/// (first GPR after `rt`), a2 → V1/XMM1 (next vector slot); result
/// returns in V0/XMM0.
pub fn callV128_v128i32v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u32,
    a2: [16]u8,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: u32, a2: Vec) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1, @bitCast(a2));
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, i32, v128, i32) → v128` invocation.
/// §9.9 / 9.9-h-28 (v128-param-pending residual discharge): enables
/// `simd_lane` `as-v8x16_shuffle-operands` /
/// `as-i*x*_add-operands` (4-arg composite that interleaves two
/// (v128, i32) `replace_lane` pairs into a single `add`). Per
/// AAPCS64 / SysV: a0 → V0/XMM0, a1 → W1/ESI, a2 → V1/XMM1, a3 →
/// W2/EDX; result returns in V0/XMM0.
pub fn callV128_v128i32v128i32(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u32,
    a2: [16]u8,
    a3: u32,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: u32, a2: Vec, a3: u32) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1, @bitCast(a2), a3);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(v128, i64, v128, i64) → v128` invocation.
/// §9.9 / 9.9-h-28 (v128-param-pending residual discharge): enables
/// `simd_lane` `as-i64x2_add-operands` (i64-typed sibling of
/// `as-i32x4_add-operands`; two `(v128, i64)` `replace_lane` pairs
/// composed into `i64x2.add`). Per AAPCS64 / SysV: a0 → V0/XMM0,
/// a1 → X1/RSI, a2 → V1/XMM1, a3 → X2/RDX; result returns in
/// V0/XMM0.
pub fn callV128_v128i64v128i64(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: [16]u8,
    a1: u64,
    a2: [16]u8,
    a3: u64,
) Error![16]u8 {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: Vec, a1: u64, a2: Vec, a3: u64) callconv(.c) Vec;
    const f = module.entry(func_idx, Fn);
    const result = f(rt, @bitCast(a0), a1, @bitCast(a2), a3);
    if (rt.trap_flag != 0) return Error.Trap;
    return @bitCast(result);
}

/// Wasm spec §4.4 — `(i32, v128) → ()` invocation. §9.9 / 9.9-h-28
/// (v128-param-pending residual discharge): enables `simd_align`
/// `v128.store align=N` fixtures (store address + v128 value, void
/// return). Per AAPCS64 / SysV: a0 → W1/ESI (i32 address), a1 →
/// V0/XMM0 (v128 value uses first FP slot); no result. The GPR /
/// FP register pools are independent so the i32 arg doesn't push
/// the v128 down the FP pool.
pub fn callVoid_i32v128(
    module: linker.JitModule,
    func_idx: u32,
    rt: *JitRuntime,
    a0: u32,
    a1: [16]u8,
) Error!void {
    rt.trap_flag = 0;
    const Vec = @Vector(16, u8);
    const Fn = *const fn (rt: *const JitRuntime, a0: u32, a1: Vec) callconv(.c) void;
    const f = module.entry(func_idx, Fn);
    f(rt, a0, @bitCast(a1));
    if (rt.trap_flag != 0) return Error.Trap;
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

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    // (i32.const 0) (i32.load offset=0) end
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{});
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
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
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
    const out = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{});
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
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{
        .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 }, // const → set
            .{ .def_pc = 2, .last_use_pc = 3 }, // get → end
        },
    };
    const slots = [_]u16{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};
    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{});
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

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var fn0 = ZirFunc.init(0, sig, &.{});
    defer fn0.deinit(testing.allocator);
    try fn0.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{});
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
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{});
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
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{});
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
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{});
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
    try fn0.instrs.append(testing.allocator, .{ .op = .end });
    fn0.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u16{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const sigs = [_]zir.FuncType{sig};

    const out0 = try emit.compile(testing.allocator, &fn0, alloc, &sigs, &.{}, 0, &.{}, &.{});
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
