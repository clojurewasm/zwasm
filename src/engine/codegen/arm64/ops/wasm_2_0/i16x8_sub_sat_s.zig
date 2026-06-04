//! arm64 emit handler for `i16x8.sub_sat_s` — Zone 2 per ADR-0074.
//! Delegates to op_simd_int_arith.emitI16x8SubSatS.

const meta = @import("../../../../../instruction/wasm_2_0/i16x8_sub_sat_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd_int_arith = @import("../../op_simd_int_arith.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd_int_arith.emitI16x8SubSatS(ctx, ins);
}
