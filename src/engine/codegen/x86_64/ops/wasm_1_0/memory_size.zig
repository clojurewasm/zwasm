//! x86_64 emit handler for `memory.size` — Zone 2 per-arch op
//! file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/memory_size.zig`.
//! Delegates to `op_call.emitMemorySizeCtx`. Loads mem_limit from
//! `[R15 + mem_limit_off]` and right-shifts by 16 to produce the
//! current page count.
//!
//! Wasm spec §4.4.7 (memory.size).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/memory_size.zig");
const ctx_mod = @import("../../ctx.zig");
const op_call = @import("../../op_call.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_call.emitMemorySizeCtx(ctx, ins);
}
