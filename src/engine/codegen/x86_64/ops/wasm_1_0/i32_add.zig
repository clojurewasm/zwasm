//! x86_64 emit handler for `i32.add` — Zone 2 per-arch op file per
//! ADR-0074.
//!
//! Identity anchor (`op_tag`, `wasm_level`, `wasi_level`) lives at
//! `src/instruction/wasm_1_0/i32_add.zig` (Zone 1). This file mirrors
//! the metadata for the Zone 2 collector's contract check and provides
//! the x86_64 emit body.
//!
//! ## State at B10 (this commit)
//!
//! Stub body returns `error.NotMigrated`; the legacy emit switch arm
//! at `src/engine/codegen/x86_64/emit.zig` retains authority for
//! `i32.add` until a later B-chunk migrates the real body here.
//!
//! Wasm spec §3.3.1 (numeric binary op — `i32.add`).
//! Intel SDM Vol 2A §3.2 `ADD r32, r32`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const meta = @import("../../../../../instruction/wasm_1_0/i32_add.zig");
const collector = @import("../../../dispatch_collector.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit() collector.DispatchError!void {
    return error.NotMigrated;
}
