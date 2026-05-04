//! WASM Spec §4.2.7 "Table Instance" — table reference cells.
//!
//! Per ADR-0023 §3 reference table + §7 item 6: extracted from
//! the previous monolithic `runtime/runtime.zig`. The runner /
//! instantiator allocates `refs` and threads the table via
//! `Runtime.tables`. `table.copy / .init / .fill / .grow` helper
//! impls land alongside Wasm 2.0 bulk-memory work; this file
//! currently owns only the data shape.
//!
//! Zone 1 (`src/runtime/`).

const value_mod = @import("../value.zig");
const zir = @import("../../ir/zir.zig");

const Value = value_mod.Value;

/// Runtime counterpart of `zir.TableEntry` — actually holds the
/// reference cells. The runner allocates `refs` and threads the
/// instance via `Runtime.tables`.
pub const TableInstance = struct {
    refs: []Value,
    elem_type: zir.ValType,
    max: ?u32 = null,
};
