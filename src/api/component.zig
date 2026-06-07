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
const wasi_host = @import("../wasi/host.zig");
const wasi_fd = @import("../wasi/fd.zig");
const wasi_p1 = @import("../wasi/preview1.zig");
const Caller = @import("../zwasm/caller.zig").Caller;

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
} || decode.Error || ctypes.Error || Module.InstantiateError;

/// An instantiated component. IT-1 holds a single embedded core module's
/// instance; multi-module graphs land in C2. The `Module`/`Instance` are
/// heap-allocated for stable addresses (the facade structs hold c-api handles;
/// heap storage keeps the handle owners pinned across the struct's lifetime).
pub const ComponentInstance = struct {
    alloc: Allocator,
    decoded: decode.Component,
    /// Decoded type/canon/alias index spaces — used to resolve a component
    /// export to the core funcs the host invokes (C2-2).
    info: ctypes.TypeInfo,
    /// Borrowed — the caller owns the `Engine` and must outlive this.
    engine: *Engine,
    module: *Module,
    core: *Instance,
    /// The core export name `reallocViaGuest` invokes — set per resolved call
    /// (defaults to the conventional `cabi_realloc`).
    realloc_name: []const u8 = "cabi_realloc",

    pub fn deinit(self: *ComponentInstance) void {
        self.core.deinit();
        self.alloc.destroy(self.core);
        self.module.deinit();
        self.alloc.destroy(self.module);
        self.info.deinit();
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

    /// Build a `canon.CanonContext` over the instance's linear memory + the
    /// guest's `cabi_realloc`. NOTE: the captured `memory` slice is valid only
    /// while the guest does not GROW memory mid-lift/lower; a growing
    /// `cabi_realloc` would dangle it (addressed for the real fixture at IT-3b).
    pub fn canonContext(self: *ComponentInstance) CanonContextError!canon.CanonContext {
        const mem = self.core.memory() orelse return CanonContextError.NoMemory;
        return .{
            .memory = mem.slice(),
            .realloc_ctx = @ptrCast(self),
            .realloc_fn = reallocViaGuest,
        };
    }

    /// Invoke a `func(string) -> string` component export end-to-end through the
    /// canonical ABI (B6 IT-3b-3). `core_func` is the lowered core export; the
    /// string result is too wide to flatten, so the core returns a RETURN-AREA
    /// POINTER to `[out_ptr:i32, out_len:i32]` in guest memory (the canon-lift
    /// convention). `post_return` (if the canon-lift had one) is called for
    /// cleanup. Returns a host-owned copy (allocated from `out_alloc`).
    ///
    /// NOTE (IT-3b shortcut): exports are addressed by their core name; the
    /// general canon-lift→core-func resolution (alias / core-instance decode)
    /// is the follow-up. utf8 string-encoding only.
    pub fn invokeString(
        self: *ComponentInstance,
        core_func: []const u8,
        post_return: ?[]const u8,
        arg: []const u8,
        out_alloc: std.mem.Allocator,
    ) InvokeStringError![]u8 {
        const cx = try self.canonContext();
        const lowered = try canon.lowerString(cx, arg);

        var args = [_]Value{ .{ .i32 = @bitCast(lowered.ptr) }, .{ .i32 = @bitCast(lowered.packed_length) } };
        var results = [_]Value{.{ .i32 = 0 }};
        try self.core.invoke(core_func, &args, &results);
        const ret_ptr: u32 = @bitCast(results[0].i32);

        // Re-fetch memory: a growing cabi_realloc could have moved the backing.
        const cx2 = try self.canonContext();
        const out_ptr = try readU32LE(cx2.memory, ret_ptr);
        const out_len = try readU32LE(cx2.memory, ret_ptr + 4);
        const borrowed = try canon.liftString(cx2, out_ptr, out_len);
        const owned = try out_alloc.dupe(u8, borrowed);
        errdefer out_alloc.free(owned);

        if (post_return) |pr| {
            var pr_args = [_]Value{.{ .i32 = @bitCast(ret_ptr) }};
            try self.core.invoke(pr, &pr_args, &.{});
        }
        return owned;
    }

    /// Invoke a `func(string) -> string` component export BY ITS COMPONENT NAME
    /// (C2-2, discharges D-304). Resolves the export → its `canon lift` → the
    /// real core funcs (lowered func / realloc / post-return) via the decoded
    /// alias + canon index spaces, then runs `invokeString` — no hard-coded core
    /// names. utf8 string-encoding only.
    pub fn invokeStringExport(self: *ComponentInstance, export_name: []const u8, arg: []const u8, out_alloc: std.mem.Allocator) InvokeStringError![]u8 {
        const r = self.info.resolveLiftedFunc(export_name) orelse return InvokeStringError.ExportNotResolved;
        if (r.string_encoding != .utf8) return InvokeStringError.UnsupportedEncoding;
        if (r.realloc) |rr| self.realloc_name = rr.name;
        const post: ?[]const u8 = if (r.post_return) |p| p.name else null;
        return self.invokeString(r.core_func.name, post, arg, out_alloc);
    }
};

pub const InvokeStringError = error{
    OutOfBounds,
    OutOfMemory,
    /// The component export name didn't resolve to a `canon lift` over a core
    /// export (unknown export, or an unresolvable alias form).
    ExportNotResolved,
} || canon.StringError || Instance.InvokeError || CanonContextError;

/// Read a little-endian u32 from a guest-memory slice (bounds-checked).
fn readU32LE(mem: []const u8, off: u32) error{OutOfBounds}!u32 {
    if (@as(usize, off) + 4 > mem.len) return error.OutOfBounds;
    return std.mem.readInt(u32, mem[off..][0..4], .little);
}

pub const InvokeFlatError = error{
    TooManyParams,
    NotFlatScalar,
} || canon.LowerError || canon.LiftError || Instance.InvokeError;

/// The `cabi_realloc` callback (ADR-0171) that runs the guest's own
/// `cabi_realloc` export — so canon lift/lower allocate in the guest's
/// allocator (spec-conformant). `ctx` is the `*ComponentInstance`.
fn reallocViaGuest(ctx: *anyopaque, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) canon.ReallocError!u32 {
    const self: *ComponentInstance = @ptrCast(@alignCast(ctx));
    var args = [_]Value{
        .{ .i32 = @bitCast(old_ptr) },
        .{ .i32 = @bitCast(old_size) },
        .{ .i32 = @bitCast(alignment) },
        .{ .i32 = @bitCast(new_size) },
    };
    var results = [_]Value{.{ .i32 = 0 }};
    self.core.invoke(self.realloc_name, &args, &results) catch return canon.ReallocError.AllocFailed;
    const ptr: u32 = @bitCast(results[0].i32);
    if (ptr == 0 and new_size != 0) return canon.ReallocError.AllocFailed; // null = OOM
    return ptr;
}

pub const CanonContextError = error{NoMemory};

fn firstCoreModule(decoded: *const decode.Component) ?[]const u8 {
    for (decoded.sections.items) |sec| {
        if (sec.id == .core_module) return sec.body;
    }
    return null;
}

fn nthChildComponent(decoded: *const decode.Component, n: u32) ?[]const u8 {
    var i: u32 = 0;
    for (decoded.sections.items) |sec| {
        if (sec.id != .component) continue;
        if (i == n) return sec.body;
        i += 1;
    }
    return null;
}

const Linker = @import("../zwasm/linker.zig").Linker;

/// A linked **multi-component graph** (C2-3b-2). Evaluates the `instance`
/// section in order: each child component's core module is instantiated, its
/// core imports satisfied from earlier instances' func exports via the facade
/// Linker (cross-module). Everything is heap-allocated for stable addresses
/// (instances reference each other; a Linker must outlive its instance).
///
/// SCOPE: leaf children (a child = one embedded core module) + flat func
/// imports matched BY NAME to a prior instance's export (sufficient for the
/// canon-lowered flat-u32 cross-component call). General `with`-arg resolution
/// through each child's canon-lower/instance structure + lifted aggregate args
/// are the follow-up.
pub const ComponentGraph = struct {
    alloc: Allocator,
    outer: decode.Component,
    info: ctypes.TypeInfo,
    children: std.ArrayList(*decode.Component),
    modules: std.ArrayList(*Module),
    linkers: std.ArrayList(*Linker),
    instances: std.ArrayList(*Instance),

    pub fn deinit(self: *ComponentGraph) void {
        for (self.instances.items) |inst| {
            inst.deinit();
            self.alloc.destroy(inst);
        }
        for (self.linkers.items) |lk| {
            lk.deinit();
            self.alloc.destroy(lk);
        }
        for (self.modules.items) |m| {
            m.deinit();
            self.alloc.destroy(m);
        }
        for (self.children.items) |c| {
            c.deinit(self.alloc);
            self.alloc.destroy(c);
        }
        self.instances.deinit(self.alloc);
        self.linkers.deinit(self.alloc);
        self.modules.deinit(self.alloc);
        self.children.deinit(self.alloc);
        self.info.deinit();
        self.outer.deinit(self.alloc);
    }

    /// Invoke a flat-scalar export by name on whichever child instance exports
    /// it (the outer re-export resolves to that instance's core func).
    pub fn invokeFlat(self: *ComponentGraph, name: []const u8, args: []const Value, results: []Value) !void {
        for (self.instances.items) |inst| {
            if (inst.exportFuncSig(name) != null) return inst.invoke(name, args, results);
        }
        return error.ExportNotResolved;
    }
};

/// Instantiate + link a multi-component graph (see `ComponentGraph`).
pub fn instantiateGraph(engine: *Engine, alloc: Allocator, bytes: []const u8) anyerror!ComponentGraph {
    var graph = ComponentGraph{
        .alloc = alloc,
        .outer = try decode.decode(alloc, bytes),
        .info = undefined,
        .children = .empty,
        .modules = .empty,
        .linkers = .empty,
        .instances = .empty,
    };
    errdefer graph.deinit();
    graph.info = try ctypes.decodeTypeInfo(alloc, &graph.outer);

    for (graph.info.component_instances.items) |ci| {
        const child_idx = switch (ci) {
            .instantiate => |it| it.component,
            .inline_exports => continue, // synthetic re-export instance — nothing to instantiate
        };
        const child_bytes = nthChildComponent(&graph.outer, child_idx) orelse return error.NoCoreModule;

        const child = try alloc.create(decode.Component);
        child.* = try decode.decode(alloc, child_bytes);
        try graph.children.append(alloc, child);

        const core_bytes = firstCoreModule(child) orelse return error.NoCoreModule;
        const module = try alloc.create(Module);
        module.* = try engine.compile(core_bytes);
        try graph.modules.append(alloc, module);

        var mod_imports = try module.imports(alloc);
        defer mod_imports.deinit();

        const inst = try alloc.create(Instance);
        if (mod_imports.items.len == 0) {
            inst.* = try module.instantiate(.{});
        } else {
            const lk = try alloc.create(Linker);
            lk.* = engine.linker();
            try graph.linkers.append(alloc, lk);
            for (mod_imports.items) |imp| {
                const src = for (graph.instances.items) |prev| {
                    if (prev.exportFuncSig(imp.name) != null) break prev;
                } else return error.ImportUnsatisfied;
                try lk.defineCrossModuleFunc(imp.module, imp.name, src, imp.name);
            }
            inst.* = try lk.instantiate(module);
        }
        try graph.instances.append(alloc, inst);
    }
    return graph;
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

    var info = try ctypes.decodeTypeInfo(alloc, &decoded);
    errdefer info.deinit();

    return .{ .alloc = alloc, .decoded = decoded, .info = info, .engine = engine, .module = module, .core = core };
}

// WASI Preview 2 host trampolines + the single-component runner live in a
// sibling module (D-309 extraction — `component.zig` crossed the file-size
// smell cap as the P2 surface grew). Re-exported here so the public `run` path
// (`cli/run.zig` → `component.runWasiP2Main`) and the in-tree e2e/unit tests
// keep the same surface.
const cwasi = @import("component_wasi_p2.zig");
pub const runWasiP2Main = cwasi.runWasiP2Main;
const WasiP2Ctx = cwasi.WasiP2Ctx;
const WasiP2Error = cwasi.WasiP2Error;
const p2GetStdout = cwasi.p2GetStdout;
const p2OutStreamWrite = cwasi.p2OutStreamWrite;
const p2OutStreamDrop = cwasi.p2OutStreamDrop;
const p2DescriptorWrite = cwasi.p2DescriptorWrite;
const p2DescriptorDrop = cwasi.p2DescriptorDrop;
const p2DescriptorOpenAt = cwasi.p2DescriptorOpenAt;
const p2GetDirectories = cwasi.p2GetDirectories;

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

test "E2 prereq: core-table index space resolves an alias-core-export table (ADR-0175)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/core_table_alias.wasm", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);

    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);
    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();

    // The general instantiation engine resolves a synthetic instance's table
    // re-export through this space (the shim `$imports` table — ADR-0175).
    try testing.expectEqual(@as(usize, 1), info.core_tables.items.len);
    const ref = info.resolveCoreTableExport(0).?;
    try testing.expectEqual(@as(u32, 0), ref.instance);
    try testing.expectEqualStrings("tbl", ref.name);
}

fn testHostInc(_: *Caller, x: u32) anyerror!u32 {
    return x + 1;
}

test "D-310: a guest call_indirects an imported host func through a table" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/edge_cases/p17/host_func_table/call_indirect_host.wasm", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(bytes);
    defer mod.deinit();
    var lk = eng.linker();
    defer lk.deinit();
    // The host func is placed in the module's table via an active elem segment;
    // run(x) reaches it by call_indirect — exercises the per-import placeholder
    // sig + the call_indirect host-dispatch (D-310 runtime fix).
    try lk.defineFunc("env", "inc", fn (*Caller, u32) anyerror!u32, testHostInc);
    var inst = try lk.instantiate(&mod);
    defer inst.deinit();

    var res = [_]Value{.{ .i32 = 0 }};
    try inst.invoke("run", &.{.{ .i32 = 41 }}, &res);
    try testing.expectEqual(@as(i32, 42), res[0].i32);
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

/// A core module with a 1-page memory + a bump-allocator `cabi_realloc` (it
/// ignores `old`/`old_size`/`align` — sufficient for the align-1 string test —
/// and never grows memory, keeping a captured memory slice valid):
/// ```wat
/// (module
///   (memory (export "memory") 1)
///   (global $next (mut i32) (i32.const 16))
///   (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (local $ret i32)
///     global.get $next  local.set $ret
///     global.get $next  local.get 3  i32.add  global.set $next
///     local.get $ret))
/// ```
const core_realloc = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm v1
    0x01, 0x09, 0x01, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f, // type (i32×4)->i32
    0x03, 0x02, 0x01, 0x00, // func: type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory: min 1 page
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x10, 0x0b, // global $next (mut i32) = 16
    0x07, 0x19, 0x02, // export section: 2 exports
    0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00, // "memory" → mem 0
    0x0c, 'c', 'a', 'b', 'i', '_', 'r', 'e', 'a', 'l', 'l', 'o', 'c', 0x00, 0x00, // "cabi_realloc" → func 0
    0x0a, 0x13, 0x01, 0x11, 0x01, 0x01, 0x7f, // code: 1 func, body size 17, 1 i32 local
    0x23, 0x00, 0x21, 0x04, // global.get 0; local.set 4 ($ret)
    0x23, 0x00, 0x20, 0x03, 0x6a, 0x24, 0x00, // global.get 0; local.get 3; i32.add; global.set 0
    0x20, 0x04, 0x0b, // local.get 4; end
};
const component_realloc = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, // component preamble
    0x01, core_realloc.len, // core-module section
} ++ core_realloc;

test "IT-3a: cabi_realloc-via-guest — string lower/lift over real guest memory" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, &component_realloc);
    defer ci.deinit();

    const cx = try ci.canonContext();
    // Lower a host string THROUGH the guest's own cabi_realloc allocator...
    const lowered = try canon.lowerString(cx, "héllo, 世界");
    try testing.expect(lowered.ptr >= 16); // past the bump start
    // ...and lift it back out of the guest linear memory.
    const back = try canon.liftString(cx, lowered.ptr, lowered.packed_length);
    try testing.expectEqualStrings("héllo, 世界", back);
}

test "IT-3a: two allocations via the guest allocator don't overlap" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, &component_realloc);
    defer ci.deinit();

    const cx = try ci.canonContext();
    const a = try canon.lowerString(cx, "first");
    const b = try canon.lowerString(cx, "second");
    try testing.expect(b.ptr >= a.ptr + a.packed_length); // bump advanced
    try testing.expectEqualStrings("first", try canon.liftString(cx, a.ptr, a.packed_length));
    try testing.expectEqualStrings("second", try canon.liftString(cx, b.ptr, b.packed_length));
}

/// Provenance of the REAL string→string component fixture (`greet(name: string)
/// -> string` ⇒ `"Hello, " ++ name ++ "!"`, built with wasm-tools). Sources at
/// `test/component/` (kept OUT of `test/edge_cases/` so the edge-case runner —
/// which runs every `.wasm` there as a core module — doesn't try to run a
/// component). Read at runtime (it lives outside the `src/`
/// package, so `@embedFile` can't reach it); `zig build test` runs from the repo
/// root so the cwd-relative path resolves.
const greet_component_path = "test/component/greet_component.wasm";

/// A real 2-component graph (wasm-tools): component B exports `adder(u32,u32)->
/// u32`; component A imports it + exports `add-five(x)=adder(x,5)`; the outer
/// instantiates B, instantiates A `with "adder"=B.adder`, re-exports add-five.
const adder_graph_path = "test/component/adder_graph.wasm";

test "C2-3b-1: a real 2-component graph decodes (nested components + instances + wiring)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, adder_graph_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);

    // The outer embeds 2 nested child components (§4).
    var children: usize = 0;
    for (comp.sections.items) |sec| {
        if (sec.id == .component) children += 1;
    }
    try testing.expectEqual(@as(usize, 2), children);

    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();

    // Two component-instances: instantiate child 0 (B) and child 1 (A) with a
    // `with` arg satisfying A's import.
    try testing.expectEqual(@as(usize, 2), info.component_instances.items.len);
    try testing.expectEqual(@as(u32, 0), info.component_instances.items[0].instantiate.component);
    try testing.expectEqual(@as(u32, 1), info.component_instances.items[1].instantiate.component);
    try testing.expect(info.component_instances.items[1].instantiate.args.len >= 1);

    // The outer re-exports add-five.
    var found = false;
    for (info.exports.items) |e| {
        if (std.mem.eql(u8, e.name, "add-five")) found = true;
    }
    try testing.expect(found);

    // Recursively decode child component B → it canon-lifts its `adder` export.
    const b_bytes = for (comp.sections.items) |sec| {
        if (sec.id == .component) break sec.body;
    } else unreachable;
    try testing.expectEqual(decode.Kind.component, try decode.classify(b_bytes));
    var b = try decode.decode(testing.allocator, b_bytes);
    defer b.deinit(testing.allocator);
    var b_info = try ctypes.decodeTypeInfo(testing.allocator, &b);
    defer b_info.deinit();
    var b_lift = false;
    for (b_info.canons.items) |c| {
        if (c == .lift) b_lift = true;
    }
    try testing.expect(b_lift);
}

/// A real WASI Preview 2 "hello world" component (hand-authored + wasm-tools):
/// imports `wasi:cli/stdout` + `wasi:io/streams` (+ `wasi:io/error`), exports
/// `wasi:cli/run`'s `run`, prints "hello" (verified via wasmtime). Source +
/// provenance: `test/component/wasi_p2_hello.{wat,go}` + README.
const wasi_p2_hello_path = "test/component/wasi_p2_hello.wasm";

test "D1-2: WASI-P2 hello-world component decodes structurally (imports wasi:cli/io)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasi_p2_hello_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    try testing.expectEqual(decode.Kind.component, try decode.classify(bytes));
    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);

    var has_import = false;
    var has_core_module = false;
    var has_canon = false;
    for (comp.sections.items) |sec| {
        switch (sec.id) {
            .import => has_import = true,
            .core_module => has_core_module = true,
            .canon => has_canon = true,
            else => {},
        }
    }
    try testing.expect(has_import and has_core_module and has_canon);

    // It imports the WASI P2 CLI-print interfaces (the adapter D1-1 name-maps).
    try testing.expect(std.mem.find(u8, bytes, "wasi:cli/stdout") != null);
    try testing.expect(std.mem.find(u8, bytes, "wasi:io/streams") != null);

    // Full type-info decode now succeeds (instance-type decode landed): the
    // component imports the 3 wasi instances + has a canon section.
    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 3), info.imports.items.len);
    var has_stdout = false;
    for (info.imports.items) |imp| {
        if (std.mem.find(u8, imp.name, "wasi:cli/stdout") != null) has_stdout = true;
        try testing.expect(imp.desc == .instance); // each wasi import is an instance
    }
    try testing.expect(has_stdout);
    try testing.expect(info.canons.items.len > 0);

    // The core-func index space interleaves the canon lowers (host-implemented
    // wasi imports) + the resource.drop builtin + the core-export alias for the
    // lowered `run`, in definition order — the unified model the host run path
    // resolves against (an alias-only count would mis-index slot 3).
    try testing.expectEqual(@as(usize, 4), info.core_funcs.items.len);
    try testing.expect(info.core_funcs.items[0] == .lower); // get-stdout
    try testing.expect(info.core_funcs.items[1] == .lower); // blocking-write-and-flush
    try testing.expect(info.core_funcs.items[2] == .resource_drop); // output-stream drop
    try testing.expect(info.core_funcs.items[3] == .alias); // $m "run"
    const run_ref = info.resolveCoreFuncExport(3).?;
    try testing.expectEqualStrings("run", run_ref.name);
    try testing.expectEqual(@as(u32, 2), run_ref.instance); // core-instance $m
}

test "C2-3b-2 (EXIT): a 2-component graph links + runs (A calls B across components)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, adder_graph_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes);
    defer graph.deinit();

    // add-five(10) = adder(10, 5) = 15 — the call crosses from component A into B.
    var results = [_]Value{.{ .i32 = 0 }};
    try graph.invokeFlat("add-five", &.{.{ .i32 = 10 }}, &results);
    try testing.expectEqual(@as(i32, 15), results[0].i32);
}

test "IT-3b-2: a real wasm-tools string→string component decodes through the pipeline" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const greet_component = try std.Io.Dir.cwd().readFileAlloc(io, greet_component_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(greet_component);

    try testing.expectEqual(decode.Kind.component, try decode.classify(greet_component));

    var comp = try decode.decode(testing.allocator, greet_component);
    defer comp.deinit(testing.allocator);

    var has_core_module = false;
    var has_canon = false;
    for (comp.sections.items) |sec| {
        if (sec.id == .core_module) has_core_module = true;
        if (sec.id == .canon) has_canon = true;
    }
    try testing.expect(has_core_module and has_canon);

    var info = try ctypes.decodeTypeInfo(testing.allocator, &comp);
    defer info.deinit();

    // The component-level func type: greet(name: string) -> string.
    const ft = info.deftypes.items[0].func;
    try testing.expectEqual(PrimValType.string, ft.params[0].ty.primitive);
    try testing.expectEqual(PrimValType.string, ft.result.?.primitive);

    // The canon section lifts greet with utf8 + memory + realloc + post-return.
    var found_lift = false;
    for (info.canons.items) |c| {
        if (c == .lift) {
            found_lift = true;
            try testing.expectEqual(ctypes.StringEncoding.utf8, c.lift.opts.string_encoding);
            try testing.expect(c.lift.opts.memory != null);
            try testing.expect(c.lift.opts.realloc != null);
            try testing.expect(c.lift.opts.post_return != null);
        }
    }
    try testing.expect(found_lift);

    // A top-level export named "greet".
    var found_export = false;
    for (info.exports.items) |e| {
        if (std.mem.eql(u8, e.name, "greet")) found_export = true;
    }
    try testing.expect(found_export);
}

test "IT-3b-3 (EXIT): a real string→string component runs end-to-end" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, greet_component_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, bytes);
    defer ci.deinit();

    // greet("zwasm") ⇒ "Hello, zwasm!" — a real component runs via zwasm.
    const result = try ci.invokeString("greet", "cabi_post_greet", "zwasm", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello, zwasm!", result);

    // A second call (fresh allocations through the guest) still works.
    const result2 = try ci.invokeString("greet", "cabi_post_greet", "世界", testing.allocator);
    defer testing.allocator.free(result2);
    try testing.expectEqualStrings("Hello, 世界!", result2);
}

test "C2-2 (D-304): resolve the component export → core funcs (no hard-coded names)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, greet_component_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var ci = try instantiate(&eng, testing.allocator, bytes);
    defer ci.deinit();

    // The resolver maps the component func type + canon-lift to the core exports.
    const r = ci.info.resolveLiftedFunc("greet").?;
    try testing.expectEqualStrings("greet", r.core_func.name);
    try testing.expectEqualStrings("cabi_realloc", r.realloc.?.name);
    try testing.expectEqualStrings("cabi_post_greet", r.post_return.?.name);
    try testing.expectEqual(ctypes.StringEncoding.utf8, r.string_encoding);

    // Invoke BY THE COMPONENT EXPORT NAME — the host resolves the core funcs.
    const result = try ci.invokeStringExport("greet", "zwasm", testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello, zwasm!", result);
}

/// A `$M`-shaped core module (the print core of `wasi_p2_hello.wat`): imports
/// `io.{get-stdout,write,drop-os}` + owns a 1-page memory with `"hello\n"` at
/// offset 16, and exports `run` which calls get-stdout, writes 6 bytes via
/// write(self, 16, 6, 128), drops the stream, returns 0. (In the real fixture
/// memory is imported from `$libc`; here it is module-owned to isolate the
/// trampoline wiring from the cross-instance-memory wiring — that is the next
/// chunk.) Assembled via wasm-tools (name section stripped).
const p2_print_core = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03, 0x60,
    0x00, 0x01, 0x7f, 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00, 0x60, 0x01,
    0x7f, 0x00, 0x02, 0x29, 0x03, 0x02, 0x69, 0x6f, 0x0a, 0x67, 0x65, 0x74,
    0x2d, 0x73, 0x74, 0x64, 0x6f, 0x75, 0x74, 0x00, 0x00, 0x02, 0x69, 0x6f,
    0x05, 0x77, 0x72, 0x69, 0x74, 0x65, 0x00, 0x01, 0x02, 0x69, 0x6f, 0x07,
    0x64, 0x72, 0x6f, 0x70, 0x2d, 0x6f, 0x73, 0x00, 0x02, 0x03, 0x02, 0x01,
    0x00, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x10, 0x02, 0x06, 0x6d, 0x65,
    0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x03, 0x72, 0x75, 0x6e, 0x00, 0x03,
    0x0a, 0x1b, 0x01, 0x19, 0x01, 0x01, 0x7f, 0x10, 0x00, 0x21, 0x00, 0x20,
    0x00, 0x41, 0x10, 0x41, 0x06, 0x41, 0x80, 0x01, 0x10, 0x01, 0x20, 0x00,
    0x10, 0x02, 0x41, 0x00, 0x0b, 0x0b, 0x0c, 0x01, 0x00, 0x41, 0x10, 0x0b,
    0x06, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a,
};

test "D1-2 trampolines: WASI-P2 output-stream funcs print to a captured fd" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&p2_print_core);
    defer mod.deinit();

    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    // Bind the trampolines directly by name — this test exercises the trampoline
    // logic in isolation (no component decode → no classifier path).
    try lk.defineFuncCtx("io", "get-stdout", &ctx, fn (*Caller) WasiP2Error!u32, p2GetStdout);
    try lk.defineFuncCtx("io", "write", &ctx, fn (*Caller, u32, u32, u32, u32) WasiP2Error!void, p2OutStreamWrite);
    try lk.defineFuncCtx("io", "drop-os", &ctx, fn (*Caller, u32) WasiP2Error!void, p2OutStreamDrop);

    var inst = try lk.instantiate(&mod);
    defer inst.deinit();

    var results = [_]Value{.{ .i32 = 1 }};
    try inst.invoke("run", &.{}, &results);
    try testing.expectEqual(@as(i32, 0), results[0].i32); // run returns ok (0)
    try testing.expectEqualStrings("hello\n", capture.items); // trampoline wrote via fd 1
}

test "D1-2 (EXIT): a real WASI-P2 hello-world component runs + prints via the adapter" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasi_p2_hello_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();

    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // greet/adder proved component invoke; this proves a real P2 CLI program
    // runs through the canon-lowered wasi imports → the P2 trampolines.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
    try testing.expectEqualStrings("hello\n", capture.items);
}

test "D2: a WASI-P2 component prints to STDERR via get-stderr (fd 2 stream)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_stderr.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var cap_err: std.ArrayList(u8) = .empty;
    defer cap_err.deinit(testing.allocator);
    var cap_out: std.ArrayList(u8) = .empty;
    defer cap_out.deinit(testing.allocator);
    host.stderr_buffer = &cap_err;
    host.stdout_buffer = &cap_out;

    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
    try testing.expectEqualStrings("oops\n", cap_err.items); // wrote to fd 2
    try testing.expectEqualStrings("", cap_out.items); // NOT stdout
}

test "D3: a WASI-P2 component calls wasi:cli/exit(err) → host exit code 1" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_exit.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // The component's `run` calls wasi:cli/exit.exit(err) — the cli_exit trampoline
    // records the code via P1 proc_exit and unwinds (noreturn); runWasiP2Main treats
    // a set exit_code as a clean termination.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
    try testing.expectEqual(@as(u32, 1), host.exit_code.?);
}

test "D3: a WASI-P2 component reads monotonic-clock.now() — sane + monotonic → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_clock.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // run() reads now() twice; exit(0) iff first>0 and second>=first (the
    // clocks_monotonic_now trampoline forwards to the host monotonic clock).
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "D3: a WASI-P2 component reads wall-clock.now() — realtime past 2017 → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_wallclock.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // run() reads wall-clock.now() into a 12-byte datetime record at retptr and
    // exit(0) iff seconds>1.5e9 (the clocks_wall_now trampoline writes seconds@0,
    // nanoseconds@8 to guest memory; realtime clock id 0).
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "D3: a WASI-P2 component calls random.get-random-bytes(16) — list realloc → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_random.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // run() calls get-random-bytes(16) — the trampoline allocates 16 bytes via the
    // guest cabi_realloc, fills with secure random, returns (ptr,len); run ORs the
    // bytes and exit(0) iff len==16 and some byte is nonzero.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "D3: a WASI-P2 component reads stdin via get-stdin+input-stream.read — echo check → exit 0" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_stdin.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    host.stdin_bytes = "zwasm";

    // run() mints an input-stream (get-stdin), read(16) returns ok(list) with the
    // 5 fed bytes via cabi_realloc; run checks len==5 + 'z'../'m' → exit 0.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
    try testing.expectEqual(@as(u32, 0), host.exit_code.?);
}

test "D2 (EXIT): a WASI-P2 fs component writes a file via get-directories+open-at+write e2e" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_fs.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    const dirfd = try host.addPreopen(tmp.dir.handle, "/sandbox");

    // Drives get-directories (realloc list area) → open-at "out.txt" → write "DATA42" → drop, all
    // through the classified fs trampolines + the guest's cabi_realloc (nested invoke).
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);

    // Read the written file back through the still-open preopen dir.
    var pmem: [128]u8 = @splat(0);
    @memcpy(pmem[0..7], "out.txt");
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.pathOpen(&host, &pmem, dirfd, 0, 0, 7, 0, wasi_p1.RIGHTS_FD_READ, 0, 0, 96));
    const rfd = std.mem.readInt(u32, pmem[96..100], .little);
    std.mem.writeInt(u32, pmem[16..20], 32, .little);
    std.mem.writeInt(u32, pmem[20..24], 6, .little);
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.fdPread(&host, &pmem, rfd, 16, 1, 0, 64));
    try testing.expectEqualStrings("DATA42", pmem[32..38]);
}

test "D3-6: a WASI-P2 fs component drives sync/stat/get-type/read + stdout flush e2e" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_fs_full.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    _ = try host.addPreopen(tmp.dir.handle, "/sandbox");

    // The guest asserts every descriptor result (sync ok, stat size==6 +
    // regular-file, get-type regular-file, read "DATA42"+eof, flush ok) and
    // traps (unreachable) on any mismatch — a clean return proves all five
    // D3-6 trampolines returned correct data.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
}

test "D-307: a failing descriptor.open-at returns result.err(no-entry), not a trap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_fs_err.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    _ = try host.addPreopen(tmp.dir.handle, "/sandbox");

    // open-at "nope.txt" without the create flag → P1 noent → the trampoline
    // writes result.err(error-code::no-entry); the guest asserts disc==err +
    // code==20 and traps on mismatch, so a clean return proves the D-307 map.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
}

test "D3-7: a WASI-P2 component drives wasi:io/poll (subscribe + poll + ready/block)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_poll.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    host.stdin_bytes = "x";

    // subscribe-duration + input-stream.subscribe mint pollables; poll([p1,p2])
    // reports both ready (indices 0,1); ready()==true, block()==noop. The guest
    // asserts each + traps on mismatch — a clean return proves the poll path.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
}

test "E2: WASI-P2 cli/environment + terminal + check-write (sandboxed non-tty host)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_cli_env.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;

    // get-environment/get-arguments empty, initial-cwd + get-terminal-stdout none,
    // check-write reports a permit. The guest asserts each + traps on mismatch.
    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
}

test "D2: WASI-P2 get-directories returns a preopen descriptor list (realloc from trampoline)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    const dirfd = try host.addPreopen(tmp.dir.handle, "/sandbox");

    const core_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/get_directories_core.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(core_bytes);
    var mod = try eng.compile(core_bytes);
    defer mod.deinit();

    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineFuncCtx("fs", "get-directories", &ctx, fn (*Caller, u32) WasiP2Error!void, p2GetDirectories);

    var inst = try lk.instantiate(&mod);
    defer inst.deinit();
    ctx.realloc_instance = &inst; // allocate the return area via the guest's cabi_realloc (nested invoke)

    var res = [_]Value{.{ .i32 = 0 }};
    try inst.invoke("run", &.{}, &res);
    try testing.expectEqual(@as(i32, 1008), res[0].i32); // list_len=1 ×1000 + str_len=8

    // The minted descriptor handle (tuple[0]) resolves to the preopen dir fd; the path string round-trips.
    const mem = inst.memory().?;
    const list_ptr = try mem.read(u32, 16);
    const handle = try mem.read(u32, list_ptr);
    const str_ptr = try mem.read(u32, list_ptr + 4);
    try testing.expectEqual(dirfd, @as(wasi_p1.Fd, @intCast(try ctx.resources.rep(WasiP2Ctx.DESCRIPTOR_RT, handle))));
    try testing.expectEqualStrings("/sandbox", try mem.sliceAt(str_ptr, 8));
}

test "D2: WASI-P2 descriptor.open-at creates+writes a file under a dir descriptor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    const dirfd = try host.addPreopen(tmp.dir.handle, "/sandbox");

    const core_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/open_at_write_core.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(core_bytes);
    var mod = try eng.compile(core_bytes);
    defer mod.deinit();

    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    const dir_handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, dirfd);

    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineFuncCtx("fs", "open-at", &ctx, fn (*Caller, u32, u32, u32, u32, u32, u32, u32) WasiP2Error!void, p2DescriptorOpenAt);
    try lk.defineFuncCtx("fs", "write", &ctx, fn (*Caller, u32, u32, u32, u64, u32) WasiP2Error!void, p2DescriptorWrite);
    try lk.defineFuncCtx("fs", "drop", &ctx, fn (*Caller, u32) WasiP2Error!void, p2DescriptorDrop);

    var inst = try lk.instantiate(&mod);
    defer inst.deinit();
    var res = [_]Value{.{ .i32 = 9 }};
    try inst.invoke("run", &.{.{ .i32 = @bitCast(dir_handle) }}, &res);
    try testing.expectEqual(@as(i32, 0), res[0].i32); // open-at ok

    // Re-open "f.txt" (the file descriptor was dropped) and read it back.
    var pmem: [128]u8 = @splat(0);
    @memcpy(pmem[0..5], "f.txt");
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.pathOpen(&host, &pmem, dirfd, 0, 0, 5, 0, wasi_p1.RIGHTS_FD_READ, 0, 0, 96));
    const rfd = std.mem.readInt(u32, pmem[96..100], .little);
    std.mem.writeInt(u32, pmem[16..20], 32, .little);
    std.mem.writeInt(u32, pmem[20..24], 6, .little);
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.fdPread(&host, &pmem, rfd, 16, 1, 0, 64));
    try testing.expectEqualStrings("DATA42", pmem[32..38]);
}

test "D2: WASI-P2 descriptor.write writes a file via the descriptor resource (fd from handle)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io;
    const dirfd = try host.addPreopen(tmp.dir.handle, "/sandbox");

    // Create "out.txt" in the preopen + mint a descriptor resource bound to its fd.
    var pmem: [128]u8 = @splat(0);
    @memcpy(pmem[0..8], "out.txt\x00");
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.pathOpen(&host, &pmem, dirfd, 0, 0, 7, wasi_p1.OFLAGS_CREAT, wasi_p1.RIGHTS_FD_WRITE | wasi_p1.RIGHTS_FD_READ, 0, 0, 96));
    const wfd = std.mem.readInt(u32, pmem[96..100], .little);

    var ctx = try WasiP2Ctx.init(testing.allocator, &host);
    defer ctx.deinit();
    const handle = try ctx.resources.new(WasiP2Ctx.DESCRIPTOR_RT, wfd);

    const core_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/descriptor_write_core.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(core_bytes);
    var mod = try eng.compile(core_bytes);
    defer mod.deinit();

    var lk = eng.linker();
    defer lk.deinit();
    try lk.defineFuncCtx("fs", "write", &ctx, fn (*Caller, u32, u32, u32, u64, u32) WasiP2Error!void, p2DescriptorWrite);
    try lk.defineFuncCtx("fs", "drop", &ctx, fn (*Caller, u32) WasiP2Error!void, p2DescriptorDrop);

    var inst = try lk.instantiate(&mod);
    defer inst.deinit();
    var noret = [_]Value{};
    try inst.invoke("run", &.{.{ .i32 = @bitCast(handle) }}, &noret); // write + drop

    // Re-open the file (the descriptor was dropped → its fd closed) and read it back.
    @memset(pmem[0..128], 0);
    @memcpy(pmem[0..8], "out.txt\x00");
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.pathOpen(&host, &pmem, dirfd, 0, 0, 7, 0, wasi_p1.RIGHTS_FD_READ, 0, 0, 96));
    const rfd = std.mem.readInt(u32, pmem[96..100], .little);
    std.mem.writeInt(u32, pmem[16..20], 32, .little); // iovec: buf=32, len=8
    std.mem.writeInt(u32, pmem[20..24], 8, .little);
    try testing.expectEqual(wasi_p1.Errno.success, wasi_fd.fdPread(&host, &pmem, rfd, 16, 1, 0, 64));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, pmem[64..68], .little));
    try testing.expectEqualStrings("HELLO-FS", pmem[32..40]);
}

test "D-306 (EXIT): a component with renamed core imports runs via classified wiring" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Core imports are opaque p0/p1/p2 (NOT get-stdout/write/drop-os); only the
    // COMPONENT interfaces match. Printing "hello" proves the host selected each
    // trampoline by interface, not by the core import name.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasi_p2_hello_renamed.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    try runWasiP2Main(&eng, testing.allocator, bytes, &host);
    try testing.expectEqualStrings("hello\n", capture.items);
}

test "D2/D-306: a lowered func resolves back to its WASI component interface + func" {
    const io = testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, wasi_p2_hello_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);
    var decoded = try decode.decode(testing.allocator, bytes);
    defer decoded.deinit(testing.allocator);
    var info = try ctypes.decodeTypeInfo(testing.allocator, &decoded);
    defer info.deinit();

    // canon lower[0] lowers component func 0 (a func alias of imported instance
    // `wasi:cli/stdout`'s `get-stdout` export); the @version suffix is stripped
    // so it matches the WASI adapter's interface table.
    const r0 = info.resolveComponentImport(0).?;
    try testing.expectEqualStrings("wasi:cli/stdout", r0.interface);
    try testing.expectEqualStrings("get-stdout", r0.func);
    // lower[1] → component func 1 → `wasi:io/streams` blocking-write-and-flush.
    const r1 = info.resolveComponentImport(1).?;
    try testing.expectEqualStrings("wasi:io/streams", r1.interface);
    try testing.expectEqualStrings("[method]output-stream.blocking-write-and-flush", r1.func);
    // A locally-defined / non-import func index does not resolve to an interface.
    try testing.expectEqual(@as(?ctypes.TypeInfo.ImportRef, null), info.resolveComponentImport(99));
}

test "IT-1: a core module (not a component) is rejected as NotAComponent" {
    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    try testing.expectError(decode.Error.NotAComponent, instantiate(&eng, testing.allocator, &core_run42));
}
