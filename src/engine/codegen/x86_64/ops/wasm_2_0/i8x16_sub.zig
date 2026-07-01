//! x86_64 emit handler for `i8x16.sub`.
//! Delegates to op_simd_int_arith.emitI8x16SubCtx.

const meta = @import("../../../../../instruction/wasm_2_0/i8x16_sub.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_int_arith = @import("../../op_simd_int_arith.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_int_arith.emitI8x16SubCtx(ctx, ins);
}
