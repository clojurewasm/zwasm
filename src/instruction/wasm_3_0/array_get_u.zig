//! `array.get_u` — Wasm 3.0 GC proposal (array cohort).
//!
//! Per-op stub registered with `wasm_level: .v3_0`. See
//! `try_table.zig` for the comptime build-filter contract.
//!
//! Spec: Wasm Core 3.0 §3.3.13 (GC; array operations).
//!
//! Zone 1 (`src/instruction/`).

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"array.get_u";
pub const wasm_level: ?WasmLevel = .v3_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_array_get_u,
    .lower = lower_array_get_u,
    .interp = interp_array_get_u,
};

fn validate_array_get_u() collector.DispatchError!void {
    return error.NotMigrated;
}

fn lower_array_get_u() collector.DispatchError!void {
    return error.NotMigrated;
}

fn interp_array_get_u() collector.DispatchError!void {
    return error.NotMigrated;
}
