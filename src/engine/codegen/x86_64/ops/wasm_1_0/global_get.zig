//! x86_64 emit handler for `global.get` — Zone 2 per-arch op
//! file per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/global_get.zig`.
//! Delegates to `op_globals.emitGlobalGetCtx`, which dispatches
//! on the global's valtype (i32 / i64 / f32 / f64 / ref / v128)
//! to the appropriate per-shape emit path.
//!
//! Wasm spec §4.4.5 (global.get N) — push global N's value.
//! Per ADR-0027 + ADR-0052: per-module `globals_offsets` /
//! `globals_valtypes` tables drive the load shape.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/global_get.zig");
const ctx_mod = @import("../../ctx.zig");
const op_globals = @import("../../op_globals.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_globals.emitGlobalGetCtx(ctx, ins);
}
