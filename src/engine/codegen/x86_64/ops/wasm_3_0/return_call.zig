//! x86_64 emit handler for `return_call` — Zone 2 per ADR-0074
//! + ADR-0112 D2.
//!
//! Wasm spec 3.0 §3.3.8.18. Frame teardown (ADD RSP + POP R15 +
//! POP RBP — mirror of regular epilogue minus RET) before the
//! branch; same-module direct case uses `JMP rel32` (linker-
//! patched via CallFixup{is_tail=true}) instead of D4's
//! prescribed `JMP R11` (the rel32 path is shorter for the in-
//! module case where the linker has the body offset; cross-
//! module / indirect / ref take the JMP R11 path through
//! follow-on chunks).
//!
//! Delegation per ADR-0112 D2: orchestration lives in
//! `x86_64/op_tail_call.emitDirectReturnCall`; this file stays
//! the dispatch-table entry point.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_3_0/return_call.zig");
const ctx_mod = @import("../../ctx.zig");
const op_tail_call = @import("../../op_tail_call.zig");
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
    try op_tail_call.emitDirectReturnCall(ctx, ins);
    ctx.dead_code.* = true;
}
