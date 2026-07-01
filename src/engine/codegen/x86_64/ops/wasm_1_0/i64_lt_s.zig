//! x86_64 emit handler for `i64.lt.s` — Zone 2 per-arch op file per
//! ADR-0074 + ADR-0075.
//!
//! Delegates to `op_alu_int.emitI64CompareCtx`.
//!
//! Wasm spec §3.3.1 (numeric relational op).
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i64_lt_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitI64CompareCtx(ctx, ins);
}
