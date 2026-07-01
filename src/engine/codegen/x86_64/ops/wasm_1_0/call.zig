//! x86_64 emit handler for `call` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/call.zig`.
//! Delegates to `op_call.emitCallCtx`. Direct call: marshals
//! args per CC; CALL rel32 (fixed up via `ctx.call_fixups`);
//! host-import dispatch when `callee_idx < num_imports`.
//!
//! Wasm spec §3.4.7 (call N).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/call.zig");
const ctx_mod = @import("../../ctx.zig");
const op_call = @import("../../op_call.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A — regalloc 3-axis classification. `call` is a
// regular function call: it returns to the caller (NOT a
// terminator), has 1 normal-return successor edge (no extra
// EH / catch edges), and IS a safepoint for GC root walking
// (per ADR-0115/0116). Per-op declaration so future regalloc
// passes can read the axes without a separate metadata table.
pub const is_terminator: bool = false;
pub const n_successor_edges: u8 = 1;
pub const is_safepoint: bool = true;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_call.emitCallCtx(ctx, ins);
}
