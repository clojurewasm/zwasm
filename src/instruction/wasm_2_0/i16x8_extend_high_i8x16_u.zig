//! `i16x8.extend_high_i8x16_u` — Wasm 2.0 SIMD narrow/extend op. Per-op file (Zone 1
//! identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i16x8.extend_high_i8x16_u";
pub const wasm_level: ?WasmLevel = .v2_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i16x8_extend_high_i8x16_u,
    .lower = lower_i16x8_extend_high_i8x16_u,
    .interp = interp_i16x8_extend_high_i8x16_u,
};

fn validate_i16x8_extend_high_i8x16_u() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_i16x8_extend_high_i8x16_u() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_i16x8_extend_high_i8x16_u() collector.DispatchError!void {
    return error.NotMigrated;
}
