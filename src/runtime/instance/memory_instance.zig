//! Per-memory runtime descriptor. Wasm 3.0 multi-memory ships at
//! 10.M-3 (MemArg memidx); 10.M-2 lands the data shape so the
//! runtime stores per-memory metadata (idx_type + page bounds)
//! alongside the bytes. The legacy `Runtime.memory: []u8` slice
//! header survives as a pointer alias of `memories[0].bytes` so
//! the ~80 code-side readers stay byte-identical (per ADR-0111
//! Decision 2 + the "i32 fast-path byte-identical" rule).
//!
//! Zone 1 (`src/runtime/instance/`) — imports Zone 1
//! (`parse/sections.zig` for the IdxType re-export) + Zone 0
//! (`platform/guarded_mem.zig` for the ADR-0202 backing descriptor).

const sections = @import("../../parse/sections.zig");
const guarded_mem = @import("../../platform/guarded_mem.zig");

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
    /// Wasm threads (ADR-0168) — carried from the memtype's 0x02 flag so
    /// `memory.atomic.wait*` can trap on a non-shared memory. No runtime
    /// behaviour difference on the single-threaded substrate.
    shared: bool = false,
    /// Wasm custom-page-sizes (ADR-0168 v0.2) — log2 of this memory's
    /// page size (0 = 1 byte, 16 = 64 KiB default). `memory.size`/`grow`
    /// report/operate in units of `1 << page_size_log2` bytes.
    page_size_log2: u8 = 16,
    /// ADR-0202 D1 — non-null when `bytes` lives in a guard-page
    /// reservation (base never moves; grow = commit-in-place; the
    /// owner releases it instead of freeing `bytes` through the
    /// allocator). Null = plain allocator heap (realloc on grow).
    reservation: ?guarded_mem.Reservation = null,
};
