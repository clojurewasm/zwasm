//! x86_64 emit handler for `ref.is_null`.
//! Delegates to op_alu_int.emitI64EqzCtx (same body as i64.eqz).

const meta = @import("../../../../../instruction/wasm_1_0/ref_is_null.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitI64EqzCtx(ctx, ins);
}
