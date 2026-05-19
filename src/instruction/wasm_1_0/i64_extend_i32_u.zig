//! `i64.extend_i32_u` — Wasm 1.0 numeric width-conversion op. Per-op file
//! (Zone 1 identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i64.extend_i32_u";
pub const wasm_level: ?WasmLevel = .v1_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i64_extend_i32_u,
    .lower = lower_i64_extend_i32_u,
    .interp = interp_i64_extend_i32_u,
};

fn validate_i64_extend_i32_u() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_i64_extend_i32_u() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_i64_extend_i32_u() collector.DispatchError!void {
    return error.NotMigrated;
}
