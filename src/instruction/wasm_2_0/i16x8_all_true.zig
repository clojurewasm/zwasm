//! `i16x8.all_true` — Wasm 2.0 SIMD bool-reduction op. Per-op file (Zone 1
//! identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i16x8.all_true";
pub const wasm_level: ?WasmLevel = .v2_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i16x8_all_true,
    .lower = lower_i16x8_all_true,
    .interp = interp_i16x8_all_true,
};

fn validate_i16x8_all_true() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_i16x8_all_true() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_i16x8_all_true() collector.DispatchError!void {
    return error.NotMigrated;
}
