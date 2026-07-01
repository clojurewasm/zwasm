//! x86_64 emit handler for `i32x4.trunc.sat.f32x4.u`.
//! Delegates to op_simd_float.emitI32x4TruncSatF32x4UCtx.

const meta = @import("../../../../../instruction/wasm_2_0/i32x4_trunc_sat_f32x4_u.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_float = @import("../../op_simd_float.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_float.emitI32x4TruncSatF32x4UCtx(ctx, ins);
}
