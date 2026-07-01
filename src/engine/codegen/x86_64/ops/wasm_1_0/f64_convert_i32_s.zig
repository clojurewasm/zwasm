//! x86_64 emit handler for `f64.convert_i32_s` — Zone 2 per-arch
//! op file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/f64_convert_i32_s.zig`.
//! Delegates to `op_convert.emitF64ConvertI32S` (alias of the
//! simple-path adapter wrapping `emitFpConvertSimple`).
//!
//! Wasm spec §4.3 (f64.convert_i32_s) — signed i32→f64.
//! Intel SDM Vol 2A `CVTSI2SD xmm, r/m32`.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/f64_convert_i32_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitF64ConvertI32S(ctx, ins);
}
