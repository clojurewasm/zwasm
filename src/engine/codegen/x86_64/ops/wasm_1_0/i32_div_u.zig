//! x86_64 emit handler for `i32.div_u` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor (`op_tag`, `wasm_level`, `wasi_level`) lives at
//! `src/instruction/wasm_1_0/i32_div_u.zig` (Zone 1). The emit
//! body delegates to `op_alu_int.emitI32DivU`, which threads
//! `ctx.bounds_fixups` for the DE / 0E trap placeholders.
//!
//! Wasm spec §4.4.1 (i32.div_u) — unsigned 32-bit integer divide;
//! traps on divisor=0.
//! Intel SDM Vol 2A `DIV r/m32` (XOR EDX,EDX ; DIV) — zero-extended
//! dividend in EDX:EAX; quotient in EAX, remainder in EDX.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`;
//! the B6x+1 cutover folds that tuple back into the unified
//! `collected_x86_64_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i32_div_u.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitI32DivU(ctx, ins);
}
