//! zwasm-specific C extensions (`include/zwasm.h`) — instance-level
//! sandboxing setters (ADR-0179 #3a-4 / D-314).
//!
//! Split from `instance.zig` (per-file cap; ADR-0099 P3: the zwasm
//! extension surface evolves with zwasm features, independently of the
//! frozen upstream wasm.h binding). `zwasm_instance_get_func` and the
//! `zwasm_wasi_config_*` family predate this file and stay where they
//! are; the Phase-16 C-surface audit owns consolidating the extension
//! surface (and completing zwasm.h's declarations for the older ones).
//!
//! These mirror the Zig facade's post-instantiate budget mutators (v1
//! exposed CONFIG-level `zwasm_config_set_*`; v2 deliberately chose
//! per-instance, mid-workload-mutable setters — ADR-0179 rev 2026-06-12).
//! The C API only creates INTERP instances (live security posture; JIT
//! budgets are the CLI surface), so `runtime` is always present today;
//! null instance/runtime = no-op, matching wasm.h's null-tolerant style.
//!
//! Zone 3 (`src/api/`).

const std = @import("std");

const capi = @import("instance.zig");
const trap_surface = @import("trap_surface.zig");
const vec = @import("vec.zig");

const Instance = capi.Instance;

/// Arm (or re-arm) the deterministic fuel budget; the running guest traps
/// "all fuel consumed" (kind `out_of_fuel` = 17) when it is exhausted.
/// Interp fuel units = instructions executed.
pub export fn zwasm_instance_set_fuel(i: ?*Instance, fuel: u64) callconv(.c) void {
    const inst = i orelse return;
    if (inst.runtime) |rt| rt.fuel = fuel;
}

/// Remove the fuel budget (unmetered).
pub export fn zwasm_instance_disable_fuel(i: ?*Instance) callconv(.c) void {
    const inst = i orelse return;
    if (inst.runtime) |rt| rt.fuel = null;
}

/// Read the remaining fuel into `out`; returns false when unmetered
/// (out untouched).
pub export fn zwasm_instance_fuel_remaining(i: ?*const Instance, out: ?*u64) callconv(.c) bool {
    const inst = i orelse return false;
    const rt = inst.runtime orelse return false;
    const f = rt.fuel orelse return false;
    if (out) |p| p.* = f;
    return true;
}

/// Impose a host max on linear memory, in PAGES (of memory 0's page size)
/// — an extra ceiling below the module's declared max. `memory.grow` past
/// it returns the spec grow-failure (-1), not a trap.
pub export fn zwasm_instance_set_memory_pages_limit(i: ?*Instance, max_pages: u64) callconv(.c) void {
    const inst = i orelse return;
    if (inst.runtime) |rt| rt.store_memory_pages_max = max_pages;
}

/// Clear the host memory cap (only the declared/spec max remains).
pub export fn zwasm_instance_clear_memory_pages_limit(i: ?*Instance) callconv(.c) void {
    const inst = i orelse return;
    if (inst.runtime) |rt| rt.store_memory_pages_max = null;
}

/// Request cooperative interruption from any thread (timeout / host
/// cancellation): the running guest traps "interrupted" (kind 16) at its
/// next poll. Idempotent; pair with `zwasm_instance_clear_interrupt`
/// before re-invoking.
pub export fn zwasm_instance_interrupt(i: ?*Instance) callconv(.c) void {
    const inst = i orelse return;
    if (inst.runtime) |rt| rt.interrupt_flag_storage.store(1, .monotonic);
}

/// Clear a prior `zwasm_instance_interrupt` so the instance runs again.
pub export fn zwasm_instance_clear_interrupt(i: ?*Instance) callconv(.c) void {
    const inst = i orelse return;
    if (inst.runtime) |rt| rt.interrupt_flag_storage.store(0, .monotonic);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const ByteVec = vec.ByteVec;
const ValVec = vec.ValVec;
const TrapKind = trap_surface.TrapKind;

// (module (func (export "spin") (loop (br 0)))) — infinite; only a
// sandboxing limit ends it (hang-as-failure, gate-timeout bounded).
const spin_loop_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x73, 0x70,
    0x69, 0x6e, 0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x03, 0x40, 0x0c,
    0x00, 0x0b, 0x0b,
};

const TestCtx = struct {
    e: *capi.Engine,
    s: *capi.Store,
    m: *capi.Module,
    i: *Instance,
    func: *capi.Func,

    fn init(bytes: []const u8) !TestCtx {
        const e = capi.wasm_engine_new() orelse return error.EngineAllocFailed;
        errdefer capi.wasm_engine_delete(e);
        const s = capi.wasm_store_new(e) orelse return error.StoreAllocFailed;
        errdefer capi.wasm_store_delete(s);
        const bv: ByteVec = .{ .size = bytes.len, .data = @constCast(bytes.ptr) };
        const m = capi.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
        errdefer capi.wasm_module_delete(m);
        const i = capi.wasm_instance_new(s, m, null, null) orelse return error.InstanceAllocFailed;
        errdefer capi.wasm_instance_delete(i);
        const func = capi.zwasm_instance_get_func(i, 0) orelse return error.FuncResolveFailed;
        return .{ .e = e, .s = s, .m = m, .i = i, .func = func };
    }

    fn deinit(self: *TestCtx) void {
        capi.wasm_func_delete(self.func);
        capi.wasm_instance_delete(self.i);
        capi.wasm_module_delete(self.m);
        capi.wasm_store_delete(self.s);
        capi.wasm_engine_delete(self.e);
    }

    fn callNoArgs(self: *TestCtx) ?*trap_surface.Trap {
        const args: ValVec = .{ .size = 0, .data = null };
        const results: ValVec = .{ .size = 0, .data = null };
        return capi.wasm_func_call(self.func, &args, @constCast(&results));
    }
};

test "zwasm_instance_set_fuel: exhaustion traps out_of_fuel (kind 17); remaining/disable round-trip (ADR-0179 #3a-4)" {
    var ctx = try TestCtx.init(&spin_loop_wasm);
    defer ctx.deinit();
    zwasm_instance_set_fuel(ctx.i, 10_000);
    const trap = ctx.callNoArgs();
    try testing.expect(trap != null);
    try testing.expectEqual(@as(i32, 17), trap_surface.zwasm_trap_kind(trap));
    trap_surface.wasm_trap_delete(trap);
    var rem: u64 = 123;
    try testing.expect(zwasm_instance_fuel_remaining(ctx.i, &rem));
    try testing.expectEqual(@as(u64, 0), rem);
    zwasm_instance_disable_fuel(ctx.i);
    try testing.expect(!zwasm_instance_fuel_remaining(ctx.i, &rem));
}

test "zwasm_instance_interrupt: raised flag traps the spin guest (kind 16); clear is observable via fuel (ADR-0179 #3a-4)" {
    // The interp's interrupt poll is THROTTLED (every ~1024 steps), so the
    // guest must actually run that far — the spin loop crosses it instantly;
    // a 2-instruction const fn never would.
    var ctx = try TestCtx.init(&spin_loop_wasm);
    defer ctx.deinit();
    zwasm_instance_interrupt(ctx.i);
    const trap = ctx.callNoArgs();
    try testing.expect(trap != null);
    try testing.expectEqual(@as(i32, 16), trap_surface.zwasm_trap_kind(trap));
    trap_surface.wasm_trap_delete(trap);
    // Clear + arm fuel: were the flag still set, the throttled poll would
    // trap kind 16 within ~1024 steps — kind 17 at 10k proves the clear.
    zwasm_instance_clear_interrupt(ctx.i);
    zwasm_instance_set_fuel(ctx.i, 10_000);
    const trap2 = ctx.callNoArgs();
    try testing.expect(trap2 != null);
    try testing.expectEqual(@as(i32, 17), trap_surface.zwasm_trap_kind(trap2));
    trap_surface.wasm_trap_delete(trap2);
}

// (module (memory 1) (func (export "_start")
//   (drop (memory.grow (i32.const 1))) (if (i32.ne (memory.grow (i32.const 1))
//   (i32.const -1)) (then unreachable)))) — clean exit iff the SECOND grow is
// refused (mirrors the CLI grow-probe; pins the C cap end-to-end).
const c_grow_probe_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60,
    0x00, 0x00, 0x03, 0x02, 0x01, 0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07,
    0x0a, 0x01, 0x06, 0x5f, 0x73, 0x74, 0x61, 0x72, 0x74, 0x00, 0x00, 0x0a,
    0x14, 0x01, 0x12, 0x00, 0x41, 0x01, 0x40, 0x00, 0x1a, 0x41, 0x01, 0x40,
    0x00, 0x41, 0x7f, 0x47, 0x04, 0x40, 0x00, 0x0b, 0x0b,
};

test "zwasm_instance_set_memory_pages_limit: caps grow; clear lifts the cap (ADR-0179 #3a-4)" {
    var ctx = try TestCtx.init(&c_grow_probe_wasm);
    defer ctx.deinit();
    // Capped at 2 pages → second grow refused (-1) → guest exits clean.
    zwasm_instance_set_memory_pages_limit(ctx.i, 2);
    const trap = ctx.callNoArgs();
    try testing.expect(trap == null);
    // Cap lifted → grow 2→3 succeeds (≠ -1) → guest's own unreachable trap.
    zwasm_instance_clear_memory_pages_limit(ctx.i);
    const trap2 = ctx.callNoArgs();
    try testing.expect(trap2 != null);
    try testing.expectEqual(TrapKind.unreachable_, trap2.?.kind);
    trap_surface.wasm_trap_delete(trap2);
}
