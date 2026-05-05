//! Zone-1 native import binding — runtime-side view of a single
//! `(import "module" "name" <kind>)` resolution at instantiation
//! time.
//!
//! Per ADR-0023 §7 item 5 (Step A2): replaces the previous
//! `?[*]const ?*const api.Extern` instantiation argument so
//! `runtime/instance/instantiate.zig` is free of Zone-3
//! binding-handle dependencies. The C-API binding
//! (`api/instance.zig:wasm_instance_new`) pre-resolves each
//! import (cross-module Extern OR WASI thunk lookup) into an
//! `ImportBinding` before calling `instantiate.instantiateRuntime`.
//!
//! Three variants cover today's import sources:
//!
//! - `cross_module` — the importer aliases the source runtime's
//!   storage (memory slice / table refs / global slot pointer /
//!   FuncEntity). Source identity is held via `*Runtime` so a
//!   funcref Value pointing at the source's `func_entities[i]`
//!   round-trips correctly.
//! - `wasi_host` — pre-resolved WASI `host_calls` slot. Carries
//!   only the thunk fn pointer; the binding-side captures
//!   `*wasi.Host` as ctx separately because it lives behind
//!   `Store.wasi_host: ?*anyopaque` (Zone-1 cannot type the
//!   Zone-2 `wasi.Host` directly).
//! - `host_func` — host-supplied non-WASI function import (post-
//!   v0.1.0 reserved; not produced by the current binding).
//!
//! Zone 1 (`src/runtime/`).

const runtime_mod = @import("../runtime.zig");
const sections = @import("../../parse/sections.zig");

const Runtime = runtime_mod.Runtime;
const ExportType = runtime_mod.ExportType;

/// Pre-resolved import resolution. The C-API binding builds one
/// per `(import ...)` row, in declaration order, and passes the
/// slice to `instantiate.instantiateRuntime`.
pub const ImportBinding = union(enum) {
    cross_module: CrossModule,
    wasi_host: WasiHost,
    host_func: HostFunc,
};

/// Cross-module import — wires the importer to a source
/// runtime's per-kind storage. Source instance lifetime is
/// guaranteed by ADR-0014 §6.K.2 sub-change 4 (zombie list).
pub const CrossModule = struct {
    kind: sections.ImportKind,
    /// Source runtime where the imported entity lives.
    source_runtime: *Runtime,
    /// Source's `export_types[]` — used for the import-vs-export
    /// type-match check (Wasm 2.0 §3.4.10, D-006).
    source_export_types: []const ExportType,
    /// Source's `exports_storage[]` — used to resolve the
    /// import name to the source's funcidx / tableidx /
    /// memidx / globalidx.
    source_exports: []const sections.Export,
    /// The import name (alias of the parser-decoded
    /// `Import.name`, points into the binary's bytes).
    name: []const u8,
};

/// WASI host-call import — pre-resolved to the runtime's
/// `host_calls` slot shape. The binding-side passes the
/// `*wasi.Host` pointer separately (as ctx) because Zone 1
/// cannot type `wasi.Host` directly.
pub const WasiHost = struct {
    fn_ptr: *const fn (*Runtime, *anyopaque) anyerror!void,
    ctx: *anyopaque,
};

/// Reserved for post-v0.1.0 host function imports outside the
/// WASI namespace. Not constructed by today's binding.
pub const HostFunc = struct {
    fn_ptr: *const fn (*Runtime, *anyopaque) anyerror!void,
    ctx: *anyopaque,
};
