//! x86_64 emit handler for `i64.extend16.s`.
//! Delegates to op_alu_int.emitSignExtendCtx.

const meta = @import("../../../../../instruction/wasm_2_0/i64_extend16_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitSignExtendCtx(ctx, ins);
}
