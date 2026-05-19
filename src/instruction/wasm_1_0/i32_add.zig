//! `i32.add` — Wasm 1.0 §5.4.5 numeric op.
//!
//! Canonical per-op file shape — the §9.12-B Q3 C adoption reference
//! template (per ADR-0023 §4.5 amend + ADR-0073 + ADR-0074). Every
//! Wasm 1.0/2.0 op file under `src/instruction/wasm_X_Y/<op>.zig`
//! mirrors this structure:
//!
//!   pub const op_tag: ZirOp = ...;
//!   pub const wasm_level: ?WasmLevel = ...;
//!   pub const wasi_level: ?WasiLevel = ...;
//!   pub const enable_features: []const Feature = &.{};
//!   pub const handlers = .{
//!       .validate = validate_<op>,
//!       .lower    = lower_<op>,
//!       .interp   = interp_<op>,
//!   };
//!
//! Per ADR-0074 (B9 amend) the arm64 / x86_64 emit handlers live at
//! Zone 2 in dedicated per-arch op files:
//!
//!   src/engine/codegen/arm64/ops/wasm_X_Y/<op>.zig
//!   src/engine/codegen/x86_64/ops/wasm_X_Y/<op>.zig
//!
//! …so the Zone 1 ↔ Zone 2 boundary is preserved while comptime DCE
//! works on every axis.
//!
//! §9.12-B / B10 lands this file with **stub** handlers that return
//! `error.NotMigrated`. The dispatch_collector framework validates the
//! shape; the live dispatch path still routes through the legacy
//! switches in validator.zig / lower.zig / interp/dispatch.zig until
//! the per-axis migration sub-chunks (B11..Bn) replace each one.
//!
//! Zone 1 (`src/instruction/`).

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i32.add";
pub const wasm_level: ?WasmLevel = .v1_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i32_add,
    .lower = lower_i32_add,
    .interp = interp_i32_add,
};

// ---------------------------------------------------------------------
// Per-axis handlers — stubs.
//
// At B10 the legacy dispatch path (validator.zig / lower.zig /
// interp/dispatch.zig) retains authority. Until B11..Bn migrate each
// axis, these stubs are unreachable from production code and only
// exist to satisfy the `validateOpModule` comptime contract.
// ---------------------------------------------------------------------

fn validate_i32_add() collector.DispatchError!void {
    return error.NotMigrated;
}

fn lower_i32_add() collector.DispatchError!void {
    return error.NotMigrated;
}

fn interp_i32_add() collector.DispatchError!void {
    return error.NotMigrated;
}
