//! arm64 emit handler for `i32.add` — Zone 2 per-arch op file per
//! ADR-0074.
//!
//! Identity anchor (`op_tag`, `wasm_level`, `wasi_level`) lives at
//! `src/instruction/wasm_1_0/i32_add.zig` (Zone 1). This file mirrors
//! the metadata for the Zone 2 collector's contract check and provides
//! the arm64 emit body.
//!
//! Wasm spec §3.3.1 (numeric binary op — `i32.add`).
//! Arm IHI 0055 §C6.2 (W-form `ADD <Wd>, <Wn>, <Wm>`).
//!
//! Delegates to `op_alu_int.emitI32Binary` (handles i32.add / sub /
//! mul / and / or / xor / shl / shr_s / shr_u via `ins.op` dispatch
//! internally).
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i32_add.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;
const ZirInstr = zir.ZirInstr;

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return op_alu_int.emitI32Binary(ctx, ins);
}
