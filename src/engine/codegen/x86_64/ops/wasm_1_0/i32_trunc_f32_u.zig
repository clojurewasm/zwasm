//! x86_64 emit handler for `i32.trunc_f32_u` — Zone 2 per-arch op
//! file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/i32_trunc_f32_u.zig`.
//! The emit body delegates to `op_convert.emitI32TruncF32U`, which
//! threads `ctx.bounds_fixups` for the NaN / lower(-1) / upper(2^32)
//! trap placeholders.
//!
//! Wasm spec §4.3 (i32.trunc_f32_u) — trapping unsigned f32→i32.
//! Traps on NaN, src ≤ -1, src ≥ 2^32.
//! Intel SDM Vol 2A `CVTTSS2SI r64, xmm/m32` (`.q` form so the
//! positive range [0, 2^32) fits in i64 directly; low 32 bits give
//! the u32 result).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i32_trunc_f32_u.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitI32TruncF32U(ctx, ins);
}
