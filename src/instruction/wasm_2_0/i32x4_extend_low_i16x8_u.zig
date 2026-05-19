//! `i32x4.extend_low_i16x8_u` — Wasm 2.0 SIMD narrow/extend op. Per-op file (Zone 1
//! identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i32x4.extend_low_i16x8_u";
pub const wasm_level: ?WasmLevel = .v2_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i32x4_extend_low_i16x8_u,
    .lower = lower_i32x4_extend_low_i16x8_u,
    .interp = interp_i32x4_extend_low_i16x8_u,
};

fn validate_i32x4_extend_low_i16x8_u() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_i32x4_extend_low_i16x8_u() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_i32x4_extend_low_i16x8_u() collector.DispatchError!void {
    return error.NotMigrated;
}
