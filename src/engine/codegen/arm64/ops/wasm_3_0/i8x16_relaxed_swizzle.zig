//! arm64 emit handler for `i8x16.relaxed_swizzle` — Zone 2 per ADR-0074.
//! OOB index → 0 (NEON TBL native): identical to strict swizzle, reuse emit.

const meta = @import("../../../../../instruction/wasm_3_0/i8x16_relaxed_swizzle.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_int_cmp_lane = @import("../../op_simd_int_cmp_lane.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_int_cmp_lane.emitI8x16Swizzle(ctx, ins);
}
