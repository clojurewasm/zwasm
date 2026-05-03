//! Vec surface of the C ABI binding (§9.5 / 5.0 chunk c
//! carve-out from `wasm_c_api.zig` per ADR-0007).
//!
//! Holds the three vec shapes upstream `wasm.h` exposes
//! (`ByteVec`, `ValVec`, `ExternVec`), the comptime-generic
//! helpers backing the `WASM_DECLARE_VEC` family (`_new_empty`
//! / `_new_uninitialized` / `_new` / `_copy` / `_delete`), and
//! the `wasm_byte_vec_*` / `wasm_val_vec_*` C exports plus the
//! `wasm_extern_vec_new_empty` / `_new_uninitialized` / `_new`
//! prefix of the extern-vec family.
//!
//! `wasm_extern_vec_delete` stays in `wasm_c_api.zig` because it
//! cascades into `wasm_extern_delete`; threading the dependency
//! one-way keeps the cycle out of the carve-out (see ADR-0007 +
//! handover note for chunk d). It moves with `instance.zig`.
//!
//! All vec data is allocated from `std.heap.c_allocator` so a vec
//! can be freed through the matching `_delete` regardless of
//! which Engine produced it — C hosts may construct vecs without
//! holding an Engine handle (e.g. before `wasm_engine_new`).
//!
//! Zone 3 — same as the rest of `src/c_api/`. References `Val`
//! and `Extern` from `wasm_c_api.zig` via a module-level circular
//! import; Zig 0.16 resolves it because the references are
//! pointer-only (no struct-layout cycle).

const std = @import("std");
const wasm_c_api = @import("wasm_c_api.zig");

const testing = std.testing;

// ============================================================
// Vec shapes (match wasm.h declarations 1:1)
// ============================================================

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
    data: ?[*]wasm_c_api.Val,
};

/// `wasm_extern_vec_t` — vec(wasm_extern_t*). Per upstream
/// `WASM_DECLARE_VEC(extern, *)` discipline, data is an array of
/// pointers; the vec owns both the array and each pointed-to
/// `Extern`.
pub const ExternVec = extern struct {
    size: usize,
    data: ?[*]?*wasm_c_api.Extern,
};

// ============================================================
// Comptime-generic helpers (WASM_DECLARE_VEC family)
// ============================================================

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

// ============================================================
// byte vec
// ============================================================

pub export fn wasm_byte_vec_new_empty(out: ?*ByteVec) callconv(.c) void {
    vecNewEmpty(ByteVec, out);
}

pub export fn wasm_byte_vec_new_uninitialized(out: ?*ByteVec, size: usize) callconv(.c) void {
    vecNewUninitialized(u8, ByteVec, out, size);
}

pub export fn wasm_byte_vec_new(out: ?*ByteVec, size: usize, src: ?[*]const u8) callconv(.c) void {
    vecNew(u8, ByteVec, out, size, src);
}

pub export fn wasm_byte_vec_copy(out: ?*ByteVec, src: ?*const ByteVec) callconv(.c) void {
    vecCopy(u8, ByteVec, out, src);
}

/// `wasm_byte_vec_delete(*ByteVec)` — free the data backing of a
/// ByteVec. Pinned to `std.heap.c_allocator` (see header above).
pub export fn wasm_byte_vec_delete(v: ?*ByteVec) callconv(.c) void {
    vecDelete(ByteVec, v);
}

// ============================================================
// val vec
// ============================================================

pub export fn wasm_val_vec_new_empty(out: ?*ValVec) callconv(.c) void {
    vecNewEmpty(ValVec, out);
}

pub export fn wasm_val_vec_new_uninitialized(out: ?*ValVec, size: usize) callconv(.c) void {
    vecNewUninitialized(wasm_c_api.Val, ValVec, out, size);
}

pub export fn wasm_val_vec_new(out: ?*ValVec, size: usize, src: ?[*]const wasm_c_api.Val) callconv(.c) void {
    vecNew(wasm_c_api.Val, ValVec, out, size, src);
}

pub export fn wasm_val_vec_copy(out: ?*ValVec, src: ?*const ValVec) callconv(.c) void {
    vecCopy(wasm_c_api.Val, ValVec, out, src);
}

pub export fn wasm_val_vec_delete(v: ?*ValVec) callconv(.c) void {
    vecDelete(ValVec, v);
}

// ============================================================
// extern vec — pointer-vec prefix
//
// `_new_empty` / `_new_uninitialized` / `_new` live here. The
// `_new_uninitialized` form `@memset`s to null (pointer-vec
// invariant) so it is open-coded rather than routed through the
// generic helper.
//
// `wasm_extern_vec_delete` does NOT live here: it cascades into
// `wasm_extern_delete`, which still lives in `wasm_c_api.zig`.
// Threading the dependency one-way keeps vec.zig cycle-free; the
// delete moves with `instance.zig` in chunk d.
// ============================================================

pub export fn wasm_extern_vec_new_empty(out: ?*ExternVec) callconv(.c) void {
    const o = out orelse return;
    o.* = .{ .size = 0, .data = null };
}

pub export fn wasm_extern_vec_new_uninitialized(out: ?*ExternVec, size: usize) callconv(.c) void {
    const o = out orelse return;
    if (size == 0) {
        o.* = .{ .size = 0, .data = null };
        return;
    }
    const buf = std.heap.c_allocator.alloc(?*wasm_c_api.Extern, size) catch {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    @memset(buf, null);
    o.* = .{ .size = size, .data = buf.ptr };
}

pub export fn wasm_extern_vec_new(out: ?*ExternVec, size: usize, src: ?[*]const ?*wasm_c_api.Extern) callconv(.c) void {
    const o = out orelse return;
    if (size == 0 or src == null) {
        o.* = .{ .size = 0, .data = null };
        return;
    }
    const buf = std.heap.c_allocator.alloc(?*wasm_c_api.Extern, size) catch {
        o.* = .{ .size = 0, .data = null };
        return;
    };
    @memcpy(buf, src.?[0..size]);
    o.* = .{ .size = size, .data = buf.ptr };
}

// ============================================================
// Tests — byte/val vec round-trips + null-arg discipline
//
// Extern-vec null-arg coverage stays in `wasm_c_api.zig` until
// chunk d moves `wasm_extern_vec_delete` alongside the rest of
// the extern surface.
// ============================================================

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
    var src: [2]wasm_c_api.Val = .{
        .{ .kind = .i32, .of = .{ .i32 = 7 } },
        .{ .kind = .i64, .of = .{ .i64 = -1 } },
    };
    var v: ValVec = .{ .size = 0, .data = null };
    wasm_val_vec_new(&v, src.len, &src);
    defer wasm_val_vec_delete(&v);
    try testing.expectEqual(@as(usize, 2), v.size);
    try testing.expectEqual(wasm_c_api.ValKind.i32, v.data.?[0].kind);
    try testing.expectEqual(@as(i32, 7), v.data.?[0].of.i32);
    try testing.expectEqual(wasm_c_api.ValKind.i64, v.data.?[1].kind);
    try testing.expectEqual(@as(i64, -1), v.data.?[1].of.i64);

    var v2: ValVec = .{ .size = 0, .data = null };
    wasm_val_vec_copy(&v2, &v);
    defer wasm_val_vec_delete(&v2);
    try testing.expectEqual(v.size, v2.size);
    try testing.expect(v.data.? != v2.data.?);
}

test "wasm_byte_vec_* / wasm_val_vec_*: null-arg discipline" {
    wasm_byte_vec_new_empty(null);
    wasm_byte_vec_new_uninitialized(null, 16);
    wasm_byte_vec_new(null, 4, null);
    wasm_byte_vec_copy(null, null);
    wasm_byte_vec_delete(null);
    wasm_val_vec_new_empty(null);
    wasm_val_vec_new_uninitialized(null, 16);
    wasm_val_vec_new(null, 4, null);
    wasm_val_vec_copy(null, null);
    wasm_val_vec_delete(null);
}
