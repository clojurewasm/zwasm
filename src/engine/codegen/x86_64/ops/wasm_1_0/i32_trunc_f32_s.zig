//! x86_64 emit handler for `i32.trunc_f32_s` — Zone 2 per-arch op
//! file per ADR-0074 + ADR-0075.
//!
//! Identity anchor (`op_tag`, `wasm_level`, `wasi_level`) lives at
//! `src/instruction/wasm_1_0/i32_trunc_f32_s.zig` (Zone 1). The
//! emit body delegates to `op_convert.emitI32TruncF32S`, which
//! threads `ctx.bounds_fixups` for the NaN / upper-bound /
//! lower-bound trap placeholders.
//!
//! Wasm spec §4.3 (i32.trunc_f32_s) — trapping signed f32→i32.
//! Traps on NaN, src ≥ 2^31, src < -2^31.
//! Intel SDM Vol 2A `CVTTSS2SI r32, xmm/m32` — truncate-toward-zero
//! convert (in-range path).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`;
//! the B6x+1 cutover folds that tuple back into the unified
//! `collected_x86_64_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i32_trunc_f32_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitI32TruncF32S(ctx, ins);
}
