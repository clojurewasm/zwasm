//! x86_64 emit handler for `return_call_indirect` — Zone 2 per
//! ADR-0074 + ADR-0112 D2.
//!
//! Wasm spec 3.0 §3.3.8.19. Pop index, bounds + sig check, then
//! frame teardown and `JMP R11` to the resolved funcptr.
//!
//! Stub: emit returns `UnsupportedOp`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_3_0/return_call_indirect.zig");
const ctx_mod = @import("../../ctx.zig");
const op_tail_call = @import("../../op_tail_call.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A — terminator axis like `return_call`.
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    try op_tail_call.emitIndirectReturnCall(ctx, ins);
    ctx.dead_code.* = true;
}
