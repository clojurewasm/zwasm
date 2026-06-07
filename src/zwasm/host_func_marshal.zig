//! Comptime host-fn adapter generator per ADR-0109 §3.2 +
//! `docs/zig_api_design.md` §3.2.
//!
//! Given a Zig host-fn signature `fn(*Caller, P1, P2, ...) R`,
//! emit a `HostCall { fn_ptr, ctx }` whose `fn_ptr` is invoked
//! from the dispatch loop when the importing module's `call N`
//! reaches the import slot. The thunk pops Wasm args off the
//! interpreter's operand stack, builds the Zig args tuple
//! (including the `*Caller`), invokes the user fn, and pushes
//! results back on the stack — matching Wasm spec §4.4.6 host
//! call semantics.

const std = @import("std");

const _runtime = @import("../runtime/runtime.zig");
const _value = @import("../runtime/value.zig");
const _zir = @import("../ir/zir.zig");
const _caller = @import("caller.zig");

pub const Caller = _caller.Caller;
const RuntimeValue = _value.Value;

pub const Error = error{
    /// The host-fn signature does not begin with `*Caller`.
    MissingCallerParam,
    /// The host-fn signature uses an unsupported Wasm type.
    UnsupportedHostFnType,
};

/// Holds the user's fn pointer typed against its concrete Sig so
/// the per-Sig thunk can `@call` it via this wrapper. Allocated by
/// `Linker.defineFunc`; lifetime tied to the Linker.
pub fn HostFnCtx(comptime Sig: type) type {
    return struct {
        user_fn: *const Sig,
        /// Opaque host context surfaced to the user fn via `Caller.data`
        /// (set by `Linker.defineFuncCtx`; null for `defineFunc`).
        host_data: ?*anyopaque = null,
    };
}

/// Comptime-emitted thunk for a given host-fn signature. Returns
/// the function pointer compatible with `runtime.HostCall.fn_ptr`.
pub fn thunkFor(comptime Sig: type) *const fn (*_runtime.Runtime, *anyopaque) anyerror!void {
    const fn_info = @typeInfo(Sig).@"fn";
    if (fn_info.params.len == 0 or (fn_info.params[0].type orelse return undefined) != *Caller) {
        // Caught at comptime when defineFunc validates; this guard
        // keeps the generated thunk well-formed in any path.
        @compileError("host fn must take *Caller as its first parameter");
    }
    return struct {
        fn t(rt: *_runtime.Runtime, ctx: *anyopaque) anyerror!void {
            const wrapper: *HostFnCtx(Sig) = @ptrCast(@alignCast(ctx));

            // Pop Wasm-typed params in reverse — last pushed is on top.
            // params[0] is *Caller, supplied separately.
            const ArgsT = std.meta.ArgsTuple(Sig);
            var args: ArgsT = undefined;
            comptime var i: comptime_int = fn_info.params.len;
            inline while (i > 1) {
                i -= 1;
                const PT = fn_info.params[i].type.?;
                const v = rt.popOperand();
                args[i] = runtimeToZig(PT, v);
            }
            var caller: Caller = .{ .rt = rt, .host_data = wrapper.host_data };
            args[0] = &caller;

            const ret = @call(.auto, wrapper.user_fn, args);

            const Ret = fn_info.return_type.?;
            if (Ret == void) return;
            switch (@typeInfo(Ret)) {
                .error_union => |eu| {
                    const ok = ret catch |err| return err;
                    try pushResult(rt, eu.payload, ok);
                },
                else => try pushResult(rt, Ret, ret),
            }
        }
    }.t;
}

fn pushResult(rt: *_runtime.Runtime, comptime Ret: type, ret: Ret) !void {
    if (Ret == void) return;
    switch (@typeInfo(Ret)) {
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                try rt.pushOperand(zigToRuntime(f.type, @field(ret, f.name)));
            }
        },
        else => try rt.pushOperand(zigToRuntime(Ret, ret)),
    }
}

fn runtimeToZig(comptime T: type, v: RuntimeValue) T {
    return switch (T) {
        i32 => v.i32,
        u32 => v.u32,
        i64 => v.i64,
        u64 => v.u64,
        f32 => @bitCast(@as(u32, @truncate(v.bits64))),
        f64 => @bitCast(v.bits64),
        else => @compileError("host fn: unsupported param type " ++ @typeName(T)),
    };
}

fn zigToRuntime(comptime T: type, v: T) RuntimeValue {
    return switch (T) {
        i32 => .{ .i32 = v },
        u32 => .{ .u32 = v },
        i64 => .{ .i64 = v },
        u64 => .{ .u64 = v },
        f32 => .{ .bits128 = @as(u128, @bitCast(@as(u32, @bitCast(v)))) },
        f64 => .{ .bits128 = @as(u128, @bitCast(@as(u64, @bitCast(v)))) },
        else => @compileError("host fn: unsupported result type " ++ @typeName(T)),
    };
}

/// Comptime-derived Wasm signature for the user's Zig fn type.
/// Used by the Linker's runtime-side type-match check at
/// `instantiate` time.
pub fn signatureOf(comptime Sig: type) struct { params: []const _zir.ValType, results: []const _zir.ValType } {
    const fn_info = @typeInfo(Sig).@"fn";
    comptime var params_buf: [fn_info.params.len]_zir.ValType = undefined;
    comptime var n_params: usize = 0;
    inline for (fn_info.params, 0..) |p, idx| {
        if (idx == 0) continue; // Skip *Caller.
        const PT = p.type orelse @compileError("host fn: anytype params unsupported");
        params_buf[n_params] = zigTypeToValType(PT);
        n_params += 1;
    }
    const params_final: [n_params]_zir.ValType = params_buf[0..n_params].*;

    const Ret = fn_info.return_type orelse @compileError("host fn: must declare return type (use void)");
    const RetPayload = switch (@typeInfo(Ret)) {
        .error_union => |eu| eu.payload,
        else => Ret,
    };
    const results_final = comptime if (RetPayload == void) blk: {
        const empty: [0]_zir.ValType = .{};
        break :blk empty;
    } else switch (@typeInfo(RetPayload)) {
        .@"struct" => |s| blk: {
            var rs: [s.fields.len]_zir.ValType = undefined;
            for (s.fields, 0..) |f, idx| rs[idx] = zigTypeToValType(f.type);
            break :blk rs;
        },
        else => blk: {
            const r: [1]_zir.ValType = .{zigTypeToValType(RetPayload)};
            break :blk r;
        },
    };

    return .{
        .params = &params_final,
        .results = &results_final,
    };
}

fn zigTypeToValType(comptime T: type) _zir.ValType {
    return switch (T) {
        i32, u32 => .i32,
        i64, u64 => .i64,
        f32 => .f32,
        f64 => .f64,
        else => @compileError("host fn: type not representable in Wasm: " ++ @typeName(T)),
    };
}
