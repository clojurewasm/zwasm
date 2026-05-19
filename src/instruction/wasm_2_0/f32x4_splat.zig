//! `f32x4.splat` — Per-op file (Zone 1 identity anchor)
//! per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"f32x4.splat";
pub const wasm_level: ?WasmLevel = .v2_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_f32x4_splat,
    .lower = lower_f32x4_splat,
    .interp = interp_f32x4_splat,
};

fn validate_f32x4_splat() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_f32x4_splat() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_f32x4_splat() collector.DispatchError!void {
    return error.NotMigrated;
}
