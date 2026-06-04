//! `wasm_module_serialize` / `_deserialize` + the `WASM_DECLARE_SHARABLE_REF`
//! share/obtain surface (wasm.h:412,422-423).
//!
//! **Byte-model** (ADR-0004 wasm-c-api; the serialized blob format is
//! runtime-defined): zwasm's `Module` is a byte-holder (it keeps the original
//! wasm bytes + re-compiles per instance), so the "serialized" form IS the wasm
//! bytes — serialize = copy `module.bytes`, deserialize = `wasm_module_new`
//! (parse). This round-trips correctly. QoI caveat (D-271): unlike wasmtime,
//! there is no compiled-artifact cache, so deserialize re-parses + each instance
//! re-compiles — functionally correct, not a perf shortcut. A SharedModule holds
//! its own copy of the bytes; `obtain` re-parses them into a Store's Module.
//!
//! Zone 3 (`src/api/`); re-exported via `api/wasm.zig`.

const std = @import("std");
const testing = std.testing;

const instance = @import("instance.zig");
const vec = @import("vec.zig");

/// `wasm_shared_module_t` — a shareable module handle: an owned copy of the wasm
/// bytes + the originating store (for the allocator). `obtain` re-parses them.
pub const SharedModule = struct {
    bytes_ptr: ?[*]u8,
    bytes_len: usize,
    store: ?*instance.Store,
};

pub export fn wasm_module_serialize(m: ?*const instance.Module, out: ?*vec.ByteVec) callconv(.c) void {
    const o = out orelse return;
    o.* = .{ .size = 0, .data = null };
    const src = m orelse return;
    const p = src.bytes_ptr orelse return; // byte-less module → empty out
    vec.wasm_byte_vec_new(o, src.bytes_len, p); // allocs + copies (the blob = the wasm bytes)
}

pub export fn wasm_module_deserialize(s: ?*instance.Store, bytes: ?*const vec.ByteVec) callconv(.c) ?*instance.Module {
    return instance.wasm_module_new(s, bytes); // parse the blob (= wasm bytes) back
}

pub export fn wasm_module_share(m: ?*const instance.Module) callconv(.c) ?*SharedModule {
    const src = m orelse return null;
    const store = src.store orelse return null;
    const alloc = instance.storeAllocator(store) orelse return null;
    const sm = alloc.create(SharedModule) catch return null;
    sm.* = .{ .bytes_ptr = null, .bytes_len = src.bytes_len, .store = store };
    if (src.bytes_ptr) |p| {
        const dup = alloc.alloc(u8, src.bytes_len) catch {
            alloc.destroy(sm);
            return null;
        };
        @memcpy(dup, p[0..src.bytes_len]);
        sm.bytes_ptr = dup.ptr;
    }
    return sm;
}

pub export fn wasm_module_obtain(s: ?*instance.Store, shared: ?*const SharedModule) callconv(.c) ?*instance.Module {
    const sm = shared orelse return null;
    const p = sm.bytes_ptr orelse return null;
    const bv: vec.ByteVec = .{ .size = sm.bytes_len, .data = p };
    return instance.wasm_module_new(s, &bv); // module_new copies the bytes → shared bytes stay owned
}

pub export fn wasm_shared_module_delete(shared: ?*SharedModule) callconv(.c) void {
    const sm = shared orelse return;
    const store = sm.store orelse return;
    const alloc = instance.storeAllocator(store) orelse return;
    if (sm.bytes_ptr) |p| alloc.free(p[0..sm.bytes_len]);
    alloc.destroy(sm);
}

test "module serialize/deserialize + share/obtain round-trip (byte-model) + null discipline" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }; // (module)
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    // serialize → deserialize → instantiate.
    var ser: vec.ByteVec = .{ .size = 0, .data = null };
    wasm_module_serialize(m, &ser);
    defer vec.wasm_byte_vec_delete(&ser);
    try testing.expectEqual(@as(usize, bytes.len), ser.size);
    const m2 = wasm_module_deserialize(s, &ser) orelse return error.NoDeser;
    defer instance.wasm_module_delete(m2);
    const inst2 = instance.wasm_instance_new(s, m2, null, null) orelse return error.NoInst;
    instance.wasm_instance_delete(inst2);

    // share → obtain → instantiate.
    const shared = wasm_module_share(m) orelse return error.NoShare;
    defer wasm_shared_module_delete(shared);
    const m3 = wasm_module_obtain(s, shared) orelse return error.NoObtain;
    defer instance.wasm_module_delete(m3);
    const inst3 = instance.wasm_instance_new(s, m3, null, null) orelse return error.NoInst;
    instance.wasm_instance_delete(inst3);

    // null discipline.
    var nser: vec.ByteVec = .{ .size = 99, .data = null };
    wasm_module_serialize(null, &nser);
    try testing.expectEqual(@as(usize, 0), nser.size);
    try testing.expect(wasm_module_deserialize(s, null) == null);
    try testing.expect(wasm_module_share(null) == null);
    try testing.expect(wasm_module_obtain(s, null) == null);
    wasm_shared_module_delete(null);
}
