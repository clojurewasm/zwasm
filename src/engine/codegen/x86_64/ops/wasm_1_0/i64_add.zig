//! x86_64 emit handler for `i64.add` — Zone 2 per-arch op file per
//! ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/i64_add.zig`.
//! Delegates to `op_alu_int.emitI64BinaryCtx` (which dispatches
//! on `ins.op` internally; shared across the 6-op i64 binary
//! ALU cohort).
//!
//! Wasm spec §3.3.1 (numeric binary op).
//! Intel SDM Vol 2A §3.2.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i64_add.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitI64BinaryCtx(ctx, ins);
}
