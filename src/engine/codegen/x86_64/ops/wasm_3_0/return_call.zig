//! x86_64 emit handler for `return_call` — Zone 2 per ADR-0074
//! + ADR-0112 D2.
//!
//! Wasm spec 3.0 §3.3.8.18. Frame teardown (POP callee-saved +
//! POP RBP) before the branch; `JMP R11` directly to callee —
//! no return address on the stack, callee returns to caller's
//! caller (per ADR-0112 D4 x86_64 shape).
//!
//! Stub: emit returns `UnsupportedOp`. Real body lands once the
//! shared `op_tail_call.zig` + `frame_teardown.zig` helpers
//! land (ADR-0112 D3).
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_3_0/return_call.zig");
const ctx_mod = @import("../../ctx.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A — terminator axis: tail-jump leaves the function.
// NOT a safepoint per ADR-0112 D7 (safepoint-free invariant
// between teardown and JMP).
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ctx;
    _ = ins;
    return error.UnsupportedOp;
}
