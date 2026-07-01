//! x86_64 emit handler for `i64.trunc_sat_f32_u` — Zone 2
//! per-arch op file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_2_0/i64_trunc_sat_f32_u.zig`.
//! Delegates to `op_convert.emitI64TruncSatF32U`, which wraps the
//! unsigned-to-i64 helper (`emitFpTruncSatU64` — 2^63 split path).
//!
//! Wasm spec §4.3 (i64.trunc_sat_f32_u) — non-trapping saturating
//! unsigned f32→i64. NaN→0, ≤-1→0, ≥2^64→UINT64_MAX.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_2_0/i64_trunc_sat_f32_u.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitI64TruncSatF32U(ctx, ins);
}
