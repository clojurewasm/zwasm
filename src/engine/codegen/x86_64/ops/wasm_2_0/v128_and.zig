//! x86_64 emit handler for `v128.and`.
//! Delegates to op_simd.emitV128AndCtx.

const meta = @import("../../../../../instruction/wasm_2_0/v128_and.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd = @import("../../op_simd.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd.emitV128AndCtx(ctx, ins);
}
