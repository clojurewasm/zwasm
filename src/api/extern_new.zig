//! Runtime-entity construction layer of the C ABI (§13.2): the
//! `wasm_{func,global,table,memory}_as_extern[_const]` conversions
//! (entity → Extern), and the home for the forthcoming host-side
//! `wasm_{global,table,memory}_new` constructors.
//!
//! Extracted from `instance.zig` per ADR-0099 §D2 (the `module_introspect.zig`
//! precedent): instance.zig sits at its 3200 FILE-SIZE-EXEMPT cap, and the
//! entity-construction surface is a cohesive separable concern. One-way
//! dependency on `instance.zig` (no cycle): this file imports the entity +
//! Extern types; instance.zig never imports back.
//!
//! Because Func / Global / Table / Memory are SEPARATE structs from Extern
//! (not a reinterpret cast as in upstream wasm-c-api), `*_as_extern` WRAPS
//! the entity in a borrowed-view Extern cached on the entity's `extern_view`
//! field — repeat calls return the same pointer, the entity stays the sole
//! owner (freeing the view in its own delete), and `wasm_extern_delete`
//! no-ops on a view (`Extern.borrowed`) so a C host can't double-free.
//!
//! Zone 3 — same as the rest of `src/api/`.

const std = @import("std");
const testing = std.testing;

const instance = @import("instance.zig");
const vec = @import("vec.zig");
const types = @import("types.zig");
const runtime = @import("../runtime/runtime.zig");
const zir = @import("../ir/zir.zig");

const Extern = instance.Extern;
const Func = instance.Func;
const Global = instance.Global;
const Table = instance.Table;
const Memory = instance.Memory;

pub export fn wasm_func_as_extern(f: ?*Func) callconv(.c) ?*Extern {
    const handle = f orelse return null;
    if (handle.extern_view) |v| return v;
    const inst = handle.instance orelse return null;
    const store = inst.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .func, .instance = inst, .func = handle, .borrowed = true };
    handle.extern_view = v;
    return v;
}

pub export fn wasm_global_as_extern(g: ?*Global) callconv(.c) ?*Extern {
    const handle = g orelse return null;
    if (handle.extern_view) |v| return v;
    // Allocator comes from the instance (export-derived) OR the Store
    // (standalone host global from `wasm_global_new`, instance == null).
    const store = if (handle.instance) |i| (i.store orelse return null) else (handle.store orelse return null);
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .global, .instance = handle.instance, .global = handle, .global_idx = handle.global_idx, .borrowed = true };
    handle.extern_view = v;
    return v;
}

pub export fn wasm_table_as_extern(t: ?*Table) callconv(.c) ?*Extern {
    const handle = t orelse return null;
    if (handle.extern_view) |v| return v;
    const inst = handle.instance orelse return null;
    const store = inst.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .table, .instance = inst, .table = handle, .table_idx = handle.table_idx, .borrowed = true };
    handle.extern_view = v;
    return v;
}

pub export fn wasm_memory_as_extern(m: ?*Memory) callconv(.c) ?*Extern {
    const handle = m orelse return null;
    if (handle.extern_view) |v| return v;
    const inst = handle.instance orelse return null;
    const store = inst.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .memory, .instance = inst, .memory = handle, .memory_idx = handle.memory_idx, .borrowed = true };
    handle.extern_view = v;
    return v;
}

/// Const-qualified `*_as_extern`. C `const` is advisory; the lazily cached
/// view is an implementation detail, so these forward through the mutable
/// form via `@constCast` and re-narrow the result.
pub export fn wasm_func_as_extern_const(f: ?*const Func) callconv(.c) ?*const Extern {
    return wasm_func_as_extern(@constCast(f));
}

pub export fn wasm_global_as_extern_const(g: ?*const Global) callconv(.c) ?*const Extern {
    return wasm_global_as_extern(@constCast(g));
}

pub export fn wasm_table_as_extern_const(t: ?*const Table) callconv(.c) ?*const Extern {
    return wasm_table_as_extern(@constCast(t));
}

pub export fn wasm_memory_as_extern_const(m: ?*const Memory) callconv(.c) ?*const Extern {
    return wasm_memory_as_extern(@constCast(m));
}

// ----------------------------------------------------------------
// Host-created standalone entities (`wasm_{global,table,memory}_new`).
// `wasm_func_new` (host callback) needs interp host-call plumbing —
// deferred D-252.
// ----------------------------------------------------------------

/// Map a `wasm_valkind_t` byte to the internal scalar valtype. v128
/// (no `wasm_val_t` slot) and ref kinds are NOT part of the c_api
/// scalar-global surface (see the v128-spec-boundary lesson), so
/// `wasm_global_new` of those returns null.
fn scalarValType(kind: u8) ?zir.ValType {
    return switch (kind) {
        0 => .i32,
        1 => .i64,
        2 => .f32,
        3 => .f64,
        else => null,
    };
}

/// `wasm_global_new(store, globaltype, val) -> own wasm_global_t*` —
/// a host-owned standalone global holding its own `*Value` cell. The
/// host get/sets it via `wasm_global_get/set`; passing
/// `wasm_global_as_extern(g)` into `wasm_instance_new`'s imports aliases
/// the cell into the guest (one shared cell). Caller owns it
/// (`wasm_global_delete`). Null on a non-scalar valtype or OOM.
pub export fn wasm_global_new(
    store: ?*instance.Store,
    gt: ?*const types.GlobalType,
    val: ?*const instance.Val,
) callconv(.c) ?*Global {
    const s = store orelse return null;
    const gtype = gt orelse return null;
    const v = val orelse return null;
    const content = types.wasm_globaltype_content(gtype) orelse return null;
    const vt = scalarValType(content.kind) orelse return null;
    const alloc = instance.storeAllocator(s) orelse return null;
    const cell = alloc.create(runtime.Value) catch return null;
    cell.* = instance.marshalValIn(v.*);
    const g = alloc.create(Global) catch {
        alloc.destroy(cell);
        return null;
    };
    g.* = .{
        .instance = null,
        .global_idx = 0,
        .valtype = vt,
        .mutable = types.wasm_globaltype_mutability(gtype) != 0,
        .cell = cell,
        .store = s,
    };
    return g;
}

// =====================================================================
// Tests
// =====================================================================

test "wasm_*_as_extern: entity → borrowed-view Extern round-trips + is cached + extern_delete no-ops" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = instance.mixed_exports_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);
    const inst = instance.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const data = exports.data orelse return error.ExportsDataNull;

    // func extern → Func → func_as_extern → view; view round-trips back to
    // the SAME Func, the view's kind is func, and a second as_extern call
    // returns the identical (cached) pointer.
    const func = instance.wasm_extern_as_func(data[0]) orelse return error.NotFunc;
    const view = wasm_func_as_extern(func) orelse return error.NoView;
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.func)), instance.wasm_extern_kind(view));
    try testing.expectEqual(func, instance.wasm_extern_as_func(view).?);
    try testing.expectEqual(view, wasm_func_as_extern(func).?); // cached
    // extern_delete on a borrowed view is a no-op: the cached view survives.
    instance.wasm_extern_delete(view);
    try testing.expectEqual(view, wasm_func_as_extern(func).?);

    // memory / table / global wrap to the matching kind.
    const mem = instance.wasm_extern_as_memory(data[1]) orelse return error.NotMem;
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.memory)), instance.wasm_extern_kind(wasm_memory_as_extern(mem).?));
    const tbl = instance.wasm_extern_as_table(data[2]) orelse return error.NotTable;
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.table)), instance.wasm_extern_kind(wasm_table_as_extern(tbl).?));
    const glb = instance.wasm_extern_as_global(data[3]) orelse return error.NotGlobal;
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.global)), instance.wasm_extern_kind(wasm_global_as_extern(glb).?));

    try testing.expect(wasm_func_as_extern(null) == null);
    try testing.expect(wasm_func_as_extern_const(null) == null);
}

test "wasm_global_new: standalone host global get/set + immutable rejects set" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    // mutable i32 global = 7 (globaltype_new consumes the valtype)
    const gt = types.wasm_globaltype_new(types.wasm_valtype_new(0), 1) orelse return error.GlobalTypeAllocFailed;
    defer types.wasm_globaltype_delete(gt);
    var init_val: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 7 } };
    const g = wasm_global_new(s, gt, &init_val) orelse return error.GlobalNewFailed;
    defer instance.wasm_global_delete(g);

    var out: instance.Val = undefined;
    instance.wasm_global_get(g, &out);
    try testing.expectEqual(@as(i32, 7), out.of.i32);
    var nine: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 9 } };
    instance.wasm_global_set(g, &nine);
    instance.wasm_global_get(g, &out);
    try testing.expectEqual(@as(i32, 9), out.of.i32);
    // as_extern wraps the standalone global to kind global.
    try testing.expectEqual(@as(u8, @intFromEnum(instance.ExternKind.global)), instance.wasm_extern_kind(wasm_global_as_extern(g).?));

    // immutable global: set is a no-op.
    const gt2 = types.wasm_globaltype_new(types.wasm_valtype_new(0), 0) orelse return error.GlobalTypeAllocFailed;
    defer types.wasm_globaltype_delete(gt2);
    var five: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 5 } };
    const gi = wasm_global_new(s, gt2, &five) orelse return error.GlobalNewFailed;
    defer instance.wasm_global_delete(gi);
    instance.wasm_global_set(gi, &nine);
    instance.wasm_global_get(gi, &out);
    try testing.expectEqual(@as(i32, 5), out.of.i32);

    try testing.expect(wasm_global_new(null, gt, &init_val) == null);
}

// (module (import "env" "g" (global (mut i32)))
//   (func (export "get") (result i32) global.get 0))
const import_global_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
    0x02, 0x0a, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x67, 0x03, 0x7f, 0x01, // import env.g global (mut i32)
    0x03, 0x02, 0x01, 0x00, // func[0]: type 0
    0x07, 0x07, 0x01, 0x03, 0x67, 0x65, 0x74, 0x00, 0x00, // export "get" → func 0
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x23, 0x00, 0x0b, // code: global.get 0
};

test "wasm_global_new: host global imported — guest global.get sees host value + host set shares the cell" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);

    const gt = types.wasm_globaltype_new(types.wasm_valtype_new(0), 1) orelse return error.GlobalTypeAllocFailed;
    defer types.wasm_globaltype_delete(gt);
    var init_val: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 42 } };
    const hg = wasm_global_new(s, gt, &init_val) orelse return error.GlobalNewFailed;
    defer instance.wasm_global_delete(hg);

    var bytes = import_global_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var imports = [_]?*const Extern{wasm_global_as_extern_const(hg)};
    const inst = instance.wasm_instance_new(s, m, &imports, null) orelse return error.InstanceAllocFailed;
    defer instance.wasm_instance_delete(inst);

    var exports: vec.ExternVec = .{ .size = 0, .data = null };
    instance.wasm_instance_exports(inst, &exports);
    defer instance.wasm_extern_vec_delete(&exports);
    const getf = instance.wasm_extern_as_func(exports.data.?[0]) orelse return error.NotFunc;

    const args: vec.ValVec = .{ .size = 0, .data = null };
    var results_data: [1]instance.Val = undefined;
    var results: vec.ValVec = .{ .size = 1, .data = &results_data };
    try testing.expect(instance.wasm_func_call(getf, &args, &results) == null);
    try testing.expectEqual(@as(i32, 42), results_data[0].of.i32); // guest reads host's value

    // Host writes the shared cell; guest re-read sees it.
    var hundred: instance.Val = .{ .kind = .i32, .of = .{ .i32 = 100 } };
    instance.wasm_global_set(hg, &hundred);
    try testing.expect(instance.wasm_func_call(getf, &args, &results) == null);
    try testing.expectEqual(@as(i32, 100), results_data[0].of.i32);
}
