//! `i32.add` — Wasm 1.0 §5.4.5 numeric op.
//!
//! Canonical per-op file shape, the §9.12-B Q3 C adoption reference
//! template (per ADR-0023 §4.5 amend + ADR-0073). Every Wasm 1.0/2.0
//! op file under `src/instruction/wasm_X_Y/<op>.zig` mirrors this
//! structure:
//!
//!   pub const op_tag: ZirOp = ...;
//!   pub const wasm_level: ?WasmLevel = ...;
//!   pub const wasi_level: ?WasiLevel = ...;
//!   pub const enable_features: []const Feature = &.{};
//!   pub const handlers = .{
//!       .validate = validate_<op>,
//!       .lower    = lower_<op>,
//!       .arm64    = emit_arm64_<op>,
//!       .x86_64   = emit_x86_64_<op>,
//!       .interp   = interp_<op>,
//!   };
//!
//! §9.12-B / B1 lands the first per-op file with **stub** handlers
//! that return `error.NotMigrated`. The dispatch_collector framework
//! validates the shape; the live dispatch path still routes through
//! the legacy switches in validator.zig / lower.zig / arm64/emit.zig
//! / x86_64/emit.zig / interp/dispatch.zig until the per-axis
//! migration sub-chunks (B2..B?) replace each one.
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
    .arm64 = emit_arm64_i32_add,
    .x86_64 = emit_x86_64_i32_add,
    .interp = interp_i32_add,
};

// ---------------------------------------------------------------------
// Per-axis handlers — stubs.
//
// At B1 the legacy dispatch path (validator.zig / lower.zig / etc.)
// retains authority. Until B2..Bn migrate each axis, these stubs are
// unreachable from production code and only exist to satisfy the
// `validateOpModule` comptime contract.
//
// `ctx: anytype` keeps the framework signature flexible until the
// real ctx types are pinned down at each axis-migration sub-chunk
// (the legacy modules each use their own ctx type today).
// ---------------------------------------------------------------------

// Stubs use zero parameters so the dispatcher's `@call(.auto, fn,
// args_tuple)` can be invoked with `.{}` (an empty tuple) and the
// per-op signature matches. Once real handler bodies migrate
// (B9..Bn), the dispatcher signature widens to accept per-axis ctx
// tuples and these zero-param stubs gain the appropriate args.
fn validate_i32_add() collector.DispatchError!void {
    return error.NotMigrated;
}

fn lower_i32_add() collector.DispatchError!void {
    return error.NotMigrated;
}

fn emit_arm64_i32_add() collector.DispatchError!void {
    return error.NotMigrated;
}

fn emit_x86_64_i32_add() collector.DispatchError!void {
    return error.NotMigrated;
}

fn interp_i32_add() collector.DispatchError!void {
    return error.NotMigrated;
}
