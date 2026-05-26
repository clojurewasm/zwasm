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
const _typed_func = @import("typed_func.zig");
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

    /// Binding-shape errors (mismatched export name / kind / arity)
    /// in union with the full `runtime.Trap` set. Every spec trap
    /// condition is individually addressable — `error.DivByZero`,
    /// `error.OutOfBoundsLoad`, etc. — per ADR-0109 §3.6.
    pub const InvokeError = error{
        ExportNotFound,
        NotAFunc,
        ArgArityMismatch,
        ResultArityMismatch,
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
        const found_idx = blk: {
            for (self.handle.exports_storage) |exp| {
                if (!std.mem.eql(u8, exp.name, name)) continue;
                if (exp.kind != .func) return error.NotAFunc;
                break :blk exp.idx;
            }
            return error.ExportNotFound;
        };

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
        for (args, 0..) |a, idx| locals[idx] = zwasmToRuntime(a);

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
            results[i] = runtimeToZwasm(v, sig.results[i]);
        }
        rt.operand_len = op_base;
    }
};

fn zwasmToRuntime(v: _zwasm.Value) _runtime_value.Value {
    return switch (v) {
        .i32 => |x| _runtime_value.Value.fromI32(x),
        .i64 => |x| _runtime_value.Value.fromI64(x),
        .f32 => |b| _runtime_value.Value.fromF32Bits(b),
        .f64 => |b| _runtime_value.Value.fromF64Bits(b),
        .v128 => |b| .{ .bits128 = b },
        .funcref => |r| .{ .ref = r orelse 0 },
        .externref => |r| .{ .ref = r orelse 0 },
    };
}

fn runtimeToZwasm(v: _runtime_value.Value, vt: _zir.ValType) _zwasm.Value {
    return switch (vt) {
        .i32 => .{ .i32 = v.i32 },
        .i64 => .{ .i64 = v.i64 },
        .f32 => .{ .f32 = @truncate(v.bits64) },
        .f64 => .{ .f64 = v.bits64 },
        .v128 => .{ .v128 = v.bits128 },
        .funcref => .{ .funcref = if (v.ref == 0) null else v.ref },
        .externref => .{ .externref = if (v.ref == 0) null else v.ref },
    };
}

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
        error.OutOfMemory => error.OutOfMemory,
        else => @panic("zwasm.Instance.invoke: dispatch returned non-Trap error variant"),
    };
}
