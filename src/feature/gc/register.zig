//! Per-feature DispatchTable registration entry per ADR-0023 §3
//! reference table (`feature/gc/` subsystem).
//!
//! `register(*DispatchTable)` is the canonical hook — when the
//! build flag `-Denable=gc` selects this feature in, the
//! central registry calls this function during startup and the
//! function installs the parser / validator / interp / arm64 /
//! x86_64 emit slots for the feature's opcodes.
//!
//! Currently a placeholder per ADR-0023 §3 P-H. Implementation
//! lands per ROADMAP §11 (proposal phasing) when the feature's
//! Phase row opens.
//!
//! Zone 1 (`src/feature/gc/`).

const dispatch_table = @import("../../ir/dispatch_table.zig");

// 10.G-i31-helpers: i31 small-integer pack/unpack helpers per
// ADR-0116 D4. Re-exported here so `zig build test` walks the
// helper unit tests + the helpers are reachable from the future
// 0xFB GC-prefix dispatcher + i31 op handlers via
// `feature.gc.i31_pack`. (`i31` itself is a Zig 0.16 primitive
// type name; the helper module is `i31_pack` to avoid shadowing.)
pub const i31_pack = @import("i31.zig");

// 10.G-2: parse-time `needs_gc_heap` predicate per ADR-0115 D2.
// Re-exported so the runtime / instance-build path can call
// `feature.gc.needs_heap_detector.detectNeedsGcHeap(&module)`
// to gate heap-slab materialisation. Also makes the detector's
// in-source unit tests discoverable by `zig build test`.
pub const needs_heap_detector = @import("needs_heap_detector.zig");

// 10.G-foundation cycle 3: per-Store GC heap slab per ADR-0115
// §1 / §5. Bump-pointer allocator over a Runtime-arena-backed
// slab; 32-bit GcRef offsets, 2-byte alignment, 4 KB grow
// granularity, 4 GiB cap.
pub const heap = @import("heap.zig");

// 10.G-foundation cycle 4: Collector vtable + null collector α
// per ADR-0115 §3 / §10. Pluggable interface mirroring
// std.mem.Allocator shape (vtable + ctx). collector_null wraps
// Heap as allocator-only (collect/walkRoots no-ops);
// collector_mark_sweep (β must-ship) lands in subsequent bundle
// cycles.
pub const collector_iface = @import("collector_iface.zig");
pub const collector_null = @import("collector_null.zig");

pub fn register(_: *dispatch_table.DispatchTable) void {
    // Placeholder — feature implementation deferred per ADR-0023.
}
