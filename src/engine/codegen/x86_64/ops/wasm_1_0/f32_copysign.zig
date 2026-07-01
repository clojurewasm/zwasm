//! x86_64 emit handler for `f32.copysign`.
//! Delegates to op_alu_float.emitFpCopysignCtx.

const meta = @import("../../../../../instruction/wasm_1_0/f32_copysign.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_float = @import("../../op_alu_float.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_float.emitFpCopysignCtx(ctx, ins);
}
