//! x86_64 emit handler for `i64.trunc_f64_u` — Zone 2 per-arch op
//! file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/i64_trunc_f64_u.zig`.
//! The emit body delegates to `op_convert.emitI64TruncF64U`, which
//! threads `ctx.bounds_fixups`.
//!
//! Wasm spec §4.3 (i64.trunc_f64_u) — trapping unsigned f64→i64.
//! Traps on NaN, src ≤ -1, src ≥ 2^64.
//! Intel SDM Vol 2A — 2^63 split path mirrors `i64.trunc_f32_u`.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i64_trunc_f64_u.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitI64TruncF64U(ctx, ins);
}
