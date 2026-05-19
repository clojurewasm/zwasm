//! arm64 emit handler for `i64.extend_i32_s` — Zone 2 per ADR-0074.
//! Delegates to op_convert.emitExtendI32S.

const meta = @import("../../../../../instruction/wasm_1_0/i64_extend_i32_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_convert = @import("../../op_convert.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_convert.emitExtendI32S(ctx, ins);
}
