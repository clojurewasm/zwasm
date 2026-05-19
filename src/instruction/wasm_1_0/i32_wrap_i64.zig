//! `i32.wrap_i64` — Wasm 1.0 numeric width-conversion op. Per-op file
//! (Zone 1 identity anchor) per ADR-0023 §4.5 amend + ADR-0074.

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i32.wrap_i64";
pub const wasm_level: ?WasmLevel = .v1_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i32_wrap_i64,
    .lower = lower_i32_wrap_i64,
    .interp = interp_i32_wrap_i64,
};

fn validate_i32_wrap_i64() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_i32_wrap_i64() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_i32_wrap_i64() collector.DispatchError!void {
    return error.NotMigrated;
}
