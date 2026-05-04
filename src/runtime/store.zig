//! WASM Spec §4.2.x / wasm-c-api `wasm_store_t` — module-
//! instantiation context + zombie-instance container.
//!
//! Per ADR-0023 §3 reference table: extracted from
//! `c_api/instance.zig`. The C ABI binding code stays in
//! `api/wasm.zig` (post-ADR-0023 §7 item 11); this file owns
//! only the data shape and the per-Store zombie list type that
//! Wasm 2.0 partial-init semantics require (ADR-0014 §2.1 /
//! 6.K.2 sub-change 4).
//!
//! WASI host wiring is forward-declared via an opaque pointer so
//! `runtime/` does not need to import `wasi/`. The C ABI binding
//! at `api/wasm.zig` casts back to `*wasi.Host` when handing the
//! pointer to `zwasm_store_set_wasi`.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const engine_mod = @import("engine.zig");
const runtime_mod = @import("runtime.zig");

const Engine = engine_mod.Engine;
const Runtime = runtime_mod.Runtime;

/// `wasm_store_t` — module-instantiation context. Carries a
/// back-pointer to its owning Engine so subsequent C-API entries
/// can recover the allocator without a global. Hosts the
/// per-Store zombie-instance list (ADR-0014 §2.1 / 6.K.2 sub-
/// change 4) so cross-module funcrefs into a failed-or-
/// destroyed instance still dispatch correctly until store
/// teardown.
///
/// Plain (non-`extern`) struct: C only sees `wasm_store_t` as
/// opaque per upstream wasm.h, so the layout is private.
/// Matches the `Instance` shape choice for the same reason.
pub const Store = struct {
    engine: ?*Engine,
    /// Optional WASI host (`zwasm_wasi_config_t` from C's
    /// perspective). Stored as `?*anyopaque` so this file in
    /// Zone 1 (`runtime/`) does not need to import Zone 2
    /// (`wasi/`). The C ABI binding casts back to `*wasi.Host`.
    /// Set via `zwasm_store_set_wasi`; ownership transfers to
    /// the Store and is freed in `wasm_store_delete`. Null when
    /// the store has no WASI hosting configured.
    wasi_host: ?*anyopaque = null,
    /// Per-Store zombie-instance list (ADR-0014 §2.1 / 6.K.2
    /// sub-change 4). When `instantiateRuntime` traps mid-
    /// element-segment processing, prior writes into a foreign
    /// instance's table cells already hold `*FuncEntity`
    /// pointers into the failing instance's arena. Per Wasm 2.0
    /// partial-init semantics those writes must persist; the
    /// failing instance's runtime + arena therefore park here
    /// instead of being destroyed by the catch path.
    /// `wasm_instance_delete` on a successfully-instantiated
    /// handle also parks (so cross-module funcrefs stay valid
    /// through the importer's lifetime). Walked + freed by
    /// `wasm_store_delete`.
    zombies: std.ArrayList(Zombie) = .empty,
};

/// One parked instance. Keeps the runtime + arena alive until
/// `wasm_store_delete` walks the list. Per ADR-0014 §2.1 /
/// 6.K.2 sub-change 4.
pub const Zombie = struct {
    runtime: *Runtime,
    arena: *std.heap.ArenaAllocator,
};
