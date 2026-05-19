//! `v128.bitselect` — Wasm 2.0 SIMD v128 logical op. Per-op file (Zone 1
//! identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"v128.bitselect";
pub const wasm_level: ?WasmLevel = .v2_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_v128_bitselect,
    .lower = lower_v128_bitselect,
    .interp = interp_v128_bitselect,
};

fn validate_v128_bitselect() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_v128_bitselect() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_v128_bitselect() collector.DispatchError!void {
    return error.NotMigrated;
}
