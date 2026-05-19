//! arm64 emit handler for `i64.extend8_s` — Zone 2 per ADR-0074.
//! Delegates to op_alu_int.emitI64Extend8S.

const meta = @import("../../../../../instruction/wasm_2_0/i64_extend8_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitI64Extend8S(ctx, ins);
}
