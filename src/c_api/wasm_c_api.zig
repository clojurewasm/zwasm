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
const lowerer = @import("../frontend/lowerer.zig");
const parser = @import("../frontend/parser.zig");
const sections = @import("../frontend/sections.zig");
const validator = @import("../frontend/validator.zig");
const zir = @import("../ir/zir.zig");

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

/// `wasm_func_t` — exported / imported function handle. Wraps a
/// pointer into the instance's function index space.
pub const Func = extern struct {
    _padding: usize = 0,
};

/// `wasm_trap_t` — runtime trap surface; carries the trap kind
/// (mirrors `interp.Trap`) plus an optional message.
pub const Trap = extern struct {
    _padding: usize = 0,
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
// Smoke tests (shape stability)
// ============================================================

const testing = std.testing;

test "wasm_c_api shapes: top-level types instantiate cleanly" {
    const e: Engine = .{ .alloc_ptr = null, .alloc_vtable = null };
    const s: Store = .{ .engine = null };
    const m: Module = .{ .store = null, .bytes_ptr = null, .bytes_len = 0 };
    const i: Instance = .{ .store = null, .module = null, .runtime = null };
    const f: Func = .{};
    const t: Trap = .{};
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
