//! x86_64 emit handler for `i16x8.extmul.low.i8x16.u`.
//! Delegates to op_simd_int_cmp_lane.emitI16x8ExtmulLowI8x16UCtx.

const meta = @import("../../../../../instruction/wasm_2_0/i16x8_extmul_low_i8x16_u.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_int_cmp_lane = @import("../../op_simd_int_cmp_lane.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_int_cmp_lane.emitI16x8ExtmulLowI8x16UCtx(ctx, ins);
}
