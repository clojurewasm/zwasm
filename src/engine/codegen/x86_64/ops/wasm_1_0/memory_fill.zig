//! x86_64 emit handler for `memory.fill` — Zone 2 per-arch op
//! file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/memory_fill.zig`.
//! Delegates to `op_memory.emitMemoryFillCtx`, which wraps the
//! 7-arg `emitMemoryFill` helper (bounds-checked inline byte
//! loop; pops dst/val/n from operand stack).
//!
//! Wasm spec §4.4.7 (memory.fill) — bulk memory fill.
//! Traps on `dst + n > mem_limit`.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/memory_fill.zig");
const ctx_mod = @import("../../ctx.zig");
const op_memory = @import("../../op_memory.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_memory.emitMemoryFillCtx(ctx, ins);
}
