//! x86_64 emit handler for `i16x8.narrow.i32x4.s`.
//! Delegates to op_simd_int_cmp_lane.emitI16x8NarrowI32x4SCtx.

const meta = @import("../../../../../instruction/wasm_2_0/i16x8_narrow_i32x4_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_int_cmp_lane = @import("../../op_simd_int_cmp_lane.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_int_cmp_lane.emitI16x8NarrowI32x4SCtx(ctx, ins);
}
