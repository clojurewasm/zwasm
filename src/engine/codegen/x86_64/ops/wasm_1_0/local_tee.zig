//! x86_64 emit handler for `local.tee` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/local_tee.zig`.
//! Delegates to `op_locals.emitLocalTeeCtx`.
//!
//! Wasm spec §3.5.3 / §4.4.5.3.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/local_tee.zig");
const ctx_mod = @import("../../ctx.zig");
const op_locals = @import("../../op_locals.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_locals.emitLocalTeeCtx(ctx, ins);
}
