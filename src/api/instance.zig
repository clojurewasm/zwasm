//! Engine / Store / Module / Instance / Func / Extern surface of
//! the C ABI binding (§9.5 / 5.0 chunk d carve-out from
//! `wasm.zig` per ADR-0007).
//!
//! Owns every value and handle type the wasm-c-api shapes the
//! life cycle around: `Engine`, `Store`, `Module`, `Instance`,
//! `Func`, `Extern` (plus `ValKind` / `Val` / `ExternKind`).
//! Holds the corresponding `*_new` / `*_delete` C exports, the
//! frontend-validate + instantiation pipelines, the Func dispatch
//! glue, the marshal helpers, the export-discovery surface
//! (`wasm_extern_*`, `wasm_instance_exports`,
//! `wasm_extern_vec_delete` — moved here because it cascades into
//! `wasm_extern_delete`), and `wasm_func_call`.
//!
//! Reaches `ByteVec` / `ValVec` / `ExternVec` from `vec.zig` and
//! `Trap` / `TrapKind` / `allocTrap` / `mapInterpTrap` from
//! `trap_surface.zig` directly (sideways imports inside Zone 3).
//! `wasm.zig` re-exports every public name in this file so
//! call sites (CLI, in-binding helpers, external tests) keep
//! addressing them as `wasm_c_api.<name>`.
//!
//! Zone 3 — same as the rest of `src/api/`. Imports lower
//! zones (`interp/`, `wasi/`, `frontend/`, `ir/`, `util/`) freely.

const std = @import("std");

const dbg = @import("../support/dbg.zig");
const runtime = @import("../runtime/runtime.zig");
const runtime_instance = @import("../runtime/instance/instance.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi = @import("wasi.zig");
const trap_surface = @import("trap_surface.zig");
const vec = @import("vec.zig");
const dispatch = @import("../interp/dispatch.zig");
const interp_mvp = @import("../interp/mvp.zig");
const ext_sign_ext = @import("../interp/ext_2_0/sign_ext.zig");
const ext_sat_trunc = @import("../interp/ext_2_0/sat_trunc.zig");
const ext_bulk_memory = @import("../interp/ext_2_0/bulk_memory.zig");
const ext_ref_types = @import("../interp/ext_2_0/ref_types.zig");
const ext_table_ops = @import("../interp/ext_2_0/table_ops.zig");
const lowerer = @import("../ir/lower.zig");
const parser = @import("../parse/parser.zig");
const cross_module = @import("cross_module.zig");
const sections = @import("../parse/sections.zig");
const validator = @import("../validate/validator.zig");
const zir = @import("../ir/zir.zig");
const dispatch_table_mod = @import("../ir/dispatch_table.zig");
const loop_info_mod = @import("../ir/analysis/loop_info.zig");
const verifier_mod = @import("../ir/verifier.zig");

const ByteVec = vec.ByteVec;
const ValVec = vec.ValVec;
const ExternVec = vec.ExternVec;
const Trap = trap_surface.Trap;
const TrapKind = trap_surface.TrapKind;
const allocTrap = trap_surface.allocTrap;
const mapInterpTrap = trap_surface.mapInterpTrap;

const testing = std.testing;

// Opaque types (match wasm.h declarations 1:1)
// ============================================================

/// `wasm_engine_t` — process-wide top-level handle. Carries the
/// allocator the binding will thread into runtimes (and into
/// future `wasm_store_t` GC roots). The §9.3 / 3.3 binding uses
/// `std.heap.c_allocator` so C hosts get malloc-equivalent
/// lifetime; a future `zwasm.h` extension will let the host
/// inject its own.
pub const Engine = runtime.Engine;
pub const Store = runtime.Store;
pub const Zombie = runtime.Zombie;

/// `wasm_module_t` — validated module. Owns a heap-allocated
/// copy of the input bytes (so the C host can free its
/// `byte_vec` immediately after `wasm_module_new`) plus a
/// pointer back to the Store so `_delete` can recover the
/// allocator. Section decode + lowering happens at `_new` time;
/// the §9.3 / 3.5 instance constructor reuses the work.
pub const Module = extern struct {
    store: ?*Store,
    bytes_ptr: ?[*]u8,
    bytes_len: usize,
};

// Instance + ExportType moved to src/runtime/instance/instance.zig
// per ADR-0023 §7 item 5. The binding-side wasm_module_t (this
// file's `Module` extern struct) stays here and is forward-cast
// through Instance.module's `?*const anyopaque` slot at the
// boundary — see `wasm_instance_new` + the equality-test site in
// the §9.3 / 3.5 lifetime test.
pub const Instance = runtime_instance.Instance;
pub const ExportType = runtime_instance.ExportType;

/// `wasm_func_t` — exported / imported function handle. Carries a
/// back-pointer to its owning Instance plus the function's index
/// in `Instance.funcs_storage`. C only ever sees the opaque
/// pointer (per upstream wasm.h), so the struct does not need
/// extern layout.
pub const Func = struct {
    instance: ?*Instance,
    func_idx: u32,
};

// `Trap` and `TrapKind` live in `src/api/trap_surface.zig`
// after the §9.5 / 5.0 chunk b carve-out (ADR-0007); see the
// re-exports near the imports at the top of this file.

// ============================================================
// Value shapes
// ============================================================

/// `wasm_valkind_t` — Wasm valtype tag.
pub const ValKind = enum(u8) {
    i32 = 0,
    i64 = 1,
    f32 = 2,
    f64 = 3,
    anyref = 128,
    funcref = 129,
};

/// `wasm_val_t` — tagged value used at host ↔ Wasm boundary.
pub const Val = extern struct {
    kind: ValKind,
    of: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        ref: ?*anyopaque,
    },
};

// `ByteVec` and `ValVec` live in `src/api/vec.zig` after the
// §9.5 / 5.0 chunk c carve-out (ADR-0007); see the re-exports
// near the imports at the top of this file.

/// `wasm_externkind_t` — tag identifying which Wasm extern shape
/// an `Extern` carries. Numeric values match upstream wasm.h
/// (`WASM_EXTERN_FUNC` = 0, …) so the binding exports the same
/// integers C hosts read.
pub const ExternKind = enum(u8) {
    func = 0,
    global = 1,
    table = 2,
    memory = 3,
};

/// `wasm_extern_t` — opaque-from-C handle for an exported /
/// imported runtime entity. The func variant carries an owned
/// `Func` handle; table / memory variants carry a pointer back
/// to the source instance plus the export's index in the source
/// module's index space, so the import wiring (§9.6 / 6.E iter
/// 7) can share the underlying TableInstance / memory slice.
/// global is declared but not yet wired through imports.
pub const Extern = struct {
    kind: ExternKind,
    /// Back-pointer for allocator recovery in `wasm_extern_delete`.
    instance: ?*Instance,
    /// For kind = func: the Func handle owned by this Extern. C
    /// hosts borrow via `wasm_extern_as_func` (no transfer of
    /// ownership) and must NOT call `wasm_func_delete` on the
    /// returned pointer; `wasm_extern_delete` releases it.
    func: ?*Func = null,
    /// For kind = table: index into the source instance's
    /// runtime table list. Only meaningful when `kind == .table`.
    table_idx: u32 = 0,
    /// For kind = memory: always references the source instance's
    /// single linear memory (multi-memory unsupported pre-v0.2).
    /// Only meaningful when `kind == .memory`.
    memory_idx: u32 = 0,
    /// For kind = global: index into the source instance's
    /// runtime globals list. Only meaningful when `kind == .global`.
    global_idx: u32 = 0,
};

// `ExternVec` lives in `src/api/vec.zig` after the §9.5 / 5.0
// chunk c carve-out (ADR-0007); see the re-exports near the
// imports at the top of this file.

// ============================================================
// Engine constructors / destructors (§9.3 / 3.3)
// ============================================================

inline fn engineAllocator(e: *const Engine) std.mem.Allocator {
    return .{
        .ptr = @ptrCast(e.alloc_ptr),
        .vtable = @ptrCast(@alignCast(e.alloc_vtable.?)),
    };
}

/// `wasm_engine_new()` — allocate an Engine + bind the C
/// allocator. Returns null on OOM (zero allocations should
/// happen at this layer beyond the Engine struct itself; the C
/// allocator is process-wide).
pub export fn wasm_engine_new() callconv(.c) ?*Engine {
    const alloc = std.heap.c_allocator;
    const e = alloc.create(Engine) catch return null;
    e.* = .{
        .alloc_ptr = alloc.ptr,
        .alloc_vtable = @ptrCast(alloc.vtable),
    };
    return e;
}

/// `wasm_engine_delete(*Engine)` — free an Engine that was
/// returned by `wasm_engine_new`. Idempotent for a null pointer
/// (mirrors upstream `WASM_DECLARE_OWN` discipline: the C host
/// passes the same pointer it got back).
pub export fn wasm_engine_delete(e: ?*Engine) callconv(.c) void {
    const handle = e orelse return;
    const alloc = engineAllocator(handle);
    alloc.destroy(handle);
}

// ============================================================
// Store constructors / destructors (§9.3 / 3.3b)
// ============================================================

/// `wasm_store_new(wasm_engine_t*)` — allocate a Store bound to
/// the given Engine. Returns null on OOM or null engine.
pub export fn wasm_store_new(e: ?*Engine) callconv(.c) ?*Store {
    const engine = e orelse return null;
    const alloc = engineAllocator(engine);
    const s = alloc.create(Store) catch return null;
    s.* = .{ .engine = engine };
    return s;
}

/// `wasm_store_delete(*Store)` — free a Store. Null-tolerant.
/// Walks the zombie-instance list (per ADR-0014 §2.1 / 6.K.2
/// sub-change 4); tears down the attached WASI Host (if any);
/// releases the struct itself.
pub export fn wasm_store_delete(s: ?*Store) callconv(.c) void {
    const handle = s orelse return;
    const engine = handle.engine orelse return; // dangling — leak rather than crash
    const alloc = engineAllocator(engine);
    // Reap zombies first: each one's runtime + arena outlived the
    // instance handle so cross-module funcrefs into it stayed
    // valid; with the store going away, no foreign reference
    // remains, so they can be freed.
    for (handle.zombies.items) |z| {
        z.runtime.deinit();
        z.arena.deinit();
        alloc.destroy(z.arena);
        alloc.destroy(z.runtime);
    }
    handle.zombies.deinit(alloc);
    if (handle.wasi_host) |host_opaque| {
        const host: *wasi_host.Host = @ptrCast(@alignCast(host_opaque));
        host.deinit();
        alloc.destroy(host);
    }
    alloc.destroy(handle);
}

/// Park a runtime + arena pair on the store's zombie list. Used
/// by `wasm_instance_new`'s catch path (failed instantiation
/// retains its state per Wasm 2.0 partial-init semantics) and
/// by `wasm_instance_delete` (cross-module funcrefs into the
/// instance's funcs stay valid until store teardown). Per
/// ADR-0014 §2.1 / 6.K.2 sub-change 4.
fn parkAsZombie(
    store_alloc: std.mem.Allocator,
    store: *Store,
    rt: *runtime.Runtime,
    arena: *std.heap.ArenaAllocator,
) std.mem.Allocator.Error!void {
    try store.zombies.append(store_alloc, .{
        .runtime = rt,
        .arena = arena,
    });
}

// ============================================================
// WASI host wiring (§9.4 / 4.7 chunk a)
// ============================================================
//
// `zwasm_wasi_config_new` and `zwasm_wasi_config_delete` live in
// `src/api/wasi.zig` (§9.5 / 5.0 carve-out per ADR-0007); only
// the Store-touching `zwasm_store_set_wasi` remains here.

/// `zwasm_store_set_wasi(*Store, ?*Host)` — install a WASI
/// host on a Store. Ownership of the Host transfers to the
/// Store; the C host must not call `zwasm_wasi_config_delete`
/// on the same pointer afterwards. Calling twice on the same
/// Store frees the previous Host first. Pass `null` to detach
/// + free the existing Host.
pub export fn zwasm_store_set_wasi(s: ?*Store, h: ?*wasi_host.Host) callconv(.c) void {
    const store = s orelse return;
    if (store.wasi_host) |old_opaque| {
        const old: *wasi_host.Host = @ptrCast(@alignCast(old_opaque));
        old.deinit();
        std.heap.c_allocator.destroy(old);
    }
    store.wasi_host = if (h) |hp| @as(*anyopaque, @ptrCast(hp)) else null;
}

// ============================================================
// Module constructors / validators / destructors (§9.3 / 3.4)
// ============================================================

pub inline fn storeAllocator(s: *const Store) ?std.mem.Allocator {
    const engine = s.engine orelse return null;
    return engineAllocator(engine);
}

/// Run the frontend pipeline (parse + section decode + per-fn
/// validate) over `binary`. Returns `true` on success. Caller
/// owns nothing — this is the read-only validate path.
fn frontendValidate(alloc: std.mem.Allocator, binary: []const u8) bool {
    var module = parser.parse(alloc, binary) catch return false;
    defer module.deinit(alloc);

    const type_section = module.find(.@"type") orelse return validateNoCode(alloc, &module);
    const code_section = module.find(.code) orelse return true;

    var types_owned = sections.decodeTypes(alloc, type_section.body) catch return false;
    defer types_owned.deinit();

    const func_section = module.find(.function);
    const defined_func_indices = if (func_section) |s|
        sections.decodeFunctions(alloc, s.body) catch return false
    else
        alloc.alloc(u32, 0) catch return false;
    defer alloc.free(defined_func_indices);

    var codes_owned = sections.decodeCodes(alloc, code_section.body) catch return false;
    defer codes_owned.deinit();

    if (codes_owned.items.len != defined_func_indices.len) return false;

    // `func_types` must span the full funcidx space (imports
    // first, then defined) — the validator's `call N` checks
    // `func_types[N]` and N can reference an imported function.
    var imports_decoded: ?sections.Imports = if (module.find(.import)) |sec|
        sections.decodeImports(alloc, sec.body) catch return false
    else
        null;
    defer if (imports_decoded) |*im| im.deinit();

    var imp_func_count: usize = 0;
    var imp_global_count: usize = 0;
    var imp_table_count: usize = 0;
    if (imports_decoded) |im| for (im.items) |it| switch (it.kind) {
        .func => imp_func_count += 1,
        .global => imp_global_count += 1,
        .table => imp_table_count += 1,
        .memory => {
            // Imported memories aren't counted by this loop —
            // function/global/table tallies feed `func_types` sizing.
        },
    };

    const func_types = alloc.alloc(zir.FuncType, imp_func_count + defined_func_indices.len) catch return false;
    defer alloc.free(func_types);
    {
        var cursor: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .func) continue;
            const ti = it.payload.func_typeidx;
            if (ti >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[ti];
            cursor += 1;
        };
        for (defined_func_indices) |type_idx| {
            if (type_idx >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[type_idx];
            cursor += 1;
        }
    }

    // global / table entries — built over the full imports +
    // defined index space so `global.get` and `table.*` ops
    // type-check properly. Mirrors test/spec/runner.zig.
    var globals_owned: ?sections.Globals = if (module.find(.global)) |s|
        sections.decodeGlobals(alloc, s.body) catch return false
    else
        null;
    defer if (globals_owned) |*g| g.deinit();
    const def_global_count: usize = if (globals_owned) |g| g.items.len else 0;
    const global_entries = alloc.alloc(validator.GlobalEntry, imp_global_count + def_global_count) catch return false;
    defer alloc.free(global_entries);
    {
        var cursor: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .global) continue;
            global_entries[cursor] = .{
                .valtype = it.payload.global.valtype,
                .mutable = it.payload.global.mutable,
            };
            cursor += 1;
        };
        if (globals_owned) |g| for (g.items) |gd| {
            global_entries[cursor] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
            cursor += 1;
        };
    }

    var tables_owned: ?sections.Tables = if (module.find(.table)) |s|
        sections.decodeTables(alloc, s.body) catch return false
    else
        null;
    defer if (tables_owned) |*t| t.deinit();
    const def_table_count: usize = if (tables_owned) |t| t.items.len else 0;
    const table_entries = alloc.alloc(zir.TableEntry, imp_table_count + def_table_count) catch return false;
    defer alloc.free(table_entries);
    {
        var cursor: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .table) continue;
            // Imported table descriptions come kind-only via §A10;
            // synthesise a permissive funcref so `table.*` ops
            // don't trip bounds checks during validation.
            table_entries[cursor] = .{ .elem_type = .funcref, .min = 0 };
            cursor += 1;
        };
        if (tables_owned) |t| for (t.items) |entry| {
            table_entries[cursor] = entry;
            cursor += 1;
        };
    }

    for (codes_owned.items, defined_func_indices) |code, type_idx| {
        const sig = types_owned.items[type_idx];
        validator.validateFunction(
            sig,
            code.locals,
            code.body,
            func_types,
            global_entries,
            types_owned.items,
            0, // data_count
            table_entries,
            0, // elem_count
        ) catch return false;
    }
    return true;
}

fn validateNoCode(_: std.mem.Allocator, _: *runtime.Module) bool {
    // No code section: nothing per-function to validate. The
    // module's section-id ordering was already checked by
    // parser.parse, which is sufficient.
    return true;
}

/// `wasm_module_new(store, binary)` — parse + validate `binary`,
/// return an owning Module on success or null on parse / validate
/// failure. The returned Module copies the binary bytes so the C
/// host can free its `byte_vec` immediately.
pub export fn wasm_module_new(s: ?*Store, binary: ?*const ByteVec) callconv(.c) ?*Module {
    const store = s orelse return null;
    const bv = binary orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    const data_ptr = bv.data orelse return null;
    const slice = data_ptr[0..bv.size];

    if (!frontendValidate(alloc, slice)) return null;

    // Copy the bytes so the Module owns them past the call.
    const owned = alloc.dupe(u8, slice) catch return null;
    errdefer alloc.free(owned);

    const m = alloc.create(Module) catch {
        alloc.free(owned);
        return null;
    };
    m.* = .{
        .store = store,
        .bytes_ptr = owned.ptr,
        .bytes_len = owned.len,
    };
    return m;
}

/// `wasm_module_validate(store, binary)` — same pipeline as
/// `_module_new` but discards the result; returns `true` if the
/// module passes validation.
pub export fn wasm_module_validate(s: ?*Store, binary: ?*const ByteVec) callconv(.c) bool {
    const store = s orelse return false;
    const bv = binary orelse return false;
    const alloc = storeAllocator(store) orelse return false;
    const data_ptr = bv.data orelse return false;
    return frontendValidate(alloc, data_ptr[0..bv.size]);
}

/// `wasm_module_delete(module)` — free a Module returned by
/// `_module_new`. Null-tolerant.
pub export fn wasm_module_delete(m: ?*Module) callconv(.c) void {
    const handle = m orelse return;
    const store = handle.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    if (handle.bytes_ptr) |p| alloc.free(p[0..handle.bytes_len]);
    alloc.destroy(handle);
}

// ============================================================
// Instance constructors / destructors (§9.3 / 3.5 + 3.6)
// ============================================================

/// Decode the Module's stored bytes into Runtime state. Allocates
/// a per-instance arena (held on `inst.arena`) into which all
/// derived state lives — types, lowered `ZirFunc`s, and the
/// `[]*const ZirFunc` table that `Runtime.funcs` borrows. On any
/// failure the partial state parks on the store's zombie list
/// (`parkAsZombie`); the arena is freed at `wasm_store_delete`.
///
/// 3.6 chunk a scope: types + functions + code section. Memory /
/// data / element / table sections land alongside `wasm_func_call`
/// in chunk b once the smallest dispatch path needs them.
fn instantiateRuntime(
    parent_alloc: std.mem.Allocator,
    bytes: []const u8,
    inst: *Instance,
    rt: *runtime.Runtime,
    imports: ?[*]const ?*const Extern,
) !void {
    const arena = try parent_alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(parent_alloc);
    inst.arena = arena;
    const a = arena.allocator();

    // §9.6 / 6.K.2 (ADR-0014 §2.2): rebind the Runtime's allocator
    // to the per-instance arena so every subsequent allocation
    // (memory, globals, tables.refs, elems, func_entities, dropped
    // flags, host_calls) and every `table.grow` realloc unifies on
    // a single arena. Wire the Instance back-ref so 6.K.3 can
    // recover the source instance from a FuncEntity's runtime.
    rt.alloc = a;
    rt.instance = inst;

    var module = try parser.parse(a, bytes);
    defer module.deinit(a);

    // §9.4 / 4.7 + §9.6 / 6.E iter 7: import section. WASI imports
    // (module = "wasi_snapshot_preview1") wire to the Store's
    // configured WASI host. All other imports must be resolved by
    // a host-supplied `imports[]` array — the runner builds this
    // by looking up registered modules' exports. An import without
    // a corresponding extern (or with the wrong kind) fails
    // instantiation.
    var imports_decoded: ?sections.Imports = null;
    defer if (imports_decoded) |*im| im.deinit();
    if (module.find(.import)) |import_section| {
        imports_decoded = try sections.decodeImports(a, import_section.body);
        for (imports_decoded.?.items, 0..) |it, idx| {
            if (std.mem.eql(u8, it.module, "wasi_snapshot_preview1")) {
                if (it.kind == .func) {
                    if (wasi.lookupWasiThunk(it.name) == null) return error.UnsupportedWasiImport;
                }
                continue;
            }
            // Cross-module import: caller must have supplied an
            // extern at the same index.
            const extern_ptr = if (imports) |arr| arr[idx] else null;
            const ext = extern_ptr orelse return error.UnknownImportModule;
            const want_kind: ExternKind = switch (it.kind) {
                .func => .func,
                .table => .table,
                .memory => .memory,
                .global => .global,
            };
            if (ext.kind != want_kind) return error.ImportKindMismatch;
            // Per Wasm 2.0 §3.4.10: import-vs-export type matching.
            // Discharges debt D-006 (the gap exposed by the
            // auto-register spike — 9 linking-errors fixtures
            // previously passed for the wrong reason because
            // manifest-discovery rejected before this check ever
            // fired). Importer's type table needed for func-sig
            // resolution; decode it lazily on first need.
            try checkImportTypeMatches(a, module, it, ext);
            // Iter 7 scope: only memory imports wire end-to-end.
            // Table / global / func imports remain unsupported
            // because their dispatch needs source-instance
            // Per ADR-0014 §2.1 / 6.K.3: every import kind (memory
            // / table / global / func) is wired below. Memory at
            // ~line 720 (slice-header alias). Table at ~line 790
            // (TableInstance value-copy — refs slice is shared).
            // Global at ~line 850 (per-slot pointer alias via
            // `Runtime.globals: []*Value`). Func via cross-module
            // call thunk at ~line 730 (host_calls slot routes the
            // call through the source instance's runtime).
        }
    }

    var imp_func_count: u32 = 0;
    var imp_table_count: u32 = 0;
    var imp_memory_count: u32 = 0;
    var imp_global_count: u32 = 0;
    if (imports_decoded) |im| for (im.items) |it| switch (it.kind) {
        .func => imp_func_count += 1,
        .table => imp_table_count += 1,
        .memory => imp_memory_count += 1,
        .global => imp_global_count += 1,
    };

    if (imp_func_count > 0) {
        // Per ADR-0014 §2.1 / 6.K.3: imported functions split into
        // two routing strategies — WASI imports go through the
        // store's WASI host (existing path); non-WASI imports go
        // through a cross-module call thunk that switches the
        // operand stack into the source instance's runtime.
        var has_wasi_import = false;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .func) continue;
            if (std.mem.eql(u8, it.module, "wasi_snapshot_preview1")) {
                has_wasi_import = true;
            }
        };
        if (has_wasi_import) {
            const store = inst.store orelse return error.WasiNotConfigured;
            if (store.wasi_host == null) return error.WasiNotConfigured;
        }
    }

    // Type / function / code sections may be absent for modules
    // that only re-export imports (e.g. an emscripten "env" stub
    // that exports memory + globals + functions for the next
    // module to import). Handle their absence by leaving the
    // function table empty rather than short-circuiting before
    // memory + table + element + export wiring.
    const code_section_opt = module.find(.code);
    const func_section = module.find(.function);
    const type_section_opt = module.find(.@"type");

    const types = if (type_section_opt) |s|
        try sections.decodeTypes(a, s.body)
    else
        sections.Types{ .arena = std.heap.ArenaAllocator.init(a), .items = &.{} };

    // Defined-function lowering. If there's no code section,
    // `funcs` stays empty — valid for import-only modules.
    var funcs: []zir.ZirFunc = &.{};
    if (code_section_opt) |code_section| {
        const def_idx = if (func_section) |s|
            try sections.decodeFunctions(a, s.body)
        else
            try a.alloc(u32, 0);

        const codes = try sections.decodeCodes(a, code_section.body);
        if (codes.items.len != def_idx.len) return error.InvalidModule;

        funcs = try a.alloc(zir.ZirFunc, codes.items.len);
        for (codes.items, def_idx, 0..) |code, type_idx, i| {
            if (type_idx >= types.items.len) return error.InvalidTypeIndex;
            funcs[i] = zir.ZirFunc.init(@intCast(imp_func_count + i), types.items[type_idx], code.locals);
            try lowerer.lowerFunctionBody(a, code.body, &funcs[i], types.items);
            // §9.6 / 6.6: populate loop_info so the verifier has
            // something analysis-derived to check, then run the
            // §9.5 / 5.5 invariant pass. Both slices live on the
            // per-instance arena alongside the lowered ZirFunc.
            funcs[i].loop_info = try loop_info_mod.compute(a, &funcs[i]);
            verifier_mod.verify(&funcs[i]) catch return error.InvalidModule;
        }
    }
    inst.funcs_storage = funcs;

    // Build the funcidx-space func-pointer table: `imp_func_count`
    // placeholder entries first (the host_calls table short-
    // circuits these in `callOp`; the placeholder ZirFunc traps
    // if dispatch ever reaches it), then the defined ZirFuncs.
    const total_funcs = imp_func_count + funcs.len;
    const func_ptrs = try a.alloc(*const zir.ZirFunc, total_funcs);
    if (imp_func_count > 0) {
        const placeholder = try a.create(zir.ZirFunc);
        placeholder.* = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
        try placeholder.instrs.append(a, .{ .op = .@"unreachable", .payload = 0, .extra = 0 });
        for (0..imp_func_count) |i| func_ptrs[i] = placeholder;
    }
    for (funcs, 0..) |*f, i| func_ptrs[imp_func_count + i] = f;
    inst.func_ptrs_storage = func_ptrs;

    // host_calls — wire each imported func to either a WASI thunk
    // (`wasi_snapshot_preview1` imports) or a cross-module call
    // thunk (other imports per ADR-0014 §2.1 / 6.K.3). The cross-
    // module thunk pops args off the importer's operand stack,
    // pushes onto the source instance's runtime, runs the source's
    // dispatch on its own runtime context, then copies results
    // back.
    if (imp_func_count > 0) {
        const host_calls = try a.alloc(?runtime.HostCall, total_funcs);
        @memset(host_calls, null);
        var imp_idx: u32 = 0;
        for (imports_decoded.?.items, 0..) |it, idx| {
            if (it.kind != .func) continue;
            if (std.mem.eql(u8, it.module, "wasi_snapshot_preview1")) {
                const wasi_host_ptr: *anyopaque = @ptrCast(inst.store.?.wasi_host.?);
                const thunk = wasi.lookupWasiThunk(it.name).?;
                host_calls[imp_idx] = .{ .fn_ptr = thunk, .ctx = wasi_host_ptr };
            } else {
                const ext = (imports orelse return error.UnknownImportModule)[idx] orelse
                    return error.UnknownImportModule;
                const source_inst = ext.instance orelse return error.UnknownImportModule;
                const source_rt = source_inst.runtime orelse return error.UnknownImportModule;
                const source_funcidx = blk: {
                    for (source_inst.exports_storage) |exp| {
                        if (exp.kind == .func and std.mem.eql(u8, exp.name, it.name))
                            break :blk exp.idx;
                    }
                    return error.UnknownImportModule;
                };
                const ctx_ptr = try a.create(cross_module.CallCtx);
                ctx_ptr.* = .{
                    .source_rt = source_rt,
                    .source_funcidx = source_funcidx,
                    .dispatch_table = dispatchTable(),
                };
                host_calls[imp_idx] = .{
                    .fn_ptr = cross_module.thunk,
                    .ctx = @ptrCast(ctx_ptr),
                };
            }
            imp_idx += 1;
        }
        rt.host_calls = host_calls;
    }

    rt.funcs = func_ptrs;
    rt.module_types = types.items;

    // §9.6 / 6.K.1 (ADR-0014 §2.1): per-instance FuncEntity array
    // parallel to func_ptrs. Defined funcs point at this Runtime;
    // imported funcs (per 6.K.3) point at the source instance's
    // runtime so call_indirect through a foreign-funcref cell
    // routes to the source's body via FuncEntity.runtime.
    if (total_funcs > 0) {
        const entities = try a.alloc(runtime.FuncEntity, total_funcs);
        for (0..total_funcs) |i| entities[i] = .{
            .runtime = rt,
            .func_idx = @intCast(i),
        };
        if (imp_func_count > 0 and imports_decoded != null) {
            var imp_idx: u32 = 0;
            for (imports_decoded.?.items, 0..) |it, idx| {
                if (it.kind != .func) continue;
                if (std.mem.eql(u8, it.module, "wasi_snapshot_preview1")) {
                    // WASI funcref isn't a realistic case (WASI
                    // is called by funcidx, not by ref); leave
                    // the local-placeholder pointer in place.
                    imp_idx += 1;
                    continue;
                }
                const ext = (imports orelse return error.UnknownImportModule)[idx] orelse
                    return error.UnknownImportModule;
                const source_inst = ext.instance orelse return error.UnknownImportModule;
                const source_rt = source_inst.runtime orelse return error.UnknownImportModule;
                const source_funcidx = blk: {
                    for (source_inst.exports_storage) |exp| {
                        if (exp.kind == .func and std.mem.eql(u8, exp.name, it.name))
                            break :blk exp.idx;
                    }
                    return error.UnknownImportModule;
                };
                entities[imp_idx] = .{
                    .runtime = source_rt,
                    .func_idx = source_funcidx,
                };
                imp_idx += 1;
            }
        }
        rt.func_entities = entities;
    }

    // §9.4 / 4.10 chunk b + §9.6 / 6.E iter 7: memory + data
    // section wiring. If the module imports a memory, alias the
    // source instance's slice (no allocation, no copy — both
    // modules see/mutate the same bytes). Otherwise allocate
    // locally based on the memory section's initial pages.
    if (imp_memory_count > 1) return error.MultiMemoryUnsupported;
    if (imp_memory_count == 1) {
        if (imports_decoded) |im| for (im.items, 0..) |it, idx| {
            if (it.kind != .memory) continue;
            const ext = imports.?[idx] orelse return error.UnknownImportModule;
            const source_inst = ext.instance orelse return error.UnknownImportModule;
            const source_rt = source_inst.runtime orelse return error.UnknownImportModule;
            // Per ADR-0014 §2.2 / 6.K.2: arena `free` is a no-op,
            // so the importer can hold the slice header without a
            // borrowed flag. The source's arena owns the bytes
            // and reclaims them at source-instance teardown.
            rt.memory = source_rt.memory;
            break;
        };
    } else if (module.find(.memory)) |memory_section| {
        var memories = try sections.decodeMemory(a, memory_section.body);
        defer memories.deinit();
        if (memories.items.len > 1) return error.MultiMemoryUnsupported;
        if (memories.items.len == 1) {
            const pages = memories.items[0].min;
            const bytes_total: usize = @as(usize, pages) * 65536;
            const mem = try a.alloc(u8, bytes_total);
            @memset(mem, 0);
            rt.memory = mem; // arena-owned; reclaimed at instance teardown
            dbg.print("c_api.alloc", "memory rt={x} ptr={x} len={d}", .{
                @intFromPtr(rt), @intFromPtr(mem.ptr), mem.len,
            });
        }
    }

    if (module.find(.data)) |data_section| {
        var datas = try sections.decodeData(a, data_section.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue; // passive = §9.4 / 4.10c+
            if (seg.memidx != 0) return error.MultiMemoryUnsupported;
            const offset = try evalConstI32Expr(seg.offset_expr);
            const dst_end = @as(usize, @intCast(offset)) + seg.bytes.len;
            if (dst_end > rt.memory.len) return error.DataSegmentOutOfRange;
            @memcpy(rt.memory[@intCast(offset) .. dst_end], seg.bytes);
        }
    }

    // §9.6 / 6.E iter 5 + iter 7: tables. Allocate one
    // `TableInstance` per total-table-space slot. Imported slots
    // alias the source instance's `refs` slice (so `table.copy`
    // / `table.set` / `table.grow` mutate the shared cells).
    // Defined slots get freshly allocated refs from `parent_alloc`
    // so realloc against `rt.alloc` is well-formed.
    {
        var tables_owned: ?sections.Tables = if (module.find(.table)) |s|
            try sections.decodeTables(a, s.body)
        else
            null;
        defer if (tables_owned) |*t| t.deinit();
        const def_table_count: u32 = if (tables_owned) |t| @intCast(t.items.len) else 0;
        const total_table_count: u32 = imp_table_count + def_table_count;
        if (total_table_count > 0) {
            const tbl_storage = try a.alloc(runtime.TableInstance, total_table_count);
            // Imported tables first.
            if (imp_table_count > 0) {
                var imp_idx: u32 = 0;
                for (imports_decoded.?.items, 0..) |it, idx| {
                    if (it.kind != .table) continue;
                    const ext = imports.?[idx] orelse return error.UnknownImportModule;
                    const source_inst = ext.instance orelse return error.UnknownImportModule;
                    const source_rt = source_inst.runtime orelse return error.UnknownImportModule;
                    if (ext.table_idx >= source_rt.tables.len) return error.UnknownImportModule;
                    tbl_storage[imp_idx] = source_rt.tables[ext.table_idx];
                    imp_idx += 1;
                }
            }
            // Then defined tables. Allocated from the per-instance
            // arena (ADR-0014 §2.2 / 6.K.2) so `table.grow`'s
            // realloc against `rt.alloc` lands on the same arena.
            if (tables_owned) |t| for (t.items, 0..) |entry, i| {
                const refs = try a.alloc(runtime.Value, entry.min);
                for (refs) |*r| r.* = .{ .ref = runtime.Value.null_ref };
                tbl_storage[imp_table_count + i] = .{
                    .refs = refs,
                    .elem_type = entry.elem_type,
                    .max = entry.max,
                };
            };
            rt.tables = tbl_storage;
        }
    }

    // §9.6 / 6.E iter 5: element segments. Resolve each segment's
    // funcidxs into a runtime ref slice. Per ADR-0014 §2.1 / 6.K.1,
    // each entry is `@intFromPtr(&rt.func_entities[fidx])` so
    // dispatch through the cell carries source-runtime identity.
    // Active segments additionally write their refs into the
    // referenced table at the const-expr-evaluated offset, then
    // count as immediately dropped (per spec); declarative
    // segments are dropped on instantiation as well.
    if (module.find(.element)) |elem_section| {
        var elems = try sections.decodeElement(a, elem_section.body);
        defer elems.deinit();
        if (elems.items.len > 0) {
            const seg_storage = try a.alloc([]const runtime.Value, elems.items.len);
            const dropped = try a.alloc(bool, elems.items.len);
            @memset(dropped, false);
            for (elems.items, 0..) |seg, idx| {
                const refs = try a.alloc(runtime.Value, seg.funcidxs.len);
                for (seg.funcidxs, 0..) |fidx, j| {
                    refs[j] = if (fidx == std.math.maxInt(u32))
                        .{ .ref = runtime.Value.null_ref }
                    else if (fidx < rt.func_entities.len)
                        runtime.Value.fromFuncRef(&rt.func_entities[fidx])
                    else
                        return error.InvalidElementFuncIndex;
                }
                seg_storage[idx] = refs;
                if (seg.kind == .active) {
                    if (seg.tableidx >= rt.tables.len) return error.InvalidTableIndex;
                    const offset = try evalConstI32Expr(seg.offset_expr);
                    const off_usize: usize = @intCast(offset);
                    const dst_end = off_usize + refs.len;
                    if (dst_end > rt.tables[seg.tableidx].refs.len) return error.ElementSegmentOutOfRange;
                    @memcpy(rt.tables[seg.tableidx].refs[off_usize..dst_end], refs);
                    dropped[idx] = true;
                } else if (seg.kind == .declarative) {
                    dropped[idx] = true;
                }
            }
            rt.elems = seg_storage;
            rt.elem_dropped = dropped;
        }
    }

    // §9.6 / 6.K.3 (ADR-0014 §2.1): wired globals — imported
    // globals alias source-instance storage via per-slot pointer
    // (`Runtime.globals: []*Value`); defined globals point at
    // arena-owned slots in `globals_storage`.
    {
        var defined_count: usize = 0;
        if (module.find(.global)) |global_section| {
            var globals = try sections.decodeGlobals(a, global_section.body);
            defer globals.deinit();
            defined_count = globals.items.len;

            const total = imp_global_count + defined_count;
            if (total > 0) {
                const slots = try a.alloc(*runtime.Value, total);
                const storage = try a.alloc(runtime.Value, defined_count);
                if (imp_global_count > 0 and imports_decoded != null) {
                    var imp_idx: u32 = 0;
                    for (imports_decoded.?.items, 0..) |it, idx| {
                        if (it.kind != .global) continue;
                        const ext = (imports orelse return error.UnknownImportModule)[idx] orelse
                            return error.UnknownImportModule;
                        const source_inst = ext.instance orelse return error.UnknownImportModule;
                        const source_rt = source_inst.runtime orelse return error.UnknownImportModule;
                        if (ext.global_idx >= source_rt.globals.len) return error.UnknownImportModule;
                        slots[imp_idx] = source_rt.globals[ext.global_idx];
                        imp_idx += 1;
                    }
                }
                for (globals.items, 0..) |g, i| {
                    storage[i] = try evalConstExprValue(g.init_expr);
                    slots[imp_global_count + i] = &storage[i];
                }
                rt.globals = slots;
                rt.globals_storage = storage;
            }
        } else if (imp_global_count > 0 and imports_decoded != null) {
            // Module has no defined globals but imports some.
            const slots = try a.alloc(*runtime.Value, imp_global_count);
            var imp_idx: u32 = 0;
            for (imports_decoded.?.items, 0..) |it, idx| {
                if (it.kind != .global) continue;
                const ext = (imports orelse return error.UnknownImportModule)[idx] orelse
                    return error.UnknownImportModule;
                const source_inst = ext.instance orelse return error.UnknownImportModule;
                const source_rt = source_inst.runtime orelse return error.UnknownImportModule;
                if (ext.global_idx >= source_rt.globals.len) return error.UnknownImportModule;
                slots[imp_idx] = source_rt.globals[ext.global_idx];
                imp_idx += 1;
            }
            rt.globals = slots;
        }
    }

    if (module.find(.@"export")) |export_section| {
        const exports = try sections.decodeExports(a, export_section.body);
        inst.exports_storage = exports.items;
        // Populate parallel export_types so cross-module imports
        // can validate type-equality at the c_api boundary.
        inst.export_types = try buildExportTypes(a, module, exports.items, imports_decoded);
    }
}

/// Wasm 2.0 §3.4.10 import-matching check. The importer's
/// `it.payload` carries its expected type; the source's
/// `ext` reaches the source `Instance.export_types[ext.<idx>]`
/// for the actual exported type. Matching rules (per spec):
/// - Func: signatures must be equal (params / results in-order).
/// - Global: valtype + mutability must be equal.
/// - Table: elem_type must match; min must satisfy
///   `source_min >= importer_min`; if importer specifies max,
///   source must too AND `source_max <= importer_max`.
/// - Memory: same min/max sub-typing as table (no elem_type).
fn checkImportTypeMatches(a: std.mem.Allocator, module: runtime.Module, it: sections.Import, ext: *const Extern) !void {
    const source_inst = ext.instance orelse return error.ImportTypeMismatch;
    const idx: usize = switch (it.kind) {
        .func => blk: {
            const fh = ext.func orelse return error.ImportTypeMismatch;
            break :blk @intCast(fh.func_idx);
        },
        .global => @intCast(ext.global_idx),
        .table => @intCast(ext.table_idx),
        .memory => @intCast(ext.memory_idx),
    };
    // Find the matching entry in source's export_types via name match.
    if (source_inst.exports_storage.len != source_inst.export_types.len)
        return error.ImportTypeMismatch;
    const src_type: ExportType = blk: {
        for (source_inst.exports_storage, 0..) |exp, i| {
            const exp_kind: sections.ImportKind = switch (exp.kind) {
                .func => .func,
                .table => .table,
                .memory => .memory,
                .global => .global,
            };
            if (exp_kind == it.kind and exp.idx == idx) {
                break :blk source_inst.export_types[i];
            }
        }
        return error.ImportTypeMismatch;
    };
    switch (it.kind) {
        .func => {
            const want_tidx = it.payload.func_typeidx;
            // Resolve importer's typeidx via its type section.
            const type_sec = module.find(.@"type") orelse return error.ImportTypeMismatch;
            var types = try sections.decodeTypes(a, type_sec.body);
            defer types.deinit();
            if (want_tidx >= types.items.len) return error.ImportTypeMismatch;
            const want_ft = types.items[want_tidx];
            switch (src_type) {
                .func => |sft| {
                    if (sft.params.len != want_ft.params.len) return error.ImportTypeMismatch;
                    if (sft.results.len != want_ft.results.len) return error.ImportTypeMismatch;
                    for (sft.params, want_ft.params) |sp, wp| {
                        if (sp != wp) return error.ImportTypeMismatch;
                    }
                    for (sft.results, want_ft.results) |sr, wr| {
                        if (sr != wr) return error.ImportTypeMismatch;
                    }
                },
                else => return error.ImportTypeMismatch,
            }
        },
        .global => {
            const want = it.payload.global;
            switch (src_type) {
                .global => |sg| {
                    if (sg.valtype != want.valtype) return error.ImportTypeMismatch;
                    if (sg.mutable != want.mutable) return error.ImportTypeMismatch;
                },
                else => return error.ImportTypeMismatch,
            }
        },
        .table => {
            const want = it.payload.table;
            switch (src_type) {
                .table => |st| {
                    if (st.elem_type != want.elem_type) return error.ImportTypeMismatch;
                    if (st.min < want.min) return error.ImportTypeMismatch;
                    if (want.max) |wm| {
                        const sm = st.max orelse return error.ImportTypeMismatch;
                        if (sm > wm) return error.ImportTypeMismatch;
                    }
                },
                else => return error.ImportTypeMismatch,
            }
        },
        .memory => {
            const want = it.payload.memory;
            switch (src_type) {
                .memory => |sm| {
                    if (sm.min < want.min) return error.ImportTypeMismatch;
                    if (want.max) |wm| {
                        const max_s = sm.max orelse return error.ImportTypeMismatch;
                        if (max_s > wm) return error.ImportTypeMismatch;
                    }
                },
                else => return error.ImportTypeMismatch,
            }
        },
    }
}

/// Resolve each export's structural type so import-side
/// validation is a direct compare. For each export:
/// - Func: walk imports + defined-funcs to find which one is at
///   `idx`; resolve typeidx via the source's type section.
/// - Global: walk imports + decoded globals for type info.
/// - Table: walk imports + decoded tables for elem_type + limits.
/// - Memory: walk imports + decoded memories for limits.
fn buildExportTypes(
    a: std.mem.Allocator,
    module: runtime.Module,
    exports_items: []sections.Export,
    imports_decoded: ?sections.Imports,
) ![]ExportType {
    if (exports_items.len == 0) return &.{};
    const out = try a.alloc(ExportType, exports_items.len);
    errdefer a.free(out);

    // Decode the type section once (used for func sig resolution).
    var types_owned: ?sections.Types = null;
    defer if (types_owned) |*t| t.deinit();
    if (module.find(.@"type")) |s| {
        types_owned = try sections.decodeTypes(a, s.body);
    }
    var func_section_funcs: ?[]u32 = null;
    if (module.find(.function)) |s| {
        func_section_funcs = try sections.decodeFunctions(a, s.body);
    }
    defer if (func_section_funcs) |slice| a.free(slice);

    var defined_globals: ?sections.Globals = null;
    defer if (defined_globals) |*g| g.deinit();
    if (module.find(.global)) |s| {
        defined_globals = try sections.decodeGlobals(a, s.body);
    }
    var defined_tables: ?sections.Tables = null;
    defer if (defined_tables) |*t| t.deinit();
    if (module.find(.table)) |s| {
        defined_tables = try sections.decodeTables(a, s.body);
    }
    var defined_memories: ?sections.Memories = null;
    defer if (defined_memories) |*m| m.deinit();
    if (module.find(.memory)) |s| {
        defined_memories = try sections.decodeMemory(a, s.body);
    }

    for (exports_items, 0..) |exp, i| {
        out[i] = switch (exp.kind) {
            .func => blk: {
                // Find this funcidx among (imports' funcs ++ defined funcs).
                var imp_count: u32 = 0;
                if (imports_decoded) |im| {
                    var idx: u32 = 0;
                    for (im.items) |it| {
                        if (it.kind != .func) continue;
                        if (idx == exp.idx) {
                            const tidx = it.payload.func_typeidx;
                            const ft = if (types_owned) |t| t.items[tidx] else
                                return error.UnsupportedImport;
                            break :blk .{ .func = ft };
                        }
                        idx += 1;
                    }
                    imp_count = idx; // total func imports walked
                }
                // Defined func: index = exp.idx - imp_count
                const def_idx = exp.idx - imp_count;
                const fs = func_section_funcs orelse return error.UnsupportedImport;
                if (def_idx >= fs.len) return error.UnsupportedImport;
                const tidx = fs[def_idx];
                const ft = if (types_owned) |t| t.items[tidx] else
                    return error.UnsupportedImport;
                break :blk .{ .func = ft };
            },
            .table => blk: {
                var imp_count: u32 = 0;
                if (imports_decoded) |im| {
                    var idx: u32 = 0;
                    for (im.items) |it| {
                        if (it.kind != .table) continue;
                        if (idx == exp.idx) {
                            const t = it.payload.table;
                            break :blk .{ .table = .{ .elem_type = t.elem_type, .min = t.min, .max = t.max } };
                        }
                        idx += 1;
                    }
                    imp_count = idx;
                }
                const def_idx = exp.idx - imp_count;
                const dt = (defined_tables orelse return error.UnsupportedImport).items;
                if (def_idx >= dt.len) return error.UnsupportedImport;
                const t = dt[def_idx];
                break :blk .{ .table = .{ .elem_type = t.elem_type, .min = t.min, .max = t.max } };
            },
            .memory => blk: {
                var imp_count: u32 = 0;
                if (imports_decoded) |im| {
                    var idx: u32 = 0;
                    for (im.items) |it| {
                        if (it.kind != .memory) continue;
                        if (idx == exp.idx) {
                            const m = it.payload.memory;
                            break :blk .{ .memory = .{ .min = m.min, .max = m.max } };
                        }
                        idx += 1;
                    }
                    imp_count = idx;
                }
                const def_idx = exp.idx - imp_count;
                const dm = (defined_memories orelse return error.UnsupportedImport).items;
                if (def_idx >= dm.len) return error.UnsupportedImport;
                const m = dm[def_idx];
                break :blk .{ .memory = .{ .min = m.min, .max = m.max } };
            },
            .global => blk: {
                var imp_count: u32 = 0;
                if (imports_decoded) |im| {
                    var idx: u32 = 0;
                    for (im.items) |it| {
                        if (it.kind != .global) continue;
                        if (idx == exp.idx) {
                            const g = it.payload.global;
                            break :blk .{ .global = .{ .valtype = g.valtype, .mutable = g.mutable } };
                        }
                        idx += 1;
                    }
                    imp_count = idx;
                }
                const def_idx = exp.idx - imp_count;
                const dg = (defined_globals orelse return error.UnsupportedImport).items;
                if (def_idx >= dg.len) return error.UnsupportedImport;
                const g = dg[def_idx];
                break :blk .{ .global = .{ .valtype = g.valtype, .mutable = g.mutable } };
            },
        };
    }
    return out;
}

/// Evaluate a global init-expression and return the initial Value.
/// Supported shapes for v0.1.0: `<i32|i64|f32|f64>.const N; end`
/// and `ref.null funcref|externref; end`. `global.get N` (importing
/// from another module's globals) defers with the rest of cross-
/// module global imports.
fn evalConstExprValue(expr: []const u8) !runtime.Value {
    if (expr.len < 2) return error.UnsupportedConstExpr;
    const leb = @import("../support/leb128.zig");
    var pos: usize = 1;
    const v: runtime.Value = switch (expr[0]) {
        0x41 => blk: {
            const n = try leb.readSleb128(i32, expr, &pos);
            break :blk .{ .i32 = n };
        },
        0x42 => blk: {
            const n = try leb.readSleb128(i64, expr, &pos);
            break :blk .{ .i64 = n };
        },
        0x43 => blk: {
            if (pos + 4 > expr.len) return error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u32, expr[pos..][0..4], .little);
            pos += 4;
            break :blk .{ .bits64 = bits };
        },
        0x44 => blk: {
            if (pos + 8 > expr.len) return error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u64, expr[pos..][0..8], .little);
            pos += 8;
            break :blk .{ .bits64 = bits };
        },
        0xD0 => blk: {
            if (pos >= expr.len) return error.UnsupportedConstExpr;
            pos += 1;
            break :blk .{ .ref = runtime.Value.null_ref };
        },
        else => return error.UnsupportedConstExpr,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
    return v;
}

/// Evaluate a Wasm const-expression that resolves to an i32.
/// Active data-segment offsets currently reach this path; the
/// only shape v0.1.0 needs is `i32.const N; end` (3+ bytes:
/// opcode 0x41, sleb128 N, opcode 0x0B).
fn evalConstI32Expr(expr: []const u8) !i32 {
    if (expr.len < 2 or expr[0] != 0x41) return error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v = try @import("../support/leb128.zig").readSleb128(i32, expr, &pos);
    if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
    return v;
}

/// `wasm_instance_new(store, module, imports, trap_out)` —
/// allocate an Instance bound to the given Module and lower its
/// code into the owned Runtime. The `imports` and `trap_out`
/// parameters are full-shape per upstream wasm.h but stubbed
/// here (`anyopaque` / unused) until §9.3 / 3.6 chunk b wires
/// `wasm_func_call` and §9.3 / 3.7 wires `wasm_extern_vec_t` /
/// `wasm_trap_t`. Returns null on any null required input,
/// instantiation failure, or OOM.
pub export fn wasm_instance_new(
    s: ?*Store,
    m: ?*const Module,
    imports: ?*const anyopaque,
    trap_out: ?*?*Trap,
) callconv(.c) ?*Instance {
    _ = trap_out;
    const store = s orelse return null;
    const module = m orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    // Upstream wasm.h declares `imports` as `wasm_extern_t* const
    // imports[]`. We accept it as an opaque pointer and recast
    // here to keep the C ABI byte-identical while letting the
    // Zig side hand a typed slice to `instantiateRuntime`.
    const imports_array: ?[*]const ?*const Extern = if (imports) |p|
        @as([*]const ?*const Extern, @ptrCast(@alignCast(p)))
    else
        null;

    const inst_rt = alloc.create(runtime.Runtime) catch return null;
    inst_rt.* = runtime.Runtime.init(alloc);

    const inst = alloc.create(Instance) catch {
        inst_rt.deinit();
        alloc.destroy(inst_rt);
        return null;
    };
    inst.* = .{
        .store = store,
        .module = module,
        .runtime = inst_rt,
    };

    const bytes_ptr = module.bytes_ptr orelse {
        inst_rt.deinit();
        alloc.destroy(inst_rt);
        alloc.destroy(inst);
        return null;
    };
    instantiateRuntime(alloc, bytes_ptr[0..module.bytes_len], inst, inst_rt, imports_array) catch {
        // Per ADR-0014 §2.1 / 6.K.2 sub-change 4: park the failed
        // instance's runtime + arena on the store's zombie list.
        // Wasm 2.0 partial-init semantics may have committed
        // cross-module writes (foreign tables holding *FuncEntity
        // pointers into our arena); destroying the arena would
        // turn those into dangling pointers and segfault later
        // call_indirect dispatches.
        if (inst.arena) |arena| {
            // If parkAsZombie itself OOMs the store list, we have
            // no graceful recovery — accept the leak (arena +
            // runtime stay around until process exit) and report
            // the original instantiation failure.
            parkAsZombie(alloc, store, inst_rt, arena) catch {};
            inst.arena = null;
        } else {
            // No arena to park (e.g., parser/import-decode failed
            // before arena setup). Safe to fully free.
            inst_rt.deinit();
            alloc.destroy(inst_rt);
        }
        // Instance struct itself can go: the C-API caller never
        // sees it (we return null below). The runtime + arena
        // outlived it via the zombie list.
        inst.funcs_storage = &.{};
        inst.func_ptrs_storage = &.{};
        alloc.destroy(inst);
        return null;
    };
    return inst;
}

/// `wasm_instance_delete(*Instance)` — release the C-side
/// `wasm_instance_t` handle. Per ADR-0014 §2.1 / 6.K.2 sub-
/// change 4 the underlying runtime + arena park as a zombie on
/// the store: cross-module funcrefs into this instance's funcs
/// from sibling instances stay valid until `wasm_store_delete`
/// reaps the zombie. Mirrors wasmtime's instance-Arc lifetime
/// (`store.rs:146`) and wazero's `involvingModuleInstances`
/// (`internal/wasm/table.go:104`).
///
/// Null-tolerant.
pub export fn wasm_instance_delete(i: ?*Instance) callconv(.c) void {
    const handle = i orelse return;
    const store = handle.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    if (handle.runtime) |rt| {
        if (handle.arena) |arena| {
            // Park instead of free. If parkAsZombie OOMs we accept
            // the arena leak (process exit cleans it up) rather
            // than UAF the cross-module references.
            parkAsZombie(alloc, store, rt, arena) catch {};
            handle.arena = null;
        } else {
            // Pre-arena state (couldn't happen on the success
            // path but defensive): free the runtime directly.
            rt.deinit();
            alloc.destroy(rt);
        }
    }
    handle.funcs_storage = &.{};
    handle.func_ptrs_storage = &.{};
    alloc.destroy(handle);
}

// ============================================================
// Func + dispatch (§9.3 / 3.6 chunk b)
// ============================================================

/// Process-wide dispatch-table cache. Lazily populated on first
/// call. The table maps `ZirOp` → handler and is identical across
/// every Engine in a process, so a single shared instance is the
/// natural shape (and avoids re-running registration on every
/// `wasm_func_call`). Single-threaded for Phases 1-9 per the
/// project's threading discipline; `std.atomic` once-init lands
/// alongside the threads proposal post-v0.1.0.
var g_dispatch_table_storage: dispatch_table_mod.DispatchTable = undefined;
var g_dispatch_table_initialized: bool = false;

fn dispatchTable() *const dispatch_table_mod.DispatchTable {
    if (!g_dispatch_table_initialized) {
        g_dispatch_table_storage = .init();
        interp_mvp.register(&g_dispatch_table_storage);
        ext_sign_ext.register(&g_dispatch_table_storage);
        ext_sat_trunc.register(&g_dispatch_table_storage);
        ext_bulk_memory.register(&g_dispatch_table_storage);
        ext_ref_types.register(&g_dispatch_table_storage);
        ext_table_ops.register(&g_dispatch_table_storage);
        g_dispatch_table_initialized = true;
    }
    return &g_dispatch_table_storage;
}

/// `zwasm_instance_get_func` — project-extension helper that
/// resolves an Instance + function index into a fresh `Func`
/// handle. The C host owns the returned pointer and must call
/// `wasm_func_delete`. Folds into upstream `wasm_instance_exports`
/// + `wasm_extern_vec_t` indexing alongside §9.3 / 3.7.
pub export fn zwasm_instance_get_func(i: ?*Instance, idx: u32) callconv(.c) ?*Func {
    const inst = i orelse return null;
    const store = inst.store orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    if (idx >= inst.funcs_storage.len) return null;
    const f = alloc.create(Func) catch return null;
    f.* = .{ .instance = inst, .func_idx = idx };
    return f;
}

/// `wasm_func_delete(*Func)` — free a `Func` handle returned by
/// `zwasm_instance_get_func`. Null-tolerant.
pub export fn wasm_func_delete(f: ?*Func) callconv(.c) void {
    const handle = f orelse return;
    const inst = handle.instance orelse return;
    const store = inst.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    alloc.destroy(handle);
}

fn marshalValIn(v: Val) runtime.Value {
    return switch (v.kind) {
        .i32 => .{ .i32 = v.of.i32 },
        .i64 => .{ .i64 = v.of.i64 },
        .f32 => .{ .bits64 = @as(u64, @as(u32, @bitCast(v.of.f32))) },
        .f64 => .{ .bits64 = @bitCast(v.of.f64) },
        .anyref, .funcref => .{ .ref = if (v.of.ref) |p| @intFromPtr(p) else runtime.Value.null_ref },
    };
}

fn marshalValOut(v: runtime.Value, kind: zir.ValType) Val {
    return switch (kind) {
        .i32 => .{ .kind = .i32, .of = .{ .i32 = v.i32 } },
        .i64 => .{ .kind = .i64, .of = .{ .i64 = v.i64 } },
        .f32 => .{ .kind = .f32, .of = .{ .f32 = @bitCast(@as(u32, @truncate(v.bits64))) } },
        .f64 => .{ .kind = .f64, .of = .{ .f64 = @bitCast(v.bits64) } },
        .funcref => .{ .kind = .funcref, .of = .{ .ref = if (v.ref == runtime.Value.null_ref) null else @ptrFromInt(v.ref) } },
        .externref => .{ .kind = .anyref, .of = .{ .ref = if (v.ref == runtime.Value.null_ref) null else @ptrFromInt(v.ref) } },
        .v128 => .{ .kind = .i64, .of = .{ .i64 = 0 } }, // unreachable for MVP
    };
}

// ============================================================
// wasm_extern_t + wasm_instance_exports (§9.3 / 3.7 chunk c)
// ============================================================

fn exportDescToExternKind(kind: sections.ExportDesc) ExternKind {
    return switch (kind) {
        .func => .func,
        .global => .global,
        .table => .table,
        .memory => .memory,
    };
}

/// `wasm_extern_kind` — return the upstream-numeric tag.
pub export fn wasm_extern_kind(e: ?*const Extern) callconv(.c) u8 {
    const handle = e orelse return @intFromEnum(ExternKind.func);
    return @intFromEnum(handle.kind);
}

/// `wasm_extern_delete(*Extern)` — free an Extern handle and
/// the contained Func (if any). Null-tolerant.
pub export fn wasm_extern_delete(e: ?*Extern) callconv(.c) void {
    const handle = e orelse return;
    if (handle.func) |fh| wasm_func_delete(fh);
    const inst = handle.instance orelse return;
    const store = inst.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    alloc.destroy(handle);
}

/// `wasm_extern_as_func(*Extern)` — borrow the Func contained in
/// an Extern. Returns null if the Extern is not of kind func.
/// **Ownership stays with the Extern**; callers must NOT call
/// `wasm_func_delete` on the returned pointer (matches upstream
/// wasm.h discipline for the `_as_*` family).
pub export fn wasm_extern_as_func(e: ?*Extern) callconv(.c) ?*Func {
    const handle = e orelse return null;
    if (handle.kind != .func) return null;
    return handle.func;
}

// --- extern vec (pointer-vec; vec_delete also frees pointed-to objects)
//
// `wasm_extern_vec_new_empty` / `_new_uninitialized` / `_new`
// live in `src/api/vec.zig`; only the delete cascade lives
// here because it must call back into `wasm_extern_delete`.

/// `wasm_extern_vec_delete(*ExternVec)` — free the vec's pointer
/// array AND each non-null pointed-to Extern (per upstream's
/// pointer-vec ownership rule for `WASM_DECLARE_REF` types).
pub export fn wasm_extern_vec_delete(v: ?*ExternVec) callconv(.c) void {
    const handle = v orelse return;
    if (handle.data) |dp| {
        for (dp[0..handle.size]) |opt_ext| {
            if (opt_ext) |ext| wasm_extern_delete(ext);
        }
        std.heap.c_allocator.free(dp[0..handle.size]);
    }
    handle.* = .{ .size = 0, .data = null };
}

/// `wasm_instance_exports(*Instance, *out vec)` — populate `out`
/// with one Extern per decoded export from the Module's export
/// section. Each Extern's contained `Func` (when kind == func)
/// resolves to the Instance's lowered ZirFunc index. The vec is
/// owned by the caller and must be released with
/// `wasm_extern_vec_delete`.
///
/// On any allocation failure the populated prefix is rolled back
/// so the out vec is either fully populated or empty — never
/// partially populated.
pub export fn wasm_instance_exports(i: ?*const Instance, out: ?*ExternVec) callconv(.c) void {
    const o = out orelse return;
    o.* = .{ .size = 0, .data = null };
    const inst = i orelse return;
    const store = inst.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    if (inst.exports_storage.len == 0) return;

    const buf = std.heap.c_allocator.alloc(?*Extern, inst.exports_storage.len) catch return;
    @memset(buf, null);
    var populated: usize = 0;

    for (inst.exports_storage, 0..) |exp, idx| {
        const ext = alloc.create(Extern) catch break;
        ext.* = .{
            .kind = exportDescToExternKind(exp.kind),
            .instance = @constCast(inst),
        };
        switch (ext.kind) {
            .func => {
                const fh = alloc.create(Func) catch {
                    alloc.destroy(ext);
                    break;
                };
                fh.* = .{ .instance = @constCast(inst), .func_idx = exp.idx };
                ext.func = fh;
            },
            .table => ext.table_idx = exp.idx,
            .memory => ext.memory_idx = exp.idx,
            .global => ext.global_idx = exp.idx,
        }
        buf[idx] = ext;
        populated += 1;
    }

    if (populated != inst.exports_storage.len) {
        // Roll back partial state — release what we did populate
        // and the buffer itself so the caller sees an empty vec.
        for (buf[0..populated]) |opt_ext| {
            if (opt_ext) |ext| wasm_extern_delete(ext);
        }
        std.heap.c_allocator.free(buf);
        return;
    }

    o.* = .{ .size = inst.exports_storage.len, .data = buf.ptr };
}

/// `wasm_func_call(func, args, results)` — invoke `func` with
/// `args.size` input values, write `results.size` output values
/// into `results.data`, return null on success or a non-null
/// `wasm_trap_t*` on Trap. The Trap surface is stubbed in this
/// chunk (single empty struct); §9.3 / 3.7 fills its message body
/// + lifetime helpers (`wasm_trap_delete` / `wasm_trap_message`).
///
/// Args / result vec sizes must match `func.sig.params.len` /
/// `func.sig.results.len` exactly — mismatch raises a Trap rather
/// than corrupting the operand stack.
pub export fn wasm_func_call(
    f: ?*const Func,
    args: ?*const ValVec,
    results: ?*ValVec,
) callconv(.c) ?*Trap {
    const handle = f orelse return null;
    const inst = handle.instance orelse return null;
    const store = inst.store orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    const rt = inst.runtime orelse return null;
    // `func_ptrs_storage` is the full funcidx-space table
    // (imports first, then defined). For exports referencing
    // imports the dispatch path would still work — the
    // callee's first instruction is the import-placeholder
    // `unreachable`, which short-circuits via host_calls in the
    // dispatch loop. For defined functions the lookup yields
    // the real ZirFunc.
    if (handle.func_idx >= inst.func_ptrs_storage.len) return allocTrap(alloc, store, .binding_error);

    const zfunc = inst.func_ptrs_storage[handle.func_idx];
    const sig = zfunc.sig;
    const args_size = if (args) |a| a.size else 0;
    const results_size = if (results) |r| r.size else 0;
    if (args_size != sig.params.len) return allocTrap(alloc, store, .binding_error);
    if (results_size != sig.results.len) return allocTrap(alloc, store, .binding_error);

    const num_locals = sig.params.len + zfunc.locals.len;
    const locals = alloc.alloc(runtime.Value, num_locals) catch return allocTrap(alloc, store, .out_of_memory);
    defer alloc.free(locals);
    for (locals) |*l| l.* = .{ .bits64 = 0 };
    if (args) |a| if (a.data) |dp| {
        for (0..a.size) |idx| locals[idx] = marshalValIn(dp[idx]);
    };

    const op_base = rt.operand_len;
    rt.pushFrame(.{
        .sig = sig,
        .locals = locals,
        .operand_base = op_base,
        .pc = 0,
        .func = zfunc,
    }) catch |err| return allocTrap(alloc, store, mapInterpTrap(err));

    dispatch.run(rt, dispatchTable(), zfunc.instrs.items) catch |err| {
        _ = rt.popFrame();
        rt.operand_len = op_base;
        return allocTrap(alloc, store, mapInterpTrap(err));
    };
    _ = rt.popFrame();

    if (rt.operand_len < op_base + sig.results.len) {
        rt.operand_len = op_base;
        return allocTrap(alloc, store, .binding_error);
    }
    if (results) |r| if (r.data) |dp| {
        var i: usize = sig.results.len;
        while (i > 0) {
            i -= 1;
            const v = rt.popOperand();
            dp[i] = marshalValOut(v, sig.results[i]);
        }
    };
    rt.operand_len = op_base;
    return null;
}

// ============================================================
// Tests
// ============================================================

test "wasm_engine_new / delete: round-trip + alloc binding survives" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    // The Engine carries c_allocator pointers; verify the round-
    // trip Allocator is usable.
    const alloc = engineAllocator(e);
    const probe = try alloc.alloc(u8, 16);
    defer alloc.free(probe);
    @memset(probe, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), probe[0]);
}

test "wasm_engine_delete: tolerates null handle" {
    wasm_engine_delete(null);
}

test "wasm_store_new / delete: round-trip with engine back-pointer" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);

    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    try testing.expect(s.engine == e);
}

test "zwasm_wasi_config_new / set / store_delete: ownership round-trip" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;

    // Initial: no WASI configured.
    try testing.expect(s.wasi_host == null);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_store_set_wasi(s, cfg);
    try testing.expect(s.wasi_host == @as(*anyopaque, @ptrCast(cfg)));

    // wasm_store_delete tears down the attached host transitively;
    // the test passes if no leak escapes through c_allocator.
    wasm_store_delete(s);
}

test "zwasm_store_set_wasi(*store, null): detaches + frees the existing host" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_store_set_wasi(s, cfg);
    try testing.expect(s.wasi_host != null);
    zwasm_store_set_wasi(s, null);
    try testing.expect(s.wasi_host == null);
}

test "zwasm_store_set_wasi: null-arg discipline" {
    zwasm_store_set_wasi(null, null);
}

test "wasm_store_new(null) returns null; delete(null) tolerates" {
    try testing.expect(wasm_store_new(null) == null);
    wasm_store_delete(null);
}

// Minimal Wasm binary: \0asm \1\0\0\0 + bare type section
// declaring `() -> ()` + function section with one entry +
// code section with `end`.
const minimal_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
    0x03, 0x02, 0x01, 0x00, // function: 1 function, type 0
    0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code: 1 fn, no locals, end
};

test "wasm_module_validate: minimal valid module → true" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    try testing.expect(wasm_module_validate(s, &bv));
}

test "wasm_module_validate: garbage bytes → false" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const bv: ByteVec = .{ .size = garbage.len, .data = &garbage };
    try testing.expect(!wasm_module_validate(s, &bv));
}

test "wasm_module_new / delete: round-trip + bytes copied" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    try testing.expectEqual(bytes.len, m.bytes_len);
    // Bytes are copied — modify our local copy, the Module's
    // owned slice should be untouched.
    bytes[8] = 0xFF;
    try testing.expectEqual(@as(u8, 0x01), m.bytes_ptr.?[8]);
}

test "wasm_module_*: null-arg discipline" {
    try testing.expect(wasm_module_new(null, null) == null);
    try testing.expect(!wasm_module_validate(null, null));
    wasm_module_delete(null);
}

test "wasm_instance_new / delete: round-trip with minimal module" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const i = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    try testing.expect(i.store == s);
    try testing.expect(i.module == @as(*const anyopaque, @ptrCast(m)));
    try testing.expect(i.runtime != null);
}

test "wasm_instance_new: lowers Module funcs into Runtime" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = minimal_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    const i = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    const rt = i.runtime.?;
    // minimal_wasm declares one type and one defined function.
    try testing.expectEqual(@as(usize, 1), rt.funcs.len);
    try testing.expectEqual(@as(usize, 1), rt.module_types.len);
    // The lowered ZirFunc body is `end` only — exactly one
    // instruction.
    try testing.expectEqual(@as(usize, 1), rt.funcs[0].instrs.items.len);
}

test "wasm_instance_*: null-arg discipline" {
    try testing.expect(wasm_instance_new(null, null, null, null) == null);
    wasm_instance_delete(null);
}

// (module (func (result i32) (i32.const 42)))
// Hand-rolled wasm so the dispatch test stays import-free (the
// realworld toolchain wasms pull in WASI imports).
const i32_const_42_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // function: 1 fn, type 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B, // code: i32.const 42, end
};

test "wasm_func_call: i32-returning function dispatches to 42" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = i32_const_42_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const i = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    const func = zwasm_instance_get_func(i, 0) orelse return error.FuncResolveFailed;
    defer wasm_func_delete(func);

    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };
    const args: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(func, &args, &results);
    try testing.expect(trap == null);
    try testing.expectEqual(ValKind.i32, results_data[0].kind);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

test "wasm_func_call: arg-count mismatch returns Trap with message; both freed" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = i32_const_42_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const i = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(i);

    const func = zwasm_instance_get_func(i, 0) orelse return error.FuncResolveFailed;
    defer wasm_func_delete(func);

    // Function takes 0 params but we pass 1. Should trap.
    var bogus_arg: [1]Val = .{.{ .kind = .i32, .of = .{ .i32 = 99 } }};
    const args: ValVec = .{ .size = 1, .data = &bogus_arg };
    const results: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(func, &args, @constCast(&results));
    try testing.expect(trap != null);
    try testing.expectEqual(TrapKind.binding_error, trap.?.kind);

    var msg: ByteVec = .{ .size = 0, .data = null };
    trap_surface.wasm_trap_message(trap, &msg);
    try testing.expect(msg.size > 0);
    vec.wasm_byte_vec_delete(&msg);
    trap_surface.wasm_trap_delete(trap);
}


// Extern-vec null-arg coverage lives here alongside
// `wasm_extern_vec_delete`; byte/val vec round-trip + null-arg
// tests live in `src/api/vec.zig`.

test "wasm_extern_vec_*: null-arg discipline" {
    vec.wasm_extern_vec_new_empty(null);
    vec.wasm_extern_vec_new_uninitialized(null, 16);
    vec.wasm_extern_vec_new(null, 4, null);
    wasm_extern_vec_delete(null);
}

// (module (func (export "main") (result i32) (i32.const 42)))
// Same as i32_const_42_wasm but with an export section between
// function (id 3) and code (id 10).
const i32_const_42_export_main_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x01, 0x00, 0x00, 0x00, // version 1
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // function: 1 fn, type 0
    0x07, 0x08, 0x01, 0x04, 0x6D, 0x61, 0x69, 0x6E, 0x00, 0x00, // export "main" (func 0)
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B, // code: i32.const 42, end
};

// (module (import "env" "foo" (func)))
// Unsupported import: the binding rejects unknown modules at
// `wasm_instance_new` time per §9.4 / 4.7 chunk b.
const env_foo_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
    0x02, 0x0B, 0x01, // import section header + count=1
    0x03, 0x65, 0x6E, 0x76, // "env"
    0x03, 0x66, 0x6F, 0x6F, // "foo"
    0x00, 0x00, // desc = func, typeidx = 0
};

// (module
//   (import "wasi_snapshot_preview1" "fd_write"
//     (func (param i32 i32 i32 i32) (result i32))))
const wasi_fd_write_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type: 1 type, (i32 i32 i32 i32) -> (i32)
    0x01, 0x09, 0x01, 0x60, 0x04, 0x7F, 0x7F, 0x7F, 0x7F, 0x01, 0x7F,
    // import section: count=1, module "wasi_snapshot_preview1"
    // (1 + 22 = 23 bytes), name "fd_write" (1 + 8 = 9 bytes),
    // desc func typeidx=0 (2 bytes), count=1 byte. Body =
    // 1 + 23 + 9 + 2 = 35 = 0x23.
    0x02, 0x23, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70,
    0x73, 0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76, 0x69,
    0x65, 0x77, 0x31, // "wasi_snapshot_preview1"
    0x08, 0x66, 0x64, 0x5F, 0x77, 0x72, 0x69, 0x74, 0x65, // "fd_write"
    0x00, 0x00, // desc = func, typeidx = 0
};

test "wasm_instance_new: rejects modules with unknown import modules" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = env_foo_import_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    // Unknown import module = instantiation fails.
    const inst = wasm_instance_new(s, m, null, null);
    try testing.expect(inst == null);
}

test "wasm_instance_new: rejects WASI imports when no host is configured" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = wasi_fd_write_import_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    // Module imports wasi_snapshot_preview1.fd_write but no host
    // is configured on the Store. wasm_instance_new fails.
    const inst = wasm_instance_new(s, m, null, null);
    try testing.expect(inst == null);
}

// (module
//   (type $sig_exit (func (param i32)))   ;; type 0
//   (type $sig_main (func))                ;; type 1
//   (import "wasi_snapshot_preview1" "proc_exit"
//     (func $exit (type 0)))               ;; funcidx 0
//   (func $main (type 1)                   ;; funcidx 1
//     i32.const 42
//     call $exit)
//   (export "main" (func $main)))
//
// End-to-end fixture: instantiating + calling main triggers
// the host thunk for proc_exit, which sets host.exit_code=42
// and unwinds the dispatch loop with `error.WasiExit`.
const proc_exit_42_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    // type section: 2 types, (i32) -> () and () -> ()
    0x01, 0x08, 0x02,
    0x60, 0x01, 0x7F, 0x00,
    0x60, 0x00, 0x00,
    // import section: count=1; "wasi_snapshot_preview1" (22 bytes)
    // + "proc_exit" (9 bytes) + 0x00 0x00 (kind=func, typeidx=0).
    // Body = 1 + 23 + 10 + 2 = 36 = 0x24.
    0x02, 0x24, 0x01,
    0x16, 0x77, 0x61, 0x73, 0x69, 0x5F, 0x73, 0x6E, 0x61, 0x70,
    0x73, 0x68, 0x6F, 0x74, 0x5F, 0x70, 0x72, 0x65, 0x76, 0x69,
    0x65, 0x77, 0x31,
    0x09, 0x70, 0x72, 0x6F, 0x63, 0x5F, 0x65, 0x78, 0x69, 0x74,
    0x00, 0x00,
    // function section: count=1, typeidx=1 (sig_main)
    0x03, 0x02, 0x01, 0x01,
    // export section: count=1, "main" (kind=func, funcidx=1)
    0x07, 0x08, 0x01, 0x04, 0x6D, 0x61, 0x69, 0x6E, 0x00, 0x01,
    // code section: count=1; fn body = locals=0, i32.const 42,
    // call 0, end. 5 instr bytes + 1 locals = 6 = 0x06.
    0x0A, 0x08, 0x01, 0x06, 0x00, 0x41, 0x2A, 0x10, 0x00, 0x0B,
};

test "wasm_func_call: dispatches main → proc_exit(42) → host.exit_code (4.7d)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_store_set_wasi(s, cfg);

    var bytes = proc_exit_42_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);
    try testing.expectEqual(@as(usize, 1), exports.size);
    const main_fn = wasm_extern_as_func(exports.data.?[0].?) orelse return error.NotFunc;

    const args: ValVec = .{ .size = 0, .data = null };
    var results: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(main_fn, &args, &results);
    // proc_exit unwinds via error.WasiExit, surfaces as a Trap.
    try testing.expect(trap != null);
    defer trap_surface.wasm_trap_delete(trap);

    // The host now carries the exit code.
    try testing.expect(s.wasi_host != null);
    const host_typed: *wasi_host.Host = @ptrCast(@alignCast(s.wasi_host.?));
    try testing.expectEqual(@as(u32, 42), host_typed.exit_code.?);
}

test "wasm_instance_new: succeeds for WASI imports when host configured (4.7c)" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    const cfg = wasi.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    zwasm_store_set_wasi(s, cfg);

    var bytes = wasi_fd_write_import_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);

    // With host configured, instantiation succeeds even though
    // no defined functions exist — the import is wired into
    // host_calls[0] via thunkFdWrite.
    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    const rt = inst.runtime.?;
    try testing.expectEqual(@as(usize, 1), rt.funcs.len); // placeholder for the import
    try testing.expectEqual(@as(usize, 1), rt.host_calls.len);
    try testing.expect(rt.host_calls[0] != null);
}

test "wasm_instance_exports: surfaces declared exports + dispatches via wasm_extern_as_func" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = i32_const_42_export_main_wasm;
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);

    try testing.expectEqual(@as(usize, 1), exports.size);
    const ext = exports.data.?[0] orelse return error.MissingExtern;
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.func)), wasm_extern_kind(ext));

    // wasm_extern_as_func returns a borrowed pointer; dispatch
    // through it without separately freeing.
    const f = wasm_extern_as_func(ext) orelse return error.NotFunc;
    var results_data: [1]Val = undefined;
    var results: ValVec = .{ .size = 1, .data = &results_data };
    const args: ValVec = .{ .size = 0, .data = null };
    const trap = wasm_func_call(f, &args, &results);
    try testing.expect(trap == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32);
}

test "wasm_instance_exports: empty when no export section" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var bytes = i32_const_42_wasm; // no export section
    const bv: ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer wasm_module_delete(m);
    const inst = wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer wasm_instance_delete(inst);

    var exports: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(inst, &exports);
    defer wasm_extern_vec_delete(&exports);
    try testing.expectEqual(@as(usize, 0), exports.size);
}

test "wasm_extern_*: null-arg discipline" {
    try testing.expectEqual(@as(u8, @intFromEnum(ExternKind.func)), wasm_extern_kind(null));
    wasm_extern_delete(null);
    try testing.expect(wasm_extern_as_func(null) == null);
    var out: ExternVec = .{ .size = 0, .data = null };
    wasm_instance_exports(null, &out);
    try testing.expectEqual(@as(usize, 0), out.size);
}

test "zwasm_instance_get_func / wasm_func_delete: null-arg discipline" {
    try testing.expect(zwasm_instance_get_func(null, 0) == null);
    wasm_func_delete(null);
}
