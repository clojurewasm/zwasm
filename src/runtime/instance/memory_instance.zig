//! Per-memory runtime descriptor. Wasm 3.0 multi-memory ships at
//! 10.M-3 (MemArg memidx); 10.M-2 lands the data shape so the
//! runtime stores per-memory metadata (idx_type + page bounds)
//! alongside the bytes. The legacy `Runtime.memory: []u8` slice
//! header survives as a pointer alias of `memories[0].bytes` so
//! the ~80 code-side readers stay byte-identical (per ADR-0111
//! Decision 2 + the "i32 fast-path byte-identical" rule).
//!
//! Zone 1 (`src/runtime/instance/`) — imports Zone 1 only
//! (`parse/sections.zig` for the IdxType re-export).

const sections = @import("../../parse/sections.zig");

/// Per-memory descriptor. `bytes` is the linear-memory backing
/// store; `idx_type` distinguishes i32 (legacy ≤ 4 GiB) from
/// i64 (memory64) at the data-shape layer so codegen (10.M-4)
/// can select the byte-identical fast path or the i64 wrap-check
/// recipe per ADR-0111 Decision 4. `pages_min` / `pages_max`
/// carry the original limits-section declaration so cross-module
/// import type-check (`instantiate.zig::lookup_source_export_type`)
/// has the spec-full page extents independent of the current
/// `bytes.len`.
pub const MemoryInstance = struct {
    bytes: []u8 = &.{},
    idx_type: sections.MemoryEntry.IdxType = .i32,
    pages_min: u64 = 0,
    pages_max: ?u64 = null,
};
