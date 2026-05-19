//! arm64 emit handler for `v128.not` — Zone 2 per ADR-0074.
//! Delegates to op_simd.emitV128Not.

const meta = @import("../../../../../instruction/wasm_2_0/v128_not.zig");
const ctx_mod = @import("../../ctx.zig");
const op_simd = @import("../../op_simd.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_simd.emitV128Not(ctx, ins);
}
