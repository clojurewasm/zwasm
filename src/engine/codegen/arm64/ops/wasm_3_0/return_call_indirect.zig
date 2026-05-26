//! arm64 emit handler for `return_call_indirect` — Zone 2 per
//! ADR-0074 + ADR-0112 D2.
//!
//! Wasm spec 3.0 §3.3.8.19 (tail-call proposal). Pop index from
//! the operand stack, bounds + sig check, then frame teardown
//! and BR X16 to the resolved funcptr.
//!
//! Stub: emit returns `UnsupportedOp` until the shared
//! `op_tail_call.zig` + `frame_teardown.zig` helpers land.
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

const meta = @import("../../../../../instruction/wasm_3_0/return_call_indirect.zig");
const ctx_mod = @import("../../ctx.zig");
const op_tail_call = @import("../../op_tail_call.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A — terminator axis like `return_call`. The bounds /
// sig checks trap on failure (a trap edge is not counted as a
// CFG successor for regalloc); on success the tail-jump leaves
// the function. NOT a safepoint per ADR-0112 D7.
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_tail_call.emitIndirectReturnCall(ctx, ins);
}
