//! `Caller` — host-fn execution context per ADR-0109 §3.2.
//!
//! Passed as the first parameter of every host function registered
//! via `Linker.defineFunc`. Provides access to the *importing*
//! instance's runtime state (linear memory, allocator) so the host
//! fn can read / write through it without smuggling a back-pointer
//! out-of-band.

const std = @import("std");

const _runtime = @import("../runtime/runtime.zig");
const _memory = @import("memory.zig");

pub const Caller = struct {
    rt: *_runtime.Runtime,
    /// Host context registered with the import via `Linker.defineFuncCtx`
    /// (wasmtime's `Caller::data`). Null for `defineFunc`-registered host fns
    /// that need no external state. Recover the typed pointer via `data`.
    host_data: ?*anyopaque = null,

    pub fn memory(self: Caller) ?_memory.Memory {
        if (self.rt.memory.len == 0) return null;
        // Linker host-fn path is interp-only (ADR-0200): wrap the runtime.
        return .{ .backing = .{ .interp = self.rt } };
    }

    pub fn allocator(self: Caller) std.mem.Allocator {
        return self.rt.alloc;
    }

    /// Recover the typed host context registered via `Linker.defineFuncCtx`.
    /// Asserts a ctx was registered (calling this from a `defineFunc` host fn,
    /// which registers none, is a programmer error).
    pub fn data(self: Caller, comptime T: type) *T {
        return @ptrCast(@alignCast(self.host_data.?));
    }
};
