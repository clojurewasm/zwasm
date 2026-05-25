//! arm64 emit handler for `return_call` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0112 D2 (separate `op_tail_call.zig` shape;
//! not an extension of `op_call.zig`).
//!
//! Wasm spec 3.0 §3.3.8.18 (tail-call proposal). Frame teardown
//! before the branch (vs after for regular `call`): consume
//! caller's frame, BR X16 directly to callee — no LR, callee
//! returns to caller's caller.
//!
//! Currently a stub: emit returns `UnsupportedOp`. Real body
//! lands in a follow-up chunk once `engine/codegen/shared/
//! frame_teardown.zig` + `engine/codegen/arm64/op_tail_call.zig`
//! land (ADR-0112 D3).
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

const meta = @import("../../../../../instruction/wasm_3_0/return_call.zig");
const ctx_mod = @import("../../ctx.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A — regalloc 3-axis classification. `return_call`
// is a terminator: it consumes the caller's frame and BRanches
// without LR, so no fallthrough exists. Zero successor edges
// (the branch target is the callee, but the regalloc
// successor-edge axis counts in-function CFG edges; tail-call
// leaves the function). NOT a safepoint per ADR-0112 D7 (no
// allocator / host-call / signal-check between teardown and
// jump — comptime-asserted).
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ctx;
    _ = ins;
    return error.UnsupportedOp;
}
