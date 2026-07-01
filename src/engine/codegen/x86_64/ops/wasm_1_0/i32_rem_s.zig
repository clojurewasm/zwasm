//! x86_64 emit handler for `i32.rem_s` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/i32_rem_s.zig`
//! (Zone 1). Delegates to `op_alu_int.emitI32RemS`, which threads
//! `ctx.bounds_fixups` for the DE / 0E trap placeholders.
//!
//! Wasm spec §4.4.1 (i32.rem_s) — signed 32-bit integer remainder;
//! traps on divisor=0. Note: `INT_MIN % -1` does NOT trap (returns 0).
//! Intel SDM Vol 2A `IDIV r/m32` — sign-extended dividend in
//! EDX:EAX; remainder in EDX.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i32_rem_s.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitI32RemS(ctx, ins);
}
