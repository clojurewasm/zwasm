//! Multi-component **graph** orchestration (Zone 3; D-305).
//!
//! `instantiateGraph` evaluates a composed component's outer `instance`
//! section in definition order. Each child component is itself a full
//! component (its own `core_instances` index space — a `$libc` core module
//! plus a main module, exactly the shape an aggregate-passing component
//! needs), so the build is TWO-LEVEL: the OUTER loop walks the
//! `component_instances`, and per child an INNER loop walks that child's
//! `core_instances` (mirroring `component_wasi_p2.buildWasiP2Component`'s
//! core-instance loop, but with WASI imports replaced by cross-component
//! ones).
//!
//! A child's component-level imports are satisfied from the outer `with`
//! args, which point at an earlier child's LIFTED export. The child's
//! `canon lower` of such an import becomes a host trampoline that marshals
//! the arguments A-memory → B-memory at the boundary (canon lower → core →
//! lift) and invokes the provider's core func — so a `string` argument is
//! copied into the callee's own linear memory via its `cabi_realloc`, not
//! passed through as a raw (ptr,len) into foreign memory.

const std = @import("std");

const decode = @import("../feature/component/decode.zig");
const canon = @import("../feature/component/canon.zig");
const ctypes = @import("../feature/component/types.zig");
const cvalidate = @import("../feature/component/validate.zig");
const zwasm = @import("../zwasm.zig");

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const linker_mod = @import("../zwasm/linker.zig");
const Linker = linker_mod.Linker;
const Caller = @import("../zwasm/caller.zig").Caller;
const Memory = @import("../zwasm/memory.zig").Memory;
const Value = zwasm.Value;
const InstantiateOpts = Module.InstantiateOpts;

pub const GraphError = error{
    /// A child component embeds no core module to instantiate.
    NoCoreModule,
    /// An outer `with` arg / core import did not resolve to a built export.
    ImportUnsatisfied,
    /// The exported entry point did not resolve to a child's lifted func.
    ExportNotResolved,
    /// A cross-component boundary uses an arg/result shape the marshaller
    /// does not implement yet (typed deferral, not a silent mis-marshal).
    UnsupportedBoundaryType,
    OutOfMemory,
} || decode.Error || ctypes.Error || Module.InstantiateError || Engine.CompileError || linker_mod.LinkError;

/// One instantiated child component: its built core instances plus the
/// memory/realloc instances the canon boundary marshals through, and a
/// resolver from a component-export NAME to the lifted core func.
const GraphChild = struct {
    alloc: Allocator,
    decoded: decode.Component,
    info: ctypes.TypeInfo,
    /// Built core instances in definition order (index = core-instance idx).
    core_instances: std.ArrayList(?*Instance),
    /// The core instance exporting `cabi_realloc` (return-area / string
    /// allocator) and the one exporting linear memory — the canon boundary
    /// the lowers bind to.
    realloc_instance: ?*Instance = null,
    realloc_name: []const u8 = "cabi_realloc",
    mem_instance: ?*Instance = null,

    fn deinit(self: *GraphChild) void {
        self.core_instances.deinit(self.alloc);
        self.info.deinit();
        self.decoded.deinit(self.alloc);
    }

    /// `CanonContext.memory_fn` — re-fetch this child's bound linear memory.
    fn memFetch(p: *anyopaque) []u8 {
        const self: *GraphChild = @ptrCast(@alignCast(p));
        const inst = self.mem_instance orelse return &.{};
        const mem = inst.memory() orelse return &.{};
        return mem.slice();
    }

    /// `CanonContext.realloc_fn` — nested-invoke this child's `cabi_realloc`.
    fn reallocFetch(p: *anyopaque, old_ptr: u32, old_size: u32, alignment: u32, new_size: u32) canon.ReallocError!u32 {
        const self: *GraphChild = @ptrCast(@alignCast(p));
        const inst = self.realloc_instance orelse return canon.ReallocError.AllocFailed;
        var args = [_]Value{
            .{ .i32 = @bitCast(old_ptr) },
            .{ .i32 = @bitCast(old_size) },
            .{ .i32 = @bitCast(alignment) },
            .{ .i32 = @bitCast(new_size) },
        };
        var res = [_]Value{.{ .i32 = 0 }};
        inst.invoke(self.realloc_name, &args, &res) catch return canon.ReallocError.AllocFailed;
        const ptr: u32 = @bitCast(res[0].i32);
        if (ptr == 0 and new_size != 0) return canon.ReallocError.AllocFailed;
        return ptr;
    }

    fn canonContext(self: *GraphChild) canon.CanonContext {
        return .{
            .memory_ctx = @ptrCast(self),
            .memory_fn = memFetch,
            .realloc_ctx = @ptrCast(self),
            .realloc_fn = reallocFetch,
        };
    }
};

/// Heap-stable context for one cross-component host trampoline: the callee
/// child it marshals into + the callee's lifted core func to invoke, and the
/// imported func's WIT signature driving the per-arg marshalling.
const BoundaryCtx = struct {
    /// The callee child (owns the target memory + realloc the args land in).
    callee: *GraphChild,
    /// The callee's core func the lowered import dispatches to (the lifted
    /// export's underlying core export).
    core_func_name: []const u8,
    /// The callee instance the core func lives on.
    core_inst: *Instance,
    /// Imported func type (drives the per-arg lower: string vs flat scalar).
    func_type: ctypes.FuncType,
    /// For a single `list<primitive>` param: the element byte size (1/2/4/8),
    /// so the boundary copies `count * elem_size` bytes. 0 = not a list param.
    list_elem_size: u32 = 0,
    /// The IMPORTER child (owns the memory + realloc a `string` RESULT is
    /// lowered INTO). Only set for the retptr-result trampoline (`tag() ->
    /// string`); null for the flat-result trampoline.
    importer: ?*GraphChild = null,
};

/// A linked multi-component graph (D-305). Heap-allocated children +
/// instances keep addresses stable (instances and trampoline contexts
/// reference each other for the lifetime of the graph).
pub const ComponentGraph = struct {
    alloc: Allocator,
    owned_bytes: []const u8,
    outer: decode.Component,
    info: ctypes.TypeInfo,
    children: std.ArrayList(*GraphChild),
    modules: std.ArrayList(*Module),
    linkers: std.ArrayList(*Linker),
    instances: std.ArrayList(*Instance),
    boundaries: std.ArrayList(*BoundaryCtx),
    /// Map a child's definition ordinal (in `component_instances`) to the
    /// built `GraphChild` slot — outer `with` args reference children by
    /// instance index.
    child_of_instance: std.ArrayList(?*GraphChild),

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
        for (self.boundaries.items) |b| self.alloc.destroy(b);
        for (self.children.items) |c| {
            c.deinit();
            self.alloc.destroy(c);
        }
        self.instances.deinit(self.alloc);
        self.linkers.deinit(self.alloc);
        self.modules.deinit(self.alloc);
        self.boundaries.deinit(self.alloc);
        self.children.deinit(self.alloc);
        self.child_of_instance.deinit(self.alloc);
        self.info.deinit();
        self.outer.deinit(self.alloc);
        self.alloc.free(self.owned_bytes);
    }

    /// Invoke a graph export by name with flat-scalar args/result through the
    /// canonical ABI. Resolves the outer export → the child + that child's
    /// lifted export, then invokes the child's lifted core func directly
    /// (flat-scalar boundary; the string-passing happens internally between
    /// children via the boundary trampolines).
    pub fn invokeFlat(self: *ComponentGraph, name: []const u8, args: []const Value, results: []Value) !void {
        const res = self.resolveExport(name) orelse return GraphError.ExportNotResolved;
        const r = res.child.info.resolveLiftedFunc(res.export_name) orelse return GraphError.ExportNotResolved;
        const inst = res.child.core_instances.items[r.core_func.instance] orelse return GraphError.ExportNotResolved;
        return inst.invoke(r.core_func.name, args, results);
    }

    const ExportResolution = struct { child: *GraphChild, export_name: []const u8 };

    /// Resolve an outer export NAME to (child, child-export-name): the outer
    /// `export` aliases a component func that aliases a local child instance's
    /// export.
    fn resolveExport(self: *ComponentGraph, name: []const u8) ?ExportResolution {
        for (self.info.exports.items) |e| {
            if (!std.mem.eql(u8, e.name, name)) continue;
            if (std.meta.activeTag(e.sort) != .func) return null;
            // e.index is a component-func index; chase its alias to a local
            // component-instance export.
            const cf = if (e.index < self.info.component_funcs.items.len)
                self.info.component_funcs.items[e.index]
            else
                return null;
            const ce = switch (cf) {
                .alias => |t| switch (t) {
                    .component_export => |c| c,
                    else => return null,
                },
                else => return null,
            };
            const child = self.childOfInstanceIndex(ce.instance) orelse return null;
            return .{ .child = child, .export_name = ce.name };
        }
        return null;
    }

    /// The `GraphChild` an outer component-instance index resolves to (a
    /// LOCAL `.instantiate`); null for imports / synthetics / out of range.
    fn childOfInstanceIndex(self: *ComponentGraph, instance_index: u32) ?*GraphChild {
        if (instance_index >= self.info.instance_origins.items.len) return null;
        if (std.meta.activeTag(self.info.instance_origins.items[instance_index]) != .local) return null;
        var local_ord: usize = 0;
        for (self.info.instance_origins.items[0..instance_index]) |o| {
            if (std.meta.activeTag(o) == .local) local_ord += 1;
        }
        if (local_ord >= self.child_of_instance.items.len) return null;
        return self.child_of_instance.items[local_ord];
    }
};

/// Instantiate + link a multi-component graph (see `ComponentGraph`).
pub fn instantiateGraph(engine: *Engine, alloc: Allocator, bytes: []const u8, opts: InstantiateOpts) GraphError!ComponentGraph {
    const owned_bytes = try alloc.dupe(u8, bytes);
    var graph = ComponentGraph{
        .alloc = alloc,
        .owned_bytes = owned_bytes,
        .outer = decode.decode(alloc, owned_bytes) catch |e| {
            alloc.free(owned_bytes);
            return e;
        },
        .info = undefined,
        .children = .empty,
        .modules = .empty,
        .linkers = .empty,
        .instances = .empty,
        .boundaries = .empty,
        .child_of_instance = .empty,
    };
    errdefer graph.deinit();
    graph.info = try ctypes.decodeTypeInfo(alloc, &graph.outer);
    try cvalidate.validate(&graph.info); // ADR-0176

    for (graph.info.component_instances.items) |ci| {
        const it = switch (ci) {
            .instantiate => |it| it,
            // A synthetic re-export instance instantiates nothing; record an
            // empty slot so child ordinals stay aligned with definition order.
            .inline_exports => {
                try graph.child_of_instance.append(alloc, null);
                continue;
            },
        };
        const child = try buildChild(engine, &graph, it, opts);
        try graph.children.append(alloc, child);
        try graph.child_of_instance.append(alloc, child);
    }
    return graph;
}

/// Build one child component: decode it, then walk its `core_instances`
/// index space in definition order. The child's component-level imports are
/// resolved from the outer `with` args (`it.args`).
fn buildChild(
    engine: *Engine,
    graph: *ComponentGraph,
    it: anytype, // .instantiate payload: { component, args }
    opts: InstantiateOpts,
) GraphError!*GraphChild {
    const alloc = graph.alloc;
    const child_bytes = nthChildComponent(&graph.outer, it.component) orelse return GraphError.NoCoreModule;

    const child = try alloc.create(GraphChild);
    errdefer alloc.destroy(child);
    child.* = .{
        .alloc = alloc,
        .decoded = try decode.decode(alloc, child_bytes),
        .info = undefined,
        .core_instances = .empty,
    };
    errdefer child.deinit();
    child.info = try ctypes.decodeTypeInfo(alloc, &child.decoded);
    try cvalidate.validate(&child.info);

    for (child.info.core_instances.items) |cinst| {
        const built = try buildCoreInstance(engine, graph, child, it, cinst, opts);
        try child.core_instances.append(alloc, built);
        if (built) |gi| {
            if (child.realloc_instance == null and instanceExportsFunc(gi, child.realloc_name))
                child.realloc_instance = gi;
            if (child.mem_instance == null and gi.memory() != null)
                child.mem_instance = gi;
        }
    }
    return child;
}

/// Build one of a child's core instances. A `.instantiate` compiles + links
/// its module (imports satisfied from earlier core instances, synthetic
/// `with` instances, or — via a boundary trampoline — a cross-component
/// lowered import). An `.inline_exports` instance is synthetic: it has no
/// `*Instance`, so it returns null and is bound lazily when an importer names
/// it (handled in `pourCoreInstanceArg`).
fn buildCoreInstance(
    engine: *Engine,
    graph: *ComponentGraph,
    child: *GraphChild,
    outer_it: anytype,
    cinst: ctypes.CoreInstance,
    opts: InstantiateOpts,
) GraphError!?*Instance {
    const alloc = graph.alloc;
    switch (cinst) {
        .inline_exports => return null,
        .instantiate => |inst_def| {
            const core_bytes = nthCoreModule(&child.decoded, inst_def.module) orelse return GraphError.NoCoreModule;
            const module = try alloc.create(Module);
            errdefer alloc.destroy(module);
            module.* = try engine.compile(core_bytes);
            try graph.modules.append(alloc, module);

            const lk = try alloc.create(Linker);
            lk.* = engine.linker();
            try graph.linkers.append(alloc, lk);

            // Pour each `with` arg's prior core instance into the linker under
            // its namespace, satisfying this module's imports.
            for (inst_def.args) |arg| {
                try pourCoreInstanceArg(graph, child, outer_it, lk, arg);
            }

            const gi = try alloc.create(Instance);
            errdefer alloc.destroy(gi);
            gi.* = try lk.instantiate(module, opts);
            try graph.instances.append(alloc, gi);
            return gi;
        },
    }
}

/// Pour one core-instance `with` arg (`name` ← core instance `arg.instance`)
/// into the linker. The referenced instance is either a real guest instance
/// (alias all its exports) OR a synthetic `.inline_exports` instance, whose
/// func exports may be lowered cross-component imports — those bind to a
/// boundary trampoline.
fn pourCoreInstanceArg(
    graph: *ComponentGraph,
    child: *GraphChild,
    outer_it: anytype,
    lk: *Linker,
    arg: ctypes.CoreInstantiateArg,
) GraphError!void {
    const cinsts = child.info.core_instances.items;
    if (arg.instance >= cinsts.len) return GraphError.ImportUnsatisfied;
    switch (cinsts[arg.instance]) {
        .instantiate => {
            const provider = child.core_instances.items[arg.instance] orelse return GraphError.ImportUnsatisfied;
            try lk.defineInstance(arg.name, provider);
        },
        .inline_exports => |exps| {
            for (exps) |ex| try pourSyntheticExport(graph, child, outer_it, lk, arg.name, ex);
        },
    }
}

/// Bind one synthetic inline-export into the linker under `ns`. A `.func`
/// export that is a `canon lower` of a component import resolves (via the
/// outer `with` args) to a provider child's lifted func; we install a host
/// trampoline that marshals across the boundary.
fn pourSyntheticExport(
    graph: *ComponentGraph,
    child: *GraphChild,
    outer_it: anytype,
    lk: *Linker,
    ns: []const u8,
    ex: ctypes.CoreInlineExport,
) GraphError!void {
    if (ex.sort != .func) return GraphError.UnsupportedBoundaryType;
    const cf = child.info.coreFunc(ex.index) orelse return GraphError.ImportUnsatisfied;
    const import_name = switch (cf) {
        .lower => |component_func_idx| importNameOfLoweredFunc(&child.info, component_func_idx) orelse return GraphError.ImportUnsatisfied,
        else => return GraphError.UnsupportedBoundaryType,
    };
    // The outer `with` arg whose name matches this import names the provider
    // child + that child's exported func.
    const provider = resolveProvider(graph, outer_it, import_name) orelse return GraphError.ImportUnsatisfied;
    try installBoundaryTrampoline(graph, lk, ns, ex.name, import_name, child, provider);
}

const Provider = struct { child: *GraphChild, export_name: []const u8 };

/// Resolve a child's component-import NAME to the provider (child + exported
/// func) via the outer `with` args: each arg satisfies an import name with a
/// `func` from a local child instance's exports.
fn resolveProvider(graph: *ComponentGraph, outer_it: anytype, import_name: []const u8) ?Provider {
    for (outer_it.args) |a| {
        if (!std.mem.eql(u8, a.name, import_name)) continue;
        if (std.meta.activeTag(a.sort) != .func) return null;
        // a.index is a component-func index in the OUTER component: a func
        // alias of a child instance export.
        const cf = if (a.index < graph.info.component_funcs.items.len)
            graph.info.component_funcs.items[a.index]
        else
            return null;
        const ce = switch (cf) {
            .alias => |t| switch (t) {
                .component_export => |c| c,
                else => return null,
            },
            else => return null,
        };
        const pc = graph.childOfInstanceIndex(ce.instance) orelse return null;
        return .{ .child = pc, .export_name = ce.name };
    }
    return null;
}

/// Install a host trampoline that, when the importer core module calls the
/// lowered import with flat args, marshals them into the provider child and
/// invokes the provider's lifted core func — copying `string` args into the
/// callee's own memory via its realloc (canon lower → core → lift).
fn installBoundaryTrampoline(
    graph: *ComponentGraph,
    lk: *Linker,
    ns: []const u8,
    core_export_name: []const u8,
    import_name: []const u8,
    importer: *GraphChild,
    provider: Provider,
) GraphError!void {
    const r = provider.child.info.resolveLiftedFunc(provider.export_name) orelse return GraphError.ImportUnsatisfied;
    const ft = provider.child.info.resolveFuncType(provider.export_name) orelse return GraphError.ImportUnsatisfied;
    const core_inst = provider.child.core_instances.items[r.core_func.instance] orelse return GraphError.ImportUnsatisfied;
    if (r.string_encoding != .utf8) return GraphError.UnsupportedBoundaryType;
    if (r.realloc) |rr| provider.child.realloc_name = rr.name;
    _ = import_name;

    // A `string` RESULT flattens to >1 core value, so per the Canonical ABI it
    // returns via a RETPTR: the lowered import's core signature is `(retptr) ->
    // ()`, NOT the fixed `(i32,i32) -> i32`. Detect it and install the dedicated
    // retptr-result trampoline (no value params; the result string is lifted
    // from B and lowered into A's memory).
    if (resultIsString(graph.alloc, &provider.child.info, ft)) {
        // Only the no-param shape `() -> string` is implemented: it flattens to
        // core `(retptr) -> ()`. Value params alongside a string result flatten
        // to `(params.., retptr)` — a broader shape (typed deferral).
        if (ft.params.len != 0) return GraphError.UnsupportedBoundaryType;
        const bctx = try graph.alloc.create(BoundaryCtx);
        errdefer graph.alloc.destroy(bctx);
        bctx.* = .{
            .callee = provider.child,
            .core_func_name = r.core_func.name,
            .core_inst = core_inst,
            .func_type = ft,
            .importer = importer,
        };
        try graph.boundaries.append(graph.alloc, bctx);
        try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), RetPtrSig, retPtrTrampoline);
        return;
    }

    // For a single `list<primitive>` param, resolve the element byte size now so
    // the call-time copy moves `count * elem_size` bytes. A `list<u32>` param is a
    // `type_index` into the provider's type space, so resolve via `canon`.
    var list_elem_size: u32 = 0;
    if (ft.params.len == 1) {
        var tmp = std.heap.ArenaAllocator.init(graph.alloc);
        defer tmp.deinit();
        if (canon.canonTypeFromDecoded(tmp.allocator(), &provider.child.info, ft.params[0].ty)) |ct| {
            if (ct == .list and ct.list.* == .prim and isFlatPrim(ct.list.*.prim))
                list_elem_size = @intCast(canon.sizeOf(ct.list.*));
        } else |_| {
            // Type resolution failed → not a flat-primitive list; the shape
            // check below rejects it (string/flat path or typed deferral).
        }
    }

    // The fixed boundary trampoline marshals shapes flattening to `(i32,i32)->i32`:
    // a `string` / `list<primitive>` param (ptr,len) OR two flat 4-byte scalars,
    // returning one flat 4-byte scalar. Broader arities / wide scalars / non-string
    // aggregate results are a typed deferral (no silent mis-marshal). D-305
    // follow-up: arity-general trampolines + record/result marshalling.
    if (!boundaryShapeOk(ft, list_elem_size > 0)) return GraphError.UnsupportedBoundaryType;

    const bctx = try graph.alloc.create(BoundaryCtx);
    errdefer graph.alloc.destroy(bctx);
    bctx.* = .{
        .callee = provider.child,
        .core_func_name = r.core_func.name,
        .core_inst = core_inst,
        .func_type = ft,
        .list_elem_size = list_elem_size,
    };
    try graph.boundaries.append(graph.alloc, bctx);

    try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), BoundarySig, boundaryTrampoline);
}

/// Does this WIT func return a `string`? A string result flattens to >1 core
/// value so it returns via a retptr — the dedicated `(retptr) -> ()` trampoline.
fn resultIsString(alloc: Allocator, info: *const ctypes.TypeInfo, ft: ctypes.FuncType) bool {
    const rt = ft.result orelse return false;
    if (isString(rt)) return true;
    // A `type_index` result may alias `string` (the provider type space).
    var tmp = std.heap.ArenaAllocator.init(alloc);
    defer tmp.deinit();
    if (canon.canonTypeFromDecoded(tmp.allocator(), info, rt)) |ct| {
        return ct == .prim and ct.prim == .string;
    } else |_| {
        return false;
    }
}

/// Does the WIT func type flatten to the core signature `(i32,i32) -> i32`, the
/// fixed shape the boundary trampoline marshals? True for `(string)`,
/// `(list<primitive>)` (when `param0_is_list`), or `(scalar4, scalar4)`,
/// returning one flat 4-byte scalar.
fn boundaryShapeOk(ft: ctypes.FuncType, param0_is_list: bool) bool {
    const result_ok = if (ft.result) |rt| isFlat4Scalar(rt) else false;
    if (!result_ok) return false;
    if (ft.params.len == 1) {
        return isString(ft.params[0].ty) or param0_is_list;
    }
    if (ft.params.len == 2) {
        return isFlat4Scalar(ft.params[0].ty) and isFlat4Scalar(ft.params[1].ty);
    }
    return false;
}

fn isString(vt: ctypes.ValType) bool {
    return switch (vt) {
        .primitive => |p| p == .string,
        else => false,
    };
}

/// A fixed-size scalar primitive (numeric/bool/char) — a `list<this>` is a flat
/// `count * size`-byte run with no internal pointers, so the boundary can copy
/// it by bytes. `string` / `error_context` need their own marshalling.
fn isFlatPrim(p: ctypes.PrimValType) bool {
    return switch (p) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char => true,
        .string, .error_context => false,
    };
}

/// A 4-byte (i32-flat) scalar valtype — flattens to a single i32 core word.
fn isFlat4Scalar(vt: ctypes.ValType) bool {
    return switch (vt) {
        .primitive => |p| switch (p) {
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char => true,
            .s64, .u64, .f32, .f64, .string, .error_context => false,
        },
        else => false,
    };
}

/// The fixed flattened core signature the boundary trampoline binds to:
/// `(w0:i32, w1:i32) -> i32`. The two words are interpreted per the WIT param
/// list at call time — a string's (ptr,len) or two flat scalars.
const BoundarySig = fn (*Caller, u32, u32) callconv(.c) BoundaryResult;
const BoundaryResult = u32;

/// Host trampoline: marshal the two flat words across the boundary per the
/// importer's WIT signature, invoke the callee's core func, return its flat
/// result. A `string` param is copied importer-memory → callee-memory via the
/// callee's realloc (canon lower → core → lift); flat scalars pass through.
fn boundaryTrampoline(caller: *Caller, w0: u32, w1: u32) callconv(.c) BoundaryResult {
    const bctx = caller.data(BoundaryCtx);
    return boundaryMarshal(caller, bctx, w0, w1) catch 0;
}

fn boundaryMarshal(caller: *Caller, bctx: *BoundaryCtx, w0: u32, w1: u32) !BoundaryResult {
    const params = bctx.func_type.params;
    var args = [_]Value{ .{ .i32 = @bitCast(w0) }, .{ .i32 = @bitCast(w1) } };

    if (bctx.list_elem_size > 0) {
        // list<primitive>: w0=ptr, w1=COUNT in the IMPORTER's memory. Copy
        // count*elem_size bytes into the CALLEE's memory via its realloc
        // (aligned to the element size), since the callee reads its OWN memory.
        const caller_mem: Memory = caller.memory() orelse return GraphError.ImportUnsatisfied;
        const byte_count: u32 = w1 * bctx.list_elem_size;
        const src = caller_mem.sliceAt(w0, byte_count) catch return GraphError.UnsupportedBoundaryType;
        const tmp = try caller.allocator().dupe(u8, src);
        defer caller.allocator().free(tmp);
        const cx = bctx.callee.canonContext();
        const ptr = cx.realloc(0, 0, bctx.list_elem_size, byte_count) catch return GraphError.UnsupportedBoundaryType;
        if (@as(usize, ptr) + byte_count > cx.mem().len) return GraphError.UnsupportedBoundaryType;
        @memcpy(cx.mem()[ptr..][0..byte_count], tmp);
        args[0] = .{ .i32 = @bitCast(ptr) };
        args[1] = .{ .i32 = @bitCast(w1) }; // count unchanged
    } else if (params.len == 1 and isString(params[0].ty)) {
        // Single string: w0=ptr, w1=len in the IMPORTER's memory. Snapshot the
        // bytes, then lower them into the CALLEE's memory via its realloc — the
        // callee reads its OWN memory, so the string must physically move.
        const caller_mem: Memory = caller.memory() orelse return GraphError.ImportUnsatisfied;
        const src = caller_mem.sliceAt(w0, w1) catch return GraphError.UnsupportedBoundaryType;
        const tmp = try caller.allocator().dupe(u8, src);
        defer caller.allocator().free(tmp);
        const cx = bctx.callee.canonContext();
        const lowered = canon.lowerString(cx, tmp) catch return GraphError.UnsupportedBoundaryType;
        args[0] = .{ .i32 = @bitCast(lowered.ptr) };
        args[1] = .{ .i32 = @bitCast(lowered.packed_length) };
    }
    // else: two flat scalars pass straight through (no memory marshalling).

    var res = [_]Value{.{ .i32 = 0 }};
    bctx.core_inst.invoke(bctx.core_func_name, &args, &res) catch return GraphError.ImportUnsatisfied;
    return @bitCast(res[0].i32);
}

/// The retptr-result trampoline's flattened core signature: `(retptr:i32) ->
/// ()`. A `string` RESULT can't be a flat return word, so the importer passes a
/// return-area pointer (into its OWN memory) where the boundary writes the
/// A-side `(ptr, len)` pair.
const RetPtrSig = fn (*Caller, u32) callconv(.c) void;

/// Host trampoline for `() -> string`: invoke the callee's core func (writing
/// the result string into the CALLEE's memory via a callee-side return area),
/// lift that string, then lower it into the IMPORTER's memory and write the
/// A-side `(ptr, len)` at the importer's retptr.
fn retPtrTrampoline(caller: *Caller, retptr: u32) callconv(.c) void {
    const bctx = caller.data(BoundaryCtx);
    retPtrMarshal(caller, bctx, retptr) catch {
        // EXEMPT-FALLBACK: a void-returning core trampoline can't surface a
        // host error to the guest; a marshalling failure leaves the importer's
        // return area untouched so the guest reads its zero-initialised default
        // (a deterministic wrong value the assert catches, never a silent
        // mis-marshal of a partial write). D-305: aggregate-result error
        // propagation across the void boundary is a follow-up.
    };
}

fn retPtrMarshal(caller: *Caller, bctx: *BoundaryCtx, retptr: u32) !void {
    // 1. Allocate a return area in the CALLEE's memory and invoke its core func,
    //    which writes the result string (ptr,len) there (B writes B's memory).
    const callee_cx = bctx.callee.canonContext();
    const callee_ret = callee_cx.realloc(0, 0, 4, 8) catch return GraphError.UnsupportedBoundaryType;
    var args = [_]Value{.{ .i32 = @bitCast(callee_ret) }};
    var res = [_]Value{};
    bctx.core_inst.invoke(bctx.core_func_name, &args, &res) catch return GraphError.ImportUnsatisfied;

    // 2. Lift the result string from the CALLEE's memory at its return area.
    if (@as(usize, callee_ret) + 8 > callee_cx.mem().len) return GraphError.UnsupportedBoundaryType;
    const b_ptr = std.mem.readInt(u32, callee_cx.mem()[callee_ret..][0..4], .little);
    const b_len = std.mem.readInt(u32, callee_cx.mem()[callee_ret + 4 ..][0..4], .little);
    const lifted = canon.liftString(callee_cx, b_ptr, b_len) catch return GraphError.UnsupportedBoundaryType;

    // 3. Lower the string into the IMPORTER's memory (snapshot first: the lift
    //    borrows callee memory, the lower realloc may move it). Then write the
    //    A-side (ptr,len) at the importer's retptr in the importer's memory.
    const importer = bctx.importer orelse return GraphError.ImportUnsatisfied;
    const tmp = try caller.allocator().dupe(u8, lifted);
    defer caller.allocator().free(tmp);
    const importer_cx = importer.canonContext();
    const lowered = canon.lowerString(importer_cx, tmp) catch return GraphError.UnsupportedBoundaryType;
    if (@as(usize, retptr) + 8 > importer_cx.mem().len) return GraphError.UnsupportedBoundaryType;
    std.mem.writeInt(u32, importer_cx.mem()[retptr..][0..4], lowered.ptr, .little);
    std.mem.writeInt(u32, importer_cx.mem()[retptr + 4 ..][0..4], lowered.packed_length, .little);
}

/// The component-import NAME a `canon lower`'s func operand aliases — for a
/// DIRECT func import (`(import "firstbyte" (func ...))`), the lowered
/// component-func index is a `ComponentFuncDef.import` into `imports`.
fn importNameOfLoweredFunc(info: *const ctypes.TypeInfo, component_func_idx: u32) ?[]const u8 {
    if (component_func_idx >= info.component_funcs.items.len) return null;
    return switch (info.component_funcs.items[component_func_idx]) {
        .import => |import_idx| if (import_idx < info.imports.items.len) info.imports.items[import_idx].name else null,
        else => null,
    };
}

fn instanceExportsFunc(inst: *Instance, name: []const u8) bool {
    return inst.exportFuncSig(name) != null;
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

fn nthCoreModule(decoded: *const decode.Component, n: u32) ?[]const u8 {
    var i: u32 = 0;
    for (decoded.sections.items) |sec| {
        if (sec.id != .core_module) continue;
        if (i == n) return sec.body;
        i += 1;
    }
    return null;
}
