//! Zone-1 native import binding — runtime-side view of a single
//! `(import "module" "name" <kind>)` resolution at instantiation
//! time.
//!
//! Per ADR-0023 §7 item 5 (Step A2): replaces the previous
//! `?[*]const ?*const api.Extern` instantiation argument so
//! `runtime/instance/instantiate.zig` is free of Zone-3
//! binding-handle dependencies. The C-API binding pre-resolves
//! every import (cross-module Extern lookup, WASI thunk lookup,
//! CallCtx allocation, source-signature retrieval) and hands a
//! `[]const ImportBinding` to `instantiate.instantiateRuntime`.
//!
//! Each variant carries:
//!   - the **wiring data** the runtime needs (HostCall slot value,
//!     source TableInstance value, source memory slice, source
//!     global slot pointer),
//!   - both the **source's actual descriptor** AND the
//!     **importer's expected descriptor** so the runtime-side
//!     `checkImportTypeMatches` is a pure data compare with no
//!     re-decoding of the source binary.
//!
//! Zone 1 (`src/runtime/`).

const runtime_mod = @import("../runtime.zig");
const zir = @import("../../ir/zir.zig");

const Runtime = runtime_mod.Runtime;
const Value = runtime_mod.Value;
const HostCall = runtime_mod.HostCall;
const TableInstance = runtime_mod.TableInstance;

/// One pre-resolved import. Order in the slice matches the
/// `(import ...)` declaration order in the importer's binary.
pub const ImportBinding = union(enum) {
    func: FuncImport,
    table: TableImport,
    memory: MemoryImport,
    global: GlobalImport,
};

/// Function import. The `host_call` slot is pre-built by the
/// binding (cross-module thunk + CallCtx for non-WASI; WASI
/// thunk + `*wasi.Host` ctx for WASI). `source` describes how
/// the FuncEntity slot should be populated:
///
/// - `cross_module`: the FuncEntity slot points at the source
///   runtime's func_idx, so funcref dispatch through this cell
///   reaches the source body via FuncEntity.runtime. The
///   `source_signature` is compared against the importer's
///   declared typeidx during the runtime-side type-match check.
/// - `wasi`: WASI is called by funcidx, never by ref; the
///   FuncEntity slot stays with the importer's local placeholder.
///   No signature compare (the binding-side guarantees the
///   thunk lookup matched the import name).
pub const FuncImport = struct {
    host_call: HostCall,
    source: union(enum) {
        cross_module: struct {
            source_runtime: *Runtime,
            source_funcidx: u32,
            source_signature: zir.FuncType,
        },
        wasi: void,
    },
};

/// Table import. The `instance` field is a value-copy of the
/// source `TableInstance` (refs slice is aliased — both modules
/// see/mutate the same cells per ADR-0014 §6.K.3). The trailing
/// fields carry the source's descriptor for the runtime-side
/// type-match check; the importer's expected descriptor comes
/// from its own `(import ... (table ...))` decoding.
pub const TableImport = struct {
    instance: TableInstance,
    source_elem_type: zir.ValType,
    source_min: u32,
    source_max: ?u32,
};

/// Memory import. The `memory` slice header aliases the source's
/// memory bytes (per ADR-0014 §2.2 / §6.K.2 the arena holds
/// the bytes alive across importer teardown).
pub const MemoryImport = struct {
    memory: []u8,
    source_min: u32,
    source_max: ?u32,
};

/// Global import. The `slot` points at the source runtime's
/// `globals[idx]` cell (per ADR-0014 §6.K.3 the importer's
/// `Runtime.globals: []*Value` aliases the source slot).
pub const GlobalImport = struct {
    slot: *Value,
    source_valtype: zir.ValType,
    source_mutable: bool,
};
