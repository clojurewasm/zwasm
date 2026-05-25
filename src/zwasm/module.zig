//! `Module` — validated Wasm module ready for instantiation per
//! ADR-0109 §3. Holds the native parsed view (`runtime.Module`) plus
//! a transitional c_api handle so the existing `Instance` veneer
//! can still instantiate. J.3 drops the c_api side.

const std = @import("std");
const Allocator = std.mem.Allocator;

const _api_instance = @import("../api/instance.zig");
const _runtime_module = @import("../runtime/module.zig");

const _zwasm = @import("../zwasm.zig");

pub const Module = struct {
    alloc: Allocator,
    // J.2 transition: c_api handle drives `instantiate` until J.3
    // lifts Instance onto the native surface.
    c_store: *_api_instance.Store,
    c_handle: *_api_instance.Module,
    native: _runtime_module.Module,

    pub fn deinit(self: *Module) void {
        _api_instance.wasm_module_delete(self.c_handle);
        self.native.deinit(self.alloc);
    }

    pub const InstantiateOpts = struct {};

    pub const InstantiateError = error{InstantiateFailed};

    pub fn instantiate(self: *Module, _: InstantiateOpts) InstantiateError!_zwasm.Instance {
        const inst = _api_instance.wasm_instance_new(self.c_store, self.c_handle, null, null) orelse return error.InstantiateFailed;
        return .{ .handle = inst, .c_store = self.c_store };
    }

    /// Section count from the native parser. The full
    /// `exports() / imports()` iterators land alongside the
    /// Linker work at J.5 (per ADR-0109 §3.2); J.2 only commits
    /// to the section-presence surface.
    pub fn sectionCount(self: *const Module) usize {
        return self.native.sections.items.len;
    }
};
