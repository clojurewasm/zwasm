//! `br_on_cast_fail` — Wasm 3.0 GC proposal (ref/cast + i31 cohort).
//!
//! Per-op stub registered with `wasm_level: .v3_0`. See
//! `try_table.zig` for the comptime build-filter contract.
//!
//! Spec: Wasm Core 3.0 §3.3.14 (GC; reference type tests / casts /
//! ext-conversions / i31 unboxing).
//!
//! Zone 1 (`src/instruction/`).

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .br_on_cast_fail;
pub const wasm_level: ?WasmLevel = .v3_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_br_on_cast_fail,
    .lower = lower_br_on_cast_fail,
    .interp = interp_br_on_cast_fail,
};

fn validate_br_on_cast_fail() collector.DispatchError!void {
    return error.NotMigrated;
}

fn lower_br_on_cast_fail() collector.DispatchError!void {
    return error.NotMigrated;
}

fn interp_br_on_cast_fail() collector.DispatchError!void {
    return error.NotMigrated;
}
