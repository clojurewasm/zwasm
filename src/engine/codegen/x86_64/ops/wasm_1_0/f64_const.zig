//! x86_64 emit handler for `f64.const` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/f64_const.zig`.
//! Delegates to `op_alu_float.emitF64Const`. Pushes the immediate as a
//! fresh vreg.
//!
//! Wasm spec §4.4.1.1 (f64.const).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/f64_const.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_float = @import("../../op_alu_float.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_float.emitF64Const(ctx, ins);
}
