//! arm64 emit handler for `ref.test_null` — Wasm 3.0 GC §3.3.5.3.
//! Identical emit to `ref.test` (the null-handling bit is folded into the
//! `jitGcRefTest` arg2 via `ins.op`), so this re-exports `ref_test.zig`'s
//! `emit` and only differs in `op_tag`.

const meta = @import("../../../../../instruction/wasm_3_0/ref_test_null.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;
pub const emit = @import("ref_test.zig").emit;
