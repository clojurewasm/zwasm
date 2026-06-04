//! arm64 emit handler for `i64x2.extmul_high_i32x4_u` — Zone 2 per ADR-0074.
//! Delegates to op_simd_int_arith.emitI64x2ExtmulHighI32x4U.

const meta = @import("../../../../../instruction/wasm_2_0/i64x2_extmul_high_i32x4_u.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_int_arith = @import("../../op_simd_int_arith.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_int_arith.emitI64x2ExtmulHighI32x4U(ctx, ins);
}
