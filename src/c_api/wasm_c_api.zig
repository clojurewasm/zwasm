//! C ABI binding for `include/wasm.h` (Phase 3 / §9.3 / 3.2).
//!
//! Zone 3 — exposes the wasm-c-api shapes upstream defines so a
//! C host can `#include <wasm.h>` and link against this binding.
//! Per ROADMAP §1.1 the wasm-c-api surface is the primary C ABI;
//! `zwasm.h` extensions land alongside (§9.3 follow-on, post-
//! v0.1.0 surface).
//!
//! After the §9.5 / 5.0 carve-out (ADR-0007), this file is the
//! **public re-export hub** for the binding. The actual code
//! lives in sibling modules:
//!
//! - `wasi.zig`          — WASI thunks + `zwasm_wasi_config_*`
//! - `trap_surface.zig`  — `Trap` / `TrapKind` / `wasm_trap_*`
//! - `vec.zig`           — `WASM_DECLARE_VEC` family
//!                         (byte / val / extern shapes + ops)
//! - `instance.zig`      — Engine / Store / Module / Instance /
//!                         Func / Extern, instantiation,
//!                         `wasm_func_call`, `wasm_instance_exports`
//!
//! Re-exports below keep call sites (`cli/run.zig`, sibling
//! carve-outs, external tests) addressing names through
//! `wasm_c_api.<name>` regardless of which file owns the symbol.
//! Linker-visible C symbols are still produced from each module's
//! own `pub export fn`s — `c_api_lib.zig` references every
//! sibling so they all land in `libzwasm.a`.

const std = @import("std");

const runtime = @import("../runtime/runtime.zig");
const wasi = @import("wasi.zig");
const trap_surface = @import("trap_surface.zig");
const vec = @import("vec.zig");
const instance = @import("instance.zig");

const testing = std.testing;

// ============================================================
// Re-exports — wasi.zig
// ============================================================

pub const zwasm_wasi_config_new = wasi.zwasm_wasi_config_new;
pub const zwasm_wasi_config_delete = wasi.zwasm_wasi_config_delete;

// ============================================================
// Re-exports — trap_surface.zig
// ============================================================

pub const TrapKind = trap_surface.TrapKind;
pub const Trap = trap_surface.Trap;
pub const wasm_trap_new = trap_surface.wasm_trap_new;
pub const wasm_trap_delete = trap_surface.wasm_trap_delete;
pub const wasm_trap_message = trap_surface.wasm_trap_message;

// ============================================================
// Re-exports — vec.zig
// ============================================================

pub const ByteVec = vec.ByteVec;
pub const ValVec = vec.ValVec;
pub const ExternVec = vec.ExternVec;
pub const wasm_byte_vec_new_empty = vec.wasm_byte_vec_new_empty;
pub const wasm_byte_vec_new_uninitialized = vec.wasm_byte_vec_new_uninitialized;
pub const wasm_byte_vec_new = vec.wasm_byte_vec_new;
pub const wasm_byte_vec_copy = vec.wasm_byte_vec_copy;
pub const wasm_byte_vec_delete = vec.wasm_byte_vec_delete;
pub const wasm_val_vec_new_empty = vec.wasm_val_vec_new_empty;
pub const wasm_val_vec_new_uninitialized = vec.wasm_val_vec_new_uninitialized;
pub const wasm_val_vec_new = vec.wasm_val_vec_new;
pub const wasm_val_vec_copy = vec.wasm_val_vec_copy;
pub const wasm_val_vec_delete = vec.wasm_val_vec_delete;
pub const wasm_extern_vec_new_empty = vec.wasm_extern_vec_new_empty;
pub const wasm_extern_vec_new_uninitialized = vec.wasm_extern_vec_new_uninitialized;
pub const wasm_extern_vec_new = vec.wasm_extern_vec_new;

// ============================================================
// Re-exports — instance.zig
// ============================================================

pub const Engine = instance.Engine;
pub const Store = instance.Store;
pub const Module = instance.Module;
pub const Instance = instance.Instance;
pub const Func = instance.Func;
pub const ValKind = instance.ValKind;
pub const Val = instance.Val;
pub const ExternKind = instance.ExternKind;
pub const Extern = instance.Extern;
pub const storeAllocator = instance.storeAllocator;
pub const wasm_engine_new = instance.wasm_engine_new;
pub const wasm_engine_delete = instance.wasm_engine_delete;
pub const wasm_store_new = instance.wasm_store_new;
pub const wasm_store_delete = instance.wasm_store_delete;
pub const zwasm_store_set_wasi = instance.zwasm_store_set_wasi;
pub const wasm_module_new = instance.wasm_module_new;
pub const wasm_module_validate = instance.wasm_module_validate;
pub const wasm_module_delete = instance.wasm_module_delete;
pub const wasm_instance_new = instance.wasm_instance_new;
pub const wasm_instance_delete = instance.wasm_instance_delete;
pub const zwasm_instance_get_func = instance.zwasm_instance_get_func;
pub const wasm_func_delete = instance.wasm_func_delete;
pub const wasm_extern_kind = instance.wasm_extern_kind;
pub const wasm_extern_delete = instance.wasm_extern_delete;
pub const wasm_extern_as_func = instance.wasm_extern_as_func;
pub const wasm_extern_vec_delete = instance.wasm_extern_vec_delete;
pub const wasm_instance_exports = instance.wasm_instance_exports;
pub const wasm_func_call = instance.wasm_func_call;

// ============================================================
// Smoke tests (re-export shape stability)
// ============================================================

test "wasm_c_api shapes: top-level types instantiate cleanly" {
    const e: Engine = .{ .alloc_ptr = null, .alloc_vtable = null };
    const s: Store = .{ .engine = null };
    const m: Module = .{ .store = null, .bytes_ptr = null, .bytes_len = 0 };
    const i: Instance = .{ .store = null, .module = null, .runtime = null };
    const f: Func = .{ .instance = null, .func_idx = 0 };
    const t: Trap = .{ .store = null, .kind = .binding_error, .message_ptr = null, .message_len = 0 };
    _ = .{ e, s, m, i, f, t };
}

test "wasm_c_api: ValKind tag values match wasm.h" {
    // wasm.h declares:
    //   WASM_I32 = 0, WASM_I64 = 1, WASM_F32 = 2, WASM_F64 = 3,
    //   WASM_EXTERNREF = 128, WASM_FUNCREF = 129
    // Our `ValKind.anyref` aliases WASM_EXTERNREF (same value);
    // the name divergence is historical (the original wasm-c-api
    // draft used `anyref`).
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
    // `runtime.Runtime` shape; the §9.3 / 3.5 instance binding
    // will own one. Just touch the type name to assert the
    // import resolves.
    _ = runtime.Runtime;
}
