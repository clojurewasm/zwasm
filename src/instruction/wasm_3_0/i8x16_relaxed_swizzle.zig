//! `i8x16.relaxed_swizzle` — Wasm relaxed-SIMD proposal (Phase-5/W3C-Rec,
//! folded into Wasm 3.0). Spec §relaxed-simd (relaxed swizzle).
//!
//! Relaxed latitude: out-of-range index byte (≥16) yields an
//! implementation-defined result. zwasm v2 pins it to **0** (uniform across
//! arches — arm64 TBL and the x86_64 PSHUFB OOB-correction both zero it), so
//! the op is behaviourally identical to strict `i8x16.swizzle` and reuses its
//! emit. See the 17.4 bundle determinism table.
//!
//! Per-op stub registered with `wasm_level: .v3_0`. validate/lower run via the
//! legacy SIMD switch (validator_simd / lower_simd); these handlers stay
//! identity anchors. Zone 1 (`src/instruction/`).

const zir = @import("../../ir/zir.zig");
const collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;
const WasmLevel = collector.WasmLevel;
const WasiLevel = collector.WasiLevel;
const Feature = collector.Feature;

pub const op_tag: ZirOp = .@"i8x16.relaxed_swizzle";
pub const wasm_level: ?WasmLevel = .v3_0;
pub const wasi_level: ?WasiLevel = null;
pub const enable_features: []const Feature = &.{};

pub const handlers = .{
    .validate = validate_i8x16_relaxed_swizzle,
    .lower = lower_i8x16_relaxed_swizzle,
    .interp = interp_i8x16_relaxed_swizzle,
};

fn validate_i8x16_relaxed_swizzle() collector.DispatchError!void {
    return error.NotMigrated;
}
fn lower_i8x16_relaxed_swizzle() collector.DispatchError!void {
    return error.NotMigrated;
}
fn interp_i8x16_relaxed_swizzle() collector.DispatchError!void {
    return error.NotMigrated;
}
