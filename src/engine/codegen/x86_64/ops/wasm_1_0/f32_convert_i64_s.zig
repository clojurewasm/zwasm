//! x86_64 emit handler for `f32.convert_i64_s` — Zone 2 per-arch
//! op file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/f32_convert_i64_s.zig`.
//! Delegates to `op_convert.emitF32ConvertI64S` (alias of the
//! simple-path adapter wrapping `emitFpConvertSimple`).
//!
//! Wasm spec §4.3 (f32.convert_i64_s) — signed i64→f32.
//! Intel SDM Vol 2A `CVTSI2SS xmm, r/m64` (REX.W).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/f32_convert_i64_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitF32ConvertI64S(ctx, ins);
}
