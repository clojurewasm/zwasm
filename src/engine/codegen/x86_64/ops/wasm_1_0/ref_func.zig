//! x86_64 emit handler for `ref.func` — Zone 2 per-arch op file
//! per ADR-0074 + ADR-0075.
//!
//! Identity anchor at `src/instruction/wasm_1_0/ref_func.zig`.
//! Delegates to `op_alu_int.emitRefFunc`. Materialises the
//! FuncEntity pointer via `MOV r,[R15 + ptr_off]` + `ADD r,
//! imm32` (where imm32 = `funcidx * sizeOf(FuncEntity)`).
//!
//! Wasm spec §4.4.5 (ref.func x).
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/ref_func.zig");
const ctx_mod = @import("../../ctx.zig");
const op_alu_int = @import("../../op_alu_int.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    return op_alu_int.emitRefFunc(ctx, ins);
}
