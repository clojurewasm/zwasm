//! x86_64 emit handler for `table.init` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/table_init.zig`.
//! Delegates to `op_table.emitTableInitCtx`. Bounds-checked load/store
//! against per-table TableSlice (per ADR-0058 + ADR-0068).
//!
//! Wasm spec §4.4.10–12 (table.init).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/table_init.zig");
const ctx_mod = @import("../../ctx.zig");
const op_table = @import("../../op_table.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_table.emitTableInitCtx(ctx, ins);
}
