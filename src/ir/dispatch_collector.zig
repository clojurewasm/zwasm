//! Central comptime dispatch collector — Phase 9 substrate audit Q3 C
//! adoption (per ADR-0023 §4.5 amend + ADR-0073, both Accepted 2026-05-19).
//!
//! This module is the **§9.12-A bootstrap** of the per-op file pattern:
//!
//!   `src/instruction/wasm_X_Y/<op>.zig` exports the canonical 5-axis
//!   handler aggregate (`pub const handlers = .{...}`) plus the
//!   `wasm_level` / `wasi_level` metadata. The collector imports every
//!   op module at comptime, validates the shape, applies the
//!   build-option DCE filter, and builds the central dispatcher per
//!   axis via `inline switch (op) { inline else => |tag| ... }`.
//!
//! In §9.12-A the framework + validation logic lands with an **empty**
//! `collected_ops` tuple. As §9.12-B migrates the 581 ZirOp handlers
//! into per-op files, each is appended here and the comptime validation
//! catches any missing axis / metadata.
//!
//! Design references:
//! - ADR-0023 §4.5 amend (per-op file migration plan).
//! - ADR-0073 (all-layer build-option DCE substrate).
//! - `private/spikes/q3-build-option-dce-poc/dispatch_collector.zig`
//!   (spike reference; 5-op PoC verified DCE works literally).
//!
//! Zone 1 (`src/ir/`) — imports Zone 0 (`build_options`) + Zone 1.

const std = @import("std");
const build_options = @import("build_options");
const zir = @import("zir.zig");

const ZirOp = zir.ZirOp;

/// WasmLevel + WasiLevel are declared inside `build.zig` and reach
/// every `build_options` consumer via `options.addOption`. We
/// re-export the runtime *values* below; per-op files type-annotate
/// against `@TypeOf(build_options.wasm_level)` so the build remains
/// the single source of truth for the enum shape.
pub const WasmLevel = @TypeOf(build_options.wasm_level);
pub const WasiLevel = @TypeOf(build_options.wasi_level);

/// IR-zone dispatch axes (per ADR-0074 split). The arch axes
/// (`arm64` / `x86_64`) live at the Zone 2 collector
/// `src/engine/codegen/dispatch_collector.zig::ArchAxis`.
pub const IRAxis = enum {
    validate,
    lower,
    interp,
};

/// Future-use feature gate tag set; placeholder for Phase 10 / 11
/// extensions (memory64, threads, custom-page-sizes, …).
pub const Feature = enum {
    /// No feature gate (always enabled).
    none,
};

// ---------------------------------------------------------------------
// Per-op module shape (the contract every `src/instruction/wasm_X_Y/<op>.zig`
// must satisfy):
//
//   pub const op_tag: ZirOp = .i32_add;
//   pub const wasm_level: ?WasmLevel = .v1_0;
//   pub const wasi_level: ?WasiLevel = null;
//   pub const enable_features: []const Feature = &.{};
//   pub const handlers = .{
//       .validate = validate_fn,
//       .lower    = lower_fn,
//       .arm64    = emit_arm64_fn,
//       .x86_64   = emit_x86_64_fn,
//       .interp   = interp_fn,
//   };
//
// `validateOpModule(comptime mod)` enforces this shape with
// `@compileError` messages that name what's missing.
// ---------------------------------------------------------------------

/// Comptime invariant check: a per-op file must export `op_tag`,
/// `wasm_level`, and a `handlers` struct with all IR-zone axes
/// (validate / lower / interp). Per-arch handlers live in Zone 2
/// per-arch op files per ADR-0074 and are validated separately by
/// `engine/codegen/dispatch_collector.zig::validateArchOpModule`.
pub fn validateOpModule(comptime mod: type) void {
    comptime {
        if (!@hasDecl(mod, "op_tag")) {
            @compileError("per-op file missing `pub const op_tag: ZirOp = ...;`");
        }
        if (!@hasDecl(mod, "wasm_level")) {
            @compileError("per-op file missing `pub const wasm_level: ?WasmLevel = ...;`");
        }
        if (!@hasDecl(mod, "handlers")) {
            @compileError("per-op file missing `pub const handlers = .{ .validate, .lower, .interp };`");
        }
        const H = @TypeOf(mod.handlers);
        for (@typeInfo(IRAxis).@"enum".fields) |axis_field| {
            if (!@hasField(H, axis_field.name)) {
                @compileError("per-op file '" ++ @tagName(mod.op_tag) ++ "' missing handler `." ++ axis_field.name ++ "` in `pub const handlers`");
            }
        }
    }
}

/// Comptime build-option filter. Returns `true` when the op is
/// enabled by the current `-Dwasm=` / `-Dwasi=` build flags.
///
/// Used as the guard in `inline for` loops + `inline switch`
/// dispatchers so disabled op bodies are never instantiated → no
/// symbol emitted in the binary.
pub fn enabledByBuild(comptime mod: type) bool {
    comptime {
        if (@hasDecl(mod, "wasm_level")) {
            if (mod.wasm_level) |lvl| {
                if (@intFromEnum(lvl) > @intFromEnum(build_options.wasm_level)) {
                    return false;
                }
            }
        }
        if (@hasDecl(mod, "wasi_level")) {
            if (mod.wasi_level) |lvl| {
                const cur = @intFromEnum(build_options.wasi_level);
                const need = @intFromEnum(lvl);
                if (need > cur and build_options.wasi_level != .both) {
                    return false;
                }
            }
        }
        return true;
    }
}

// ---------------------------------------------------------------------
// Collected op modules.
//
// §9.12-A bootstrap: empty. §9.12-B migration appends one entry per
// migrated op:
//
//     const i32_add = @import("../instruction/wasm_1_0/i32_add.zig");
//     ...
//     pub const collected_ops = .{
//         i32_add,
//         ...
//     };
//
// The validation at module top-level walks the tuple and runs
// `validateOpModule(@TypeOf(op))` on each, emitting a `@compileError`
// if any shape invariant is violated. This means **adding a malformed
// per-op file fails the build immediately** — the substrate cannot
// silently regress.
// ---------------------------------------------------------------------

// Per-op module imports. As §9.12-B sub-chunks migrate ops, each new
// per-op file is added below and appended to `collected_ops`.
const i32_add = @import("../instruction/wasm_1_0/i32_add.zig");
const i32_sub = @import("../instruction/wasm_1_0/i32_sub.zig");
const i32_mul = @import("../instruction/wasm_1_0/i32_mul.zig");
const i32_and = @import("../instruction/wasm_1_0/i32_and.zig");
const i32_or = @import("../instruction/wasm_1_0/i32_or.zig");
const i32_xor = @import("../instruction/wasm_1_0/i32_xor.zig");

const i64_add = @import("../instruction/wasm_1_0/i64_add.zig");
const i64_sub = @import("../instruction/wasm_1_0/i64_sub.zig");
const i64_mul = @import("../instruction/wasm_1_0/i64_mul.zig");
const i64_and = @import("../instruction/wasm_1_0/i64_and.zig");
const i64_or = @import("../instruction/wasm_1_0/i64_or.zig");
const i64_xor = @import("../instruction/wasm_1_0/i64_xor.zig");

const i32_eq = @import("../instruction/wasm_1_0/i32_eq.zig");
const i32_ne = @import("../instruction/wasm_1_0/i32_ne.zig");
const i32_lt_s = @import("../instruction/wasm_1_0/i32_lt_s.zig");
const i32_lt_u = @import("../instruction/wasm_1_0/i32_lt_u.zig");
const i32_gt_s = @import("../instruction/wasm_1_0/i32_gt_s.zig");
const i32_gt_u = @import("../instruction/wasm_1_0/i32_gt_u.zig");
const i32_le_s = @import("../instruction/wasm_1_0/i32_le_s.zig");
const i32_le_u = @import("../instruction/wasm_1_0/i32_le_u.zig");
const i32_ge_s = @import("../instruction/wasm_1_0/i32_ge_s.zig");
const i32_ge_u = @import("../instruction/wasm_1_0/i32_ge_u.zig");

const i64_eq = @import("../instruction/wasm_1_0/i64_eq.zig");
const i64_ne = @import("../instruction/wasm_1_0/i64_ne.zig");
const i64_lt_s = @import("../instruction/wasm_1_0/i64_lt_s.zig");
const i64_lt_u = @import("../instruction/wasm_1_0/i64_lt_u.zig");
const i64_gt_s = @import("../instruction/wasm_1_0/i64_gt_s.zig");
const i64_gt_u = @import("../instruction/wasm_1_0/i64_gt_u.zig");
const i64_le_s = @import("../instruction/wasm_1_0/i64_le_s.zig");
const i64_le_u = @import("../instruction/wasm_1_0/i64_le_u.zig");
const i64_ge_s = @import("../instruction/wasm_1_0/i64_ge_s.zig");
const i64_ge_u = @import("../instruction/wasm_1_0/i64_ge_u.zig");

const i32_eqz = @import("../instruction/wasm_1_0/i32_eqz.zig");
const i64_eqz = @import("../instruction/wasm_1_0/i64_eqz.zig");
const i32_shl = @import("../instruction/wasm_1_0/i32_shl.zig");
const i32_shr_s = @import("../instruction/wasm_1_0/i32_shr_s.zig");
const i32_shr_u = @import("../instruction/wasm_1_0/i32_shr_u.zig");
const i32_rotl = @import("../instruction/wasm_1_0/i32_rotl.zig");
const i32_rotr = @import("../instruction/wasm_1_0/i32_rotr.zig");
const i64_shl = @import("../instruction/wasm_1_0/i64_shl.zig");
const i64_shr_s = @import("../instruction/wasm_1_0/i64_shr_s.zig");
const i64_shr_u = @import("../instruction/wasm_1_0/i64_shr_u.zig");
const i64_rotl = @import("../instruction/wasm_1_0/i64_rotl.zig");
const i64_rotr = @import("../instruction/wasm_1_0/i64_rotr.zig");

const i32_clz = @import("../instruction/wasm_1_0/i32_clz.zig");
const i32_ctz = @import("../instruction/wasm_1_0/i32_ctz.zig");
const i32_popcnt = @import("../instruction/wasm_1_0/i32_popcnt.zig");
const i64_clz = @import("../instruction/wasm_1_0/i64_clz.zig");
const i64_ctz = @import("../instruction/wasm_1_0/i64_ctz.zig");
const i64_popcnt = @import("../instruction/wasm_1_0/i64_popcnt.zig");

const i32_extend8_s = @import("../instruction/wasm_2_0/i32_extend8_s.zig");
const i32_extend16_s = @import("../instruction/wasm_2_0/i32_extend16_s.zig");
const i64_extend8_s = @import("../instruction/wasm_2_0/i64_extend8_s.zig");
const i64_extend16_s = @import("../instruction/wasm_2_0/i64_extend16_s.zig");
const i64_extend32_s = @import("../instruction/wasm_2_0/i64_extend32_s.zig");

const i32_trunc_sat_f32_s = @import("../instruction/wasm_2_0/i32_trunc_sat_f32_s.zig");
const i32_trunc_sat_f32_u = @import("../instruction/wasm_2_0/i32_trunc_sat_f32_u.zig");
const i32_trunc_sat_f64_s = @import("../instruction/wasm_2_0/i32_trunc_sat_f64_s.zig");
const i32_trunc_sat_f64_u = @import("../instruction/wasm_2_0/i32_trunc_sat_f64_u.zig");
const i64_trunc_sat_f32_s = @import("../instruction/wasm_2_0/i64_trunc_sat_f32_s.zig");
const i64_trunc_sat_f32_u = @import("../instruction/wasm_2_0/i64_trunc_sat_f32_u.zig");
const i64_trunc_sat_f64_s = @import("../instruction/wasm_2_0/i64_trunc_sat_f64_s.zig");
const i64_trunc_sat_f64_u = @import("../instruction/wasm_2_0/i64_trunc_sat_f64_u.zig");

const v128_not = @import("../instruction/wasm_2_0/v128_not.zig");
const v128_and = @import("../instruction/wasm_2_0/v128_and.zig");
const v128_or = @import("../instruction/wasm_2_0/v128_or.zig");
const v128_xor = @import("../instruction/wasm_2_0/v128_xor.zig");
const v128_andnot = @import("../instruction/wasm_2_0/v128_andnot.zig");
const v128_bitselect = @import("../instruction/wasm_2_0/v128_bitselect.zig");

const i8x16_add = @import("../instruction/wasm_2_0/i8x16_add.zig");
const i8x16_sub = @import("../instruction/wasm_2_0/i8x16_sub.zig");
const i16x8_add = @import("../instruction/wasm_2_0/i16x8_add.zig");
const i16x8_sub = @import("../instruction/wasm_2_0/i16x8_sub.zig");
const i16x8_mul = @import("../instruction/wasm_2_0/i16x8_mul.zig");
const i32x4_add = @import("../instruction/wasm_2_0/i32x4_add.zig");
const i32x4_sub = @import("../instruction/wasm_2_0/i32x4_sub.zig");
const i32x4_mul = @import("../instruction/wasm_2_0/i32x4_mul.zig");
const i64x2_add = @import("../instruction/wasm_2_0/i64x2_add.zig");
const i64x2_sub = @import("../instruction/wasm_2_0/i64x2_sub.zig");

const i8x16_neg = @import("../instruction/wasm_2_0/i8x16_neg.zig");
const i8x16_abs = @import("../instruction/wasm_2_0/i8x16_abs.zig");
const i16x8_neg = @import("../instruction/wasm_2_0/i16x8_neg.zig");
const i16x8_abs = @import("../instruction/wasm_2_0/i16x8_abs.zig");
const i32x4_neg = @import("../instruction/wasm_2_0/i32x4_neg.zig");
const i32x4_abs = @import("../instruction/wasm_2_0/i32x4_abs.zig");
const i64x2_neg = @import("../instruction/wasm_2_0/i64x2_neg.zig");
const i64x2_abs = @import("../instruction/wasm_2_0/i64x2_abs.zig");

const i8x16_eq = @import("../instruction/wasm_2_0/i8x16_eq.zig");
const i8x16_ne = @import("../instruction/wasm_2_0/i8x16_ne.zig");
const i8x16_lt_s = @import("../instruction/wasm_2_0/i8x16_lt_s.zig");
const i8x16_lt_u = @import("../instruction/wasm_2_0/i8x16_lt_u.zig");
const i8x16_gt_s = @import("../instruction/wasm_2_0/i8x16_gt_s.zig");
const i8x16_gt_u = @import("../instruction/wasm_2_0/i8x16_gt_u.zig");
const i8x16_le_s = @import("../instruction/wasm_2_0/i8x16_le_s.zig");
const i8x16_le_u = @import("../instruction/wasm_2_0/i8x16_le_u.zig");
const i8x16_ge_s = @import("../instruction/wasm_2_0/i8x16_ge_s.zig");
const i8x16_ge_u = @import("../instruction/wasm_2_0/i8x16_ge_u.zig");

const i32_div_s = @import("../instruction/wasm_1_0/i32_div_s.zig");
const i32_div_u = @import("../instruction/wasm_1_0/i32_div_u.zig");
const i32_rem_s = @import("../instruction/wasm_1_0/i32_rem_s.zig");
const i32_rem_u = @import("../instruction/wasm_1_0/i32_rem_u.zig");
const i64_div_s = @import("../instruction/wasm_1_0/i64_div_s.zig");
const i64_div_u = @import("../instruction/wasm_1_0/i64_div_u.zig");
const i64_rem_s = @import("../instruction/wasm_1_0/i64_rem_s.zig");
const i64_rem_u = @import("../instruction/wasm_1_0/i64_rem_u.zig");

const i32_wrap_i64 = @import("../instruction/wasm_1_0/i32_wrap_i64.zig");
const i64_extend_i32_s = @import("../instruction/wasm_1_0/i64_extend_i32_s.zig");
const i64_extend_i32_u = @import("../instruction/wasm_1_0/i64_extend_i32_u.zig");

const f32_add = @import("../instruction/wasm_1_0/f32_add.zig");
const f32_sub = @import("../instruction/wasm_1_0/f32_sub.zig");
const f32_mul = @import("../instruction/wasm_1_0/f32_mul.zig");
const f32_div = @import("../instruction/wasm_1_0/f32_div.zig");
const f64_add = @import("../instruction/wasm_1_0/f64_add.zig");
const f64_sub = @import("../instruction/wasm_1_0/f64_sub.zig");
const f64_mul = @import("../instruction/wasm_1_0/f64_mul.zig");
const f64_div = @import("../instruction/wasm_1_0/f64_div.zig");

const f32_eq = @import("../instruction/wasm_1_0/f32_eq.zig");
const f32_ne = @import("../instruction/wasm_1_0/f32_ne.zig");
const f32_lt = @import("../instruction/wasm_1_0/f32_lt.zig");
const f32_gt = @import("../instruction/wasm_1_0/f32_gt.zig");
const f32_le = @import("../instruction/wasm_1_0/f32_le.zig");
const f32_ge = @import("../instruction/wasm_1_0/f32_ge.zig");
const f64_eq = @import("../instruction/wasm_1_0/f64_eq.zig");
const f64_ne = @import("../instruction/wasm_1_0/f64_ne.zig");
const f64_lt = @import("../instruction/wasm_1_0/f64_lt.zig");
const f64_gt = @import("../instruction/wasm_1_0/f64_gt.zig");
const f64_le = @import("../instruction/wasm_1_0/f64_le.zig");
const f64_ge = @import("../instruction/wasm_1_0/f64_ge.zig");

const f32_abs = @import("../instruction/wasm_1_0/f32_abs.zig");
const f32_neg = @import("../instruction/wasm_1_0/f32_neg.zig");
const f32_sqrt = @import("../instruction/wasm_1_0/f32_sqrt.zig");
const f32_ceil = @import("../instruction/wasm_1_0/f32_ceil.zig");
const f32_floor = @import("../instruction/wasm_1_0/f32_floor.zig");
const f32_trunc = @import("../instruction/wasm_1_0/f32_trunc.zig");
const f32_nearest = @import("../instruction/wasm_1_0/f32_nearest.zig");
const f64_abs = @import("../instruction/wasm_1_0/f64_abs.zig");
const f64_neg = @import("../instruction/wasm_1_0/f64_neg.zig");
const f64_sqrt = @import("../instruction/wasm_1_0/f64_sqrt.zig");
const f64_ceil = @import("../instruction/wasm_1_0/f64_ceil.zig");
const f64_floor = @import("../instruction/wasm_1_0/f64_floor.zig");
const f64_trunc = @import("../instruction/wasm_1_0/f64_trunc.zig");
const f64_nearest = @import("../instruction/wasm_1_0/f64_nearest.zig");

const f32_min = @import("../instruction/wasm_1_0/f32_min.zig");
const f32_max = @import("../instruction/wasm_1_0/f32_max.zig");
const f64_min = @import("../instruction/wasm_1_0/f64_min.zig");
const f64_max = @import("../instruction/wasm_1_0/f64_max.zig");
const f32_copysign = @import("../instruction/wasm_1_0/f32_copysign.zig");
const f64_copysign = @import("../instruction/wasm_1_0/f64_copysign.zig");

const f32_convert_i32_s = @import("../instruction/wasm_1_0/f32_convert_i32_s.zig");
const f32_convert_i32_u = @import("../instruction/wasm_1_0/f32_convert_i32_u.zig");
const f32_convert_i64_s = @import("../instruction/wasm_1_0/f32_convert_i64_s.zig");
const f32_convert_i64_u = @import("../instruction/wasm_1_0/f32_convert_i64_u.zig");
const f64_convert_i32_s = @import("../instruction/wasm_1_0/f64_convert_i32_s.zig");
const f64_convert_i32_u = @import("../instruction/wasm_1_0/f64_convert_i32_u.zig");
const f64_convert_i64_s = @import("../instruction/wasm_1_0/f64_convert_i64_s.zig");
const f64_convert_i64_u = @import("../instruction/wasm_1_0/f64_convert_i64_u.zig");

const i32_reinterpret_f32 = @import("../instruction/wasm_1_0/i32_reinterpret_f32.zig");
const i64_reinterpret_f64 = @import("../instruction/wasm_1_0/i64_reinterpret_f64.zig");
const f32_reinterpret_i32 = @import("../instruction/wasm_1_0/f32_reinterpret_i32.zig");
const f64_reinterpret_i64 = @import("../instruction/wasm_1_0/f64_reinterpret_i64.zig");
const f32_demote_f64 = @import("../instruction/wasm_1_0/f32_demote_f64.zig");
const f64_promote_f32 = @import("../instruction/wasm_1_0/f64_promote_f32.zig");

/// Tuple of all migrated per-op modules. Order is not load-bearing;
/// `dispatcher` uses `op_tag` for routing.
pub const collected_ops = .{
    i32_add,
    i32_sub,
    i32_mul,
    i32_and,
    i32_or,
    i32_xor,
    i64_add,
    i64_sub,
    i64_mul,
    i64_and,
    i64_or,
    i64_xor,
    i32_eq,
    i32_ne,
    i32_lt_s,
    i32_lt_u,
    i32_gt_s,
    i32_gt_u,
    i32_le_s,
    i32_le_u,
    i32_ge_s,
    i32_ge_u,
    i64_eq,
    i64_ne,
    i64_lt_s,
    i64_lt_u,
    i64_gt_s,
    i64_gt_u,
    i64_le_s,
    i64_le_u,
    i64_ge_s,
    i64_ge_u,
    i32_eqz,
    i64_eqz,
    i32_shl,
    i32_shr_s,
    i32_shr_u,
    i32_rotl,
    i32_rotr,
    i64_shl,
    i64_shr_s,
    i64_shr_u,
    i64_rotl,
    i64_rotr,
    i32_clz,
    i32_ctz,
    i32_popcnt,
    i64_clz,
    i64_ctz,
    i64_popcnt,
    i32_extend8_s,
    i32_extend16_s,
    i64_extend8_s,
    i64_extend16_s,
    i64_extend32_s,
    i32_div_s,
    i32_div_u,
    i32_rem_s,
    i32_rem_u,
    i64_div_s,
    i64_div_u,
    i64_rem_s,
    i64_rem_u,
    i32_wrap_i64,
    i64_extend_i32_s,
    i64_extend_i32_u,
    f32_add,
    f32_sub,
    f32_mul,
    f32_div,
    f64_add,
    f64_sub,
    f64_mul,
    f64_div,
    f32_eq,
    f32_ne,
    f32_lt,
    f32_gt,
    f32_le,
    f32_ge,
    f64_eq,
    f64_ne,
    f64_lt,
    f64_gt,
    f64_le,
    f64_ge,
    f32_abs,
    f32_neg,
    f32_sqrt,
    f32_ceil,
    f32_floor,
    f32_trunc,
    f32_nearest,
    f64_abs,
    f64_neg,
    f64_sqrt,
    f64_ceil,
    f64_floor,
    f64_trunc,
    f64_nearest,
    f32_min,
    f32_max,
    f64_min,
    f64_max,
    f32_copysign,
    f64_copysign,
    f32_convert_i32_s,
    f32_convert_i32_u,
    f32_convert_i64_s,
    f32_convert_i64_u,
    f64_convert_i32_s,
    f64_convert_i32_u,
    f64_convert_i64_s,
    f64_convert_i64_u,
    i32_trunc_sat_f32_s,
    i32_trunc_sat_f32_u,
    i32_trunc_sat_f64_s,
    i32_trunc_sat_f64_u,
    i64_trunc_sat_f32_s,
    i64_trunc_sat_f32_u,
    i64_trunc_sat_f64_s,
    i64_trunc_sat_f64_u,
    i32_reinterpret_f32,
    i64_reinterpret_f64,
    f32_reinterpret_i32,
    f64_reinterpret_i64,
    f32_demote_f64,
    f64_promote_f32,
    v128_not,
    v128_and,
    v128_or,
    v128_xor,
    v128_andnot,
    v128_bitselect,
    i8x16_add,
    i8x16_sub,
    i16x8_add,
    i16x8_sub,
    i16x8_mul,
    i32x4_add,
    i32x4_sub,
    i32x4_mul,
    i64x2_add,
    i64x2_sub,
    i8x16_neg,
    i8x16_abs,
    i16x8_neg,
    i16x8_abs,
    i32x4_neg,
    i32x4_abs,
    i64x2_neg,
    i64x2_abs,
    i8x16_eq,
    i8x16_ne,
    i8x16_lt_s,
    i8x16_lt_u,
    i8x16_gt_s,
    i8x16_gt_u,
    i8x16_le_s,
    i8x16_le_u,
    i8x16_ge_s,
    i8x16_ge_u,
};

comptime {
    for (collected_ops) |op_mod| {
        validateOpModule(op_mod);
    }
}

/// Count of currently-migrated ops, filtered by the active build options.
/// All comptime-resolved; returns a constant for the current build.
pub fn migratedOpCount() usize {
    return comptime blk: {
        var n: usize = 0;
        for (collected_ops) |op_mod| {
            if (enabledByBuild(op_mod)) {
                n += 1;
            }
        }
        break :blk n;
    };
}

/// Count of ZirOp tags (canonical authoritative number; ~581 at Phase 9).
pub fn zirOpTagCount() usize {
    return @typeInfo(ZirOp).@"enum".fields.len;
}

/// Whether the substrate migration is complete (= every ZirOp tag has
/// a corresponding per-op module). At §9.12-B exit this returns true;
/// during §9.12-A it returns false (collected_ops is empty).
pub fn migrationComplete() bool {
    return migratedOpCount() == zirOpTagCount();
}

// ---------------------------------------------------------------------
// Dispatcher framework (per-axis).
//
// In §9.12-B, validator.zig / lower.zig / arm64/emit.zig /
// x86_64/emit.zig / interp/dispatch.zig will replace their exhaustive
// switches with thin calls to `dispatcher(.<axis>)`. The dispatcher
// inline-switches on the ZirOp tag; each arm `comptime`-resolves the
// corresponding op_mod and either invokes the handler or `continue`s
// (skipping if disabled by build option).
//
// At §9.12-A the dispatcher returns a placeholder error for every op,
// because `collected_ops` is empty. The framework compiles, gets
// covered by tests, and is ready for §9.12-B to fill in.
// ---------------------------------------------------------------------

pub const DispatchError = error{
    /// The op is not migrated to a per-op file yet (§9.12-B incomplete).
    /// Eliminated once `migrationComplete()` returns true.
    NotMigrated,
    /// The op is filtered out by the current build option set (e.g.
    /// `-Dwasm=v1_0` building Wasm 2.0+ op).
    UnsupportedOpForBuildLevel,
};

/// Populate a `DispatchTable.interp` slot from each migrated op_mod
/// whose `handlers.interp` matches the `dispatch_table.InterpFn`
/// signature. Per ADR-0073 + `.dev/dispatcher_wire_design.md` §2.4:
/// the interp axis is structurally **table-population** (function
/// pointer table indexed by ZirOp) rather than per-call switch.
///
/// At §9.12-B / B6 this function is a no-op installer: i32_add and
/// any subsequent stubs use the zero-arg `fn() DispatchError!void`
/// shape — installing them as `InterpFn` would require a wrapper
/// that returns `error.NotMigrated` to the runtime, breaking
/// real-op interp paths. The function exists so the wire-in shape
/// is in place; later B-handler-migration sub-chunks (when per-op
/// interp handlers gain the proper `(ctx, instr) anyerror!void`
/// signature) will install them here. Comptime check via
/// `@TypeOf(op_mod.handlers.interp) == @import("dispatch_table.zig").InterpFn`
/// gates each installation; stubs remain skipped.
pub fn populateDispatchTable(table: *@import("dispatch_table.zig").DispatchTable) void {
    const InterpFn = @import("dispatch_table.zig").InterpFn;
    inline for (collected_ops) |op_mod| {
        if (comptime !enabledByBuild(op_mod)) continue;
        const handler = @field(op_mod.handlers, "interp");
        if (comptime @TypeOf(handler) == InterpFn) {
            // Install; per-op handler is real, matches the runtime
            // dispatch signature.
            table.interp[@intFromEnum(op_mod.op_tag)] = handler;
        }
        // Else: per-op handler is still a stub. Skip installation;
        // legacy interp slot retains authority.
    }
}

/// Look up the per-op module for `tag` at comptime; returns null when
/// no migrated module matches. The returned `type` is the imported
/// namespace (`@import("instruction/wasm_X_Y/<op>.zig")` — a `type`
/// value in Zig); callers can read `.op_tag` / `.handlers.*` off it.
pub fn opModuleFor(comptime tag: ZirOp) ?type {
    comptime {
        for (collected_ops) |op_mod| {
            if (op_mod.op_tag == tag) {
                return op_mod;
            }
        }
        return null;
    }
}

/// Per-axis dispatch. Walks `collected_ops` at comptime, picks the
/// arm matching `op`'s tag, applies the build-option filter, and
/// invokes the axis handler with `ctx`.
///
/// Returns `error.NotMigrated` when no migrated op_mod matches the
/// tag (= the legacy dispatcher in validator/lower/emit/interp is
/// still authoritative for that op). Returns
/// `error.UnsupportedOpForBuildLevel` when a migrated op exists but
/// is filtered out by the current `-Dwasm=` / `-Dwasi=` build.
/// Otherwise propagates whatever the axis handler returned.
///
/// §9.12-B / B2 lands this function with `anyerror!void` shape; the
/// validator / lower / emit / interp call sites (B3..Bn) wrap their
/// per-axis ctx types into the call. At each axis-migration sub-chunk,
/// the legacy dispatcher in that file becomes a thin call to
/// `dispatcher(.<axis>)(op, &ctx)` that falls through to a residual
/// legacy switch only when `error.NotMigrated` is returned.
pub fn dispatcher(comptime axis: IRAxis) fn (op: ZirOp, args: anytype) DispatchError!void {
    return struct {
        fn dispatch(op: ZirOp, args: anytype) DispatchError!void {
            inline for (collected_ops) |op_mod| {
                if (comptime !enabledByBuild(op_mod)) continue;
                if (op == op_mod.op_tag) {
                    // Per-op handlers in B-sub-chunks (until they migrate
                    // to real bodies) only return DispatchError values.
                    // Once real bodies land, the dispatcher will become
                    // generic over the axis's Error set; B-pre work uses
                    // the narrow set so callers can match exhaustively.
                    return @call(.auto, @field(op_mod.handlers, @tagName(axis)), args);
                }
            }
            return DispatchError.NotMigrated;
        }
    }.dispatch;
}

// ---------------------------------------------------------------------
// Tests — exercise the framework (Step 5 gate coverage).
// ---------------------------------------------------------------------

test "zirOpTagCount matches the ZirOp enum field count" {
    const n = zirOpTagCount();
    // Phase 9 has 581 declared ZirOp tags (per ADR-0071 §Context).
    // Loose lower bound test — any drop indicates an accidental enum truncation.
    try std.testing.expect(n >= 200);
}

test "migratedOpCount tracks collected_ops length (162 after §9.12-B / B32 i8x16 cmp)" {
    // Running tally: 152 + i8x16 cmp 10 = 162.
    try std.testing.expectEqual(@as(usize, 162), migratedOpCount());
}

test "migrationComplete is false until §9.12-B migrates all 581 ops" {
    try std.testing.expect(!migrationComplete());
}

test "opModuleFor returns the registered op_mod for migrated ops" {
    // i32.add is the first per-op module migrated in §9.12-B / B1.
    const result = comptime opModuleFor(.@"i32.add");
    try std.testing.expect(result != null);
}

test "opModuleFor returns null for not-yet-migrated tags" {
    // Use a tag that's still in the legacy dispatch path. `unreachable`
    // is in the Wasm 1.0 control category — migrates in a later
    // §9.12-B sub-chunk.
    const result = comptime opModuleFor(.@"unreachable");
    try std.testing.expectEqual(@as(?type, null), result);
}

test "IRAxis enum has exactly 3 variants per ADR-0074 (Zone 1 IR-axes only)" {
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(IRAxis).@"enum".fields.len);
}

test "dispatcher(.validate) routes i32.add to its per-op stub (returns NotMigrated by design)" {
    // i32_add's validate handler is a B1 stub that returns
    // error.NotMigrated. The dispatcher finds the matching op_mod and
    // invokes the stub; the err propagates back to the caller. Once
    // B-sub-chunks implement real validate bodies, this same call
    // shape will return `void` on success.
    const result = dispatcher(.validate)(.@"i32.add", .{});
    try std.testing.expectError(error.NotMigrated, result);
}

test "dispatcher(.validate) returns NotMigrated for not-yet-migrated tags" {
    // `unreachable` is not migrated; collector returns NotMigrated so
    // the legacy validator switch retains authority.
    const result = dispatcher(.validate)(.@"unreachable", .{});
    try std.testing.expectError(error.NotMigrated, result);
}

test "populateDispatchTable is callable + no-op for current stubs" {
    // i32_add's interp handler is a zero-arg DispatchError!void stub —
    // signature doesn't match InterpFn, so populateDispatchTable
    // intentionally skips it. The table's interp slots remain all
    // null after this call.
    var table = @import("dispatch_table.zig").DispatchTable.init();
    populateDispatchTable(&table);
    try std.testing.expect(table.interp[@intFromEnum(ZirOp.@"i32.add")] == null);
}

test "dispatcher returns a callable function value per IR-axis" {
    inline for (@typeInfo(IRAxis).@"enum".fields) |f| {
        const axis: IRAxis = @enumFromInt(f.value);
        const fn_ref = dispatcher(axis);
        _ = fn_ref;
    }
}
