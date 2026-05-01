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

// ============================================================
// Opaque types (match wasm.h declarations 1:1)
// ============================================================

/// `wasm_engine_t` — process-wide top-level handle. Owns nothing
/// directly; created via `wasm_engine_new()`. C hosts treat it
/// as opaque.
pub const Engine = extern struct {
    _padding: usize = 0,
};

/// `wasm_store_t` — module-instantiation context owning a single
/// `interp.Runtime` plus the GC root set the binding will need
/// once §9.3 / 3.5 (instance new) lands.
pub const Store = extern struct {
    _padding: usize = 0,
};

/// `wasm_module_t` — validated + lowered module. Wraps a
/// frontend-produced ZIR + section snapshots.
pub const Module = extern struct {
    _padding: usize = 0,
};

/// `wasm_instance_t` — instantiated module; owns the runtime
/// frame stack + linear memory + tables for one Wasm instance.
pub const Instance = extern struct {
    _padding: usize = 0,
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
// Smoke tests (shape stability)
// ============================================================

const testing = std.testing;

test "wasm_c_api shapes: extern structs are pointer-stable" {
    const e: Engine = .{};
    const s: Store = .{};
    const m: Module = .{};
    const i: Instance = .{};
    const f: Func = .{};
    const t: Trap = .{};
    _ = .{ e, s, m, i, f, t };
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
