//! `i8x16.le_s` — Wasm 2.0 SIMD int compare op. Per-op file (Zone 1
//! identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i8x16.le_s";
pub const wasm_level: ?WasmLevel = .v2_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i8x16_le_s,
    .lower = lower_i8x16_le_s,
    .interp = interp_i8x16_le_s,
};

fn validate_i8x16_le_s() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_i8x16_le_s() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_i8x16_le_s() collector.DispatchError!void {
    return error.NotMigrated;
}
