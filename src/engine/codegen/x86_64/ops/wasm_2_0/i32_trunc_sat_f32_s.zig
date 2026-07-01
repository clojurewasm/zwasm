//! x86_64 emit handler for `i32.trunc_sat_f32_s` — Zone 2
//! per-arch op file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_2_0/i32_trunc_sat_f32_s.zig`.
//! The emit body delegates to `op_convert.emitI32TruncSatF32S`,
//! which wraps the saturating signed `emitFpTruncSatSigned` helper
//! (CVTTSS2SI + sentinel detection; non-trapping).
//!
//! Wasm spec §4.3 (i32.trunc_sat_f32_s) — non-trapping saturating
//! signed f32→i32. NaN→0, ≥2^31→INT_MAX, <-2^31→INT_MIN.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_2_0/i32_trunc_sat_f32_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitI32TruncSatF32S(ctx, ins);
}
