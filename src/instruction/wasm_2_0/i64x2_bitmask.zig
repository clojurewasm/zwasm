//! `i64x2.bitmask` — Wasm 2.0 SIMD bool-reduction op. Per-op file (Zone 1
//! identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i64x2.bitmask";
pub const wasm_level: ?WasmLevel = .v2_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i64x2_bitmask,
    .lower = lower_i64x2_bitmask,
    .interp = interp_i64x2_bitmask,
};

fn validate_i64x2_bitmask() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_i64x2_bitmask() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_i64x2_bitmask() collector.DispatchError!void {
    return error.NotMigrated;
}
