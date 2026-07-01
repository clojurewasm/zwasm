//! x86_64 emit handler for `f32x4.nearest`.
//! Delegates to op_simd_float.emitF32x4NearestCtx.

const meta = @import("../../../../../instruction/wasm_2_0/f32x4_nearest.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_float = @import("../../op_simd_float.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_float.emitF32x4NearestCtx(ctx, ins);
}
