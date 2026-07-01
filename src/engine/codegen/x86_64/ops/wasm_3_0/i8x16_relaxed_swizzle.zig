//! x86_64 emit handler for `i8x16.relaxed_swizzle`.
//! OOB index → 0: the strict-swizzle PSHUFB control-mask correction already
//! zeroes idx ≥16 (PCMPGTB+POR sets bit7; ≥128 zeroes natively), matching the
//! v2 deterministic choice — reuse emitI8x16SwizzleCtx.

const meta = @import("../../../../../instruction/wasm_3_0/i8x16_relaxed_swizzle.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_int_cmp_lane = @import("../../op_simd_int_cmp_lane.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_int_cmp_lane.emitI8x16SwizzleCtx(ctx, ins);
}
