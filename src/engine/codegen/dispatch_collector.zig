//! Zone 2 codegen dispatch collector — arm64 / x86_64 axes per ADR-0074
//! (per-op file zone split along axis boundary).
//!
//! ## Why this file exists
//!
//! ADR-0073 + ADR-0023 §4.5 amend established the per-op file pattern;
//! ADR-0074 (B9) refined it: the 5 dispatch axes split across two
//! zones to keep handler bodies at the same zone as their ctx types
//! (preserves comptime DCE on every axis).
//!
//!   Zone 1 collector: `src/ir/dispatch_collector.zig`
//!     IRAxis = { .validate, .lower, .interp }
//!     Imports `src/instruction/wasm_X_Y/<op>.zig` (Zone 1).
//!
//!   Zone 2 collector: THIS FILE.
//!     ArchAxis = { .arm64, .x86_64 }
//!     Imports `src/engine/codegen/<arch>/ops/wasm_X_Y/<op>.zig`
//!     (Zone 2). Each arch op file in turn imports the Zone 1
//!     identity anchor for `op_tag` / `wasm_level` / `wasi_level`.
//!
//! The two collectors share `WasmLevel` / `WasiLevel` / `enabledByBuild`
//! (re-exported from Zone 1) so the build-option filter applies
//! uniformly across all 5 axes.
//!
//! ## Dispatch contract (B11 refactor)
//!
//! `dispatch(axis, op, args)` returns `!bool`:
//!   - `true`: the per-arch handler for `op` ran (errors propagated
//!     via the `try`-propagating inferred error set).
//!   - `false`: no per-arch op file is registered for `op` (= legacy
//!     switch in `<arch>/emit.zig` retains authority).
//!   - error: whatever the per-arch handler raised; the caller's
//!     enclosing fn's `Error` set must include it (per-arch handlers
//!     return `arm64/ctx.Error!void` or `x86_64/ctx.Error!void`,
//!     matching the wire-call's enclosing fn).
//!
//! Per-arch op file shape:
//!
//!   pub const op_tag: ZirOp = ...;        // mirrored from Zone 1
//!   pub const wasm_level: ?WasmLevel = ...;
//!   pub const wasi_level: ?WasiLevel = ...;
//!   pub fn emit(...) Error!void { ... }   // real body; per-arch ctx
//!
//! Zone 2 (`src/engine/codegen/`).

const std = @import("std");
const zir = @import("../../ir/zir.zig");
const ir_collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;

pub const WasmLevel = ir_collector.WasmLevel;
pub const WasiLevel = ir_collector.WasiLevel;
pub const enabledByBuild = ir_collector.enabledByBuild;

/// Per-arch codegen axes (per ADR-0074). The IR-axis counterparts
/// live at Zone 1's `IRAxis` enum.
pub const ArchAxis = enum {
    arm64,
    x86_64,
};

/// Comptime contract check for per-arch op modules.
pub fn validateArchOpModule(comptime mod: type) void {
    comptime {
        if (!@hasDecl(mod, "op_tag")) {
            @compileError("per-arch op file missing `pub const op_tag: ZirOp = ...;`");
        }
        if (!@hasDecl(mod, "wasm_level")) {
            @compileError("per-arch op file missing `pub const wasm_level: ?WasmLevel = ...;`");
        }
        if (!@hasDecl(mod, "emit")) {
            @compileError("per-arch op file missing `pub fn emit(...) Error!void { ... }`");
        }
    }
}

// ---------------------------------------------------------------------
// Per-arch collected op modules.
//
// B11: arm64 i32.add real body.
// B12: x86_64 i32.add real body.
// B13: i32 binary ALU cohort (sub/mul/and/or/xor × 2 arches).
// ---------------------------------------------------------------------

const arm64_i32_add = @import("arm64/ops/wasm_1_0/i32_add.zig");
const arm64_i32_sub = @import("arm64/ops/wasm_1_0/i32_sub.zig");
const arm64_i32_mul = @import("arm64/ops/wasm_1_0/i32_mul.zig");
const arm64_i32_and = @import("arm64/ops/wasm_1_0/i32_and.zig");
const arm64_i32_or = @import("arm64/ops/wasm_1_0/i32_or.zig");
const arm64_i32_xor = @import("arm64/ops/wasm_1_0/i32_xor.zig");
const arm64_i64_add = @import("arm64/ops/wasm_1_0/i64_add.zig");
const arm64_i64_sub = @import("arm64/ops/wasm_1_0/i64_sub.zig");
const arm64_i64_mul = @import("arm64/ops/wasm_1_0/i64_mul.zig");
const arm64_i64_and = @import("arm64/ops/wasm_1_0/i64_and.zig");
const arm64_i64_or = @import("arm64/ops/wasm_1_0/i64_or.zig");
const arm64_i64_xor = @import("arm64/ops/wasm_1_0/i64_xor.zig");
const arm64_i32_eq = @import("arm64/ops/wasm_1_0/i32_eq.zig");
const arm64_i32_ne = @import("arm64/ops/wasm_1_0/i32_ne.zig");
const arm64_i32_lt_s = @import("arm64/ops/wasm_1_0/i32_lt_s.zig");
const arm64_i32_lt_u = @import("arm64/ops/wasm_1_0/i32_lt_u.zig");
const arm64_i32_gt_s = @import("arm64/ops/wasm_1_0/i32_gt_s.zig");
const arm64_i32_gt_u = @import("arm64/ops/wasm_1_0/i32_gt_u.zig");
const arm64_i32_le_s = @import("arm64/ops/wasm_1_0/i32_le_s.zig");
const arm64_i32_le_u = @import("arm64/ops/wasm_1_0/i32_le_u.zig");
const arm64_i32_ge_s = @import("arm64/ops/wasm_1_0/i32_ge_s.zig");
const arm64_i32_ge_u = @import("arm64/ops/wasm_1_0/i32_ge_u.zig");
const arm64_i64_eq = @import("arm64/ops/wasm_1_0/i64_eq.zig");
const arm64_i64_ne = @import("arm64/ops/wasm_1_0/i64_ne.zig");
const arm64_i64_lt_s = @import("arm64/ops/wasm_1_0/i64_lt_s.zig");
const arm64_i64_lt_u = @import("arm64/ops/wasm_1_0/i64_lt_u.zig");
const arm64_i64_gt_s = @import("arm64/ops/wasm_1_0/i64_gt_s.zig");
const arm64_i64_gt_u = @import("arm64/ops/wasm_1_0/i64_gt_u.zig");
const arm64_i64_le_s = @import("arm64/ops/wasm_1_0/i64_le_s.zig");
const arm64_i64_le_u = @import("arm64/ops/wasm_1_0/i64_le_u.zig");
const arm64_i64_ge_s = @import("arm64/ops/wasm_1_0/i64_ge_s.zig");
const arm64_i64_ge_u = @import("arm64/ops/wasm_1_0/i64_ge_u.zig");
const arm64_i32_eqz = @import("arm64/ops/wasm_1_0/i32_eqz.zig");
const arm64_i64_eqz = @import("arm64/ops/wasm_1_0/i64_eqz.zig");
const arm64_i32_shl = @import("arm64/ops/wasm_1_0/i32_shl.zig");
const arm64_i32_shr_s = @import("arm64/ops/wasm_1_0/i32_shr_s.zig");
const arm64_i32_shr_u = @import("arm64/ops/wasm_1_0/i32_shr_u.zig");
const arm64_i32_rotl = @import("arm64/ops/wasm_1_0/i32_rotl.zig");
const arm64_i32_rotr = @import("arm64/ops/wasm_1_0/i32_rotr.zig");
const arm64_i64_shl = @import("arm64/ops/wasm_1_0/i64_shl.zig");
const arm64_i64_shr_s = @import("arm64/ops/wasm_1_0/i64_shr_s.zig");
const arm64_i64_shr_u = @import("arm64/ops/wasm_1_0/i64_shr_u.zig");
const arm64_i64_rotl = @import("arm64/ops/wasm_1_0/i64_rotl.zig");
const arm64_i64_rotr = @import("arm64/ops/wasm_1_0/i64_rotr.zig");
const arm64_i32_clz = @import("arm64/ops/wasm_1_0/i32_clz.zig");
const arm64_i32_ctz = @import("arm64/ops/wasm_1_0/i32_ctz.zig");
const arm64_i32_popcnt = @import("arm64/ops/wasm_1_0/i32_popcnt.zig");
const arm64_i64_clz = @import("arm64/ops/wasm_1_0/i64_clz.zig");
const arm64_i64_ctz = @import("arm64/ops/wasm_1_0/i64_ctz.zig");
const arm64_i64_popcnt = @import("arm64/ops/wasm_1_0/i64_popcnt.zig");
const arm64_i32_extend8_s = @import("arm64/ops/wasm_2_0/i32_extend8_s.zig");
const arm64_i32_extend16_s = @import("arm64/ops/wasm_2_0/i32_extend16_s.zig");
const arm64_i64_extend8_s = @import("arm64/ops/wasm_2_0/i64_extend8_s.zig");
const arm64_i64_extend16_s = @import("arm64/ops/wasm_2_0/i64_extend16_s.zig");
const arm64_i64_extend32_s = @import("arm64/ops/wasm_2_0/i64_extend32_s.zig");

const arm64_i32_trunc_sat_f32_s = @import("arm64/ops/wasm_2_0/i32_trunc_sat_f32_s.zig");
const arm64_i32_trunc_sat_f32_u = @import("arm64/ops/wasm_2_0/i32_trunc_sat_f32_u.zig");
const arm64_i32_trunc_sat_f64_s = @import("arm64/ops/wasm_2_0/i32_trunc_sat_f64_s.zig");
const arm64_i32_trunc_sat_f64_u = @import("arm64/ops/wasm_2_0/i32_trunc_sat_f64_u.zig");
const arm64_i64_trunc_sat_f32_s = @import("arm64/ops/wasm_2_0/i64_trunc_sat_f32_s.zig");
const arm64_i64_trunc_sat_f32_u = @import("arm64/ops/wasm_2_0/i64_trunc_sat_f32_u.zig");
const arm64_i64_trunc_sat_f64_s = @import("arm64/ops/wasm_2_0/i64_trunc_sat_f64_s.zig");
const arm64_i64_trunc_sat_f64_u = @import("arm64/ops/wasm_2_0/i64_trunc_sat_f64_u.zig");
const arm64_v128_not = @import("arm64/ops/wasm_2_0/v128_not.zig");
const arm64_v128_and = @import("arm64/ops/wasm_2_0/v128_and.zig");
const arm64_v128_or = @import("arm64/ops/wasm_2_0/v128_or.zig");
const arm64_v128_xor = @import("arm64/ops/wasm_2_0/v128_xor.zig");
const arm64_v128_andnot = @import("arm64/ops/wasm_2_0/v128_andnot.zig");
const arm64_v128_bitselect = @import("arm64/ops/wasm_2_0/v128_bitselect.zig");

const x86_64_v128_not = @import("x86_64/ops/wasm_2_0/v128_not.zig");
const x86_64_v128_and = @import("x86_64/ops/wasm_2_0/v128_and.zig");
const x86_64_v128_or = @import("x86_64/ops/wasm_2_0/v128_or.zig");
const x86_64_v128_xor = @import("x86_64/ops/wasm_2_0/v128_xor.zig");
const x86_64_v128_andnot = @import("x86_64/ops/wasm_2_0/v128_andnot.zig");
const x86_64_v128_bitselect = @import("x86_64/ops/wasm_2_0/v128_bitselect.zig");

const x86_64_i32_trunc_sat_f32_s = @import("x86_64/ops/wasm_2_0/i32_trunc_sat_f32_s.zig");
const x86_64_i32_trunc_sat_f32_u = @import("x86_64/ops/wasm_2_0/i32_trunc_sat_f32_u.zig");
const x86_64_i32_trunc_sat_f64_s = @import("x86_64/ops/wasm_2_0/i32_trunc_sat_f64_s.zig");
const x86_64_i32_trunc_sat_f64_u = @import("x86_64/ops/wasm_2_0/i32_trunc_sat_f64_u.zig");
const x86_64_i64_trunc_sat_f32_s = @import("x86_64/ops/wasm_2_0/i64_trunc_sat_f32_s.zig");
const x86_64_i64_trunc_sat_f32_u = @import("x86_64/ops/wasm_2_0/i64_trunc_sat_f32_u.zig");
const x86_64_i64_trunc_sat_f64_s = @import("x86_64/ops/wasm_2_0/i64_trunc_sat_f64_s.zig");
const x86_64_i64_trunc_sat_f64_u = @import("x86_64/ops/wasm_2_0/i64_trunc_sat_f64_u.zig");

const arm64_i32_div_s = @import("arm64/ops/wasm_1_0/i32_div_s.zig");
const arm64_i32_div_u = @import("arm64/ops/wasm_1_0/i32_div_u.zig");
const arm64_i32_rem_s = @import("arm64/ops/wasm_1_0/i32_rem_s.zig");
const arm64_i32_rem_u = @import("arm64/ops/wasm_1_0/i32_rem_u.zig");
const arm64_i64_div_s = @import("arm64/ops/wasm_1_0/i64_div_s.zig");
const arm64_i64_div_u = @import("arm64/ops/wasm_1_0/i64_div_u.zig");
const arm64_i64_rem_s = @import("arm64/ops/wasm_1_0/i64_rem_s.zig");
const arm64_i64_rem_u = @import("arm64/ops/wasm_1_0/i64_rem_u.zig");
const arm64_i32_wrap_i64 = @import("arm64/ops/wasm_1_0/i32_wrap_i64.zig");
const arm64_i64_extend_i32_s = @import("arm64/ops/wasm_1_0/i64_extend_i32_s.zig");
const arm64_i64_extend_i32_u = @import("arm64/ops/wasm_1_0/i64_extend_i32_u.zig");

const arm64_f32_add = @import("arm64/ops/wasm_1_0/f32_add.zig");
const arm64_f32_sub = @import("arm64/ops/wasm_1_0/f32_sub.zig");
const arm64_f32_mul = @import("arm64/ops/wasm_1_0/f32_mul.zig");
const arm64_f32_div = @import("arm64/ops/wasm_1_0/f32_div.zig");
const arm64_f64_add = @import("arm64/ops/wasm_1_0/f64_add.zig");
const arm64_f64_sub = @import("arm64/ops/wasm_1_0/f64_sub.zig");
const arm64_f64_mul = @import("arm64/ops/wasm_1_0/f64_mul.zig");
const arm64_f64_div = @import("arm64/ops/wasm_1_0/f64_div.zig");
const arm64_f32_eq = @import("arm64/ops/wasm_1_0/f32_eq.zig");
const arm64_f32_ne = @import("arm64/ops/wasm_1_0/f32_ne.zig");
const arm64_f32_lt = @import("arm64/ops/wasm_1_0/f32_lt.zig");
const arm64_f32_gt = @import("arm64/ops/wasm_1_0/f32_gt.zig");
const arm64_f32_le = @import("arm64/ops/wasm_1_0/f32_le.zig");
const arm64_f32_ge = @import("arm64/ops/wasm_1_0/f32_ge.zig");
const arm64_f64_eq = @import("arm64/ops/wasm_1_0/f64_eq.zig");
const arm64_f64_ne = @import("arm64/ops/wasm_1_0/f64_ne.zig");
const arm64_f64_lt = @import("arm64/ops/wasm_1_0/f64_lt.zig");
const arm64_f64_gt = @import("arm64/ops/wasm_1_0/f64_gt.zig");
const arm64_f64_le = @import("arm64/ops/wasm_1_0/f64_le.zig");
const arm64_f64_ge = @import("arm64/ops/wasm_1_0/f64_ge.zig");
const arm64_f32_abs = @import("arm64/ops/wasm_1_0/f32_abs.zig");
const arm64_f32_neg = @import("arm64/ops/wasm_1_0/f32_neg.zig");
const arm64_f32_sqrt = @import("arm64/ops/wasm_1_0/f32_sqrt.zig");
const arm64_f32_ceil = @import("arm64/ops/wasm_1_0/f32_ceil.zig");
const arm64_f32_floor = @import("arm64/ops/wasm_1_0/f32_floor.zig");
const arm64_f32_trunc = @import("arm64/ops/wasm_1_0/f32_trunc.zig");
const arm64_f32_nearest = @import("arm64/ops/wasm_1_0/f32_nearest.zig");
const arm64_f64_abs = @import("arm64/ops/wasm_1_0/f64_abs.zig");
const arm64_f64_neg = @import("arm64/ops/wasm_1_0/f64_neg.zig");
const arm64_f64_sqrt = @import("arm64/ops/wasm_1_0/f64_sqrt.zig");
const arm64_f64_ceil = @import("arm64/ops/wasm_1_0/f64_ceil.zig");
const arm64_f64_floor = @import("arm64/ops/wasm_1_0/f64_floor.zig");
const arm64_f64_trunc = @import("arm64/ops/wasm_1_0/f64_trunc.zig");
const arm64_f64_nearest = @import("arm64/ops/wasm_1_0/f64_nearest.zig");
const arm64_f32_min = @import("arm64/ops/wasm_1_0/f32_min.zig");
const arm64_f32_max = @import("arm64/ops/wasm_1_0/f32_max.zig");
const arm64_f64_min = @import("arm64/ops/wasm_1_0/f64_min.zig");
const arm64_f64_max = @import("arm64/ops/wasm_1_0/f64_max.zig");
const arm64_f32_copysign = @import("arm64/ops/wasm_1_0/f32_copysign.zig");
const arm64_f64_copysign = @import("arm64/ops/wasm_1_0/f64_copysign.zig");
const arm64_f32_convert_i32_s = @import("arm64/ops/wasm_1_0/f32_convert_i32_s.zig");
const arm64_f32_convert_i32_u = @import("arm64/ops/wasm_1_0/f32_convert_i32_u.zig");
const arm64_f32_convert_i64_s = @import("arm64/ops/wasm_1_0/f32_convert_i64_s.zig");
const arm64_f32_convert_i64_u = @import("arm64/ops/wasm_1_0/f32_convert_i64_u.zig");
const arm64_f64_convert_i32_s = @import("arm64/ops/wasm_1_0/f64_convert_i32_s.zig");
const arm64_f64_convert_i32_u = @import("arm64/ops/wasm_1_0/f64_convert_i32_u.zig");
const arm64_f64_convert_i64_s = @import("arm64/ops/wasm_1_0/f64_convert_i64_s.zig");
const arm64_f64_convert_i64_u = @import("arm64/ops/wasm_1_0/f64_convert_i64_u.zig");
const arm64_i32_reinterpret_f32 = @import("arm64/ops/wasm_1_0/i32_reinterpret_f32.zig");
const arm64_i64_reinterpret_f64 = @import("arm64/ops/wasm_1_0/i64_reinterpret_f64.zig");
const arm64_f32_reinterpret_i32 = @import("arm64/ops/wasm_1_0/f32_reinterpret_i32.zig");
const arm64_f64_reinterpret_i64 = @import("arm64/ops/wasm_1_0/f64_reinterpret_i64.zig");
const arm64_f32_demote_f64 = @import("arm64/ops/wasm_1_0/f32_demote_f64.zig");
const arm64_f64_promote_f32 = @import("arm64/ops/wasm_1_0/f64_promote_f32.zig");

const x86_64_i32_reinterpret_f32 = @import("x86_64/ops/wasm_1_0/i32_reinterpret_f32.zig");
const x86_64_i64_reinterpret_f64 = @import("x86_64/ops/wasm_1_0/i64_reinterpret_f64.zig");
const x86_64_f32_reinterpret_i32 = @import("x86_64/ops/wasm_1_0/f32_reinterpret_i32.zig");
const x86_64_f64_reinterpret_i64 = @import("x86_64/ops/wasm_1_0/f64_reinterpret_i64.zig");
const x86_64_f32_demote_f64 = @import("x86_64/ops/wasm_1_0/f32_demote_f64.zig");
const x86_64_f64_promote_f32 = @import("x86_64/ops/wasm_1_0/f64_promote_f32.zig");

const x86_64_f32_add = @import("x86_64/ops/wasm_1_0/f32_add.zig");
const x86_64_f32_sub = @import("x86_64/ops/wasm_1_0/f32_sub.zig");
const x86_64_f32_mul = @import("x86_64/ops/wasm_1_0/f32_mul.zig");
const x86_64_f32_div = @import("x86_64/ops/wasm_1_0/f32_div.zig");
const x86_64_f64_add = @import("x86_64/ops/wasm_1_0/f64_add.zig");
const x86_64_f64_sub = @import("x86_64/ops/wasm_1_0/f64_sub.zig");
const x86_64_f64_mul = @import("x86_64/ops/wasm_1_0/f64_mul.zig");
const x86_64_f64_div = @import("x86_64/ops/wasm_1_0/f64_div.zig");
const x86_64_f32_eq = @import("x86_64/ops/wasm_1_0/f32_eq.zig");
const x86_64_f32_ne = @import("x86_64/ops/wasm_1_0/f32_ne.zig");
const x86_64_f32_lt = @import("x86_64/ops/wasm_1_0/f32_lt.zig");
const x86_64_f32_gt = @import("x86_64/ops/wasm_1_0/f32_gt.zig");
const x86_64_f32_le = @import("x86_64/ops/wasm_1_0/f32_le.zig");
const x86_64_f32_ge = @import("x86_64/ops/wasm_1_0/f32_ge.zig");
const x86_64_f64_eq = @import("x86_64/ops/wasm_1_0/f64_eq.zig");
const x86_64_f64_ne = @import("x86_64/ops/wasm_1_0/f64_ne.zig");
const x86_64_f64_lt = @import("x86_64/ops/wasm_1_0/f64_lt.zig");
const x86_64_f64_gt = @import("x86_64/ops/wasm_1_0/f64_gt.zig");
const x86_64_f64_le = @import("x86_64/ops/wasm_1_0/f64_le.zig");
const x86_64_f64_ge = @import("x86_64/ops/wasm_1_0/f64_ge.zig");
const x86_64_f32_abs = @import("x86_64/ops/wasm_1_0/f32_abs.zig");
const x86_64_f32_neg = @import("x86_64/ops/wasm_1_0/f32_neg.zig");
const x86_64_f32_sqrt = @import("x86_64/ops/wasm_1_0/f32_sqrt.zig");
const x86_64_f32_ceil = @import("x86_64/ops/wasm_1_0/f32_ceil.zig");
const x86_64_f32_floor = @import("x86_64/ops/wasm_1_0/f32_floor.zig");
const x86_64_f32_trunc = @import("x86_64/ops/wasm_1_0/f32_trunc.zig");
const x86_64_f32_nearest = @import("x86_64/ops/wasm_1_0/f32_nearest.zig");
const x86_64_f64_abs = @import("x86_64/ops/wasm_1_0/f64_abs.zig");
const x86_64_f64_neg = @import("x86_64/ops/wasm_1_0/f64_neg.zig");
const x86_64_f64_sqrt = @import("x86_64/ops/wasm_1_0/f64_sqrt.zig");
const x86_64_f64_ceil = @import("x86_64/ops/wasm_1_0/f64_ceil.zig");
const x86_64_f64_floor = @import("x86_64/ops/wasm_1_0/f64_floor.zig");
const x86_64_f64_trunc = @import("x86_64/ops/wasm_1_0/f64_trunc.zig");
const x86_64_f64_nearest = @import("x86_64/ops/wasm_1_0/f64_nearest.zig");
const x86_64_f32_min = @import("x86_64/ops/wasm_1_0/f32_min.zig");
const x86_64_f32_max = @import("x86_64/ops/wasm_1_0/f32_max.zig");
const x86_64_f64_min = @import("x86_64/ops/wasm_1_0/f64_min.zig");
const x86_64_f64_max = @import("x86_64/ops/wasm_1_0/f64_max.zig");
const x86_64_f32_copysign = @import("x86_64/ops/wasm_1_0/f32_copysign.zig");
const x86_64_f64_copysign = @import("x86_64/ops/wasm_1_0/f64_copysign.zig");
const x86_64_f32_convert_i32_s = @import("x86_64/ops/wasm_1_0/f32_convert_i32_s.zig");
const x86_64_f32_convert_i32_u = @import("x86_64/ops/wasm_1_0/f32_convert_i32_u.zig");
const x86_64_f32_convert_i64_s = @import("x86_64/ops/wasm_1_0/f32_convert_i64_s.zig");
const x86_64_f32_convert_i64_u = @import("x86_64/ops/wasm_1_0/f32_convert_i64_u.zig");
const x86_64_f64_convert_i32_s = @import("x86_64/ops/wasm_1_0/f64_convert_i32_s.zig");
const x86_64_f64_convert_i32_u = @import("x86_64/ops/wasm_1_0/f64_convert_i32_u.zig");
const x86_64_f64_convert_i64_s = @import("x86_64/ops/wasm_1_0/f64_convert_i64_s.zig");
const x86_64_f64_convert_i64_u = @import("x86_64/ops/wasm_1_0/f64_convert_i64_u.zig");

const x86_64_i32_wrap_i64 = @import("x86_64/ops/wasm_1_0/i32_wrap_i64.zig");
const x86_64_i64_extend_i32_s = @import("x86_64/ops/wasm_1_0/i64_extend_i32_s.zig");
const x86_64_i64_extend_i32_u = @import("x86_64/ops/wasm_1_0/i64_extend_i32_u.zig");

const x86_64_i32_add = @import("x86_64/ops/wasm_1_0/i32_add.zig");
const x86_64_i32_sub = @import("x86_64/ops/wasm_1_0/i32_sub.zig");
const x86_64_i32_mul = @import("x86_64/ops/wasm_1_0/i32_mul.zig");
const x86_64_i32_and = @import("x86_64/ops/wasm_1_0/i32_and.zig");
const x86_64_i32_or = @import("x86_64/ops/wasm_1_0/i32_or.zig");
const x86_64_i32_xor = @import("x86_64/ops/wasm_1_0/i32_xor.zig");
const x86_64_i64_add = @import("x86_64/ops/wasm_1_0/i64_add.zig");
const x86_64_i64_sub = @import("x86_64/ops/wasm_1_0/i64_sub.zig");
const x86_64_i64_mul = @import("x86_64/ops/wasm_1_0/i64_mul.zig");
const x86_64_i64_and = @import("x86_64/ops/wasm_1_0/i64_and.zig");
const x86_64_i64_or = @import("x86_64/ops/wasm_1_0/i64_or.zig");
const x86_64_i64_xor = @import("x86_64/ops/wasm_1_0/i64_xor.zig");
const x86_64_i32_eq = @import("x86_64/ops/wasm_1_0/i32_eq.zig");
const x86_64_i32_ne = @import("x86_64/ops/wasm_1_0/i32_ne.zig");
const x86_64_i32_lt_s = @import("x86_64/ops/wasm_1_0/i32_lt_s.zig");
const x86_64_i32_lt_u = @import("x86_64/ops/wasm_1_0/i32_lt_u.zig");
const x86_64_i32_gt_s = @import("x86_64/ops/wasm_1_0/i32_gt_s.zig");
const x86_64_i32_gt_u = @import("x86_64/ops/wasm_1_0/i32_gt_u.zig");
const x86_64_i32_le_s = @import("x86_64/ops/wasm_1_0/i32_le_s.zig");
const x86_64_i32_le_u = @import("x86_64/ops/wasm_1_0/i32_le_u.zig");
const x86_64_i32_ge_s = @import("x86_64/ops/wasm_1_0/i32_ge_s.zig");
const x86_64_i32_ge_u = @import("x86_64/ops/wasm_1_0/i32_ge_u.zig");
const x86_64_i64_eq = @import("x86_64/ops/wasm_1_0/i64_eq.zig");
const x86_64_i64_ne = @import("x86_64/ops/wasm_1_0/i64_ne.zig");
const x86_64_i64_lt_s = @import("x86_64/ops/wasm_1_0/i64_lt_s.zig");
const x86_64_i64_lt_u = @import("x86_64/ops/wasm_1_0/i64_lt_u.zig");
const x86_64_i64_gt_s = @import("x86_64/ops/wasm_1_0/i64_gt_s.zig");
const x86_64_i64_gt_u = @import("x86_64/ops/wasm_1_0/i64_gt_u.zig");
const x86_64_i64_le_s = @import("x86_64/ops/wasm_1_0/i64_le_s.zig");
const x86_64_i64_le_u = @import("x86_64/ops/wasm_1_0/i64_le_u.zig");
const x86_64_i64_ge_s = @import("x86_64/ops/wasm_1_0/i64_ge_s.zig");
const x86_64_i64_ge_u = @import("x86_64/ops/wasm_1_0/i64_ge_u.zig");
const x86_64_i32_eqz = @import("x86_64/ops/wasm_1_0/i32_eqz.zig");
const x86_64_i64_eqz = @import("x86_64/ops/wasm_1_0/i64_eqz.zig");
const x86_64_i32_shl = @import("x86_64/ops/wasm_1_0/i32_shl.zig");
const x86_64_i32_shr_s = @import("x86_64/ops/wasm_1_0/i32_shr_s.zig");
const x86_64_i32_shr_u = @import("x86_64/ops/wasm_1_0/i32_shr_u.zig");
const x86_64_i32_rotl = @import("x86_64/ops/wasm_1_0/i32_rotl.zig");
const x86_64_i32_rotr = @import("x86_64/ops/wasm_1_0/i32_rotr.zig");
const x86_64_i64_shl = @import("x86_64/ops/wasm_1_0/i64_shl.zig");
const x86_64_i64_shr_s = @import("x86_64/ops/wasm_1_0/i64_shr_s.zig");
const x86_64_i64_shr_u = @import("x86_64/ops/wasm_1_0/i64_shr_u.zig");
const x86_64_i64_rotl = @import("x86_64/ops/wasm_1_0/i64_rotl.zig");
const x86_64_i64_rotr = @import("x86_64/ops/wasm_1_0/i64_rotr.zig");
const x86_64_i32_clz = @import("x86_64/ops/wasm_1_0/i32_clz.zig");
const x86_64_i32_ctz = @import("x86_64/ops/wasm_1_0/i32_ctz.zig");
const x86_64_i32_popcnt = @import("x86_64/ops/wasm_1_0/i32_popcnt.zig");
const x86_64_i64_clz = @import("x86_64/ops/wasm_1_0/i64_clz.zig");
const x86_64_i64_ctz = @import("x86_64/ops/wasm_1_0/i64_ctz.zig");
const x86_64_i64_popcnt = @import("x86_64/ops/wasm_1_0/i64_popcnt.zig");
const x86_64_i32_extend8_s = @import("x86_64/ops/wasm_2_0/i32_extend8_s.zig");
const x86_64_i32_extend16_s = @import("x86_64/ops/wasm_2_0/i32_extend16_s.zig");
const x86_64_i64_extend8_s = @import("x86_64/ops/wasm_2_0/i64_extend8_s.zig");
const x86_64_i64_extend16_s = @import("x86_64/ops/wasm_2_0/i64_extend16_s.zig");
const x86_64_i64_extend32_s = @import("x86_64/ops/wasm_2_0/i64_extend32_s.zig");

/// Tuple of all migrated arm64 per-op modules.
pub const collected_arm64_ops = .{
    arm64_i32_add,
    arm64_i32_sub,
    arm64_i32_mul,
    arm64_i32_and,
    arm64_i32_or,
    arm64_i32_xor,
    arm64_i64_add,
    arm64_i64_sub,
    arm64_i64_mul,
    arm64_i64_and,
    arm64_i64_or,
    arm64_i64_xor,
    arm64_i32_eq,
    arm64_i32_ne,
    arm64_i32_lt_s,
    arm64_i32_lt_u,
    arm64_i32_gt_s,
    arm64_i32_gt_u,
    arm64_i32_le_s,
    arm64_i32_le_u,
    arm64_i32_ge_s,
    arm64_i32_ge_u,
    arm64_i64_eq,
    arm64_i64_ne,
    arm64_i64_lt_s,
    arm64_i64_lt_u,
    arm64_i64_gt_s,
    arm64_i64_gt_u,
    arm64_i64_le_s,
    arm64_i64_le_u,
    arm64_i64_ge_s,
    arm64_i64_ge_u,
    arm64_i32_eqz,
    arm64_i64_eqz,
    arm64_i32_shl,
    arm64_i32_shr_s,
    arm64_i32_shr_u,
    arm64_i32_rotl,
    arm64_i32_rotr,
    arm64_i64_shl,
    arm64_i64_shr_s,
    arm64_i64_shr_u,
    arm64_i64_rotl,
    arm64_i64_rotr,
    arm64_i32_clz,
    arm64_i32_ctz,
    arm64_i32_popcnt,
    arm64_i64_clz,
    arm64_i64_ctz,
    arm64_i64_popcnt,
    arm64_i32_extend8_s,
    arm64_i32_extend16_s,
    arm64_i64_extend8_s,
    arm64_i64_extend16_s,
    arm64_i64_extend32_s,
    arm64_i32_div_s,
    arm64_i32_div_u,
    arm64_i32_rem_s,
    arm64_i32_rem_u,
    arm64_i64_div_s,
    arm64_i64_div_u,
    arm64_i64_rem_s,
    arm64_i64_rem_u,
    arm64_i32_wrap_i64,
    arm64_i64_extend_i32_s,
    arm64_i64_extend_i32_u,
    arm64_f32_add,
    arm64_f32_sub,
    arm64_f32_mul,
    arm64_f32_div,
    arm64_f64_add,
    arm64_f64_sub,
    arm64_f64_mul,
    arm64_f64_div,
    arm64_f32_eq,
    arm64_f32_ne,
    arm64_f32_lt,
    arm64_f32_gt,
    arm64_f32_le,
    arm64_f32_ge,
    arm64_f64_eq,
    arm64_f64_ne,
    arm64_f64_lt,
    arm64_f64_gt,
    arm64_f64_le,
    arm64_f64_ge,
    arm64_f32_abs,
    arm64_f32_neg,
    arm64_f32_sqrt,
    arm64_f32_ceil,
    arm64_f32_floor,
    arm64_f32_trunc,
    arm64_f32_nearest,
    arm64_f64_abs,
    arm64_f64_neg,
    arm64_f64_sqrt,
    arm64_f64_ceil,
    arm64_f64_floor,
    arm64_f64_trunc,
    arm64_f64_nearest,
    arm64_f32_min,
    arm64_f32_max,
    arm64_f64_min,
    arm64_f64_max,
    arm64_f32_copysign,
    arm64_f64_copysign,
    arm64_f32_convert_i32_s,
    arm64_f32_convert_i32_u,
    arm64_f32_convert_i64_s,
    arm64_f32_convert_i64_u,
    arm64_f64_convert_i32_s,
    arm64_f64_convert_i32_u,
    arm64_f64_convert_i64_s,
    arm64_f64_convert_i64_u,
    arm64_i32_trunc_sat_f32_s,
    arm64_i32_trunc_sat_f32_u,
    arm64_i32_trunc_sat_f64_s,
    arm64_i32_trunc_sat_f64_u,
    arm64_i64_trunc_sat_f32_s,
    arm64_i64_trunc_sat_f32_u,
    arm64_i64_trunc_sat_f64_s,
    arm64_i64_trunc_sat_f64_u,
    arm64_i32_reinterpret_f32,
    arm64_i64_reinterpret_f64,
    arm64_f32_reinterpret_i32,
    arm64_f64_reinterpret_i64,
    arm64_f32_demote_f64,
    arm64_f64_promote_f32,
    arm64_v128_not,
    arm64_v128_and,
    arm64_v128_or,
    arm64_v128_xor,
    arm64_v128_andnot,
    arm64_v128_bitselect,
};

/// Tuple of all migrated x86_64 per-op modules.
pub const collected_x86_64_ops = .{
    x86_64_i32_add,
    x86_64_i32_sub,
    x86_64_i32_mul,
    x86_64_i32_and,
    x86_64_i32_or,
    x86_64_i32_xor,
    x86_64_i64_add,
    x86_64_i64_sub,
    x86_64_i64_mul,
    x86_64_i64_and,
    x86_64_i64_or,
    x86_64_i64_xor,
    x86_64_i32_eq,
    x86_64_i32_ne,
    x86_64_i32_lt_s,
    x86_64_i32_lt_u,
    x86_64_i32_gt_s,
    x86_64_i32_gt_u,
    x86_64_i32_le_s,
    x86_64_i32_le_u,
    x86_64_i32_ge_s,
    x86_64_i32_ge_u,
    x86_64_i64_eq,
    x86_64_i64_ne,
    x86_64_i64_lt_s,
    x86_64_i64_lt_u,
    x86_64_i64_gt_s,
    x86_64_i64_gt_u,
    x86_64_i64_le_s,
    x86_64_i64_le_u,
    x86_64_i64_ge_s,
    x86_64_i64_ge_u,
    x86_64_i32_eqz,
    x86_64_i64_eqz,
    x86_64_i32_shl,
    x86_64_i32_shr_s,
    x86_64_i32_shr_u,
    x86_64_i32_rotl,
    x86_64_i32_rotr,
    x86_64_i64_shl,
    x86_64_i64_shr_s,
    x86_64_i64_shr_u,
    x86_64_i64_rotl,
    x86_64_i64_rotr,
    x86_64_i32_clz,
    x86_64_i32_ctz,
    x86_64_i32_popcnt,
    x86_64_i64_clz,
    x86_64_i64_ctz,
    x86_64_i64_popcnt,
    x86_64_i32_extend8_s,
    x86_64_i32_extend16_s,
    x86_64_i64_extend8_s,
    x86_64_i64_extend16_s,
    x86_64_i64_extend32_s,
    x86_64_i32_wrap_i64,
    x86_64_i64_extend_i32_s,
    x86_64_i64_extend_i32_u,
    x86_64_f32_add,
    x86_64_f32_sub,
    x86_64_f32_mul,
    x86_64_f32_div,
    x86_64_f64_add,
    x86_64_f64_sub,
    x86_64_f64_mul,
    x86_64_f64_div,
    x86_64_f32_eq,
    x86_64_f32_ne,
    x86_64_f32_lt,
    x86_64_f32_gt,
    x86_64_f32_le,
    x86_64_f32_ge,
    x86_64_f64_eq,
    x86_64_f64_ne,
    x86_64_f64_lt,
    x86_64_f64_gt,
    x86_64_f64_le,
    x86_64_f64_ge,
    x86_64_f32_abs,
    x86_64_f32_neg,
    x86_64_f32_sqrt,
    x86_64_f32_ceil,
    x86_64_f32_floor,
    x86_64_f32_trunc,
    x86_64_f32_nearest,
    x86_64_f64_abs,
    x86_64_f64_neg,
    x86_64_f64_sqrt,
    x86_64_f64_ceil,
    x86_64_f64_floor,
    x86_64_f64_trunc,
    x86_64_f64_nearest,
    x86_64_f32_min,
    x86_64_f32_max,
    x86_64_f64_min,
    x86_64_f64_max,
    x86_64_f32_copysign,
    x86_64_f64_copysign,
    x86_64_f32_convert_i32_s,
    x86_64_f32_convert_i32_u,
    x86_64_f32_convert_i64_s,
    x86_64_f32_convert_i64_u,
    x86_64_f64_convert_i32_s,
    x86_64_f64_convert_i32_u,
    x86_64_f64_convert_i64_s,
    x86_64_f64_convert_i64_u,
    x86_64_i32_trunc_sat_f32_s,
    x86_64_i32_trunc_sat_f32_u,
    x86_64_i32_trunc_sat_f64_s,
    x86_64_i32_trunc_sat_f64_u,
    x86_64_i64_trunc_sat_f32_s,
    x86_64_i64_trunc_sat_f32_u,
    x86_64_i64_trunc_sat_f64_s,
    x86_64_i64_trunc_sat_f64_u,
    x86_64_i32_reinterpret_f32,
    x86_64_i64_reinterpret_f64,
    x86_64_f32_reinterpret_i32,
    x86_64_f64_reinterpret_i64,
    x86_64_f32_demote_f64,
    x86_64_f64_promote_f32,
    x86_64_v128_not,
    x86_64_v128_and,
    x86_64_v128_or,
    x86_64_v128_xor,
    x86_64_v128_andnot,
    x86_64_v128_bitselect,
};

comptime {
    for (collected_arm64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
    for (collected_x86_64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
}

/// Count of currently-migrated arch ops, filtered by the active build
/// options. All comptime-resolved.
pub fn migratedArchOpCount(comptime axis: ArchAxis) usize {
    return comptime blk: {
        const ops = switch (axis) {
            .arm64 => collected_arm64_ops,
            .x86_64 => collected_x86_64_ops,
        };
        var n: usize = 0;
        for (ops) |op_mod| {
            if (enabledByBuild(op_mod)) {
                n += 1;
            }
        }
        break :blk n;
    };
}

/// Per-arch dispatch. Returns `true` if the per-arch handler ran;
/// `false` if no per-arch op file is registered (legacy switch should
/// take over). Handler errors propagate via the inferred error set.
///
/// `args` is a tuple matching the per-arch `emit` function's signature
/// (per-arch ctx types are Zone 2 concerns).
pub fn dispatch(comptime axis: ArchAxis, op: ZirOp, args: anytype) !bool {
    const ops = comptime switch (axis) {
        .arm64 => collected_arm64_ops,
        .x86_64 => collected_x86_64_ops,
    };
    inline for (ops) |op_mod| {
        if (comptime !enabledByBuild(op_mod)) continue;
        if (op == op_mod.op_tag) {
            try @call(.auto, op_mod.emit, args);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------

test "ArchAxis enum has exactly 2 variants per ADR-0074 (Zone 2 arch-axes)" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(ArchAxis).@"enum".fields.len);
}

test "migratedArchOpCount tracks collected per-arch tuples (B29: arm64=134, x86_64=126)" {
    // arm64 = 128 + 6 v128 logical; x86_64 = 120 + 6.
    try std.testing.expectEqual(@as(usize, 134), migratedArchOpCount(.arm64));
    try std.testing.expectEqual(@as(usize, 126), migratedArchOpCount(.x86_64));
}

// Note: a `dispatch(.arm64, tag, args)` test at this layer would
// fail to compile because `inline for` expands the `@call(.auto,
// op_mod.emit, args)` at comptime against every registered per-arch
// handler — handlers require their real ctx tuples, not a smoke
// `.{}`. The dispatcher's wire contract is covered by integration
// tests at `arm64/emit.zig` (and `x86_64/emit.zig` once B12 lands)
// going through real spec-driven fixtures.
