//! WASM Spec §4.2.5 "Module Instance" — runtime-side instantiated
//! module data shape.
//!
//! Per ADR-0023 §3 reference table + §7 item 5: extracted from
//! `c_api/instance.zig`. The wasm-c-api binding handle for
//! `wasm_module_t` is forward-declared here as `?*const anyopaque`
//! because the binding-side struct is owned by `api/wasm.zig`
//! (post-ADR-0023 §7 item 11) and including its concrete type
//! would require this Zone 1 file to import Zone 3 — a P-A
//! violation. The C-API binding casts back to its concrete shape
//! at the boundary.
//!
//! Per-instance type granularity (memory / table / global / func /
//! element / data) lands in §7 item 6's sibling files; for now
//! those concepts live as inline slices on Instance.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const runtime_mod = @import("../runtime.zig");
const store_mod = @import("../store.zig");
const sections = @import("../../frontend/sections.zig");
const zir = @import("../../ir/zir.zig");

const Store = store_mod.Store;
const Runtime = runtime_mod.Runtime;

/// `wasm_instance_t` — instantiated module. Owns one
/// `runtime.Runtime` plus a per-instance arena that backs every
/// derived state slice (types, lowered `ZirFunc`s, the func-
/// pointer table seen by `Runtime.funcs`). C only ever sees a
/// pointer to this struct (the upstream wasm.h declares
/// `wasm_instance_t` as opaque), so it does not need an extern
/// layout — using a regular Zig `struct` lets us hold proper
/// slices without packing them as `[*]T + len` pairs.
///
/// §9.3 / 3.5 wired the lifetime; §9.3 / 3.6 (chunk a) wires
/// instantiation — at `wasm_instance_new` time the Module bytes
/// are decoded + lowered into `Runtime.funcs` /
/// `Runtime.module_types`. `Runtime.memory` / `.tables` /
/// `.datas` / `.elems` follow when 3.6's call surface needs them.
pub const Instance = struct {
    store: ?*Store,
    /// Back-pointer to the binding-side wasm_module_t handle
    /// (`c_api/instance.zig:Module`, post-§7 item 11
    /// `api/wasm.zig`). Held as `?*const anyopaque` so this
    /// Zone 1 file does not import the Zone 3 binding layer; the
    /// C-API binding casts at the boundary.
    module: ?*const anyopaque,
    runtime: ?*Runtime,
    /// Per-instance arena holding every derived-state slice. A
    /// single `arena.deinit()` releases types, lowered ZirFunc
    /// state, the func-pointer table — uniformly. Owned (heap-
    /// allocated) so its identity survives moves of the Instance
    /// struct itself.
    arena: ?*std.heap.ArenaAllocator = null,
    funcs_storage: []zir.ZirFunc = &.{},
    func_ptrs_storage: []*const zir.ZirFunc = &.{},
    /// Decoded export-section entries (arena-backed). Used by
    /// `wasm_instance_exports` to surface the upstream-standard
    /// discovery path.
    exports_storage: []sections.Export = &.{},
    /// Parallel to `exports_storage` — `export_types[i]` is the
    /// structural type of `exports_storage[i]`. Populated during
    /// `instantiateRuntime` so cross-module imports can validate
    /// import-vs-export type matching at the c_api boundary
    /// (Wasm 2.0 §3.4.10). See `ExportType` below + the
    /// validation site at the import-resolution loop. Discharges
    /// debt D-006 (the "linking-errors-pass-for-the-wrong-reason"
    /// gap exposed by the auto-register spike).
    export_types: []ExportType = &.{},
};

/// Structural type of an exported entity. Mirrors the four
/// `ImportPayload` variants in `frontend/sections.zig` but with
/// `func` resolving the typeidx to a concrete `FuncType` so the
/// importer-vs-exporter comparison is direct.
pub const ExportType = union(sections.ImportKind) {
    func: zir.FuncType,
    table: struct { elem_type: zir.ValType, min: u32, max: ?u32 },
    memory: struct { min: u32, max: ?u32 },
    global: struct { valtype: zir.ValType, mutable: bool },
};
