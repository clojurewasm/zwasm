//! `f32.sqrt` — Wasm 1.0 float unary op. Per-op file (Zone 1
//! identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"f32.sqrt";
pub const wasm_level: ?WasmLevel = .v1_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_f32_sqrt,
    .lower = lower_f32_sqrt,
    .interp = interp_f32_sqrt,
};

fn validate_f32_sqrt() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_f32_sqrt() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_f32_sqrt() collector.DispatchError!void {
    return error.NotMigrated;
}
