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
    const inst = handle.instance orelse return null;
    const store = inst.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const v = alloc.create(Extern) catch return null;
    v.* = .{ .kind = .global, .instance = inst, .global = handle, .global_idx = handle.global_idx, .borrowed = true };
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
