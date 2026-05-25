//! arm64 emit handler for `call` — Zone 2 per ADR-0074.

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
    return op_call.emitCall(ctx, ins);
}
