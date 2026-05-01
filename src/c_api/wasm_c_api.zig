//! C ABI binding for `include/wasm.h` (Phase 3 / §9.3 / 3.2).
//!
//! Zone 3 — exposes the wasm-c-api shapes upstream defines so a
//! C host can `#include <wasm.h>` and link against this binding.
//! Per ROADMAP §1.1 the wasm-c-api surface is the primary C ABI;
//! `zwasm.h` extensions land alongside (§9.3 follow-on, post-
//! v0.1.0 surface).
//!
//! Chunk-3.2 scope: shape declarations only. Each opaque
//! upstream `wasm_<name>_t` is declared as an `extern struct`
//! Zig type whose pointer is what C sees. Concrete `_new` /
//! `_delete` / `_call` constructors land in §9.3 / 3.3 – 3.7.
//!
//! Imports Zone 0 (`util/`) + Zone 1 (`ir/`) + Zone 2
//! (`interp/`); a forthcoming `wasi/`-backed binding will mirror
//! this file's structure for `wasi.h` in Phase 4.

const std = @import("std");

const interp = @import("../interp/mod.zig");
const dispatch = @import("../interp/dispatch.zig");
const interp_mvp = @import("../interp/mvp.zig");
const ext_sign_ext = @import("../interp/ext_2_0/sign_ext.zig");
const ext_sat_trunc = @import("../interp/ext_2_0/sat_trunc.zig");
const ext_bulk_memory = @import("../interp/ext_2_0/bulk_memory.zig");
const ext_ref_types = @import("../interp/ext_2_0/ref_types.zig");
const ext_table_ops = @import("../interp/ext_2_0/table_ops.zig");
const lowerer = @import("../frontend/lowerer.zig");
const parser = @import("../frontend/parser.zig");
const sections = @import("../frontend/sections.zig");
const validator = @import("../frontend/validator.zig");
const zir = @import("../ir/zir.zig");
const dispatch_table_mod = @import("../ir/dispatch_table.zig");

// ============================================================
// Opaque types (match wasm.h declarations 1:1)
// ============================================================

/// `wasm_engine_t` — process-wide top-level handle. Carries the
/// allocator the binding will thread into runtimes (and into
/// future `wasm_store_t` GC roots). The §9.3 / 3.3 binding uses
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

/// `wasm_store_t` — module-instantiation context. Carries a
/// back-pointer to its owning Engine so subsequent C-API entries
/// can recover the allocator without a global. Once §9.3 / 3.5
/// (instance new) lands, this struct will also own a single
/// `interp.Runtime` plus the GC root set.
pub const Store = extern struct {
    engine: ?*Engine,
};

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

/// `wasm_instance_t` — instantiated module. Owns one
/// `interp.Runtime` plus a per-instance arena that backs every
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
    module: ?*const Module,
    runtime: ?*interp.Runtime,
    /// Per-instance arena holding every derived-state slice. A
    /// single `arena.deinit()` releases types, lowered ZirFunc
    /// state, the func-pointer table — uniformly. Owned (heap-
    /// allocated) so its identity survives moves of the Instance
    /// struct itself.
    arena: ?*std.heap.ArenaAllocator = null,
    funcs_storage: []zir.ZirFunc = &.{},
    func_ptrs_storage: []*const zir.ZirFunc = &.{},
};

/// `wasm_func_t` — exported / imported function handle. Carries a
/// back-pointer to its owning Instance plus the function's index
/// in `Instance.funcs_storage`. C only ever sees the opaque
/// pointer (per upstream wasm.h), so the struct does not need
/// extern layout.
pub const Func = struct {
    instance: ?*Instance,
    func_idx: u32,
};

/// `wasm_trap_kind_t` — internal classification of a Trap.
/// Maps `interp.Trap` conditions to the spec-conformant message
/// strings the C host expects (per Wasm spec assertion text);
/// also covers binding-layer failures such as arg-count
/// mismatches that wasm.h surfaces as traps too.
pub const TrapKind = enum(u32) {
    binding_error = 0,
    unreachable_ = 1,
    div_by_zero = 2,
    int_overflow = 3,
    invalid_conversion = 4,
    oob_memory = 5,
    oob_table = 6,
    uninitialized_elem = 7,
    indirect_call_mismatch = 8,
    stack_overflow = 9,
    out_of_memory = 10,
};

/// `wasm_trap_t` — runtime trap surface. Carries the trap kind +
/// a heap-allocated message (always populated; freed in
/// `wasm_trap_delete`) + a back-pointer to the originating Store
/// so `_delete` can recover the allocator without a global.
pub const Trap = extern struct {
    store: ?*Store,
    kind: TrapKind,
    message_ptr: ?[*]u8,
    message_len: usize,
};

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

/// `wasm_byte_vec_t` — generic vec(byte). The wasm.h header
/// declares one such type per element variant via the
/// `WASM_DECLARE_VEC` macro family; Zig needs only the byte
/// flavour for now (string-typed identifiers in the binding's
/// `wasm_module_new` path).
pub const ByteVec = extern struct {
    size: usize,
    data: ?[*]u8,
};

/// `wasm_val_vec_t` — vec(wasm_val_t). Used for the
/// `wasm_func_call` arg / result surfaces. The C host owns the
/// `data` storage; the binding writes into it and never frees it.
pub const ValVec = extern struct {
    size: usize,
    data: ?[*]Val,
};

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
export fn wasm_engine_new() callconv(.c) ?*Engine {
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
export fn wasm_engine_delete(e: ?*Engine) callconv(.c) void {
    const handle = e orelse return;
    const alloc = engineAllocator(handle);
    alloc.destroy(handle);
}

// ============================================================
// Store constructors / destructors (§9.3 / 3.3b)
// ============================================================

/// `wasm_store_new(wasm_engine_t*)` — allocate a Store bound to
/// the given Engine. Returns null on OOM or null engine.
export fn wasm_store_new(e: ?*Engine) callconv(.c) ?*Store {
    const engine = e orelse return null;
    const alloc = engineAllocator(engine);
    const s = alloc.create(Store) catch return null;
    s.* = .{ .engine = engine };
    return s;
}

/// `wasm_store_delete(*Store)` — free a Store. Null-tolerant.
export fn wasm_store_delete(s: ?*Store) callconv(.c) void {
    const handle = s orelse return;
    const engine = handle.engine orelse return; // dangling — leak rather than crash
    const alloc = engineAllocator(engine);
    alloc.destroy(handle);
}

// ============================================================
// Module constructors / validators / destructors (§9.3 / 3.4)
// ============================================================

inline fn storeAllocator(s: *const Store) ?std.mem.Allocator {
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

    const func_types = alloc.alloc(zir.FuncType, defined_func_indices.len) catch return false;
    defer alloc.free(func_types);
    for (defined_func_indices, 0..) |type_idx, i| {
        if (type_idx >= types_owned.items.len) return false;
        func_types[i] = types_owned.items[type_idx];
    }

    for (codes_owned.items, defined_func_indices) |code, type_idx| {
        const sig = types_owned.items[type_idx];
        validator.validateFunction(
            sig,
            code.locals,
            code.body,
            func_types,
            &.{},
            types_owned.items,
            0,
            &.{},
            0,
        ) catch return false;
    }
    return true;
}

fn validateNoCode(_: std.mem.Allocator, _: *parser.Module) bool {
    // No code section: nothing per-function to validate. The
    // module's section-id ordering was already checked by
    // parser.parse, which is sufficient.
    return true;
}

/// `wasm_module_new(store, binary)` — parse + validate `binary`,
/// return an owning Module on success or null on parse / validate
/// failure. The returned Module copies the binary bytes so the C
/// host can free its `byte_vec` immediately.
export fn wasm_module_new(s: ?*Store, binary: ?*const ByteVec) callconv(.c) ?*Module {
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
export fn wasm_module_validate(s: ?*Store, binary: ?*const ByteVec) callconv(.c) bool {
    const store = s orelse return false;
    const bv = binary orelse return false;
    const alloc = storeAllocator(store) orelse return false;
    const data_ptr = bv.data orelse return false;
    return frontendValidate(alloc, data_ptr[0..bv.size]);
}

/// `wasm_module_delete(module)` — free a Module returned by
/// `_module_new`. Null-tolerant.
export fn wasm_module_delete(m: ?*Module) callconv(.c) void {
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
/// failure the partial state is released by `freeInstanceState`.
///
/// 3.6 chunk a scope: types + functions + code section. Memory /
/// data / element / table sections land alongside `wasm_func_call`
/// in chunk b once the smallest dispatch path needs them.
fn instantiateRuntime(
    parent_alloc: std.mem.Allocator,
    bytes: []const u8,
    inst: *Instance,
    rt: *interp.Runtime,
) !void {
    const arena = try parent_alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(parent_alloc);
    inst.arena = arena;
    const a = arena.allocator();

    var module = try parser.parse(a, bytes);
    defer module.deinit(a);

    const type_section = module.find(.@"type") orelse return;
    const code_section = module.find(.code) orelse return;
    const func_section = module.find(.function);

    const types = try sections.decodeTypes(a, type_section.body);

    const def_idx = if (func_section) |s|
        try sections.decodeFunctions(a, s.body)
    else
        try a.alloc(u32, 0);

    const codes = try sections.decodeCodes(a, code_section.body);
    if (codes.items.len != def_idx.len) return error.InvalidModule;

    const funcs = try a.alloc(zir.ZirFunc, codes.items.len);
    for (codes.items, def_idx, 0..) |code, type_idx, i| {
        if (type_idx >= types.items.len) return error.InvalidTypeIndex;
        funcs[i] = zir.ZirFunc.init(@intCast(i), types.items[type_idx], code.locals);
        try lowerer.lowerFunctionBody(a, code.body, &funcs[i], types.items);
    }
    inst.funcs_storage = funcs;

    const func_ptrs = try a.alloc(*const zir.ZirFunc, funcs.len);
    for (funcs, 0..) |*f, i| func_ptrs[i] = f;
    inst.func_ptrs_storage = func_ptrs;

    rt.funcs = func_ptrs;
    rt.module_types = types.items;
}

fn freeInstanceState(parent_alloc: std.mem.Allocator, inst: *Instance) void {
    if (inst.arena) |a| {
        a.deinit();
        parent_alloc.destroy(a);
        inst.arena = null;
    }
    inst.funcs_storage = &.{};
    inst.func_ptrs_storage = &.{};
}

/// `wasm_instance_new(store, module, imports, trap_out)` —
/// allocate an Instance bound to the given Module and lower its
/// code into the owned Runtime. The `imports` and `trap_out`
/// parameters are full-shape per upstream wasm.h but stubbed
/// here (`anyopaque` / unused) until §9.3 / 3.6 chunk b wires
/// `wasm_func_call` and §9.3 / 3.7 wires `wasm_extern_vec_t` /
/// `wasm_trap_t`. Returns null on any null required input,
/// instantiation failure, or OOM.
export fn wasm_instance_new(
    s: ?*Store,
    m: ?*const Module,
    imports: ?*const anyopaque,
    trap_out: ?*?*Trap,
) callconv(.c) ?*Instance {
    _ = imports;
    _ = trap_out;
    const store = s orelse return null;
    const module = m orelse return null;
    const alloc = storeAllocator(store) orelse return null;

    const runtime = alloc.create(interp.Runtime) catch return null;
    runtime.* = interp.Runtime.init(alloc);

    const inst = alloc.create(Instance) catch {
        runtime.deinit();
        alloc.destroy(runtime);
        return null;
    };
    inst.* = .{
        .store = store,
        .module = module,
        .runtime = runtime,
    };

    const bytes_ptr = module.bytes_ptr orelse {
        runtime.deinit();
        alloc.destroy(runtime);
        alloc.destroy(inst);
        return null;
    };
    instantiateRuntime(alloc, bytes_ptr[0..module.bytes_len], inst, runtime) catch {
        freeInstanceState(alloc, inst);
        runtime.deinit();
        alloc.destroy(runtime);
        alloc.destroy(inst);
        return null;
    };
    return inst;
}

/// `wasm_instance_delete(*Instance)` — free an Instance returned
/// by `wasm_instance_new`. Null-tolerant; tears down arena-owned
/// derived state, then the Runtime, then the struct itself.
export fn wasm_instance_delete(i: ?*Instance) callconv(.c) void {
    const handle = i orelse return;
    const store = handle.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    freeInstanceState(alloc, handle);
    if (handle.runtime) |rt| {
        rt.deinit();
        alloc.destroy(rt);
    }
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
export fn zwasm_instance_get_func(i: ?*Instance, idx: u32) callconv(.c) ?*Func {
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
export fn wasm_func_delete(f: ?*Func) callconv(.c) void {
    const handle = f orelse return;
    const inst = handle.instance orelse return;
    const store = inst.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    alloc.destroy(handle);
}

fn marshalValIn(v: Val) interp.Value {
    return switch (v.kind) {
        .i32 => .{ .i32 = v.of.i32 },
        .i64 => .{ .i64 = v.of.i64 },
        .f32 => .{ .bits64 = @as(u64, @as(u32, @bitCast(v.of.f32))) },
        .f64 => .{ .bits64 = @bitCast(v.of.f64) },
        .anyref, .funcref => .{ .ref = if (v.of.ref) |p| @intFromPtr(p) else interp.Value.null_ref },
    };
}

fn marshalValOut(v: interp.Value, kind: zir.ValType) Val {
    return switch (kind) {
        .i32 => .{ .kind = .i32, .of = .{ .i32 = v.i32 } },
        .i64 => .{ .kind = .i64, .of = .{ .i64 = v.i64 } },
        .f32 => .{ .kind = .f32, .of = .{ .f32 = @bitCast(@as(u32, @truncate(v.bits64))) } },
        .f64 => .{ .kind = .f64, .of = .{ .f64 = @bitCast(v.bits64) } },
        .funcref => .{ .kind = .funcref, .of = .{ .ref = if (v.ref == interp.Value.null_ref) null else @ptrFromInt(v.ref) } },
        .externref => .{ .kind = .anyref, .of = .{ .ref = if (v.ref == interp.Value.null_ref) null else @ptrFromInt(v.ref) } },
        .v128 => .{ .kind = .i64, .of = .{ .i64 = 0 } }, // unreachable for MVP
    };
}

fn trapMessageFor(kind: TrapKind) []const u8 {
    return switch (kind) {
        .binding_error => "host invocation error",
        .unreachable_ => "unreachable",
        .div_by_zero => "integer divide by zero",
        .int_overflow => "integer overflow",
        .invalid_conversion => "invalid conversion to integer",
        .oob_memory => "out of bounds memory access",
        .oob_table => "out of bounds table access",
        .uninitialized_elem => "uninitialized element",
        .indirect_call_mismatch => "indirect call type mismatch",
        .stack_overflow => "call stack exhausted",
        .out_of_memory => "out of memory",
    };
}

fn mapInterpTrap(err: anyerror) TrapKind {
    return switch (err) {
        error.Unreachable => .unreachable_,
        error.DivByZero => .div_by_zero,
        error.IntOverflow => .int_overflow,
        error.InvalidConversionToInt => .invalid_conversion,
        error.OutOfBoundsLoad, error.OutOfBoundsStore => .oob_memory,
        error.OutOfBoundsTableAccess => .oob_table,
        error.UninitializedElement => .uninitialized_elem,
        error.IndirectCallTypeMismatch => .indirect_call_mismatch,
        error.StackOverflow, error.CallStackExhausted => .stack_overflow,
        error.OutOfMemory => .out_of_memory,
        else => .binding_error,
    };
}

fn allocTrap(alloc: std.mem.Allocator, store: ?*Store, kind: TrapKind) ?*Trap {
    const msg = trapMessageFor(kind);
    const buf = alloc.dupe(u8, msg) catch return null;
    const t = alloc.create(Trap) catch {
        alloc.free(buf);
        return null;
    };
    t.* = .{
        .store = store,
        .kind = kind,
        .message_ptr = buf.ptr,
        .message_len = buf.len,
    };
    return t;
}

/// `wasm_trap_new(store, message)` — allocate a Trap whose
/// message is a copy of the byte_vec contents. Used by C hosts
/// to surface their own host-side errors as traps; the binding
/// itself prefers `allocTrap` with a `TrapKind` so it can map
/// runtime conditions to the spec-conformant strings.
export fn wasm_trap_new(s: ?*Store, message: ?*const ByteVec) callconv(.c) ?*Trap {
    const store = s orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    const m = message orelse return null;
    const data_ptr = m.data orelse return null;
    const buf = alloc.dupe(u8, data_ptr[0..m.size]) catch return null;
    const t = alloc.create(Trap) catch {
        alloc.free(buf);
        return null;
    };
    t.* = .{
        .store = store,
        .kind = .binding_error,
        .message_ptr = buf.ptr,
        .message_len = buf.len,
    };
    return t;
}

/// `wasm_trap_delete(*Trap)` — free a Trap returned by any path
/// (binding-internal `allocTrap`, `wasm_trap_new`, or
/// `wasm_func_call`). Releases the message bytes first, then
/// the struct. Null-tolerant.
export fn wasm_trap_delete(t: ?*Trap) callconv(.c) void {
    const handle = t orelse return;
    const store = handle.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    if (handle.message_ptr) |p| alloc.free(p[0..handle.message_len]);
    alloc.destroy(handle);
}

/// `wasm_trap_message(*Trap, *out ByteVec)` — populate `out`
/// with a freshly-allocated copy of the trap's message (per
/// upstream wasm.h's `own` discipline: `out` becomes owned by
/// the caller and must be released via `wasm_byte_vec_delete`).
/// Writes a zero-length vec if the trap has no message or
/// allocation fails.
export fn wasm_trap_message(t: ?*const Trap, out: ?*ByteVec) callconv(.c) void {
    const out_ptr = out orelse return;
    out_ptr.* = .{ .size = 0, .data = null };
    const handle = t orelse return;
    const store = handle.store orelse return;
    const alloc = storeAllocator(store) orelse return;
    const ptr = handle.message_ptr orelse return;
    const copy = alloc.dupe(u8, ptr[0..handle.message_len]) catch return;
    out_ptr.* = .{ .size = copy.len, .data = copy.ptr };
}

// ============================================================
// wasm_*_vec_t family (§9.3 / 3.7 chunk b)
// ============================================================
//
// Per upstream `WASM_DECLARE_VEC(name, …)`, every vec type gets
// `_new_empty` / `_new_uninitialized` / `_new` / `_copy` /
// `_delete`. The data pointer is allocated from
// `std.heap.c_allocator` so every vec is freeable through the
// matching `_delete` regardless of which Engine produced it —
// the allocator must be vec-global since C hosts can construct
// vecs without an Engine handle (e.g. before `wasm_engine_new`).

fn vecNewEmpty(comptime VecT: type, out: ?*VecT) void {
    const o = out orelse return;
    o.* = .{ .size = 0, .data = null };
}

fn vecNewUninitialized(comptime T: type, comptime VecT: type, out: ?*VecT, size: usize) void {
    const o = out orelse return;
    if (size == 0) {
        o.* = .{ .size = 0, .data = null };
        return;
    }
    const buf = std.heap.c_allocator.alloc(T, size) catch {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    o.* = .{ .size = size, .data = buf.ptr };
}

fn vecNew(comptime T: type, comptime VecT: type, out: ?*VecT, size: usize, src: ?[*]const T) void {
    const o = out orelse return;
    if (size == 0 or src == null) {
        o.* = .{ .size = 0, .data = null };
        return;
    }
    const buf = std.heap.c_allocator.alloc(T, size) catch {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    @memcpy(buf, src.?[0..size]);
    o.* = .{ .size = size, .data = buf.ptr };
}

fn vecCopy(comptime T: type, comptime VecT: type, out: ?*VecT, src: ?*const VecT) void {
    const o = out orelse return;
    const s = src orelse {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    vecNew(T, VecT, o, s.size, s.data);
}

fn vecDelete(comptime VecT: type, v: ?*VecT) void {
    const handle = v orelse return;
    if (handle.data) |p| std.heap.c_allocator.free(p[0..handle.size]);
    handle.* = .{ .size = 0, .data = null };
}

// --- byte vec ---

export fn wasm_byte_vec_new_empty(out: ?*ByteVec) callconv(.c) void {
    vecNewEmpty(ByteVec, out);
}

export fn wasm_byte_vec_new_uninitialized(out: ?*ByteVec, size: usize) callconv(.c) void {
    vecNewUninitialized(u8, ByteVec, out, size);
}

export fn wasm_byte_vec_new(out: ?*ByteVec, size: usize, src: ?[*]const u8) callconv(.c) void {
    vecNew(u8, ByteVec, out, size, src);
}

export fn wasm_byte_vec_copy(out: ?*ByteVec, src: ?*const ByteVec) callconv(.c) void {
    vecCopy(u8, ByteVec, out, src);
}

/// `wasm_byte_vec_delete(*ByteVec)` — free the data backing of a
/// ByteVec. Pinned to `std.heap.c_allocator` (see header above).
export fn wasm_byte_vec_delete(v: ?*ByteVec) callconv(.c) void {
    vecDelete(ByteVec, v);
}

// --- val vec ---

export fn wasm_val_vec_new_empty(out: ?*ValVec) callconv(.c) void {
    vecNewEmpty(ValVec, out);
}

export fn wasm_val_vec_new_uninitialized(out: ?*ValVec, size: usize) callconv(.c) void {
    vecNewUninitialized(Val, ValVec, out, size);
}

export fn wasm_val_vec_new(out: ?*ValVec, size: usize, src: ?[*]const Val) callconv(.c) void {
    vecNew(Val, ValVec, out, size, src);
}

export fn wasm_val_vec_copy(out: ?*ValVec, src: ?*const ValVec) callconv(.c) void {
    vecCopy(Val, ValVec, out, src);
}

export fn wasm_val_vec_delete(v: ?*ValVec) callconv(.c) void {
    vecDelete(ValVec, v);
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
export fn wasm_func_call(
    f: ?*const Func,
    args: ?*const ValVec,
    results: ?*ValVec,
) callconv(.c) ?*Trap {
    const handle = f orelse return null;
    const inst = handle.instance orelse return null;
    const store = inst.store orelse return null;
    const alloc = storeAllocator(store) orelse return null;
    const rt = inst.runtime orelse return null;
    if (handle.func_idx >= inst.funcs_storage.len) return allocTrap(alloc, store, .binding_error);

    const zfunc = &inst.funcs_storage[handle.func_idx];
    const sig = zfunc.sig;
    const args_size = if (args) |a| a.size else 0;
    const results_size = if (results) |r| r.size else 0;
    if (args_size != sig.params.len) return allocTrap(alloc, store, .binding_error);
    if (results_size != sig.results.len) return allocTrap(alloc, store, .binding_error);

    const num_locals = sig.params.len + zfunc.locals.len;
    const locals = alloc.alloc(interp.Value, num_locals) catch return allocTrap(alloc, store, .out_of_memory);
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
// Smoke tests (shape stability)
// ============================================================

const testing = std.testing;

test "wasm_c_api shapes: top-level types instantiate cleanly" {
    const e: Engine = .{ .alloc_ptr = null, .alloc_vtable = null };
    const s: Store = .{ .engine = null };
    const m: Module = .{ .store = null, .bytes_ptr = null, .bytes_len = 0 };
    const i: Instance = .{ .store = null, .module = null, .runtime = null };
    const f: Func = .{ .instance = null, .func_idx = 0 };
    const t: Trap = .{ .store = null, .kind = .binding_error, .message_ptr = null, .message_len = 0 };
    _ = .{ e, s, m, i, f, t };
}

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
    try testing.expect(i.module == m);
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
    wasm_trap_message(trap, &msg);
    try testing.expect(msg.size > 0);
    wasm_byte_vec_delete(&msg);
    wasm_trap_delete(trap);
}

test "wasm_trap_new / message / delete: round-trip from caller-supplied message" {
    const e = wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_engine_delete(e);
    const s = wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_store_delete(s);

    var msg_bytes = "host failure".*;
    const msg_bv: ByteVec = .{ .size = msg_bytes.len, .data = &msg_bytes };
    const trap = wasm_trap_new(s, &msg_bv) orelse return error.TrapAllocFailed;
    defer wasm_trap_delete(trap);

    var out: ByteVec = .{ .size = 0, .data = null };
    wasm_trap_message(trap, &out);
    defer wasm_byte_vec_delete(&out);
    try testing.expectEqual(@as(usize, 12), out.size);
    try testing.expectEqualStrings("host failure", out.data.?[0..out.size]);
}

test "wasm_trap_*: null-arg discipline" {
    try testing.expect(wasm_trap_new(null, null) == null);
    wasm_trap_delete(null);
    var out: ByteVec = .{ .size = 0, .data = null };
    wasm_trap_message(null, &out);
    try testing.expectEqual(@as(usize, 0), out.size);
    wasm_byte_vec_delete(null);
}

test "wasm_byte_vec_new / copy / delete: round-trip with independent buffers" {
    var src_bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var v: ByteVec = .{ .size = 0, .data = null };
    wasm_byte_vec_new(&v, src_bytes.len, &src_bytes);
    defer wasm_byte_vec_delete(&v);
    try testing.expectEqual(@as(usize, 4), v.size);
    try testing.expectEqual(@as(u8, 0xDE), v.data.?[0]);
    try testing.expectEqual(@as(u8, 0xEF), v.data.?[3]);

    var v2: ByteVec = .{ .size = 0, .data = null };
    wasm_byte_vec_copy(&v2, &v);
    defer wasm_byte_vec_delete(&v2);
    try testing.expectEqual(v.size, v2.size);
    try testing.expectEqual(@as(u8, 0xEF), v2.data.?[3]);
    // Independent backing — copy must own a fresh buffer.
    try testing.expect(v.data.? != v2.data.?);
}

test "wasm_byte_vec_new_empty / new_uninitialized" {
    var stale: ByteVec = .{ .size = 99, .data = null };
    wasm_byte_vec_new_empty(&stale);
    try testing.expectEqual(@as(usize, 0), stale.size);
    try testing.expect(stale.data == null);

    var u: ByteVec = .{ .size = 0, .data = null };
    wasm_byte_vec_new_uninitialized(&u, 8);
    defer wasm_byte_vec_delete(&u);
    try testing.expectEqual(@as(usize, 8), u.size);
    try testing.expect(u.data != null);
}

test "wasm_val_vec_new / copy / delete: round-trip" {
    var src: [2]Val = .{
        .{ .kind = .i32, .of = .{ .i32 = 7 } },
        .{ .kind = .i64, .of = .{ .i64 = -1 } },
    };
    var v: ValVec = .{ .size = 0, .data = null };
    wasm_val_vec_new(&v, src.len, &src);
    defer wasm_val_vec_delete(&v);
    try testing.expectEqual(@as(usize, 2), v.size);
    try testing.expectEqual(ValKind.i32, v.data.?[0].kind);
    try testing.expectEqual(@as(i32, 7), v.data.?[0].of.i32);
    try testing.expectEqual(ValKind.i64, v.data.?[1].kind);
    try testing.expectEqual(@as(i64, -1), v.data.?[1].of.i64);

    var v2: ValVec = .{ .size = 0, .data = null };
    wasm_val_vec_copy(&v2, &v);
    defer wasm_val_vec_delete(&v2);
    try testing.expectEqual(v.size, v2.size);
    try testing.expect(v.data.? != v2.data.?);
}

test "wasm_*_vec_*: null-arg discipline" {
    wasm_byte_vec_new_empty(null);
    wasm_byte_vec_new_uninitialized(null, 16);
    wasm_byte_vec_new(null, 4, null);
    wasm_byte_vec_copy(null, null);
    wasm_val_vec_new_empty(null);
    wasm_val_vec_new_uninitialized(null, 16);
    wasm_val_vec_new(null, 4, null);
    wasm_val_vec_copy(null, null);
    wasm_val_vec_delete(null);
}

test "zwasm_instance_get_func / wasm_func_delete: null-arg discipline" {
    try testing.expect(zwasm_instance_get_func(null, 0) == null);
    wasm_func_delete(null);
}

test "wasm_c_api: ValKind tag values match wasm.h" {
    // wasm.h:
    //   WASM_I32 = 0, WASM_I64 = 1, WASM_F32 = 2, WASM_F64 = 3,
    //   WASM_ANYREF = 128, WASM_FUNCREF = 129
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ValKind.i32));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ValKind.i64));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ValKind.f32));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ValKind.f64));
    try testing.expectEqual(@as(u8, 128), @intFromEnum(ValKind.anyref));
    try testing.expectEqual(@as(u8, 129), @intFromEnum(ValKind.funcref));
}

test "wasm_c_api: Val tagged-union round-trip" {
    const v_i32: Val = .{ .kind = .i32, .of = .{ .i32 = -42 } };
    try testing.expectEqual(@as(i32, -42), v_i32.of.i32);

    const v_f64: Val = .{ .kind = .f64, .of = .{ .f64 = 3.14 } };
    try testing.expectEqual(@as(f64, 3.14), v_f64.of.f64);
}

test "wasm_c_api: ByteVec carries size + data" {
    var bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const v: ByteVec = .{ .size = bytes.len, .data = &bytes };
    try testing.expectEqual(@as(usize, 4), v.size);
    try testing.expectEqual(@as(u8, 0xDE), v.data.?[0]);
}

test "wasm_c_api: imports interp namespace (Zone-3 layering)" {
    // Compile-time check that the binding can reach
    // `interp.Runtime` shape; the §9.3 / 3.5 instance binding
    // will own one. Just touch the type name to assert the
    // import resolves.
    _ = interp.Runtime;
}
