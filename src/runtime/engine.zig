//! WASM Spec §4.2.x / wasm-c-api `wasm_engine_t` — top-level
//! configuration handle that owns the allocator vtable injected
//! by the C host.
//!
//! Per ADR-0023 §3 reference table: extracted from
//! `c_api/instance.zig`. The C ABI binding code (`wasm_engine_new`
//! / `_delete`) stays in `api/wasm.zig` (post-ADR-0023 §7 item 11);
//! this file owns only the data shape.
//!
//! Zone 1 (`src/runtime/`).

/// `wasm_engine_t` — top-level configuration handle. Carries the
/// allocator that backs every Store / Module / Instance that
/// derive from it (so the C host can recover its allocator from
/// any future `wasm_store_t` GC roots). The §9.3 / 3.3 binding uses
/// `std.heap.c_allocator` so C hosts get malloc-equivalent
/// lifetime; a future `zwasm.h` extension will let the host
/// inject its own.
pub const Engine = extern struct {
    /// Type-erased allocator pointer + vtable. Stored as two
    /// `*anyopaque` so the layout is C-stable — Zig's
    /// `std.mem.Allocator` is `extern struct { ptr: *anyopaque,
    /// vtable: *const VTable }` so a memcpy / pointer cast
    /// round-trips.
    alloc_ptr: ?*anyopaque,
    alloc_vtable: ?*const anyopaque,
};
