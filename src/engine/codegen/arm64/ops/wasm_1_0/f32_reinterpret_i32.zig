//! arm64 emit handler for `f32.reinterpret_i32` — Zone 2 per ADR-0074.
//! Delegates to op_convert.emitReinterpretF32FromI32.

const meta = @import("../../../../../instruction/wasm_1_0/f32_reinterpret_i32.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitReinterpretF32FromI32(ctx, ins);
}
