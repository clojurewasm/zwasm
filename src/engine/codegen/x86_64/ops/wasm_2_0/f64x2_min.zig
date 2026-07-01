//! x86_64 emit handler for `f64x2.min`.
//! Delegates to op_simd_float.emitF64x2MinCtx.

const meta = @import("../../../../../instruction/wasm_2_0/f64x2_min.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_float = @import("../../op_simd_float.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_float.emitF64x2MinCtx(ctx, ins);
}
