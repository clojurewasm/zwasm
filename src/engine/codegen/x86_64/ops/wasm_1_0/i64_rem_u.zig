//! x86_64 emit handler for `i64.rem_u` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/i64_rem_u.zig`
//! (Zone 1). Delegates to `op_alu_int.emitI64RemU`, which threads
//! `ctx.bounds_fixups` for the DE trap placeholder.
//!
//! Wasm spec §4.4.1 (i64.rem_u) — unsigned 64-bit integer remainder;
//! traps on divisor=0.
//! Intel SDM Vol 2A `DIV r/m64` — zero-extended dividend in RDX:RAX;
//! remainder in RDX.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i64_rem_u.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitI64RemU(ctx, ins);
}
