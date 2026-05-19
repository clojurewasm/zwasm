//! arm64 emit handler for `call_indirect` — Zone 2 per ADR-0074.

const meta = @import("../../../../../instruction/wasm_1_0/call_indirect.zig");
const ctx_mod = @import("../../ctx.zig");
const op_call = @import("../../op_call.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_call.emitCallIndirect(ctx, ins);
}
