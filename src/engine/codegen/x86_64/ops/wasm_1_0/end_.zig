//! x86_64 emit handler for `end` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/end_.zig`.
//! Delegates to `op_control.emitEndCtx`, which dispatches between
//! the intra-function form (label pop + fixup patch) and the
//! function-level form (marshal + epilogue + trap stub + SIMD
//! const-pool). Body-loop break for the function-level form
//! lives in emit.zig's dispatch arm (snapshot labels.len pre-call).
//!
//! Wasm spec §3.4.4 (end) / §4.4.7 (function-final end).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/end_.zig");
const ctx_mod = @import("../../ctx.zig");
const op_control = @import("../../op_control.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_control.emitEndCtx(ctx, ins);
}
