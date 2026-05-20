//! x86_64 emit handler for `br` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075 (B75 br family migration to `(ctx, ins)`).
//!
//! Identity anchor at `src/instruction/wasm_1_0/br.zig`.
//! Delegates to `op_control.emitBrCtx`. All ctx fields (frame_bytes,
//! uses_runtime_ptr, labels, etc.) already exist post-B74.
//!
//! Wasm spec §3.4.6 / §4.4.7 (br).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/br.zig");
const ctx_mod = @import("../../ctx.zig");
const op_control = @import("../../op_control.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_control.emitBrCtx(ctx, ins);
}
