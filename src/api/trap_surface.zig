//! Trap surface of the C ABI binding (§9.5 / 5.0 chunk b
//! carve-out from `wasm.zig` per ADR-0007).
//!
//! Holds the `TrapKind` classification, the `Trap` shape itself,
//! the interp-error → kind mapping, the message lookup, the
//! binding-internal `allocTrap` helper, and the three
//! `wasm_trap_*` C exports.
//!
//! `Store` and `ByteVec` are still defined in `wasm.zig`;
//! we reach back through a module-level circular import (Zig 0.16
//! resolves it because the references are pointer-only — no
//! struct-layout cycle).
//!
//! `wasm_byte_vec_delete` ADR-listed alongside this file but
//! actually has zero Trap coupling; it stays in `wasm.zig`
//! and moves later with the rest of the vec family in chunk c.
//!
//! Zone 3 — same as the rest of `src/api/`.

const std = @import("std");
const wasm_c_api = @import("wasm.zig");

const testing = std.testing;

// ============================================================
// Trap classification + shape
// ============================================================

/// `wasm_trap_kind_t` — internal classification of a Trap.
/// Maps `runtime.Trap` conditions to the spec-conformant message
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
    store: ?*wasm_c_api.Store,
    kind: TrapKind,
    message_ptr: ?[*]u8,
    message_len: usize,
};

// ============================================================
// Internal helpers
// ============================================================

pub fn trapMessageFor(kind: TrapKind) []const u8 {
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

pub fn mapInterpTrap(err: anyerror) TrapKind {
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

pub fn allocTrap(alloc: std.mem.Allocator, store: ?*wasm_c_api.Store, kind: TrapKind) ?*Trap {
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

// ============================================================
// C exports
// ============================================================

/// `wasm_trap_new(store, message)` — allocate a Trap whose
/// message is a copy of the byte_vec contents. Used by C hosts
/// to surface their own host-side errors as traps; the binding
/// itself prefers `allocTrap` with a `TrapKind` so it can map
/// runtime conditions to the spec-conformant strings.
pub export fn wasm_trap_new(s: ?*wasm_c_api.Store, message: ?*const wasm_c_api.ByteVec) callconv(.c) ?*Trap {
    const store = s orelse return null;
    const alloc = wasm_c_api.storeAllocator(store) orelse return null;
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
pub export fn wasm_trap_delete(t: ?*Trap) callconv(.c) void {
    const handle = t orelse return;
    const store = handle.store orelse return;
    const alloc = wasm_c_api.storeAllocator(store) orelse return;
    if (handle.message_ptr) |p| alloc.free(p[0..handle.message_len]);
    alloc.destroy(handle);
}

/// `wasm_trap_message(*Trap, *out ByteVec)` — populate `out`
/// with a freshly-allocated copy of the trap's message (per
/// upstream wasm.h's `own` discipline: `out` becomes owned by
/// the caller and must be released via `wasm_byte_vec_delete`).
/// Writes a zero-length vec if the trap has no message or
/// allocation fails.
pub export fn wasm_trap_message(t: ?*const Trap, out: ?*wasm_c_api.ByteVec) callconv(.c) void {
    const out_ptr = out orelse return;
    out_ptr.* = .{ .size = 0, .data = null };
    const handle = t orelse return;
    const store = handle.store orelse return;
    const alloc = wasm_c_api.storeAllocator(store) orelse return;
    const ptr = handle.message_ptr orelse return;
    const copy = alloc.dupe(u8, ptr[0..handle.message_len]) catch return;
    out_ptr.* = .{ .size = copy.len, .data = copy.ptr };
}

// ============================================================
// Tests
// ============================================================

test "wasm_trap_new / message / delete: round-trip from caller-supplied message" {
    const e = wasm_c_api.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer wasm_c_api.wasm_engine_delete(e);
    const s = wasm_c_api.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer wasm_c_api.wasm_store_delete(s);

    var msg_bytes = "host failure".*;
    const msg_bv: wasm_c_api.ByteVec = .{ .size = msg_bytes.len, .data = &msg_bytes };
    const trap = wasm_trap_new(s, &msg_bv) orelse return error.TrapAllocFailed;
    defer wasm_trap_delete(trap);

    var out: wasm_c_api.ByteVec = .{ .size = 0, .data = null };
    wasm_trap_message(trap, &out);
    defer wasm_c_api.wasm_byte_vec_delete(&out);
    try testing.expectEqual(@as(usize, 12), out.size);
    try testing.expectEqualStrings("host failure", out.data.?[0..out.size]);
}

test "wasm_trap_*: null-arg discipline" {
    try testing.expect(wasm_trap_new(null, null) == null);
    wasm_trap_delete(null);
    var out: wasm_c_api.ByteVec = .{ .size = 0, .data = null };
    wasm_trap_message(null, &out);
    try testing.expectEqual(@as(usize, 0), out.size);
    wasm_c_api.wasm_byte_vec_delete(null);
}
