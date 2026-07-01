//! x86_64 emit handler for `block` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/block.zig`.
//! Delegates to `op_control.emitBlockCtx`. Pushes a forward-jump
//! label frame onto `ctx.labels`; pending `br` fixups land in
//! `label.pending` and get patched at the matching `end`.
//!
//! Wasm spec §3.4.6 (block bt).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/block.zig");
const ctx_mod = @import("../../ctx.zig");
const op_control = @import("../../op_control.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_control.emitBlockCtx(ctx, ins);
}
