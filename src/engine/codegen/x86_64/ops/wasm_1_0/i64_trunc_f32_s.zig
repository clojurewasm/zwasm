//! x86_64 emit handler for `i64.trunc_f32_s` — Zone 2 per-arch op
//! file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/i64_trunc_f32_s.zig`.
//! The emit body delegates to `op_convert.emitI64TruncF32S`, which
//! threads `ctx.bounds_fixups` for the NaN / upper-bound / lower-
//! bound trap placeholders.
//!
//! Wasm spec §4.3 (i64.trunc_f32_s) — trapping signed f32→i64.
//! Traps on NaN, src ≥ 2^63, src < -2^63.
//! Intel SDM Vol 2A `CVTTSS2SI r64, xmm/m32` — in-range path.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i64_trunc_f32_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitI64TruncF32S(ctx, ins);
}
