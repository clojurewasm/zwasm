//! `Instance` — native Zig facade for an instantiated module per
//! ADR-0109 §3.5 + §3.6.
//!
//! Wraps `runtime/instance/instance.zig::Instance` (aliased
//! through `src/api/instance.zig` as the public binding handle)
//! and exposes `invoke(name, args, results)` with a typed
//! `InvokeError` union of the binding-shape errors plus every
//! `runtime.Trap` variant. The previous c_api veneer (`src/zwasm.zig`)
//! collapsed the 12 trap variants onto a single `error.Trap`
//! catchall; this surface restores the per-variant precision so
//! Zig callers can branch on the specific spec condition.

const std = @import("std");
const Allocator = std.mem.Allocator;

const _api_instance = @import("../api/instance.zig");
const _runtime_value = @import("../runtime/value.zig");
const _runtime_trap = @import("../runtime/trap.zig");
const _dispatch = @import("../interp/dispatch.zig");
const _zir = @import("../ir/zir.zig");

const _memory = @import("memory.zig");
const _global = @import("global.zig");
const _table = @import("table.zig");
const _typed_func = @import("typed_func.zig");
const _vc = @import("value_conv.zig");
const _zwasm = @import("../zwasm.zig");

/// Wasm spec §4.4 — runtime trap conditions. Re-exported from
/// `runtime.Trap` (12 variants).
pub const Trap = _runtime_trap.Trap;

pub const Instance = struct {
    handle: *_api_instance.Instance,
    c_store: *_api_instance.Store,

    pub fn deinit(self: *Instance) void {
        _api_instance.wasm_instance_delete(self.handle);
    }

    /// ADR-0179 #3a — request cooperative interruption of this instance from
    /// any thread (timeout / host cancellation). The running guest traps
    /// `error.Interrupted` at the next function entry or loop back-edge poll.
    /// Idempotent. Call `clearInterrupt` before re-invoking.
    ///
    /// INVARIANT / D-314 seam: the facade only produces interp-backed instances
    /// today, so `handle.runtime` is always present and the budget mutators
    /// always take effect. The assert pins that — a future JIT-backed facade
    /// instance (`handle.runtime == null`) MUST route to the JIT limit path
    /// (D-314), never fall through this setter as a no-op.
    pub fn interrupt(self: *Instance) void {
        std.debug.assert(self.handle.runtime != null);
        if (self.handle.runtime) |rt| rt.interrupt_flag_storage.store(1, .monotonic);
    }

    /// Clear a prior `interrupt()` so this instance can be invoked again.
    pub fn clearInterrupt(self: *Instance) void {
        std.debug.assert(self.handle.runtime != null); // D-314 seam (see `interrupt`)
        if (self.handle.runtime) |rt| rt.interrupt_flag_storage.store(0, .monotonic);
    }

    /// Whether an interruption is currently pending (set, not yet cleared).
    pub fn interruptRequested(self: *Instance) bool {
        if (self.handle.runtime) |rt| return rt.interrupt_flag_storage.load(.monotonic) != 0;
        return false;
    }

    /// ADR-0179 #3c — impose a host max on linear-memory size, in PAGES (of
    /// memory 0's page size), an extra cap below the module's declared max.
    /// `memory.grow` past it returns the spec grow-failure (−1), not a trap.
    /// `null` clears the host cap. (Interp/facade path; the JIT `--engine jit`
    /// grow cap is clamped at setup — #3c-2.)
    pub fn setMemoryPagesLimit(self: *Instance, max_pages: ?u64) void {
        std.debug.assert(self.handle.runtime != null); // D-314 seam (see `interrupt`)
        if (self.handle.runtime) |rt| rt.store_memory_pages_max = max_pages;
    }

    /// D-316 — impose a host max on table size, in ELEMENTS, applied to every
    /// table in this instance (an extra cap below each table's declared max).
    /// `table.grow` past it returns the spec grow-failure (−1), not a trap.
    /// `null` clears the host cap. (Interp/facade path; the JIT table-grow cap
    /// is a documented post-v0.1 enhancement — see the D-314 seam on `interrupt`.)
    pub fn setTableElementsLimit(self: *Instance, max_elements: ?u64) void {
        std.debug.assert(self.handle.runtime != null); // D-314 seam (see `interrupt`)
        if (self.handle.runtime) |rt| rt.store_table_elements_max = max_elements;
    }

    /// ADR-0179 #3b — set the deterministic instruction budget (fuel). The
    /// interp decrements once per executed instruction and traps
    /// `error.OutOfFuel` at 0. `null` = unmetered. (Interp/default engine; JIT
    /// fuel is a documented post-v0.1 enhancement.)
    pub fn setFuel(self: *Instance, fuel: ?u64) void {
        std.debug.assert(self.handle.runtime != null); // D-314 seam (see `interrupt`)
        if (self.handle.runtime) |rt| rt.fuel = fuel;
    }

    /// Remaining fuel, or `null` if unmetered / no live runtime.
    pub fn fuelRemaining(self: *Instance) ?u64 {
        if (self.handle.runtime) |rt| return rt.fuel;
        return null;
    }

    /// Wasm spec §4.5.3 — comptime-typed export-function wrapper.
    /// `Sig` must be a Zig function type whose param + result
    /// types map to Wasm scalars (i32/i64/f32/f64); multi-result
    /// signatures use an anonymous-struct return type
    /// (`fn(i32, i32) struct { i32, i32 }`). Lookup of the export
    /// itself is deferred to `.call()` so the typed wrapper is a
    /// cheap value (no syscall on construction).
    pub fn typedFunc(self: *Instance, comptime Sig: type, name: []const u8) _typed_func.TypedFunc(Sig) {
        return .{ .instance = self, .export_name = name };
    }

    /// Wasm spec §4.5.3 — surface the named export's function
    /// signature for callers that need to size args / results
    /// buffers without invoking. Returns null if the name has no
    /// matching export, the export isn't a function, or the
    /// func slot is missing. Consumed today by the wasm-3.0-spec
    /// runner's `assert_trap` path, which sizes a results buffer
    /// to `sig.results.len` before calling `invoke` (so the
    /// arity check doesn't trip before the function actually
    /// runs).
    pub fn exportFuncSig(self: *Instance, name: []const u8) ?_zir.FuncType {
        for (self.handle.exports_storage) |exp| {
            if (!std.mem.eql(u8, exp.name, name)) continue;
            if (exp.kind != .func) return null;
            if (exp.idx >= self.handle.func_ptrs_storage.len) return null;
            return self.handle.func_ptrs_storage[exp.idx].sig;
        }
        return null;
    }

    /// Wasm spec §4.2.8 — first memory instance, if any. Wasm 1.0
    /// allows at most one per module; v0.1 of the facade returns
    /// the implicit memory0 view.
    pub fn memory(self: *Instance) ?_memory.Memory {
        const rt = self.handle.runtime orelse return null;
        if (rt.memory.len == 0) return null;
        return .{ .rt = rt };
    }

    /// Wasm spec §4.5.5/6 — accessor for an exported global by name
    /// (D-272). Returns null if the name has no matching export, the
    /// export isn't a global, or its slot is missing. The returned
    /// `Global` reads/writes the live runtime cell (`get`/`set`);
    /// `set` on an immutable global is `error.Immutable`.
    pub fn global(self: *Instance, name: []const u8) ?_global.Global {
        const rt = self.handle.runtime orelse return null;
        for (self.handle.exports_storage, self.handle.export_types) |exp, et| {
            if (!std.mem.eql(u8, exp.name, name)) continue;
            if (exp.kind != .global) return null;
            if (exp.idx >= rt.globals.len) return null;
            return .{
                .rt = rt,
                .global_idx = exp.idx,
                .valtype = et.global.valtype,
                .mutable = et.global.mutable,
            };
        }
        return null;
    }

    /// Wasm spec §4.4.6/7 — accessor for an exported table by name
    /// (D-272). Returns null if the name has no matching export, the
    /// export isn't a table, or its slot is missing. The returned
    /// `Table` reads/writes the live runtime table (`get`/`set`/`size`/
    /// `grow`).
    pub fn table(self: *Instance, name: []const u8) ?_table.Table {
        const rt = self.handle.runtime orelse return null;
        for (self.handle.exports_storage, self.handle.export_types) |exp, et| {
            if (!std.mem.eql(u8, exp.name, name)) continue;
            if (exp.kind != .table) return null;
            if (exp.idx >= rt.tables.len) return null;
            return .{
                .rt = rt,
                .table_idx = exp.idx,
                .elem_type = et.table.elem_type,
                .max = et.table.max,
            };
        }
        return null;
    }

    /// Binding-shape errors (mismatched export name / kind / arity)
    /// in union with the full `runtime.Trap` set. Every spec trap
    /// condition is individually addressable — `error.DivByZero`,
    /// `error.OutOfBoundsLoad`, etc. — per ADR-0109 §3.6.
    pub const InvokeError = error{
        ExportNotFound,
        NotAFunc,
        ArgArityMismatch,
        ResultArityMismatch,
        /// A WASI host function requested process exit (e.g. `wasi:cli/exit`):
        /// the host records the exit code out-of-band and returns this to unwind
        /// the guest (a clean noreturn termination, NOT a wasm trap). The
        /// component-run caller catches it and reads the recorded code.
        ProcExit,
    } || Trap;

    /// Wasm spec §4.5.3 + §4.4 — invoke an exported function by name.
    /// `args` / `results` are raw `Value` slices (the TypedFunc path
    /// at J.4 wraps this with a comptime marshal layer).
    pub fn invoke(
        self: *Instance,
        name: []const u8,
        args: []const _zwasm.Value,
        results: []_zwasm.Value,
    ) InvokeError!void {
        // ADR-0179 #3a: the facade runs the body via `dispatch.run` directly
        // (not `mvp.invoke`), so the function-entry interrupt poll must happen
        // here; the throttled loop poll inside `dispatch.run` covers tight loops.
        if (self.handle.runtime) |rt0| try rt0.checkInterrupt();
        const found_idx = blk: {
            for (self.handle.exports_storage) |exp| {
                if (!std.mem.eql(u8, exp.name, name)) continue;
                if (exp.kind != .func) return error.NotAFunc;
                break :blk exp.idx;
            }
            return error.ExportNotFound;
        };

        // D-201a — a re-exported IMPORTED func occupies the empty-sig
        // `unreachable` placeholder in `func_ptrs_storage`; invoking it
        // by name must dispatch CROSS-MODULE via the `host_calls` thunk
        // (which reads args off the operand stack + pushes results) using
        // the SOURCE func's sig, not run the placeholder body.
        if (self.handle.runtime) |rt0| {
            if (found_idx < rt0.host_calls.len and found_idx < rt0.func_entities.len) {
                if (rt0.host_calls[found_idx]) |hc| {
                    const fe = rt0.func_entities[found_idx];
                    if (fe.func_idx >= fe.runtime.funcs.len) return error.ExportNotFound;
                    const isig = fe.runtime.funcs[fe.func_idx].sig;
                    if (args.len != isig.params.len) return error.ArgArityMismatch;
                    if (results.len != isig.results.len) return error.ResultArityMismatch;
                    const op_base = rt0.operand_len;
                    for (args) |a| rt0.pushOperand(_vc.zwasmToRuntime(a)) catch |e| {
                        rt0.operand_len = op_base;
                        return mapDispatchErr(e);
                    };
                    hc.fn_ptr(rt0, hc.ctx) catch |err| {
                        rt0.operand_len = op_base;
                        return mapDispatchErr(err);
                    };
                    if (rt0.operand_len < op_base + isig.results.len) {
                        rt0.operand_len = op_base;
                        return error.ResultArityMismatch;
                    }
                    var ri: usize = isig.results.len;
                    while (ri > 0) {
                        ri -= 1;
                        results[ri] = _vc.runtimeToZwasm(rt0.operand_buf[op_base + ri], isig.results[ri]);
                    }
                    rt0.operand_len = op_base;
                    return;
                }
            }
        }

        if (found_idx >= self.handle.func_ptrs_storage.len) return error.ExportNotFound;
        const zfunc = self.handle.func_ptrs_storage[found_idx];
        const sig = zfunc.sig;

        if (args.len != sig.params.len) return error.ArgArityMismatch;
        if (results.len != sig.results.len) return error.ResultArityMismatch;

        const rt = self.handle.runtime orelse return error.ExportNotFound;
        const store = self.handle.store orelse return error.ExportNotFound;
        const alloc = _api_instance.storeAllocator(store) orelse return error.OutOfMemory;

        const num_locals = sig.params.len + zfunc.locals.len;
        const locals = try alloc.alloc(_runtime_value.Value, num_locals);
        defer alloc.free(locals);
        for (locals) |*l| l.* = _runtime_value.Value.zero;
        for (args, 0..) |a, idx| locals[idx] = _vc.zwasmToRuntime(a);

        const op_base = rt.operand_len;
        try rt.pushFrame(.{
            .sig = sig,
            .locals = locals,
            .operand_base = op_base,
            .pc = 0,
            .func = zfunc,
        });

        _dispatch.run(rt, _api_instance.dispatchTable(), zfunc.instrs.items) catch |err| {
            _ = rt.popFrame();
            rt.operand_len = op_base;
            return mapDispatchErr(err);
        };
        _ = rt.popFrame();

        if (rt.operand_len < op_base + sig.results.len) {
            rt.operand_len = op_base;
            return error.ResultArityMismatch;
        }

        var i: usize = sig.results.len;
        while (i > 0) {
            i -= 1;
            const v = rt.operand_buf[op_base + i];
            results[i] = _vc.runtimeToZwasm(v, sig.results[i]);
        }
        rt.operand_len = op_base;
    }
};

/// Narrow `dispatch.run`'s `anyerror!void` return back to the
/// `Trap`-shaped set the spec actually defines. `else => @panic`
/// guards against future dispatch additions that emit non-Trap
/// errors (a new variant must be added to `runtime.Trap` and
/// echoed here — caught at compile time of the new path's tests).
fn mapDispatchErr(err: anyerror) Instance.InvokeError {
    return switch (err) {
        error.Unreachable => error.Unreachable,
        error.DivByZero => error.DivByZero,
        error.IntOverflow => error.IntOverflow,
        error.InvalidConversionToInt => error.InvalidConversionToInt,
        error.OutOfBoundsLoad => error.OutOfBoundsLoad,
        error.OutOfBoundsStore => error.OutOfBoundsStore,
        error.OutOfBoundsTableAccess => error.OutOfBoundsTableAccess,
        error.UninitializedElement => error.UninitializedElement,
        error.IndirectCallTypeMismatch => error.IndirectCallTypeMismatch,
        error.StackOverflow => error.StackOverflow,
        error.CallStackExhausted => error.CallStackExhausted,
        error.NullReference => error.NullReference,
        error.UncaughtException => error.UncaughtException,
        error.CastFailure => error.CastFailure, // Wasm 3.0 GC ref.cast (10.G c152)
        error.UnalignedAtomic => error.UnalignedAtomic, // Wasm threads (ADR-0168)
        error.ExpectedSharedMemory => error.ExpectedSharedMemory, // Wasm threads (ADR-0168)
        error.Interrupted => error.Interrupted, // host timeout/cancel (ADR-0179 #3a)
        error.OutOfFuel => error.OutOfFuel, // host fuel budget exhausted (ADR-0179 #3b)
        error.OutOfMemory => error.OutOfMemory,
        // A host func (e.g. wasi:cli/exit) requested process exit — unwind cleanly.
        error.ProcExit => error.ProcExit,
        else => @panic("zwasm.Instance.invoke: dispatch returned non-Trap error variant"),
    };
}

const testing = std.testing;

test "facade Instance.interrupt(): a pending interrupt traps the next invoke; clear re-enables (ADR-0179 #3a-2)" {
    // (module (func (export "f") (result i32) (i32.const 42)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->(i32)
        0x03, 0x02, 0x01, 0x00, // func: 1× type 0
        0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00, // export "f" = func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42; end
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .i32 = 0 }};

    // Baseline: runs to completion.
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);

    // Host requests interruption → the next invoke traps at function entry.
    try testing.expect(!inst.interruptRequested());
    inst.interrupt();
    try testing.expect(inst.interruptRequested());
    try testing.expectError(error.Interrupted, inst.invoke("f", &.{}, &results));

    // Cleared → runs to completion again.
    inst.clearInterrupt();
    try testing.expect(!inst.interruptRequested());
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "facade setMemoryPagesLimit: host cap refuses memory.grow past it (ADR-0179 #3c)" {
    // (module (memory (export "m") 1))  — min 1 page, no declared max.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x05, 0x03, 0x01, 0x00, 0x01, // memory: 1× {min 1}
        0x07, 0x05, 0x01, 0x01, 'm', 0x02, 0x00, // export "m" = memory 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    inst.setMemoryPagesLimit(2); // host cap = 2 pages (below the spec max)
    const mem = inst.memory() orelse return error.NoMemory;

    try testing.expectEqual(@as(?u32, 1), mem.grow(1)); // 1 → 2 OK (old size 1)
    try testing.expectEqual(@as(?u32, null), mem.grow(1)); // 2 → 3 refused by host cap

    inst.setMemoryPagesLimit(4); // raise the cap → growth allowed again
    try testing.expectEqual(@as(?u32, 2), mem.grow(1)); // 2 → 3 OK

    inst.setMemoryPagesLimit(null); // clear host cap
    try testing.expectEqual(@as(?u32, 3), mem.grow(1)); // 3 → 4 OK (spec max only)
}

test "facade setTableElementsLimit: host cap refuses table.grow past it (D-316)" {
    // (module (table (export "t") 1 funcref))  — min 1, no declared max.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table: 1× funcref {min 1}
        0x07, 0x05, 0x01, 0x01, 't', 0x01, 0x00, // export "t" = table 0
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    inst.setTableElementsLimit(3); // host cap = 3 elements (below the spec max)
    const tab = inst.table("t") orelse return error.NoTable;
    const nullref = _zwasm.Value{ .funcref = null };

    try tab.grow(2, nullref); // 1 → 3 OK (at the cap)
    try testing.expectError(error.GrowFailed, tab.grow(1, nullref)); // 3 → 4 refused

    inst.setTableElementsLimit(5); // raise the cap → growth allowed again
    try tab.grow(2, nullref); // 3 → 5 OK

    inst.setTableElementsLimit(null); // clear host cap
    try tab.grow(1, nullref); // 5 → 6 OK (no declared/spec table max here)
}

test "facade setFuel: exhausted budget traps OutOfFuel; ample budget completes + drains (ADR-0179 #3b)" {
    // (module (func (export "f") (result i32) (i32.const 42)))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: ()->(i32)
        0x03, 0x02, 0x01, 0x00, // func: 1× type 0
        0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00, // export "f" = func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42; end
    };
    var eng = try _zwasm.Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&bytes);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    var results = [_]_zwasm.Value{.{ .i32 = 0 }};

    // Zero budget → the first instruction traps deterministically.
    inst.setFuel(0);
    try testing.expectError(error.OutOfFuel, inst.invoke("f", &.{}, &results));

    // Ample budget → completes, and instructions were charged.
    inst.setFuel(1000);
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
    const rem = inst.fuelRemaining() orelse return error.NoFuel;
    try testing.expect(rem < 1000);

    // Unmetered → always completes.
    inst.setFuel(null);
    try inst.invoke("f", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}
