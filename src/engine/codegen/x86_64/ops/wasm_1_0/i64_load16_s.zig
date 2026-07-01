//! x86_64 emit handler for `i64.load16_s` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/i64_load16_s.zig`.
//! Delegates to `op_memory.emitI64Load16S` (one of 23 aliases of the
//! shared `(ctx, ins)` adapter wrapping `emitMemOp` —
//! bounds-checked load/store with eff-addr/trap prologue).
//!
//! Wasm spec §4.4.7 (i64.load16_s) — scalar memory access; traps on
//! `eff_addr + access_size > mem_limit`.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i64_load16_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_memory = @import("../../op_memory.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_memory.emitI64Load16S(ctx, ins);
}
