//! Component Model **host orchestration** (Zone 3; CM campaign chunk B6).
//!
//! Per ADR-0172 the engine-driving orchestration lives here (Zone 3): it
//! decodes a component (Zone-1 `feature/component/decode`), instantiates the
//! embedded core modules via the public `Engine` facade, and invokes exports.
//! The pure canonical-ABI / WIT logic stays in Zone 1; this file is the only
//! place that touches `invoke`.
//!
//! IT-1 (this chunk): a single embedded core module is instantiated behind a
//! heap-stable `ComponentInstance` handle, and a flat-scalar export is
//! invokable directly with facade `Value`s (no canon trampoline yet). Canon
//! lift/lower + the `cabi_realloc` wiring engage at IT-3 (string→string).

const std = @import("std");

const decode = @import("../feature/component/decode.zig");
const canon = @import("../feature/component/canon.zig");
const ctypes = @import("../feature/component/types.zig");
const runtime_value = @import("../runtime/value.zig");
const value_conv = @import("../zwasm/value_conv.zig");
const zwasm = @import("../zwasm.zig");

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Value = zwasm.Value;
const PrimValType = ctypes.PrimValType;

/// Max flattened core params for the flat (register) call path (`CanonicalABI.md`).
pub const MAX_FLAT_PARAMS = 16;

/// Bridge a lowered core value (`runtime.Value`) to a facade `Value` for the
/// `invoke` path, per the flattened core type.
fn coreToFacade(rv: runtime_value.Value, ct: canon.CoreType) Value {
    return switch (ct) {
        .i32 => .{ .i32 = rv.i32 },
        .i64 => .{ .i64 = rv.i64 },
        .f32 => .{ .f32 = @bitCast(rv.f32) },
        .f64 => .{ .f64 = @bitCast(rv.f64) },
    };
}

pub const Error = error{
    /// The component embeds no core module to instantiate.
    NoCoreModule,
    OutOfMemory,
} || decode.Error || Module.InstantiateError;

/// An instantiated component. IT-1 holds a single embedded core module's
/// instance; multi-module graphs land in C2. The `Module`/`Instance` are
/// heap-allocated for stable addresses (the facade structs hold c-api handles;
/// heap storage keeps the handle owners pinned across the struct's lifetime).
pub const ComponentInstance = struct {
    alloc: Allocator,
    decoded: decode.Component,
    /// Borrowed — the caller owns the `Engine` and must outlive this.
    engine: *Engine,
    module: *Module,
    core: *Instance,

    pub fn deinit(self: *ComponentInstance) void {
        self.core.deinit();
        self.alloc.destroy(self.core);
        self.module.deinit();
        self.alloc.destroy(self.module);
        self.decoded.deinit(self.alloc);
    }

    /// Invoke a core export by name with raw facade `Value`s (flat-scalar
    /// path; canon-typed component invoke arrives at IT-3).
    pub fn invokeCore(self: *ComponentInstance, name: []const u8, args: []const Value, results: []Value) Instance.InvokeError!void {
        return self.core.invoke(name, args, results);
    }

    /// Invoke a component export through the canonical-ABI **flat trampoline**:
    /// lower each component-level `canon.Value` arg to its single core value,
    /// invoke the core export, and lift the (optional) single result back. B6
    /// IT-2 — flat scalars only (no memory / cabi_realloc; that is IT-3). The
    /// param/result types are supplied by the caller (later derived from the
    /// component's own type section).
    pub fn invokeFlat(
        self: *ComponentInstance,
        name: []const u8,
        args: []const canon.Value,
        arg_types: []const PrimValType,
        result_type: ?PrimValType,
        out: *canon.Value,
    ) InvokeFlatError!void {
        std.debug.assert(args.len == arg_types.len);
        if (args.len > MAX_FLAT_PARAMS) return InvokeFlatError.TooManyParams;

        var argbuf: [MAX_FLAT_PARAMS]Value = undefined;
        for (args, arg_types, 0..) |a, ty, i| {
            const ct = canon.flatCoreType(ty) orelse return InvokeFlatError.NotFlatScalar;
            argbuf[i] = coreToFacade(try canon.lower(a), ct);
        }

        var resbuf: [1]Value = .{.{ .i32 = 0 }};
        const results: []Value = if (result_type != null) resbuf[0..1] else resbuf[0..0];
        try self.core.invoke(name, argbuf[0..args.len], results);

        if (result_type) |rt| {
            out.* = try canon.lift(value_conv.zwasmToRuntime(resbuf[0]), rt);
        }
    }
};

pub const InvokeFlatError = error{
    TooManyParams,
    NotFlatScalar,
} || canon.LowerError || canon.LiftError || Instance.InvokeError;

fn firstCoreModule(decoded: *const decode.Component) ?[]const u8 {
    for (decoded.sections.items) |sec| {
        if (sec.id == .core_module) return sec.body;
    }
    return null;
}

/// Decode a component and instantiate its (first) embedded core module via the
/// `Engine` facade. `engine` must outlive the returned `ComponentInstance`.
pub fn instantiate(engine: *Engine, alloc: Allocator, bytes: []const u8) Error!ComponentInstance {
    var decoded = try decode.decode(alloc, bytes);
    errdefer decoded.deinit(alloc);

    const core_bytes = firstCoreModule(&decoded) orelse return Error.NoCoreModule;

    const module = try alloc.create(Module);
    errdefer alloc.destroy(module);
    module.* = engine.compile(core_bytes) catch return Error.InstantiateFailed;
    errdefer module.deinit();

    const core = try alloc.create(Instance);
    errdefer alloc.destroy(core);
    core.* = try module.instantiate(.{});

    return .{ .alloc = alloc, .decoded = decoded, .engine = engine, .module = module, .core = core };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

/// A minimal core module: `(module (func (export "run") (result i32) i32.const 42))`.
const core_run42 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm v1
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> (i32)
    0x03, 0x02, 0x01, 0x00, // func: 1 fn, type 0
    0x07, 0x07, 0x01, 0x03, 'r', 'u', 'n', 0x00, 0x00, // export "run" (func 0)
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42; end
};

/// The above core module embedded in a component (core-module section, id 1).
const component_run42 = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // component preamble
    0x01, core_run42.len, // core-module section: id 1, size 36
} ++ core_run42;

test "IT-1: instantiate embedded core module + invoke a ()->i32 export" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();

    var ci = try instantiate(&eng, testing.allocator, &component_run42);
    defer ci.deinit();

    var results = [_]Value{.{ .i32 = 0 }};
    try ci.invokeCore("run", &.{}, &results);
    try testing.expectEqual(@as(i32, 42), results[0].i32);
}

test "IT-1: a component with no core module is rejected" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    // Empty component (preamble only, no sections).
    const empty = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    try testing.expectError(Error.NoCoreModule, instantiate(&eng, testing.allocator, &empty));
}

/// `(module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))`.
const core_add = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm v1
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32,i32)->(i32)
    0x03, 0x02, 0x01, 0x00, // func: 1 fn, type 0
    0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00, // export "add"
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code: local.get 0/1; i32.add
};
const component_add = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // component preamble
    0x01, core_add.len, // core-module section
} ++ core_add;

test "IT-2: canon flat trampoline — add(u32,u32)->u32 component invoke" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, &component_add);
    defer ci.deinit();

    var out: canon.Value = undefined;
    try ci.invokeFlat("add", &.{ .{ .u32 = 40 }, .{ .u32 = 2 } }, &.{ .u32, .u32 }, .u32, &out);
    try testing.expectEqual(@as(u32, 42), out.u32);
}

test "IT-2: trampoline lifts a signed result through the canon boundary" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, &component_add);
    defer ci.deinit();
    // s32 view of the same add: -1 + -1 = -2 (two's complement through i32 core).
    var out: canon.Value = undefined;
    try ci.invokeFlat("add", &.{ .{ .s32 = -1 }, .{ .s32 = -1 } }, &.{ .s32, .s32 }, .s32, &out);
    try testing.expectEqual(@as(i32, -2), out.s32);
}

test "IT-1: a core module (not a component) is rejected as NotAComponent" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    try testing.expectError(decode.Error.NotAComponent, instantiate(&eng, testing.allocator, &core_run42));
}
