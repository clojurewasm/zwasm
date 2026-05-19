//! `v128.any_true` — Wasm 2.0 SIMD bool-reduction op. Per-op file (Zone 1
//! identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"v128.any_true";
pub const wasm_level: ?WasmLevel = .v2_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_v128_any_true,
    .lower = lower_v128_any_true,
    .interp = interp_v128_any_true,
};

fn validate_v128_any_true() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_v128_any_true() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_v128_any_true() collector.DispatchError!void {
    return error.NotMigrated;
}
