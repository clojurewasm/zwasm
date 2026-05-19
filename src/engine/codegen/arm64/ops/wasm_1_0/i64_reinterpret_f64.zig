//! arm64 emit handler for `i64.reinterpret_f64` — Zone 2 per ADR-0074.
//! Delegates to op_convert.emitReinterpretI64FromF64.

const meta = @import("../../../../../instruction/wasm_1_0/i64_reinterpret_f64.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitReinterpretI64FromF64(ctx, ins);
}
