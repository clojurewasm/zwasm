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

const arm64_i8x16_add = @import("arm64/ops/wasm_2_0/i8x16_add.zig");
const arm64_i8x16_sub = @import("arm64/ops/wasm_2_0/i8x16_sub.zig");
const arm64_i16x8_add = @import("arm64/ops/wasm_2_0/i16x8_add.zig");
const arm64_i16x8_sub = @import("arm64/ops/wasm_2_0/i16x8_sub.zig");
const arm64_i16x8_mul = @import("arm64/ops/wasm_2_0/i16x8_mul.zig");
const arm64_i32x4_add = @import("arm64/ops/wasm_2_0/i32x4_add.zig");
const arm64_i32x4_sub = @import("arm64/ops/wasm_2_0/i32x4_sub.zig");
const arm64_i32x4_mul = @import("arm64/ops/wasm_2_0/i32x4_mul.zig");
const arm64_i64x2_add = @import("arm64/ops/wasm_2_0/i64x2_add.zig");
const arm64_i64x2_sub = @import("arm64/ops/wasm_2_0/i64x2_sub.zig");
const arm64_i8x16_neg = @import("arm64/ops/wasm_2_0/i8x16_neg.zig");
const arm64_i8x16_abs = @import("arm64/ops/wasm_2_0/i8x16_abs.zig");
const arm64_i16x8_neg = @import("arm64/ops/wasm_2_0/i16x8_neg.zig");
const arm64_i16x8_abs = @import("arm64/ops/wasm_2_0/i16x8_abs.zig");
const arm64_i32x4_neg = @import("arm64/ops/wasm_2_0/i32x4_neg.zig");
const arm64_i32x4_abs = @import("arm64/ops/wasm_2_0/i32x4_abs.zig");
const arm64_i64x2_neg = @import("arm64/ops/wasm_2_0/i64x2_neg.zig");
const arm64_i64x2_abs = @import("arm64/ops/wasm_2_0/i64x2_abs.zig");
const arm64_i8x16_eq = @import("arm64/ops/wasm_2_0/i8x16_eq.zig");
const arm64_i8x16_ne = @import("arm64/ops/wasm_2_0/i8x16_ne.zig");
const arm64_i8x16_lt_s = @import("arm64/ops/wasm_2_0/i8x16_lt_s.zig");
const arm64_i8x16_lt_u = @import("arm64/ops/wasm_2_0/i8x16_lt_u.zig");
const arm64_i8x16_gt_s = @import("arm64/ops/wasm_2_0/i8x16_gt_s.zig");
const arm64_i8x16_gt_u = @import("arm64/ops/wasm_2_0/i8x16_gt_u.zig");
const arm64_i8x16_le_s = @import("arm64/ops/wasm_2_0/i8x16_le_s.zig");
const arm64_i8x16_le_u = @import("arm64/ops/wasm_2_0/i8x16_le_u.zig");
const arm64_i8x16_ge_s = @import("arm64/ops/wasm_2_0/i8x16_ge_s.zig");
const arm64_i8x16_ge_u = @import("arm64/ops/wasm_2_0/i8x16_ge_u.zig");

const x86_64_i8x16_eq = @import("x86_64/ops/wasm_2_0/i8x16_eq.zig");
const x86_64_i8x16_ne = @import("x86_64/ops/wasm_2_0/i8x16_ne.zig");
const x86_64_i8x16_lt_s = @import("x86_64/ops/wasm_2_0/i8x16_lt_s.zig");
const x86_64_i8x16_lt_u = @import("x86_64/ops/wasm_2_0/i8x16_lt_u.zig");
const x86_64_i8x16_gt_s = @import("x86_64/ops/wasm_2_0/i8x16_gt_s.zig");
const x86_64_i8x16_gt_u = @import("x86_64/ops/wasm_2_0/i8x16_gt_u.zig");
const x86_64_i8x16_le_s = @import("x86_64/ops/wasm_2_0/i8x16_le_s.zig");
const x86_64_i8x16_le_u = @import("x86_64/ops/wasm_2_0/i8x16_le_u.zig");
const x86_64_i8x16_ge_s = @import("x86_64/ops/wasm_2_0/i8x16_ge_s.zig");
const x86_64_i8x16_ge_u = @import("x86_64/ops/wasm_2_0/i8x16_ge_u.zig");

const arm64_i16x8_eq = @import("arm64/ops/wasm_2_0/i16x8_eq.zig");
const arm64_i16x8_ne = @import("arm64/ops/wasm_2_0/i16x8_ne.zig");
const arm64_i16x8_lt_s = @import("arm64/ops/wasm_2_0/i16x8_lt_s.zig");
const arm64_i16x8_lt_u = @import("arm64/ops/wasm_2_0/i16x8_lt_u.zig");
const arm64_i16x8_gt_s = @import("arm64/ops/wasm_2_0/i16x8_gt_s.zig");
const arm64_i16x8_gt_u = @import("arm64/ops/wasm_2_0/i16x8_gt_u.zig");
const arm64_i16x8_le_s = @import("arm64/ops/wasm_2_0/i16x8_le_s.zig");
const arm64_i16x8_le_u = @import("arm64/ops/wasm_2_0/i16x8_le_u.zig");
const arm64_i16x8_ge_s = @import("arm64/ops/wasm_2_0/i16x8_ge_s.zig");
const arm64_i16x8_ge_u = @import("arm64/ops/wasm_2_0/i16x8_ge_u.zig");

const arm64_i32x4_eq = @import("arm64/ops/wasm_2_0/i32x4_eq.zig");
const arm64_i32x4_ne = @import("arm64/ops/wasm_2_0/i32x4_ne.zig");
const arm64_i32x4_lt_s = @import("arm64/ops/wasm_2_0/i32x4_lt_s.zig");
const arm64_i32x4_lt_u = @import("arm64/ops/wasm_2_0/i32x4_lt_u.zig");
const arm64_i32x4_gt_s = @import("arm64/ops/wasm_2_0/i32x4_gt_s.zig");
const arm64_i32x4_gt_u = @import("arm64/ops/wasm_2_0/i32x4_gt_u.zig");
const arm64_i32x4_le_s = @import("arm64/ops/wasm_2_0/i32x4_le_s.zig");
const arm64_i32x4_le_u = @import("arm64/ops/wasm_2_0/i32x4_le_u.zig");
const arm64_i32x4_ge_s = @import("arm64/ops/wasm_2_0/i32x4_ge_s.zig");
const arm64_i32x4_ge_u = @import("arm64/ops/wasm_2_0/i32x4_ge_u.zig");

const arm64_i64x2_eq = @import("arm64/ops/wasm_2_0/i64x2_eq.zig");
const arm64_i64x2_ne = @import("arm64/ops/wasm_2_0/i64x2_ne.zig");
const arm64_i64x2_lt_s = @import("arm64/ops/wasm_2_0/i64x2_lt_s.zig");
const arm64_i64x2_gt_s = @import("arm64/ops/wasm_2_0/i64x2_gt_s.zig");
const arm64_i64x2_le_s = @import("arm64/ops/wasm_2_0/i64x2_le_s.zig");
const arm64_i64x2_ge_s = @import("arm64/ops/wasm_2_0/i64x2_ge_s.zig");

const arm64_i8x16_avgr_u = @import("arm64/ops/wasm_2_0/i8x16_avgr_u.zig");
const arm64_i16x8_avgr_u = @import("arm64/ops/wasm_2_0/i16x8_avgr_u.zig");

const arm64_call = @import("arm64/ops/wasm_1_0/call.zig");
const arm64_call_indirect = @import("arm64/ops/wasm_1_0/call_indirect.zig");

const arm64_ref_is_null = @import("arm64/ops/wasm_1_0/ref_is_null.zig");
const arm64_i8x16_splat = @import("arm64/ops/wasm_2_0/i8x16_splat.zig");
const arm64_i16x8_splat = @import("arm64/ops/wasm_2_0/i16x8_splat.zig");
const arm64_i32x4_splat = @import("arm64/ops/wasm_2_0/i32x4_splat.zig");
const arm64_i64x2_splat = @import("arm64/ops/wasm_2_0/i64x2_splat.zig");
const arm64_f32x4_splat = @import("arm64/ops/wasm_2_0/f32x4_splat.zig");
const arm64_f64x2_splat = @import("arm64/ops/wasm_2_0/f64x2_splat.zig");

const x86_64_ref_is_null = @import("x86_64/ops/wasm_1_0/ref_is_null.zig");
const x86_64_i8x16_splat = @import("x86_64/ops/wasm_2_0/i8x16_splat.zig");
const x86_64_i16x8_splat = @import("x86_64/ops/wasm_2_0/i16x8_splat.zig");
const x86_64_i32x4_splat = @import("x86_64/ops/wasm_2_0/i32x4_splat.zig");
const x86_64_i64x2_splat = @import("x86_64/ops/wasm_2_0/i64x2_splat.zig");
const x86_64_f32x4_splat = @import("x86_64/ops/wasm_2_0/f32x4_splat.zig");
const x86_64_f64x2_splat = @import("x86_64/ops/wasm_2_0/f64x2_splat.zig");

const arm64_i32_trunc_f32_s = @import("arm64/ops/wasm_1_0/i32_trunc_f32_s.zig");
const arm64_i32_trunc_f32_u = @import("arm64/ops/wasm_1_0/i32_trunc_f32_u.zig");
const arm64_i64_trunc_f32_s = @import("arm64/ops/wasm_1_0/i64_trunc_f32_s.zig");
const arm64_i64_trunc_f32_u = @import("arm64/ops/wasm_1_0/i64_trunc_f32_u.zig");
const arm64_i32_trunc_f64_s = @import("arm64/ops/wasm_1_0/i32_trunc_f64_s.zig");
const arm64_i32_trunc_f64_u = @import("arm64/ops/wasm_1_0/i32_trunc_f64_u.zig");
const arm64_i64_trunc_f64_s = @import("arm64/ops/wasm_1_0/i64_trunc_f64_s.zig");
const arm64_i64_trunc_f64_u = @import("arm64/ops/wasm_1_0/i64_trunc_f64_u.zig");

const arm64_block = @import("arm64/ops/wasm_1_0/block.zig");
const arm64_loop = @import("arm64/ops/wasm_1_0/loop.zig");
const arm64_br_if = @import("arm64/ops/wasm_1_0/br_if.zig");
const arm64_br_table = @import("arm64/ops/wasm_1_0/br_table.zig");
const arm64_if_ = @import("arm64/ops/wasm_1_0/if_.zig");
const arm64_else_ = @import("arm64/ops/wasm_1_0/else_.zig");

const arm64_memory_fill = @import("arm64/ops/wasm_1_0/memory_fill.zig");
const arm64_memory_copy = @import("arm64/ops/wasm_1_0/memory_copy.zig");
const arm64_memory_init = @import("arm64/ops/wasm_1_0/memory_init.zig");

const arm64_i32_load = @import("arm64/ops/wasm_1_0/i32_load.zig");
const arm64_i32_load8_s = @import("arm64/ops/wasm_1_0/i32_load8_s.zig");
const arm64_i32_load8_u = @import("arm64/ops/wasm_1_0/i32_load8_u.zig");
const arm64_i32_load16_s = @import("arm64/ops/wasm_1_0/i32_load16_s.zig");
const arm64_i32_load16_u = @import("arm64/ops/wasm_1_0/i32_load16_u.zig");
const arm64_i32_store = @import("arm64/ops/wasm_1_0/i32_store.zig");
const arm64_i32_store8 = @import("arm64/ops/wasm_1_0/i32_store8.zig");
const arm64_i32_store16 = @import("arm64/ops/wasm_1_0/i32_store16.zig");
const arm64_i64_load = @import("arm64/ops/wasm_1_0/i64_load.zig");
const arm64_i64_load8_s = @import("arm64/ops/wasm_1_0/i64_load8_s.zig");
const arm64_i64_load8_u = @import("arm64/ops/wasm_1_0/i64_load8_u.zig");
const arm64_i64_load16_s = @import("arm64/ops/wasm_1_0/i64_load16_s.zig");
const arm64_i64_load16_u = @import("arm64/ops/wasm_1_0/i64_load16_u.zig");
const arm64_i64_load32_s = @import("arm64/ops/wasm_1_0/i64_load32_s.zig");
const arm64_i64_load32_u = @import("arm64/ops/wasm_1_0/i64_load32_u.zig");
const arm64_i64_store = @import("arm64/ops/wasm_1_0/i64_store.zig");
const arm64_i64_store8 = @import("arm64/ops/wasm_1_0/i64_store8.zig");
const arm64_i64_store16 = @import("arm64/ops/wasm_1_0/i64_store16.zig");
const arm64_i64_store32 = @import("arm64/ops/wasm_1_0/i64_store32.zig");
const arm64_f32_load = @import("arm64/ops/wasm_1_0/f32_load.zig");
const arm64_f32_store = @import("arm64/ops/wasm_1_0/f32_store.zig");
const arm64_f64_load = @import("arm64/ops/wasm_1_0/f64_load.zig");
const arm64_f64_store = @import("arm64/ops/wasm_1_0/f64_store.zig");

const arm64_global_get = @import("arm64/ops/wasm_1_0/global_get.zig");
const arm64_global_set = @import("arm64/ops/wasm_1_0/global_set.zig");
const arm64_table_get = @import("arm64/ops/wasm_1_0/table_get.zig");
const arm64_table_set = @import("arm64/ops/wasm_1_0/table_set.zig");
const arm64_table_size = @import("arm64/ops/wasm_1_0/table_size.zig");
const arm64_table_grow = @import("arm64/ops/wasm_1_0/table_grow.zig");
const arm64_table_fill = @import("arm64/ops/wasm_1_0/table_fill.zig");
const arm64_table_copy = @import("arm64/ops/wasm_1_0/table_copy.zig");
const arm64_table_init = @import("arm64/ops/wasm_1_0/table_init.zig");

const arm64_i8x16_swizzle = @import("arm64/ops/wasm_2_0/i8x16_swizzle.zig");
const arm64_i8x16_popcnt = @import("arm64/ops/wasm_2_0/i8x16_popcnt.zig");
const arm64_f32x4_convert_i32x4_s = @import("arm64/ops/wasm_2_0/f32x4_convert_i32x4_s.zig");
const arm64_f32x4_convert_i32x4_u = @import("arm64/ops/wasm_2_0/f32x4_convert_i32x4_u.zig");
const arm64_f64x2_convert_low_i32x4_s = @import("arm64/ops/wasm_2_0/f64x2_convert_low_i32x4_s.zig");
const arm64_f64x2_promote_low_f32x4 = @import("arm64/ops/wasm_2_0/f64x2_promote_low_f32x4.zig");
const arm64_f32x4_demote_f64x2_zero = @import("arm64/ops/wasm_2_0/f32x4_demote_f64x2_zero.zig");
const arm64_i32x4_trunc_sat_f32x4_s = @import("arm64/ops/wasm_2_0/i32x4_trunc_sat_f32x4_s.zig");
const arm64_i32x4_trunc_sat_f32x4_u = @import("arm64/ops/wasm_2_0/i32x4_trunc_sat_f32x4_u.zig");

const arm64_i8x16_narrow_i16x8_s = @import("arm64/ops/wasm_2_0/i8x16_narrow_i16x8_s.zig");
const arm64_i8x16_narrow_i16x8_u = @import("arm64/ops/wasm_2_0/i8x16_narrow_i16x8_u.zig");
const arm64_i16x8_narrow_i32x4_s = @import("arm64/ops/wasm_2_0/i16x8_narrow_i32x4_s.zig");
const arm64_i16x8_narrow_i32x4_u = @import("arm64/ops/wasm_2_0/i16x8_narrow_i32x4_u.zig");
const arm64_i16x8_extend_low_i8x16_s = @import("arm64/ops/wasm_2_0/i16x8_extend_low_i8x16_s.zig");
const arm64_i16x8_extend_high_i8x16_s = @import("arm64/ops/wasm_2_0/i16x8_extend_high_i8x16_s.zig");
const arm64_i16x8_extend_low_i8x16_u = @import("arm64/ops/wasm_2_0/i16x8_extend_low_i8x16_u.zig");
const arm64_i16x8_extend_high_i8x16_u = @import("arm64/ops/wasm_2_0/i16x8_extend_high_i8x16_u.zig");
const arm64_i32x4_extend_low_i16x8_s = @import("arm64/ops/wasm_2_0/i32x4_extend_low_i16x8_s.zig");
const arm64_i32x4_extend_high_i16x8_s = @import("arm64/ops/wasm_2_0/i32x4_extend_high_i16x8_s.zig");
const arm64_i32x4_extend_low_i16x8_u = @import("arm64/ops/wasm_2_0/i32x4_extend_low_i16x8_u.zig");
const arm64_i32x4_extend_high_i16x8_u = @import("arm64/ops/wasm_2_0/i32x4_extend_high_i16x8_u.zig");
const arm64_i64x2_extend_low_i32x4_s = @import("arm64/ops/wasm_2_0/i64x2_extend_low_i32x4_s.zig");
const arm64_i64x2_extend_high_i32x4_s = @import("arm64/ops/wasm_2_0/i64x2_extend_high_i32x4_s.zig");
const arm64_i64x2_extend_low_i32x4_u = @import("arm64/ops/wasm_2_0/i64x2_extend_low_i32x4_u.zig");
const arm64_i64x2_extend_high_i32x4_u = @import("arm64/ops/wasm_2_0/i64x2_extend_high_i32x4_u.zig");

const arm64_v128_any_true = @import("arm64/ops/wasm_2_0/v128_any_true.zig");
const arm64_i8x16_all_true = @import("arm64/ops/wasm_2_0/i8x16_all_true.zig");
const arm64_i16x8_all_true = @import("arm64/ops/wasm_2_0/i16x8_all_true.zig");
const arm64_i32x4_all_true = @import("arm64/ops/wasm_2_0/i32x4_all_true.zig");
const arm64_i64x2_all_true = @import("arm64/ops/wasm_2_0/i64x2_all_true.zig");
const arm64_i8x16_bitmask = @import("arm64/ops/wasm_2_0/i8x16_bitmask.zig");
const arm64_i16x8_bitmask = @import("arm64/ops/wasm_2_0/i16x8_bitmask.zig");
const arm64_i32x4_bitmask = @import("arm64/ops/wasm_2_0/i32x4_bitmask.zig");
const arm64_i64x2_bitmask = @import("arm64/ops/wasm_2_0/i64x2_bitmask.zig");

const arm64_f32x4_eq = @import("arm64/ops/wasm_2_0/f32x4_eq.zig");
const arm64_f32x4_ne = @import("arm64/ops/wasm_2_0/f32x4_ne.zig");
const arm64_f32x4_lt = @import("arm64/ops/wasm_2_0/f32x4_lt.zig");
const arm64_f32x4_gt = @import("arm64/ops/wasm_2_0/f32x4_gt.zig");
const arm64_f32x4_le = @import("arm64/ops/wasm_2_0/f32x4_le.zig");
const arm64_f32x4_ge = @import("arm64/ops/wasm_2_0/f32x4_ge.zig");
const arm64_f64x2_eq = @import("arm64/ops/wasm_2_0/f64x2_eq.zig");
const arm64_f64x2_ne = @import("arm64/ops/wasm_2_0/f64x2_ne.zig");
const arm64_f64x2_lt = @import("arm64/ops/wasm_2_0/f64x2_lt.zig");
const arm64_f64x2_gt = @import("arm64/ops/wasm_2_0/f64x2_gt.zig");
const arm64_f64x2_le = @import("arm64/ops/wasm_2_0/f64x2_le.zig");
const arm64_f64x2_ge = @import("arm64/ops/wasm_2_0/f64x2_ge.zig");

const arm64_f32x4_abs = @import("arm64/ops/wasm_2_0/f32x4_abs.zig");
const arm64_f32x4_neg = @import("arm64/ops/wasm_2_0/f32x4_neg.zig");
const arm64_f32x4_sqrt = @import("arm64/ops/wasm_2_0/f32x4_sqrt.zig");
const arm64_f32x4_ceil = @import("arm64/ops/wasm_2_0/f32x4_ceil.zig");
const arm64_f32x4_floor = @import("arm64/ops/wasm_2_0/f32x4_floor.zig");
const arm64_f32x4_trunc = @import("arm64/ops/wasm_2_0/f32x4_trunc.zig");
const arm64_f32x4_nearest = @import("arm64/ops/wasm_2_0/f32x4_nearest.zig");
const arm64_f64x2_abs = @import("arm64/ops/wasm_2_0/f64x2_abs.zig");
const arm64_f64x2_neg = @import("arm64/ops/wasm_2_0/f64x2_neg.zig");
const arm64_f64x2_sqrt = @import("arm64/ops/wasm_2_0/f64x2_sqrt.zig");
const arm64_f64x2_ceil = @import("arm64/ops/wasm_2_0/f64x2_ceil.zig");
const arm64_f64x2_floor = @import("arm64/ops/wasm_2_0/f64x2_floor.zig");
const arm64_f64x2_trunc = @import("arm64/ops/wasm_2_0/f64x2_trunc.zig");
const arm64_f64x2_nearest = @import("arm64/ops/wasm_2_0/f64x2_nearest.zig");

const arm64_f32x4_add = @import("arm64/ops/wasm_2_0/f32x4_add.zig");
const arm64_f32x4_sub = @import("arm64/ops/wasm_2_0/f32x4_sub.zig");
const arm64_f32x4_mul = @import("arm64/ops/wasm_2_0/f32x4_mul.zig");
const arm64_f32x4_div = @import("arm64/ops/wasm_2_0/f32x4_div.zig");
const arm64_f32x4_min = @import("arm64/ops/wasm_2_0/f32x4_min.zig");
const arm64_f32x4_max = @import("arm64/ops/wasm_2_0/f32x4_max.zig");
const arm64_f32x4_pmin = @import("arm64/ops/wasm_2_0/f32x4_pmin.zig");
const arm64_f32x4_pmax = @import("arm64/ops/wasm_2_0/f32x4_pmax.zig");
const arm64_f64x2_add = @import("arm64/ops/wasm_2_0/f64x2_add.zig");
const arm64_f64x2_sub = @import("arm64/ops/wasm_2_0/f64x2_sub.zig");
const arm64_f64x2_mul = @import("arm64/ops/wasm_2_0/f64x2_mul.zig");
const arm64_f64x2_div = @import("arm64/ops/wasm_2_0/f64x2_div.zig");
const arm64_f64x2_min = @import("arm64/ops/wasm_2_0/f64x2_min.zig");
const arm64_f64x2_max = @import("arm64/ops/wasm_2_0/f64x2_max.zig");
const arm64_f64x2_pmin = @import("arm64/ops/wasm_2_0/f64x2_pmin.zig");
const arm64_f64x2_pmax = @import("arm64/ops/wasm_2_0/f64x2_pmax.zig");

const arm64_i8x16_min_s = @import("arm64/ops/wasm_2_0/i8x16_min_s.zig");
const arm64_i8x16_min_u = @import("arm64/ops/wasm_2_0/i8x16_min_u.zig");
const arm64_i8x16_max_s = @import("arm64/ops/wasm_2_0/i8x16_max_s.zig");
const arm64_i8x16_max_u = @import("arm64/ops/wasm_2_0/i8x16_max_u.zig");
const arm64_i16x8_min_s = @import("arm64/ops/wasm_2_0/i16x8_min_s.zig");
const arm64_i16x8_min_u = @import("arm64/ops/wasm_2_0/i16x8_min_u.zig");
const arm64_i16x8_max_s = @import("arm64/ops/wasm_2_0/i16x8_max_s.zig");
const arm64_i16x8_max_u = @import("arm64/ops/wasm_2_0/i16x8_max_u.zig");
const arm64_i32x4_min_s = @import("arm64/ops/wasm_2_0/i32x4_min_s.zig");
const arm64_i32x4_min_u = @import("arm64/ops/wasm_2_0/i32x4_min_u.zig");
const arm64_i32x4_max_s = @import("arm64/ops/wasm_2_0/i32x4_max_s.zig");
const arm64_i32x4_max_u = @import("arm64/ops/wasm_2_0/i32x4_max_u.zig");

const arm64_i8x16_shl = @import("arm64/ops/wasm_2_0/i8x16_shl.zig");
const arm64_i8x16_shr_s = @import("arm64/ops/wasm_2_0/i8x16_shr_s.zig");
const arm64_i8x16_shr_u = @import("arm64/ops/wasm_2_0/i8x16_shr_u.zig");
const arm64_i16x8_shl = @import("arm64/ops/wasm_2_0/i16x8_shl.zig");
const arm64_i16x8_shr_s = @import("arm64/ops/wasm_2_0/i16x8_shr_s.zig");
const arm64_i16x8_shr_u = @import("arm64/ops/wasm_2_0/i16x8_shr_u.zig");
const arm64_i32x4_shl = @import("arm64/ops/wasm_2_0/i32x4_shl.zig");
const arm64_i32x4_shr_s = @import("arm64/ops/wasm_2_0/i32x4_shr_s.zig");
const arm64_i32x4_shr_u = @import("arm64/ops/wasm_2_0/i32x4_shr_u.zig");
const arm64_i64x2_shl = @import("arm64/ops/wasm_2_0/i64x2_shl.zig");
const arm64_i64x2_shr_s = @import("arm64/ops/wasm_2_0/i64x2_shr_s.zig");
const arm64_i64x2_shr_u = @import("arm64/ops/wasm_2_0/i64x2_shr_u.zig");

const x86_64_i16x8_eq = @import("x86_64/ops/wasm_2_0/i16x8_eq.zig");
const x86_64_i16x8_ne = @import("x86_64/ops/wasm_2_0/i16x8_ne.zig");
const x86_64_i16x8_lt_s = @import("x86_64/ops/wasm_2_0/i16x8_lt_s.zig");
const x86_64_i16x8_lt_u = @import("x86_64/ops/wasm_2_0/i16x8_lt_u.zig");
const x86_64_i16x8_gt_s = @import("x86_64/ops/wasm_2_0/i16x8_gt_s.zig");
const x86_64_i16x8_gt_u = @import("x86_64/ops/wasm_2_0/i16x8_gt_u.zig");
const x86_64_i16x8_le_s = @import("x86_64/ops/wasm_2_0/i16x8_le_s.zig");
const x86_64_i16x8_le_u = @import("x86_64/ops/wasm_2_0/i16x8_le_u.zig");
const x86_64_i16x8_ge_s = @import("x86_64/ops/wasm_2_0/i16x8_ge_s.zig");
const x86_64_i16x8_ge_u = @import("x86_64/ops/wasm_2_0/i16x8_ge_u.zig");

const x86_64_i32x4_eq = @import("x86_64/ops/wasm_2_0/i32x4_eq.zig");
const x86_64_i32x4_ne = @import("x86_64/ops/wasm_2_0/i32x4_ne.zig");
const x86_64_i32x4_lt_s = @import("x86_64/ops/wasm_2_0/i32x4_lt_s.zig");
const x86_64_i32x4_lt_u = @import("x86_64/ops/wasm_2_0/i32x4_lt_u.zig");
const x86_64_i32x4_gt_s = @import("x86_64/ops/wasm_2_0/i32x4_gt_s.zig");
const x86_64_i32x4_gt_u = @import("x86_64/ops/wasm_2_0/i32x4_gt_u.zig");
const x86_64_i32x4_le_s = @import("x86_64/ops/wasm_2_0/i32x4_le_s.zig");
const x86_64_i32x4_le_u = @import("x86_64/ops/wasm_2_0/i32x4_le_u.zig");
const x86_64_i32x4_ge_s = @import("x86_64/ops/wasm_2_0/i32x4_ge_s.zig");
const x86_64_i32x4_ge_u = @import("x86_64/ops/wasm_2_0/i32x4_ge_u.zig");

const x86_64_i64x2_eq = @import("x86_64/ops/wasm_2_0/i64x2_eq.zig");
const x86_64_i64x2_ne = @import("x86_64/ops/wasm_2_0/i64x2_ne.zig");
const x86_64_i64x2_lt_s = @import("x86_64/ops/wasm_2_0/i64x2_lt_s.zig");
const x86_64_i64x2_gt_s = @import("x86_64/ops/wasm_2_0/i64x2_gt_s.zig");
const x86_64_i64x2_le_s = @import("x86_64/ops/wasm_2_0/i64x2_le_s.zig");
const x86_64_i64x2_ge_s = @import("x86_64/ops/wasm_2_0/i64x2_ge_s.zig");

const x86_64_i8x16_swizzle = @import("x86_64/ops/wasm_2_0/i8x16_swizzle.zig");
const x86_64_i32x4_dot_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_dot_i16x8_s.zig");
const x86_64_i16x8_q15mulr_sat_s = @import("x86_64/ops/wasm_2_0/i16x8_q15mulr_sat_s.zig");
const x86_64_f32x4_convert_i32x4_s = @import("x86_64/ops/wasm_2_0/f32x4_convert_i32x4_s.zig");
const x86_64_f32x4_convert_i32x4_u = @import("x86_64/ops/wasm_2_0/f32x4_convert_i32x4_u.zig");
const x86_64_f64x2_convert_low_i32x4_s = @import("x86_64/ops/wasm_2_0/f64x2_convert_low_i32x4_s.zig");
const x86_64_f64x2_promote_low_f32x4 = @import("x86_64/ops/wasm_2_0/f64x2_promote_low_f32x4.zig");
const x86_64_f32x4_demote_f64x2_zero = @import("x86_64/ops/wasm_2_0/f32x4_demote_f64x2_zero.zig");
const x86_64_i32x4_trunc_sat_f32x4_s = @import("x86_64/ops/wasm_2_0/i32x4_trunc_sat_f32x4_s.zig");
const x86_64_i32x4_trunc_sat_f32x4_u = @import("x86_64/ops/wasm_2_0/i32x4_trunc_sat_f32x4_u.zig");

const x86_64_i16x8_extmul_low_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extmul_low_i8x16_s.zig");
const x86_64_i16x8_extmul_high_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extmul_high_i8x16_s.zig");
const x86_64_i16x8_extmul_low_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extmul_low_i8x16_u.zig");
const x86_64_i16x8_extmul_high_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extmul_high_i8x16_u.zig");
const x86_64_i32x4_extmul_low_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extmul_low_i16x8_s.zig");
const x86_64_i32x4_extmul_high_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extmul_high_i16x8_s.zig");
const x86_64_i32x4_extmul_low_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extmul_low_i16x8_u.zig");
const x86_64_i32x4_extmul_high_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extmul_high_i16x8_u.zig");
const x86_64_i64x2_extmul_low_i32x4_s = @import("x86_64/ops/wasm_2_0/i64x2_extmul_low_i32x4_s.zig");
const x86_64_i64x2_extmul_high_i32x4_s = @import("x86_64/ops/wasm_2_0/i64x2_extmul_high_i32x4_s.zig");
const x86_64_i64x2_extmul_low_i32x4_u = @import("x86_64/ops/wasm_2_0/i64x2_extmul_low_i32x4_u.zig");
const x86_64_i64x2_extmul_high_i32x4_u = @import("x86_64/ops/wasm_2_0/i64x2_extmul_high_i32x4_u.zig");
const x86_64_i16x8_extadd_pairwise_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extadd_pairwise_i8x16_s.zig");
const x86_64_i16x8_extadd_pairwise_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extadd_pairwise_i8x16_u.zig");
const x86_64_i32x4_extadd_pairwise_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extadd_pairwise_i16x8_s.zig");
const x86_64_i32x4_extadd_pairwise_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extadd_pairwise_i16x8_u.zig");

const x86_64_i8x16_narrow_i16x8_s = @import("x86_64/ops/wasm_2_0/i8x16_narrow_i16x8_s.zig");
const x86_64_i8x16_narrow_i16x8_u = @import("x86_64/ops/wasm_2_0/i8x16_narrow_i16x8_u.zig");
const x86_64_i16x8_narrow_i32x4_s = @import("x86_64/ops/wasm_2_0/i16x8_narrow_i32x4_s.zig");
const x86_64_i16x8_narrow_i32x4_u = @import("x86_64/ops/wasm_2_0/i16x8_narrow_i32x4_u.zig");
const x86_64_i16x8_extend_low_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extend_low_i8x16_s.zig");
const x86_64_i16x8_extend_high_i8x16_s = @import("x86_64/ops/wasm_2_0/i16x8_extend_high_i8x16_s.zig");
const x86_64_i16x8_extend_low_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extend_low_i8x16_u.zig");
const x86_64_i16x8_extend_high_i8x16_u = @import("x86_64/ops/wasm_2_0/i16x8_extend_high_i8x16_u.zig");
const x86_64_i32x4_extend_low_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extend_low_i16x8_s.zig");
const x86_64_i32x4_extend_high_i16x8_s = @import("x86_64/ops/wasm_2_0/i32x4_extend_high_i16x8_s.zig");
const x86_64_i32x4_extend_low_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extend_low_i16x8_u.zig");
const x86_64_i32x4_extend_high_i16x8_u = @import("x86_64/ops/wasm_2_0/i32x4_extend_high_i16x8_u.zig");
const x86_64_i64x2_extend_low_i32x4_s = @import("x86_64/ops/wasm_2_0/i64x2_extend_low_i32x4_s.zig");
const x86_64_i64x2_extend_high_i32x4_s = @import("x86_64/ops/wasm_2_0/i64x2_extend_high_i32x4_s.zig");
const x86_64_i64x2_extend_low_i32x4_u = @import("x86_64/ops/wasm_2_0/i64x2_extend_low_i32x4_u.zig");
const x86_64_i64x2_extend_high_i32x4_u = @import("x86_64/ops/wasm_2_0/i64x2_extend_high_i32x4_u.zig");

const x86_64_v128_any_true = @import("x86_64/ops/wasm_2_0/v128_any_true.zig");
const x86_64_i8x16_all_true = @import("x86_64/ops/wasm_2_0/i8x16_all_true.zig");
const x86_64_i16x8_all_true = @import("x86_64/ops/wasm_2_0/i16x8_all_true.zig");
const x86_64_i32x4_all_true = @import("x86_64/ops/wasm_2_0/i32x4_all_true.zig");
const x86_64_i64x2_all_true = @import("x86_64/ops/wasm_2_0/i64x2_all_true.zig");
const x86_64_i8x16_bitmask = @import("x86_64/ops/wasm_2_0/i8x16_bitmask.zig");
const x86_64_i16x8_bitmask = @import("x86_64/ops/wasm_2_0/i16x8_bitmask.zig");
const x86_64_i32x4_bitmask = @import("x86_64/ops/wasm_2_0/i32x4_bitmask.zig");
const x86_64_i64x2_bitmask = @import("x86_64/ops/wasm_2_0/i64x2_bitmask.zig");

const x86_64_f32x4_eq = @import("x86_64/ops/wasm_2_0/f32x4_eq.zig");
const x86_64_f32x4_ne = @import("x86_64/ops/wasm_2_0/f32x4_ne.zig");
const x86_64_f32x4_lt = @import("x86_64/ops/wasm_2_0/f32x4_lt.zig");
const x86_64_f32x4_gt = @import("x86_64/ops/wasm_2_0/f32x4_gt.zig");
const x86_64_f32x4_le = @import("x86_64/ops/wasm_2_0/f32x4_le.zig");
const x86_64_f32x4_ge = @import("x86_64/ops/wasm_2_0/f32x4_ge.zig");
const x86_64_f64x2_eq = @import("x86_64/ops/wasm_2_0/f64x2_eq.zig");
const x86_64_f64x2_ne = @import("x86_64/ops/wasm_2_0/f64x2_ne.zig");
const x86_64_f64x2_lt = @import("x86_64/ops/wasm_2_0/f64x2_lt.zig");
const x86_64_f64x2_gt = @import("x86_64/ops/wasm_2_0/f64x2_gt.zig");
const x86_64_f64x2_le = @import("x86_64/ops/wasm_2_0/f64x2_le.zig");
const x86_64_f64x2_ge = @import("x86_64/ops/wasm_2_0/f64x2_ge.zig");

const x86_64_f32x4_abs = @import("x86_64/ops/wasm_2_0/f32x4_abs.zig");
const x86_64_f32x4_neg = @import("x86_64/ops/wasm_2_0/f32x4_neg.zig");
const x86_64_f32x4_sqrt = @import("x86_64/ops/wasm_2_0/f32x4_sqrt.zig");
const x86_64_f32x4_ceil = @import("x86_64/ops/wasm_2_0/f32x4_ceil.zig");
const x86_64_f32x4_floor = @import("x86_64/ops/wasm_2_0/f32x4_floor.zig");
const x86_64_f32x4_trunc = @import("x86_64/ops/wasm_2_0/f32x4_trunc.zig");
const x86_64_f32x4_nearest = @import("x86_64/ops/wasm_2_0/f32x4_nearest.zig");
const x86_64_f64x2_abs = @import("x86_64/ops/wasm_2_0/f64x2_abs.zig");
const x86_64_f64x2_neg = @import("x86_64/ops/wasm_2_0/f64x2_neg.zig");
const x86_64_f64x2_sqrt = @import("x86_64/ops/wasm_2_0/f64x2_sqrt.zig");
const x86_64_f64x2_ceil = @import("x86_64/ops/wasm_2_0/f64x2_ceil.zig");
const x86_64_f64x2_floor = @import("x86_64/ops/wasm_2_0/f64x2_floor.zig");
const x86_64_f64x2_trunc = @import("x86_64/ops/wasm_2_0/f64x2_trunc.zig");
const x86_64_f64x2_nearest = @import("x86_64/ops/wasm_2_0/f64x2_nearest.zig");

const x86_64_f32x4_add = @import("x86_64/ops/wasm_2_0/f32x4_add.zig");
const x86_64_f32x4_sub = @import("x86_64/ops/wasm_2_0/f32x4_sub.zig");
const x86_64_f32x4_mul = @import("x86_64/ops/wasm_2_0/f32x4_mul.zig");
const x86_64_f32x4_div = @import("x86_64/ops/wasm_2_0/f32x4_div.zig");
const x86_64_f32x4_min = @import("x86_64/ops/wasm_2_0/f32x4_min.zig");
const x86_64_f32x4_max = @import("x86_64/ops/wasm_2_0/f32x4_max.zig");
const x86_64_f32x4_pmin = @import("x86_64/ops/wasm_2_0/f32x4_pmin.zig");
const x86_64_f32x4_pmax = @import("x86_64/ops/wasm_2_0/f32x4_pmax.zig");
const x86_64_f64x2_add = @import("x86_64/ops/wasm_2_0/f64x2_add.zig");
const x86_64_f64x2_sub = @import("x86_64/ops/wasm_2_0/f64x2_sub.zig");
const x86_64_f64x2_mul = @import("x86_64/ops/wasm_2_0/f64x2_mul.zig");
const x86_64_f64x2_div = @import("x86_64/ops/wasm_2_0/f64x2_div.zig");
const x86_64_f64x2_min = @import("x86_64/ops/wasm_2_0/f64x2_min.zig");
const x86_64_f64x2_max = @import("x86_64/ops/wasm_2_0/f64x2_max.zig");
const x86_64_f64x2_pmin = @import("x86_64/ops/wasm_2_0/f64x2_pmin.zig");
const x86_64_f64x2_pmax = @import("x86_64/ops/wasm_2_0/f64x2_pmax.zig");

const x86_64_i8x16_add_sat_s = @import("x86_64/ops/wasm_2_0/i8x16_add_sat_s.zig");
const x86_64_i8x16_add_sat_u = @import("x86_64/ops/wasm_2_0/i8x16_add_sat_u.zig");
const x86_64_i8x16_sub_sat_s = @import("x86_64/ops/wasm_2_0/i8x16_sub_sat_s.zig");
const x86_64_i8x16_sub_sat_u = @import("x86_64/ops/wasm_2_0/i8x16_sub_sat_u.zig");
const x86_64_i8x16_avgr_u = @import("x86_64/ops/wasm_2_0/i8x16_avgr_u.zig");
const x86_64_i16x8_add_sat_s = @import("x86_64/ops/wasm_2_0/i16x8_add_sat_s.zig");
const x86_64_i16x8_add_sat_u = @import("x86_64/ops/wasm_2_0/i16x8_add_sat_u.zig");
const x86_64_i16x8_sub_sat_s = @import("x86_64/ops/wasm_2_0/i16x8_sub_sat_s.zig");
const x86_64_i16x8_sub_sat_u = @import("x86_64/ops/wasm_2_0/i16x8_sub_sat_u.zig");
const x86_64_i16x8_avgr_u = @import("x86_64/ops/wasm_2_0/i16x8_avgr_u.zig");

const x86_64_i8x16_min_s = @import("x86_64/ops/wasm_2_0/i8x16_min_s.zig");
const x86_64_i8x16_min_u = @import("x86_64/ops/wasm_2_0/i8x16_min_u.zig");
const x86_64_i8x16_max_s = @import("x86_64/ops/wasm_2_0/i8x16_max_s.zig");
const x86_64_i8x16_max_u = @import("x86_64/ops/wasm_2_0/i8x16_max_u.zig");
const x86_64_i16x8_min_s = @import("x86_64/ops/wasm_2_0/i16x8_min_s.zig");
const x86_64_i16x8_min_u = @import("x86_64/ops/wasm_2_0/i16x8_min_u.zig");
const x86_64_i16x8_max_s = @import("x86_64/ops/wasm_2_0/i16x8_max_s.zig");
const x86_64_i16x8_max_u = @import("x86_64/ops/wasm_2_0/i16x8_max_u.zig");
const x86_64_i32x4_min_s = @import("x86_64/ops/wasm_2_0/i32x4_min_s.zig");
const x86_64_i32x4_min_u = @import("x86_64/ops/wasm_2_0/i32x4_min_u.zig");
const x86_64_i32x4_max_s = @import("x86_64/ops/wasm_2_0/i32x4_max_s.zig");
const x86_64_i32x4_max_u = @import("x86_64/ops/wasm_2_0/i32x4_max_u.zig");

const x86_64_i8x16_shl = @import("x86_64/ops/wasm_2_0/i8x16_shl.zig");
const x86_64_i8x16_shr_s = @import("x86_64/ops/wasm_2_0/i8x16_shr_s.zig");
const x86_64_i8x16_shr_u = @import("x86_64/ops/wasm_2_0/i8x16_shr_u.zig");
const x86_64_i16x8_shl = @import("x86_64/ops/wasm_2_0/i16x8_shl.zig");
const x86_64_i16x8_shr_s = @import("x86_64/ops/wasm_2_0/i16x8_shr_s.zig");
const x86_64_i16x8_shr_u = @import("x86_64/ops/wasm_2_0/i16x8_shr_u.zig");
const x86_64_i32x4_shl = @import("x86_64/ops/wasm_2_0/i32x4_shl.zig");
const x86_64_i32x4_shr_s = @import("x86_64/ops/wasm_2_0/i32x4_shr_s.zig");
const x86_64_i32x4_shr_u = @import("x86_64/ops/wasm_2_0/i32x4_shr_u.zig");
const x86_64_i64x2_shl = @import("x86_64/ops/wasm_2_0/i64x2_shl.zig");
const x86_64_i64x2_shr_s = @import("x86_64/ops/wasm_2_0/i64x2_shr_s.zig");
const x86_64_i64x2_shr_u = @import("x86_64/ops/wasm_2_0/i64x2_shr_u.zig");

const x86_64_i8x16_neg = @import("x86_64/ops/wasm_2_0/i8x16_neg.zig");
const x86_64_i8x16_abs = @import("x86_64/ops/wasm_2_0/i8x16_abs.zig");
const x86_64_i16x8_neg = @import("x86_64/ops/wasm_2_0/i16x8_neg.zig");
const x86_64_i16x8_abs = @import("x86_64/ops/wasm_2_0/i16x8_abs.zig");
const x86_64_i32x4_neg = @import("x86_64/ops/wasm_2_0/i32x4_neg.zig");
const x86_64_i32x4_abs = @import("x86_64/ops/wasm_2_0/i32x4_abs.zig");
const x86_64_i64x2_neg = @import("x86_64/ops/wasm_2_0/i64x2_neg.zig");
const x86_64_i64x2_abs = @import("x86_64/ops/wasm_2_0/i64x2_abs.zig");

const x86_64_v128_not = @import("x86_64/ops/wasm_2_0/v128_not.zig");
const x86_64_v128_and = @import("x86_64/ops/wasm_2_0/v128_and.zig");
const x86_64_v128_or = @import("x86_64/ops/wasm_2_0/v128_or.zig");
const x86_64_v128_xor = @import("x86_64/ops/wasm_2_0/v128_xor.zig");
const x86_64_v128_andnot = @import("x86_64/ops/wasm_2_0/v128_andnot.zig");
const x86_64_v128_bitselect = @import("x86_64/ops/wasm_2_0/v128_bitselect.zig");

const x86_64_i8x16_add = @import("x86_64/ops/wasm_2_0/i8x16_add.zig");
const x86_64_i8x16_sub = @import("x86_64/ops/wasm_2_0/i8x16_sub.zig");
const x86_64_i16x8_add = @import("x86_64/ops/wasm_2_0/i16x8_add.zig");
const x86_64_i16x8_sub = @import("x86_64/ops/wasm_2_0/i16x8_sub.zig");
const x86_64_i16x8_mul = @import("x86_64/ops/wasm_2_0/i16x8_mul.zig");
const x86_64_i32x4_add = @import("x86_64/ops/wasm_2_0/i32x4_add.zig");
const x86_64_i32x4_sub = @import("x86_64/ops/wasm_2_0/i32x4_sub.zig");
const x86_64_i32x4_mul = @import("x86_64/ops/wasm_2_0/i32x4_mul.zig");
const x86_64_i64x2_add = @import("x86_64/ops/wasm_2_0/i64x2_add.zig");
const x86_64_i64x2_sub = @import("x86_64/ops/wasm_2_0/i64x2_sub.zig");

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

// §9.12-B / B54+B55 (ADR-0075) — x86_64 per-op files migrated to
// the `(ctx, ins)` shape. Tracked in `collected_x86_64_ctx_ops`
// (see below). Not in `collected_x86_64_ops` until the B6x+1
// dispatcher cutover renames the ctx tuple to the unified one.
const x86_64_i32_div_s = @import("x86_64/ops/wasm_1_0/i32_div_s.zig");
const x86_64_i32_div_u = @import("x86_64/ops/wasm_1_0/i32_div_u.zig");
const x86_64_i32_rem_s = @import("x86_64/ops/wasm_1_0/i32_rem_s.zig");
const x86_64_i32_rem_u = @import("x86_64/ops/wasm_1_0/i32_rem_u.zig");
const x86_64_i64_div_s = @import("x86_64/ops/wasm_1_0/i64_div_s.zig");
const x86_64_i64_div_u = @import("x86_64/ops/wasm_1_0/i64_div_u.zig");
const x86_64_i64_rem_s = @import("x86_64/ops/wasm_1_0/i64_rem_s.zig");
const x86_64_i64_rem_u = @import("x86_64/ops/wasm_1_0/i64_rem_u.zig");
const x86_64_i32_trunc_f32_s = @import("x86_64/ops/wasm_1_0/i32_trunc_f32_s.zig");
const x86_64_i32_trunc_f64_s = @import("x86_64/ops/wasm_1_0/i32_trunc_f64_s.zig");
const x86_64_i64_trunc_f32_s = @import("x86_64/ops/wasm_1_0/i64_trunc_f32_s.zig");
const x86_64_i64_trunc_f64_s = @import("x86_64/ops/wasm_1_0/i64_trunc_f64_s.zig");
const x86_64_i32_trunc_f32_u = @import("x86_64/ops/wasm_1_0/i32_trunc_f32_u.zig");
const x86_64_i32_trunc_f64_u = @import("x86_64/ops/wasm_1_0/i32_trunc_f64_u.zig");
const x86_64_i64_trunc_f32_u = @import("x86_64/ops/wasm_1_0/i64_trunc_f32_u.zig");
const x86_64_i64_trunc_f64_u = @import("x86_64/ops/wasm_1_0/i64_trunc_f64_u.zig");
const x86_64_i32_load = @import("x86_64/ops/wasm_1_0/i32_load.zig");
const x86_64_i32_load8_s = @import("x86_64/ops/wasm_1_0/i32_load8_s.zig");
const x86_64_i32_load8_u = @import("x86_64/ops/wasm_1_0/i32_load8_u.zig");
const x86_64_i32_load16_s = @import("x86_64/ops/wasm_1_0/i32_load16_s.zig");
const x86_64_i32_load16_u = @import("x86_64/ops/wasm_1_0/i32_load16_u.zig");
const x86_64_i32_store = @import("x86_64/ops/wasm_1_0/i32_store.zig");
const x86_64_i32_store8 = @import("x86_64/ops/wasm_1_0/i32_store8.zig");
const x86_64_i32_store16 = @import("x86_64/ops/wasm_1_0/i32_store16.zig");
const x86_64_i64_load = @import("x86_64/ops/wasm_1_0/i64_load.zig");
const x86_64_i64_load8_s = @import("x86_64/ops/wasm_1_0/i64_load8_s.zig");
const x86_64_i64_load8_u = @import("x86_64/ops/wasm_1_0/i64_load8_u.zig");
const x86_64_i64_load16_s = @import("x86_64/ops/wasm_1_0/i64_load16_s.zig");
const x86_64_i64_load16_u = @import("x86_64/ops/wasm_1_0/i64_load16_u.zig");
const x86_64_i64_load32_s = @import("x86_64/ops/wasm_1_0/i64_load32_s.zig");
const x86_64_i64_load32_u = @import("x86_64/ops/wasm_1_0/i64_load32_u.zig");
const x86_64_i64_store = @import("x86_64/ops/wasm_1_0/i64_store.zig");
const x86_64_i64_store8 = @import("x86_64/ops/wasm_1_0/i64_store8.zig");
const x86_64_i64_store16 = @import("x86_64/ops/wasm_1_0/i64_store16.zig");
const x86_64_i64_store32 = @import("x86_64/ops/wasm_1_0/i64_store32.zig");
const x86_64_f32_load = @import("x86_64/ops/wasm_1_0/f32_load.zig");
const x86_64_f64_load = @import("x86_64/ops/wasm_1_0/f64_load.zig");
const x86_64_f32_store = @import("x86_64/ops/wasm_1_0/f32_store.zig");
const x86_64_f64_store = @import("x86_64/ops/wasm_1_0/f64_store.zig");
const x86_64_memory_fill = @import("x86_64/ops/wasm_1_0/memory_fill.zig");
const x86_64_memory_copy = @import("x86_64/ops/wasm_1_0/memory_copy.zig");
const x86_64_memory_init = @import("x86_64/ops/wasm_1_0/memory_init.zig");
const x86_64_global_get = @import("x86_64/ops/wasm_1_0/global_get.zig");
const x86_64_global_set = @import("x86_64/ops/wasm_1_0/global_set.zig");
const x86_64_table_get = @import("x86_64/ops/wasm_1_0/table_get.zig");
const x86_64_table_set = @import("x86_64/ops/wasm_1_0/table_set.zig");
const x86_64_table_size = @import("x86_64/ops/wasm_1_0/table_size.zig");
const x86_64_table_grow = @import("x86_64/ops/wasm_1_0/table_grow.zig");
const x86_64_table_fill = @import("x86_64/ops/wasm_1_0/table_fill.zig");
const x86_64_table_copy = @import("x86_64/ops/wasm_1_0/table_copy.zig");
const x86_64_table_init = @import("x86_64/ops/wasm_1_0/table_init.zig");
const x86_64_call = @import("x86_64/ops/wasm_1_0/call.zig");
const x86_64_call_indirect = @import("x86_64/ops/wasm_1_0/call_indirect.zig");
const x86_64_block = @import("x86_64/ops/wasm_1_0/block.zig");
const x86_64_loop = @import("x86_64/ops/wasm_1_0/loop.zig");
const x86_64_i32_const = @import("x86_64/ops/wasm_1_0/i32_const.zig");
const x86_64_i64_const = @import("x86_64/ops/wasm_1_0/i64_const.zig");
const x86_64_f32_const = @import("x86_64/ops/wasm_1_0/f32_const.zig");
const x86_64_f64_const = @import("x86_64/ops/wasm_1_0/f64_const.zig");
const x86_64_ref_null = @import("x86_64/ops/wasm_1_0/ref_null.zig");
const x86_64_ref_func = @import("x86_64/ops/wasm_1_0/ref_func.zig");
const x86_64_drop = @import("x86_64/ops/wasm_1_0/drop.zig");
const x86_64_select = @import("x86_64/ops/wasm_1_0/select.zig");
const x86_64_memory_size = @import("x86_64/ops/wasm_1_0/memory_size.zig");
const x86_64_memory_grow = @import("x86_64/ops/wasm_1_0/memory_grow.zig");
const x86_64_nop = @import("x86_64/ops/wasm_1_0/nop.zig");
const x86_64_unreachable = @import("x86_64/ops/wasm_1_0/unreachable_.zig");
const x86_64_return = @import("x86_64/ops/wasm_1_0/return_.zig");
const x86_64_br = @import("x86_64/ops/wasm_1_0/br.zig");
const x86_64_br_if = @import("x86_64/ops/wasm_1_0/br_if.zig");
const x86_64_br_table = @import("x86_64/ops/wasm_1_0/br_table.zig");
const x86_64_if = @import("x86_64/ops/wasm_1_0/if_.zig");
const x86_64_else = @import("x86_64/ops/wasm_1_0/else_.zig");
const x86_64_end = @import("x86_64/ops/wasm_1_0/end_.zig");
const x86_64_local_get = @import("x86_64/ops/wasm_1_0/local_get.zig");
const x86_64_local_set = @import("x86_64/ops/wasm_1_0/local_set.zig");
const x86_64_local_tee = @import("x86_64/ops/wasm_1_0/local_tee.zig");

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
    arm64_i8x16_add,
    arm64_i8x16_sub,
    arm64_i16x8_add,
    arm64_i16x8_sub,
    arm64_i16x8_mul,
    arm64_i32x4_add,
    arm64_i32x4_sub,
    arm64_i32x4_mul,
    arm64_i64x2_add,
    arm64_i64x2_sub,
    arm64_i8x16_neg,
    arm64_i8x16_abs,
    arm64_i16x8_neg,
    arm64_i16x8_abs,
    arm64_i32x4_neg,
    arm64_i32x4_abs,
    arm64_i64x2_neg,
    arm64_i64x2_abs,
    arm64_i8x16_eq,
    arm64_i8x16_ne,
    arm64_i8x16_lt_s,
    arm64_i8x16_lt_u,
    arm64_i8x16_gt_s,
    arm64_i8x16_gt_u,
    arm64_i8x16_le_s,
    arm64_i8x16_le_u,
    arm64_i8x16_ge_s,
    arm64_i8x16_ge_u,
    arm64_i16x8_eq,
    arm64_i16x8_ne,
    arm64_i16x8_lt_s,
    arm64_i16x8_lt_u,
    arm64_i16x8_gt_s,
    arm64_i16x8_gt_u,
    arm64_i16x8_le_s,
    arm64_i16x8_le_u,
    arm64_i16x8_ge_s,
    arm64_i16x8_ge_u,
    arm64_i32x4_eq,
    arm64_i32x4_ne,
    arm64_i32x4_lt_s,
    arm64_i32x4_lt_u,
    arm64_i32x4_gt_s,
    arm64_i32x4_gt_u,
    arm64_i32x4_le_s,
    arm64_i32x4_le_u,
    arm64_i32x4_ge_s,
    arm64_i32x4_ge_u,
    arm64_i64x2_eq,
    arm64_i64x2_ne,
    arm64_i64x2_lt_s,
    arm64_i64x2_gt_s,
    arm64_i64x2_le_s,
    arm64_i64x2_ge_s,
    arm64_i8x16_shl,
    arm64_i8x16_shr_s,
    arm64_i8x16_shr_u,
    arm64_i16x8_shl,
    arm64_i16x8_shr_s,
    arm64_i16x8_shr_u,
    arm64_i32x4_shl,
    arm64_i32x4_shr_s,
    arm64_i32x4_shr_u,
    arm64_i64x2_shl,
    arm64_i64x2_shr_s,
    arm64_i64x2_shr_u,
    arm64_i8x16_min_s,
    arm64_i8x16_min_u,
    arm64_i8x16_max_s,
    arm64_i8x16_max_u,
    arm64_i16x8_min_s,
    arm64_i16x8_min_u,
    arm64_i16x8_max_s,
    arm64_i16x8_max_u,
    arm64_i32x4_min_s,
    arm64_i32x4_min_u,
    arm64_i32x4_max_s,
    arm64_i32x4_max_u,
    arm64_i8x16_avgr_u,
    arm64_i16x8_avgr_u,
    arm64_f32x4_add,
    arm64_f32x4_sub,
    arm64_f32x4_mul,
    arm64_f32x4_div,
    arm64_f32x4_min,
    arm64_f32x4_max,
    arm64_f32x4_pmin,
    arm64_f32x4_pmax,
    arm64_f64x2_add,
    arm64_f64x2_sub,
    arm64_f64x2_mul,
    arm64_f64x2_div,
    arm64_f64x2_min,
    arm64_f64x2_max,
    arm64_f64x2_pmin,
    arm64_f64x2_pmax,
    arm64_f32x4_abs,
    arm64_f32x4_neg,
    arm64_f32x4_sqrt,
    arm64_f32x4_ceil,
    arm64_f32x4_floor,
    arm64_f32x4_trunc,
    arm64_f32x4_nearest,
    arm64_f64x2_abs,
    arm64_f64x2_neg,
    arm64_f64x2_sqrt,
    arm64_f64x2_ceil,
    arm64_f64x2_floor,
    arm64_f64x2_trunc,
    arm64_f64x2_nearest,
    arm64_f32x4_eq,
    arm64_f32x4_ne,
    arm64_f32x4_lt,
    arm64_f32x4_gt,
    arm64_f32x4_le,
    arm64_f32x4_ge,
    arm64_f64x2_eq,
    arm64_f64x2_ne,
    arm64_f64x2_lt,
    arm64_f64x2_gt,
    arm64_f64x2_le,
    arm64_f64x2_ge,
    arm64_v128_any_true,
    arm64_i8x16_all_true,
    arm64_i16x8_all_true,
    arm64_i32x4_all_true,
    arm64_i64x2_all_true,
    arm64_i8x16_bitmask,
    arm64_i16x8_bitmask,
    arm64_i32x4_bitmask,
    arm64_i64x2_bitmask,
    arm64_i8x16_narrow_i16x8_s,
    arm64_i8x16_narrow_i16x8_u,
    arm64_i16x8_narrow_i32x4_s,
    arm64_i16x8_narrow_i32x4_u,
    arm64_i16x8_extend_low_i8x16_s,
    arm64_i16x8_extend_high_i8x16_s,
    arm64_i16x8_extend_low_i8x16_u,
    arm64_i16x8_extend_high_i8x16_u,
    arm64_i32x4_extend_low_i16x8_s,
    arm64_i32x4_extend_high_i16x8_s,
    arm64_i32x4_extend_low_i16x8_u,
    arm64_i32x4_extend_high_i16x8_u,
    arm64_i64x2_extend_low_i32x4_s,
    arm64_i64x2_extend_high_i32x4_s,
    arm64_i64x2_extend_low_i32x4_u,
    arm64_i64x2_extend_high_i32x4_u,
    arm64_i8x16_swizzle,
    arm64_i8x16_popcnt,
    arm64_f32x4_convert_i32x4_s,
    arm64_f32x4_convert_i32x4_u,
    arm64_f64x2_convert_low_i32x4_s,
    arm64_f64x2_promote_low_f32x4,
    arm64_f32x4_demote_f64x2_zero,
    arm64_i32x4_trunc_sat_f32x4_s,
    arm64_i32x4_trunc_sat_f32x4_u,
    arm64_global_get,
    arm64_global_set,
    arm64_table_get,
    arm64_table_set,
    arm64_table_size,
    arm64_table_grow,
    arm64_table_fill,
    arm64_table_copy,
    arm64_table_init,
    arm64_i32_load,
    arm64_i32_load8_s,
    arm64_i32_load8_u,
    arm64_i32_load16_s,
    arm64_i32_load16_u,
    arm64_i32_store,
    arm64_i32_store8,
    arm64_i32_store16,
    arm64_i64_load,
    arm64_i64_load8_s,
    arm64_i64_load8_u,
    arm64_i64_load16_s,
    arm64_i64_load16_u,
    arm64_i64_load32_s,
    arm64_i64_load32_u,
    arm64_i64_store,
    arm64_i64_store8,
    arm64_i64_store16,
    arm64_i64_store32,
    arm64_f32_load,
    arm64_f32_store,
    arm64_f64_load,
    arm64_f64_store,
    arm64_memory_fill,
    arm64_memory_copy,
    arm64_memory_init,
    arm64_call,
    arm64_call_indirect,
    arm64_block,
    arm64_loop,
    arm64_br_if,
    arm64_br_table,
    arm64_if_,
    arm64_else_,
    arm64_i32_trunc_f32_s,
    arm64_i32_trunc_f32_u,
    arm64_i64_trunc_f32_s,
    arm64_i64_trunc_f32_u,
    arm64_i32_trunc_f64_s,
    arm64_i32_trunc_f64_u,
    arm64_i64_trunc_f64_s,
    arm64_i64_trunc_f64_u,
    arm64_ref_is_null,
    arm64_i8x16_splat,
    arm64_i16x8_splat,
    arm64_i32x4_splat,
    arm64_i64x2_splat,
    arm64_f32x4_splat,
    arm64_f64x2_splat,
};

/// Tuple of all migrated x86_64 per-op modules.
pub const collected_x86_64_ops = .{
    // i32 binary ALU cohort moved to collected_x86_64_ctx_ops at B79
    // (i32.add/sub/mul/and/or/xor; same emitI32BinaryCtx adapter).
    // i64 binary ALU cohort moved at B80 (i64.add/sub/mul/and/or/xor;
    // same emitI64BinaryCtx adapter).
    // i32 compare cohort moved at B81 (10 ops; emitI32CompareCtx).
    // i64 compare cohort moved at B82 (10 ops; emitI64CompareCtx).
    // i32+i64 shift cohorts moved at B83 (10 ops; emitI{32,64}ShiftCtx).
    // bitcount + eqz cohorts moved at B84 (8 ops; emitI{32,64}{Bitcount,Eqz}Ctx).
    // sign-extension (5) + width-conversion (3) = 8 ops moved at B85.
    // FP arith cohort (8 ops; emitFpBinaryCtx) moved at B86.
    // FP compare cohort (12 ops; emitFpCompareCtx) moved at B87.
    // FP unary cohort (14 ops; emitFpUnaryCtx) moved at B88.
    // FP min/max + copysign (6 ops; emitFp{MinMax,Copysign}Ctx) moved at B89.
    // B57: i{32,64}.trunc_sat_f{32,64}_{s,u} migrated from
    // `collected_x86_64_ops` (314 → 306) to
    // `collected_x86_64_ctx_ops` (16 → 24) as part of the
    // ADR-0075 `(ctx, ins)` migration. The per-op files at
    // `x86_64/ops/wasm_2_0/i{32,64}_trunc_sat_*.zig` now ship
    // the 2-arg `emit(*EmitCtx, *const ZirInstr)` shape.
    // B58: f{32,64}.convert_i{32,64}_{s,u} migrated from
    // `collected_x86_64_ops` (306 → 298) to `_ctx_ops`
    // (24 → 32). The B26 7-arg stubs at
    // `x86_64/ops/wasm_1_0/f{32,64}_convert_*.zig` rewritten
    // in place to the 2-arg shape.
    // B59: i{32,64}.reinterpret_f{32,64} + f{32,64}.reinterpret_
    // i{32,64} + f64.promote_f32 + f32.demote_f64 migrated from
    // `collected_x86_64_ops` (298 → 292) to `_ctx_ops` (32 → 38).
    // The B28 7-arg stubs rewritten in place.
    // v128 logical cohort moved to ctx tuple at B90 (6 ops).
    // SIMD int binary arith cohort moved at B91 (10 ops: add/sub
    // × 4 widths + i16x8/i32x4.mul; i64x2.mul skipped — no Zone 1
    // meta file).
    // SIMD int neg/abs cohort moved at B92 (8 ops).
    x86_64_i8x16_eq,
    x86_64_i8x16_ne,
    x86_64_i8x16_lt_s,
    x86_64_i8x16_lt_u,
    x86_64_i8x16_gt_s,
    x86_64_i8x16_gt_u,
    x86_64_i8x16_le_s,
    x86_64_i8x16_le_u,
    x86_64_i8x16_ge_s,
    x86_64_i8x16_ge_u,
    x86_64_i16x8_eq,
    x86_64_i16x8_ne,
    x86_64_i16x8_lt_s,
    x86_64_i16x8_lt_u,
    x86_64_i16x8_gt_s,
    x86_64_i16x8_gt_u,
    x86_64_i16x8_le_s,
    x86_64_i16x8_le_u,
    x86_64_i16x8_ge_s,
    x86_64_i16x8_ge_u,
    x86_64_i32x4_eq,
    x86_64_i32x4_ne,
    x86_64_i32x4_lt_s,
    x86_64_i32x4_lt_u,
    x86_64_i32x4_gt_s,
    x86_64_i32x4_gt_u,
    x86_64_i32x4_le_s,
    x86_64_i32x4_le_u,
    x86_64_i32x4_ge_s,
    x86_64_i32x4_ge_u,
    x86_64_i64x2_eq,
    x86_64_i64x2_ne,
    x86_64_i64x2_lt_s,
    x86_64_i64x2_gt_s,
    x86_64_i64x2_le_s,
    x86_64_i64x2_ge_s,
    x86_64_i8x16_shl,
    x86_64_i8x16_shr_s,
    x86_64_i8x16_shr_u,
    x86_64_i16x8_shl,
    x86_64_i16x8_shr_s,
    x86_64_i16x8_shr_u,
    x86_64_i32x4_shl,
    x86_64_i32x4_shr_s,
    x86_64_i32x4_shr_u,
    x86_64_i64x2_shl,
    x86_64_i64x2_shr_s,
    x86_64_i64x2_shr_u,
    x86_64_i8x16_min_s,
    x86_64_i8x16_min_u,
    x86_64_i8x16_max_s,
    x86_64_i8x16_max_u,
    x86_64_i16x8_min_s,
    x86_64_i16x8_min_u,
    x86_64_i16x8_max_s,
    x86_64_i16x8_max_u,
    x86_64_i32x4_min_s,
    x86_64_i32x4_min_u,
    x86_64_i32x4_max_s,
    x86_64_i32x4_max_u,
    x86_64_i8x16_add_sat_s,
    x86_64_i8x16_add_sat_u,
    x86_64_i8x16_sub_sat_s,
    x86_64_i8x16_sub_sat_u,
    x86_64_i8x16_avgr_u,
    x86_64_i16x8_add_sat_s,
    x86_64_i16x8_add_sat_u,
    x86_64_i16x8_sub_sat_s,
    x86_64_i16x8_sub_sat_u,
    x86_64_i16x8_avgr_u,
    x86_64_f32x4_add,
    x86_64_f32x4_sub,
    x86_64_f32x4_mul,
    x86_64_f32x4_div,
    x86_64_f32x4_min,
    x86_64_f32x4_max,
    x86_64_f32x4_pmin,
    x86_64_f32x4_pmax,
    x86_64_f64x2_add,
    x86_64_f64x2_sub,
    x86_64_f64x2_mul,
    x86_64_f64x2_div,
    x86_64_f64x2_min,
    x86_64_f64x2_max,
    x86_64_f64x2_pmin,
    x86_64_f64x2_pmax,
    x86_64_f32x4_abs,
    x86_64_f32x4_neg,
    x86_64_f32x4_sqrt,
    x86_64_f32x4_ceil,
    x86_64_f32x4_floor,
    x86_64_f32x4_trunc,
    x86_64_f32x4_nearest,
    x86_64_f64x2_abs,
    x86_64_f64x2_neg,
    x86_64_f64x2_sqrt,
    x86_64_f64x2_ceil,
    x86_64_f64x2_floor,
    x86_64_f64x2_trunc,
    x86_64_f64x2_nearest,
    x86_64_f32x4_eq,
    x86_64_f32x4_ne,
    x86_64_f32x4_lt,
    x86_64_f32x4_gt,
    x86_64_f32x4_le,
    x86_64_f32x4_ge,
    x86_64_f64x2_eq,
    x86_64_f64x2_ne,
    x86_64_f64x2_lt,
    x86_64_f64x2_gt,
    x86_64_f64x2_le,
    x86_64_f64x2_ge,
    x86_64_ref_is_null,
    x86_64_i8x16_splat,
    x86_64_i16x8_splat,
    x86_64_i32x4_splat,
    x86_64_i64x2_splat,
    x86_64_f32x4_splat,
    x86_64_f64x2_splat,
    x86_64_v128_any_true,
    x86_64_i8x16_all_true,
    x86_64_i16x8_all_true,
    x86_64_i32x4_all_true,
    x86_64_i64x2_all_true,
    x86_64_i8x16_bitmask,
    x86_64_i16x8_bitmask,
    x86_64_i32x4_bitmask,
    x86_64_i64x2_bitmask,
    x86_64_i8x16_narrow_i16x8_s,
    x86_64_i8x16_narrow_i16x8_u,
    x86_64_i16x8_narrow_i32x4_s,
    x86_64_i16x8_narrow_i32x4_u,
    x86_64_i16x8_extend_low_i8x16_s,
    x86_64_i16x8_extend_high_i8x16_s,
    x86_64_i16x8_extend_low_i8x16_u,
    x86_64_i16x8_extend_high_i8x16_u,
    x86_64_i32x4_extend_low_i16x8_s,
    x86_64_i32x4_extend_high_i16x8_s,
    x86_64_i32x4_extend_low_i16x8_u,
    x86_64_i32x4_extend_high_i16x8_u,
    x86_64_i64x2_extend_low_i32x4_s,
    x86_64_i64x2_extend_high_i32x4_s,
    x86_64_i64x2_extend_low_i32x4_u,
    x86_64_i64x2_extend_high_i32x4_u,
    x86_64_i16x8_extmul_low_i8x16_s,
    x86_64_i16x8_extmul_high_i8x16_s,
    x86_64_i16x8_extmul_low_i8x16_u,
    x86_64_i16x8_extmul_high_i8x16_u,
    x86_64_i32x4_extmul_low_i16x8_s,
    x86_64_i32x4_extmul_high_i16x8_s,
    x86_64_i32x4_extmul_low_i16x8_u,
    x86_64_i32x4_extmul_high_i16x8_u,
    x86_64_i64x2_extmul_low_i32x4_s,
    x86_64_i64x2_extmul_high_i32x4_s,
    x86_64_i64x2_extmul_low_i32x4_u,
    x86_64_i64x2_extmul_high_i32x4_u,
    x86_64_i16x8_extadd_pairwise_i8x16_s,
    x86_64_i16x8_extadd_pairwise_i8x16_u,
    x86_64_i32x4_extadd_pairwise_i16x8_s,
    x86_64_i32x4_extadd_pairwise_i16x8_u,
    x86_64_i8x16_swizzle,
    x86_64_i32x4_dot_i16x8_s,
    x86_64_i16x8_q15mulr_sat_s,
    x86_64_f32x4_convert_i32x4_s,
    x86_64_f32x4_convert_i32x4_u,
    x86_64_f64x2_convert_low_i32x4_s,
    x86_64_f64x2_promote_low_f32x4,
    x86_64_f32x4_demote_f64x2_zero,
    x86_64_i32x4_trunc_sat_f32x4_s,
    x86_64_i32x4_trunc_sat_f32x4_u,
};

/// §9.12-B / B54 (ADR-0075) — x86_64 per-op modules migrated to
/// the `(ctx, ins)` emit signature. Separate from
/// `collected_x86_64_ops` because the legacy dispatcher's `args`
/// tuple shape is incompatible at comptime. At B6x+1 cutover
/// (per ADR-0075 §Implementation plan) the legacy tuple is
/// removed and this constant is renamed to the unified
/// `collected_x86_64_ops`.
pub const collected_x86_64_ctx_ops = .{
    x86_64_i32_div_s,
    x86_64_i32_div_u,
    x86_64_i32_rem_s,
    x86_64_i32_rem_u,
    x86_64_i64_div_s,
    x86_64_i64_div_u,
    x86_64_i64_rem_s,
    x86_64_i64_rem_u,
    x86_64_i32_trunc_f32_s,
    x86_64_i32_trunc_f64_s,
    x86_64_i64_trunc_f32_s,
    x86_64_i64_trunc_f64_s,
    x86_64_i32_trunc_f32_u,
    x86_64_i32_trunc_f64_u,
    x86_64_i64_trunc_f32_u,
    x86_64_i64_trunc_f64_u,
    x86_64_i32_trunc_sat_f32_s,
    x86_64_i32_trunc_sat_f64_s,
    x86_64_i64_trunc_sat_f32_s,
    x86_64_i64_trunc_sat_f64_s,
    x86_64_i32_trunc_sat_f32_u,
    x86_64_i32_trunc_sat_f64_u,
    x86_64_i64_trunc_sat_f32_u,
    x86_64_i64_trunc_sat_f64_u,
    x86_64_f32_convert_i32_s,
    x86_64_f32_convert_i64_s,
    x86_64_f64_convert_i32_s,
    x86_64_f64_convert_i64_s,
    x86_64_f32_convert_i32_u,
    x86_64_f64_convert_i32_u,
    x86_64_f32_convert_i64_u,
    x86_64_f64_convert_i64_u,
    x86_64_i32_reinterpret_f32,
    x86_64_i64_reinterpret_f64,
    x86_64_f32_reinterpret_i32,
    x86_64_f64_reinterpret_i64,
    x86_64_f64_promote_f32,
    x86_64_f32_demote_f64,
    x86_64_i32_load,
    x86_64_i32_load8_s,
    x86_64_i32_load8_u,
    x86_64_i32_load16_s,
    x86_64_i32_load16_u,
    x86_64_i32_store,
    x86_64_i32_store8,
    x86_64_i32_store16,
    x86_64_i64_load,
    x86_64_i64_load8_s,
    x86_64_i64_load8_u,
    x86_64_i64_load16_s,
    x86_64_i64_load16_u,
    x86_64_i64_load32_s,
    x86_64_i64_load32_u,
    x86_64_i64_store,
    x86_64_i64_store8,
    x86_64_i64_store16,
    x86_64_i64_store32,
    x86_64_f32_load,
    x86_64_f64_load,
    x86_64_f32_store,
    x86_64_f64_store,
    x86_64_memory_fill,
    x86_64_memory_copy,
    x86_64_memory_init,
    x86_64_global_get,
    x86_64_global_set,
    x86_64_table_get,
    x86_64_table_set,
    x86_64_table_size,
    x86_64_table_grow,
    x86_64_table_fill,
    x86_64_table_copy,
    x86_64_table_init,
    x86_64_call,
    x86_64_call_indirect,
    x86_64_block,
    x86_64_loop,
    x86_64_i32_const,
    x86_64_i64_const,
    x86_64_f32_const,
    x86_64_f64_const,
    x86_64_ref_null,
    x86_64_ref_func,
    x86_64_drop,
    x86_64_select,
    x86_64_memory_size,
    x86_64_memory_grow,
    x86_64_nop,
    x86_64_unreachable,
    x86_64_return,
    x86_64_br,
    x86_64_br_if,
    x86_64_br_table,
    x86_64_if,
    x86_64_else,
    x86_64_end,
    x86_64_local_get,
    x86_64_local_set,
    x86_64_local_tee,
    // B79: i32 binary ALU cohort moved from legacy tuple.
    x86_64_i32_add,
    x86_64_i32_sub,
    x86_64_i32_mul,
    x86_64_i32_and,
    x86_64_i32_or,
    x86_64_i32_xor,
    // B80: i64 binary ALU cohort moved from legacy tuple.
    x86_64_i64_add,
    x86_64_i64_sub,
    x86_64_i64_mul,
    x86_64_i64_and,
    x86_64_i64_or,
    x86_64_i64_xor,
    // B81: i32 compare cohort moved from legacy tuple.
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
    // B82: i64 compare cohort moved from legacy tuple.
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
    // B83: i32 + i64 shift cohorts moved from legacy.
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
    // B84: bitcount + eqz cohorts moved from legacy.
    x86_64_i32_clz,
    x86_64_i32_ctz,
    x86_64_i32_popcnt,
    x86_64_i64_clz,
    x86_64_i64_ctz,
    x86_64_i64_popcnt,
    x86_64_i32_eqz,
    x86_64_i64_eqz,
    // B85: sign-extension + width-conversion cohorts moved.
    x86_64_i32_extend8_s,
    x86_64_i32_extend16_s,
    x86_64_i64_extend8_s,
    x86_64_i64_extend16_s,
    x86_64_i64_extend32_s,
    x86_64_i32_wrap_i64,
    x86_64_i64_extend_i32_s,
    x86_64_i64_extend_i32_u,
    // B86: FP arith cohort moved from legacy.
    x86_64_f32_add,
    x86_64_f32_sub,
    x86_64_f32_mul,
    x86_64_f32_div,
    x86_64_f64_add,
    x86_64_f64_sub,
    x86_64_f64_mul,
    x86_64_f64_div,
    // B87: FP compare cohort moved from legacy.
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
    // B88: FP unary cohort moved from legacy.
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
    // B89: FP min/max + copysign cohorts moved from legacy.
    x86_64_f32_min,
    x86_64_f32_max,
    x86_64_f64_min,
    x86_64_f64_max,
    x86_64_f32_copysign,
    x86_64_f64_copysign,
    // B90: v128 logical cohort moved from legacy (first SIMD).
    x86_64_v128_not,
    x86_64_v128_and,
    x86_64_v128_andnot,
    x86_64_v128_or,
    x86_64_v128_xor,
    x86_64_v128_bitselect,
    // B91: SIMD int binary arith cohort moved from legacy.
    x86_64_i8x16_add,
    x86_64_i8x16_sub,
    x86_64_i16x8_add,
    x86_64_i16x8_sub,
    x86_64_i16x8_mul,
    x86_64_i32x4_add,
    x86_64_i32x4_sub,
    x86_64_i32x4_mul,
    x86_64_i64x2_add,
    x86_64_i64x2_sub,
    // B92: SIMD int neg/abs cohort moved from legacy.
    x86_64_i8x16_neg,
    x86_64_i16x8_neg,
    x86_64_i32x4_neg,
    x86_64_i64x2_neg,
    x86_64_i8x16_abs,
    x86_64_i16x8_abs,
    x86_64_i32x4_abs,
    x86_64_i64x2_abs,
};

comptime {
    @setEvalBranchQuota(10_000);
    for (collected_arm64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
    for (collected_x86_64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
    for (collected_x86_64_ctx_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
}

/// Count of currently-migrated arch ops, filtered by the active build
/// options. All comptime-resolved.
pub fn migratedArchOpCount(comptime axis: ArchAxis) usize {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
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

test "migratedArchOpCount tracks collected per-arch tuples (B59: arm64=348, x86_64=292)" {
    // arm64 = 162 + 10 i16x8 cmp; x86_64 = 154 + 10 - 8 trunc_sat
    // (B57) - 8 int→float convert (B58) - 6 reinterpret/promote/demote
    // (B59 moved B28 stubs to ctx tuple). B60 added 23 NEW scalar
    // load/store per-op files directly to ctx tuple (not in legacy
    // tuple before, so x86_64 count unchanged).
    try std.testing.expectEqual(@as(usize, 348), migratedArchOpCount(.arm64));
    // B79..B91 walked cohorts; B92 SIMD int neg/abs (8 ops).
    try std.testing.expectEqual(@as(usize, 170), migratedArchOpCount(.x86_64));
}

test "collected_x86_64_ctx_ops tracks B54+ migrations to `(ctx, ins)` shape" {
    // B54: i32.div_s PoC (1). B55: full i32+i64 div/rem cohort (+7 = 8).
    // B56: Wasm 1.0 trapping trunc cohort (+8 = 16). B57: Wasm 2.0
    // trunc_sat cohort moved from legacy tuple (+8 = 24). B58: Wasm
    // 1.0 int→float convert cohort moved from legacy tuple (+8 = 32).
    // B59: reinterpret + promote/demote moved from legacy tuple
    // (+6 = 38). B60: scalar load/store cohort (23 new per-op files,
    // +23 = 61). B61: bulk-memory cohort (3 new per-op files for
    // memory.fill/copy/init, +3 = 64; data.drop / elem.drop deferred
    // — Zone 1 meta files don't exist yet). B62: globals cohort
    // (global.get/set, 2 new per-op files, +2 = 66). B63: table
    // ops cohort (7 new per-op files: table.get/set/size/grow/
    // fill/copy/init, +7 = 73). B64: call cohort (call +
    // call_indirect, 2 new per-op files, +2 = 75). B65: control
    // structure cohort (block + loop, 2 new per-op files, +2 = 77).
    // B66: Zone 1 meta backfill (no Zone 2 change). B67: const
    // cohort (i32/i64/f32/f64.const, 4 new per-op files, +4 = 81).
    // B68: ref cohort (ref.null + ref.func, 2 new per-op files,
    // +2 = 83). B69: drop (1 new per-op file, +1 = 84). B70:
    // select (1 new per-op file, +1 = 85; select_typed shares
    // runtime via emit.zig grouped arm but lacks Zone 1 meta —
    // its per-op file is deferred). The B6x+1 cutover folds this
    // tuple back into `collected_x86_64_ops`. B71: memory.size +
    // memory.grow (2 new per-op files + 2 Zone 1 meta backfills,
    // +2 = 87). B72: nop (1 new per-op file + 1 meta backfill,
    // +1 = 88). B73: unreachable (1 new per-op file; ctx extended
    // with `dead_code: *bool`, +1 = 89). B74: return (1 new
    // per-op file; ctx extended with `frame_bytes: u32` +
    // `uses_runtime_ptr: bool`, +1 = 90). B75: br family
    // (br + br_if + br_table, all ctx fields exist; 3 new per-op
    // files, +3 = 93). B76: if + else (2 new per-op files,
    // +2 = 95). B77: end (1 new per-op file, +1 = 96 —
    // function-level form + label-end form both route through
    // op_control.emitEndCtx; emit.zig dispatch snapshots
    // labels.len pre-call to decide body-loop break). B78:
    // local.{get,set,tee} (3 new per-op files, +3 = 99;
    // new op_locals.zig host module, ctx ext for total_locals
    // + local_disps). B79: i32 binary ALU cohort (i32.add/sub/
    // mul/and/or/xor, 6 ops) moved from legacy tuple (+6 = 105;
    // emitI32BinaryCtx adapter wraps existing emitI32Binary).
    // B80: i64 binary ALU cohort (6 ops; emitI64BinaryCtx) moved
    // from legacy (+6 = 111). B81: i32 compare cohort (10 ops;
    // emitI32CompareCtx) moved from legacy (+10 = 121).
    // B82: i64 compare cohort (10 ops; emitI64CompareCtx) moved
    // from legacy (+10 = 131). B83: i32+i64 shift cohorts (10 ops;
    // emitI{32,64}ShiftCtx) moved from legacy (+10 = 141).
    // B84: bitcount(6) + eqz(2) = 8 ops moved from legacy (+8 = 149).
    // B85: sign-extension(5) + width-conversion(3) = 8 ops moved
    // (+8 = 157). B86: FP arith (8 ops; emitFpBinaryCtx) moved
    // (+8 = 165). B87: FP compare (12 ops; emitFpCompareCtx)
    // moved (+12 = 177). B88: FP unary (14 ops; emitFpUnaryCtx)
    // moved (+14 = 191). B89: FP min/max+copysign (6 ops;
    // emitFp{MinMax,Copysign}Ctx) moved (+6 = 197). B90: v128
    // logical (6 ops; emitV128*Ctx adapters; first SIMD migration)
    // moved (+6 = 203). B91: SIMD int binary arith (10 ops; add/sub
    // × 4 widths + i16x8/i32x4.mul; i64x2.mul deferred — no Zone 1
    // meta) moved (+10 = 213). B92: SIMD int neg/abs (8 ops;
    // 5-arg helpers, ins ignored) moved (+8 = 221).
    try std.testing.expectEqual(@as(usize, 221), collected_x86_64_ctx_ops.len);
}

// Note: a `dispatch(.arm64, tag, args)` test at this layer would
// fail to compile because `inline for` expands the `@call(.auto,
// op_mod.emit, args)` at comptime against every registered per-arch
// handler — handlers require their real ctx tuples, not a smoke
// `.{}`. The dispatcher's wire contract is covered by integration
// tests at `arm64/emit.zig` (and `x86_64/emit.zig` once B12 lands)
// going through real spec-driven fixtures.
