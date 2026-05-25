//! arm64 emit handler for `return_call_ref` — Zone 2 per
//! ADR-0074 + ADR-0112 D2.
//!
//! Wasm spec 3.0 §3.3.8.20 (tail-call proposal extended with
//! typed-func-ref operand). Pop a `(ref $sig)` funcref, null-
//! check + sig dispatch via the funcref's embedded type, then
//! frame teardown and BR X16.
//!
//! Stub: emit returns `UnsupportedOp`.
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

const meta = @import("../../../../../instruction/wasm_3_0/return_call_ref.zig");
const ctx_mod = @import("../../ctx.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A — terminator axis like the other return_call
// flavors. Null-check trap is a trap edge (not a CFG successor).
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ctx;
    _ = ins;
    return error.UnsupportedOp;
}
