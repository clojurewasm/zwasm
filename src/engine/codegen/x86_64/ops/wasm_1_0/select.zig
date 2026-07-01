//! x86_64 emit handler for `select` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/select.zig`.
//! Delegates to `op_alu_int.emitSelectCtx` (3-path dispatch:
//! v128 via op_simd, fp via op_alu_float, GPR with alias-aware
//! CMOV). Note: `select_typed` shares the same runtime body via
//! emit.zig's grouped arm; a select_typed per-op file is
//! deferred until its Zone 1 meta lands.
//!
//! Wasm spec §4.4.4 / §3.3.2.2.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/select.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitSelectCtx(ctx, ins);
}
