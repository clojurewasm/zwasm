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
const async_mod = @import("../feature/component/async.zig");
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
} || decode.Error || ctypes.Error || Module.InstantiateError || Engine.CompileError || linker_mod.LinkError || async_mod.Error;

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
    /// Set when the imported func is async-lifted (ADR-0195 c-2b): the shared
    /// graph scheduler state the async trampoline enqueues the callee subtask
    /// into. null for a synchronous boundary.
    async_state: ?*GraphAsync = null,
    /// The callee subtask's registry funcidx in `GraphAsync.callbacks` — the id
    /// the async trampoline tags the enqueued `TaskDescriptor` with so the
    /// scheduler re-enters the right callee callback. Only set for an async
    /// boundary.
    async_cb_funcidx: u32 = 0,
};

/// ADR-0195 c-2b — the shared cross-component async scheduler state. Owns the
/// graph's single `TaskTable` and a registry mapping a synthetic task funcidx
/// to the (instance, callback name) the scheduler re-enters. A funcidx here is
/// NOT a core-module funcidx; it is the dense registry index the graph mints so
/// `driveScheduler`'s `invokeTaskCallback(funcidx, …)` dispatches across
/// instances (the single-component runner ignores funcidx — there it is one
/// callback; the graph needs the per-task instance routing).
const GraphAsync = struct {
    alloc: Allocator,
    tasks: async_mod.TaskTable,
    /// funcidx (registry index) → the callback to re-enter for that task.
    callbacks: std.ArrayList(CallbackTarget),
    /// ADR-0195 step (d-a): the task currently executing a guest entry/callback.
    /// Set IMMEDIATELY before each callee invoke so the graph-level `task.return`
    /// host func knows which task's `TaskDescriptor.result` to store into. 0 = no
    /// task executing (the reserved table id is never a live task).
    current_task_id: u32 = 0,

    const CallbackTarget = struct { inst: *Instance, name: []const u8 };

    fn init(alloc: Allocator) async_mod.Error!GraphAsync {
        return .{ .alloc = alloc, .tasks = try async_mod.TaskTable.init(alloc), .callbacks = .empty };
    }

    fn deinit(self: *GraphAsync) void {
        self.tasks.deinit();
        self.callbacks.deinit(self.alloc);
    }

    /// Register a callback target and return its funcidx (the dense registry
    /// index the scheduler dispatches on). Index 0 is a valid registry slot
    /// here (unlike the table's reserved-0 handle): the funcidx is a plain
    /// array index, never a task id.
    fn registerCallback(self: *GraphAsync, inst: *Instance, name: []const u8) async_mod.Error!u32 {
        const idx: u32 = @intCast(self.callbacks.items.len);
        try self.callbacks.append(self.alloc, .{ .inst = inst, .name = name });
        return idx;
    }

    /// The live task id whose callback is registry `funcidx` (ADR-0195 d-a),
    /// or 0 if none — drives `current_task_id` so a callback's `task.return`
    /// stores into the right per-task slot. Each task registers a distinct
    /// callback funcidx, so the match is unique.
    fn taskOfCallback(self: *GraphAsync, funcidx: u32) u32 {
        for (self.tasks.slots.items, 0..) |slot, i| {
            const t = slot orelse continue;
            if (t.callback_funcidx == funcidx) return @intCast(i);
        }
        return 0;
    }
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
    /// The shared cross-component async scheduler state (ADR-0195 c-2b), created
    /// lazily the first time an async boundary is installed; null for a graph
    /// with no async imports.
    async_state: ?*GraphAsync = null,

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
        if (self.async_state) |as| {
            as.deinit();
            self.alloc.destroy(as);
        }
        self.info.deinit();
        self.outer.deinit(self.alloc);
        self.alloc.free(self.owned_bytes);
    }

    /// Lazily create + return the shared async scheduler state (ADR-0195 c-2b).
    fn asyncState(self: *ComponentGraph) async_mod.Error!*GraphAsync {
        if (self.async_state) |as| return as;
        const as = try self.alloc.create(GraphAsync);
        errdefer self.alloc.destroy(as);
        as.* = try GraphAsync.init(self.alloc);
        self.async_state = as;
        return as;
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

    /// The ctx `driveScheduler` is generic over for the cross-component graph
    /// (ADR-0195 c-2b): dispatch a task's callback by its registry funcidx across
    /// the graph's instances. `pollSet` has no cross-component waitable delivery
    /// yet (streams/futures across the boundary land in step (d)/(e)) — it always
    /// returns null, so a task that WAITs with no progress deadlocks loudly via
    /// `driveScheduler`'s `AsyncDeadlock` (never a silent NONE).
    const GraphAsyncCtx = struct {
        state: *GraphAsync,

        pub fn invokeTaskCallback(self: *GraphAsyncCtx, funcidx: u32, event_code: u32, p1: u32, p2: u32) !u32 {
            if (funcidx >= self.state.callbacks.items.len) return GraphError.ExportNotResolved;
            const target = self.state.callbacks.items[funcidx];
            var args = [_]Value{
                .{ .i32 = @bitCast(event_code) },
                .{ .i32 = @bitCast(p1) },
                .{ .i32 = @bitCast(p2) },
            };
            var res = [_]Value{.{ .i32 = 0 }};
            // ADR-0195 d-a: mark the task whose callback this is as current so a
            // task.return from inside the callback lands in its own result slot.
            const prev = self.state.current_task_id;
            self.state.current_task_id = self.state.taskOfCallback(funcidx);
            defer self.state.current_task_id = prev;
            try target.inst.invoke(target.name, &args, &res);
            return @bitCast(res[0].i32);
        }

        pub fn pollSet(self: *GraphAsyncCtx, set_index: u32) !?async_mod.EventTuple {
            _ = self;
            _ = set_index;
            return null;
        }
    };

    /// Drive the graph's main async export (`name`) to completion through the
    /// stackless callback scheduler (ADR-0195 c-2b). Seeds task 0 = the named
    /// async export, then runs `driveScheduler` over the graph's shared
    /// `TaskTable`: a cross-component async import (component A's `canon lower …
    /// async` of B's async `tick`) enqueues B's subtask into the SAME table at
    /// boundary-call time, so the scheduler drives BOTH guests to completion.
    /// Traps `AsyncDeadlock` (not a silent NONE) if a task blocks with no
    /// deliverable event.
    pub fn driveAsyncMain(self: *ComponentGraph, name: []const u8) !void {
        const res = self.resolveExport(name) orelse return GraphError.ExportNotResolved;
        const r = res.child.info.resolveLiftedFunc(res.export_name) orelse return GraphError.ExportNotResolved;
        if (!r.is_async) return GraphError.UnsupportedBoundaryType; // not an async export
        const cb = r.callback orelse return GraphError.UnsupportedBoundaryType; // async lift implies a callback
        const inst = res.child.core_instances.items[r.core_func.instance] orelse return GraphError.ExportNotResolved;
        const cb_inst = res.child.core_instances.items[cb.instance] orelse return GraphError.ExportNotResolved;

        const as = try self.asyncState();

        // Reserve task 0's id BEFORE invoking the main entry, so a `task.return`
        // from inside it (a result-bearing async export) lands in this task's slot
        // (ADR-0195 d-a). The placeholder is folded to its real state afterward.
        const main_funcidx = try as.registerCallback(cb_inst, cb.name);
        const main_id = try as.tasks.add(.{ .callback_funcidx = main_funcidx });
        as.current_task_id = main_id;

        // Invoke the async task entry once; its packed i32 return seeds the task.
        var results = [_]Value{.{ .i32 = 0 }};
        try inst.invoke(r.core_func.name, &.{}, &results);
        const initial: u32 = @bitCast(results[0].i32);
        as.current_task_id = 0;

        const seed = try async_mod.seedTask(initial);
        const main_task = try as.tasks.get(main_id);
        main_task.state = seed.state;
        main_task.set_index = seed.set_index;

        var ctx = GraphAsyncCtx{ .state = as };
        try async_mod.driveScheduler(&ctx, &as.tasks);
    }

    /// Count the (live, non-tombstone) tasks the async scheduler has driven and
    /// how many reached `.done` — the test seam proving BOTH the caller (A's
    /// `run`) and the enqueued callee (B's `tick`) completed (ADR-0195 c-2b).
    pub fn asyncTaskCounts(self: *ComponentGraph) struct { total: usize, done: usize } {
        const as = self.async_state orelse return .{ .total = 0, .done = 0 };
        var total: usize = 0;
        var done: usize = 0;
        for (as.tasks.slots.items) |slot| {
            const t = slot orelse continue;
            total += 1;
            if (t.state == .done) done += 1;
        }
        return .{ .total = total, .done = done };
    }

    /// ADR-0195 step (d-a) — the value task `id` delivered via `canon task.return`
    /// (the cross-component async DATA channel), or null if the task never returned
    /// a value (or `id` is not a live task). The test seam proving a callee's
    /// `task.return(value)` was captured graph-side into its per-task slot.
    pub fn taskResult(self: *ComponentGraph, id: u32) ?u32 {
        const as = self.async_state orelse return null;
        const task = as.tasks.get(id) catch return null;
        return task.result;
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
        // A child's own `canon task.return` (ADR-0195 d-a): wire the graph-level
        // host func that captures the value into the currently-executing task.
        // Only the minimal single-`u32` result is implemented; a multi-value /
        // typed task.return is a typed deferral (UnsupportedBoundaryType), never
        // a silent partial capture.
        .task_return => |tr| {
            if (tr.result == null or !isFlat4Scalar(tr.result.?)) return GraphError.UnsupportedBoundaryType;
            const as = try graph.asyncState();
            try lk.defineFuncCtx(ns, ex.name, @ptrCast(as), TaskReturnSig, graphTaskReturn);
            return;
        },
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

    // ADR-0195 c-2b — the imported func is async-lifted: route through the
    // async boundary trampoline (mint a subtask for the callee + enqueue it into
    // the shared scheduler `TaskTable`), not the synchronous marshal-and-call.
    if (r.is_async) {
        return installAsyncBoundary(graph, lk, ns, core_export_name, ft, r, core_inst, provider);
    }

    // A `string` RESULT flattens to >1 core value, so per the Canonical ABI it
    // returns via a RETPTR: the lowered import's core signature is `(retptr) ->
    // ()`, NOT the fixed `(i32,i32) -> i32`. Detect it and install the dedicated
    // retptr-result trampoline (no value params; the result string is lifted
    // from B and lowered into A's memory).
    if (resultIsString(graph.alloc, &provider.child.info, ft)) {
        // Two retptr-result shapes are implemented:
        //   `() -> string`         → core `(retptr) -> ()`
        //   `(string) -> string`   → core `(param_ptr, param_len, retptr) -> ()`
        // Any other param list alongside a string result is a broader shape
        // (typed deferral — no silent mis-marshal).
        const param_is_string = ft.params.len == 1 and isString(ft.params[0].ty);
        if (ft.params.len != 0 and !param_is_string) return GraphError.UnsupportedBoundaryType;
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
        if (param_is_string) {
            try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), StrRetStrSig, strRetStrTrampoline);
        } else {
            try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), RetPtrSig, retPtrTrampoline);
        }
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

/// `Subtask.State` codes the async-LOWERED import returns to the caller per the
/// Canonical ABI (`CanonicalABI.md` `Subtask.State`). RETURNED=2 means the
/// callee resolved within the call (a synchronous completion); the minimal c-2b
/// fixture's callee EXITs immediately, so the lowered call returns RETURNED.
const SUBTASK_RETURNED: u32 = @intFromEnum(async_mod.SubtaskState.returned);

/// The async boundary trampoline's flattened core signature for a NO-RESULT
/// async import (`canon lower … async` of `func()`): `() -> i32`, returning the
/// async-call status code. `BoundaryError!u32` so a callee trap propagates.
const AsyncBoundarySig = fn (*Caller) BoundaryError!u32;

/// The async boundary trampoline's core signature for a RESULT-BEARING async
/// import (`canon lower … async` of `func() -> u32`): the lowered core func gains
/// a leading `retptr` param naming where the importer would receive the result,
/// `(retptr:i32) -> i32`. The result itself travels via the callee's
/// `task.return` (captured graph-side into the subtask's per-task slot, ADR-0195
/// d-a), so the retptr is currently unused by the boundary (the minimal d-a step
/// captures graph-side; lowering the result back into the importer's retptr is a
/// later slice).
const AsyncBoundaryRetSig = fn (*Caller, u32) BoundaryError!u32;

/// Install the async cross-component boundary (ADR-0195 c-2b / d-a). When the
/// importer calls the async-lowered import, the trampoline invokes the callee's
/// async task entry once, mints a `Subtask` for it, and enqueues a
/// `TaskDescriptor` (callback = the callee's async `callback`) into the shared
/// scheduler table so the graph runner drives the callee to completion alongside
/// the caller.
///
/// Two shapes are implemented: the no-result `func()` (c-2b) and a single
/// flat-4-scalar result `func() -> u32` (d-a — the result is delivered via the
/// callee's `task.return`, captured graph-side). Any param list, or a wider /
/// aggregate result that needs cross-boundary marshalling, is a typed deferral:
/// `UnsupportedBoundaryType`, never a silent wrong value.
fn installAsyncBoundary(
    graph: *ComponentGraph,
    lk: *Linker,
    ns: []const u8,
    core_export_name: []const u8,
    ft: ctypes.FuncType,
    r: ctypes.TypeInfo.ResolvedLift,
    core_inst: *Instance,
    provider: Provider,
) GraphError!void {
    if (ft.params.len != 0) return GraphError.UnsupportedBoundaryType;
    const has_result = if (ft.result) |rt| blk: {
        if (!isFlat4Scalar(rt)) return GraphError.UnsupportedBoundaryType;
        break :blk true;
    } else false;
    const cb = r.callback orelse return GraphError.UnsupportedBoundaryType; // async lift implies a callback
    const cb_inst = provider.child.core_instances.items[cb.instance] orelse return GraphError.ImportUnsatisfied;

    const as = try graph.asyncState();
    const cb_funcidx = try as.registerCallback(cb_inst, cb.name);

    const bctx = try graph.alloc.create(BoundaryCtx);
    errdefer graph.alloc.destroy(bctx);
    bctx.* = .{
        .callee = provider.child,
        .core_func_name = r.core_func.name,
        .core_inst = core_inst,
        .func_type = ft,
        .async_state = as,
        .async_cb_funcidx = cb_funcidx,
    };
    try graph.boundaries.append(graph.alloc, bctx);

    if (has_result) {
        try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), AsyncBoundaryRetSig, asyncBoundaryRetTrampoline);
    } else {
        try lk.defineFuncCtx(ns, core_export_name, @ptrCast(bctx), AsyncBoundarySig, asyncBoundaryTrampoline);
    }
}

/// Host trampoline for an async cross-component import (ADR-0195 c-2b): invoke
/// the callee's async task entry, seed a `TaskDescriptor` from its packed result
/// (EXIT → done, YIELD → ready, WAIT → waiting), enqueue it into the shared
/// scheduler table, and return the async-call status (RETURNED, since the
/// minimal callee resolves synchronously). A callee trap propagates as a trap.
fn asyncBoundaryTrampoline(caller: *Caller) BoundaryError!u32 {
    return enqueueCalleeSubtask(caller.data(BoundaryCtx));
}

/// Result-bearing async import (`func() -> u32`, ADR-0195 d-a): the lowered core
/// func carries a leading `retptr` (where the importer would receive the result).
/// The result travels via the callee's `task.return` (captured graph-side), so
/// the retptr is unused here — the enqueue path is identical to the void shape.
fn asyncBoundaryRetTrampoline(caller: *Caller, retptr: u32) BoundaryError!u32 {
    // d-a: the callee's task.return value is captured graph-side (TaskDescriptor.result),
    // NOT lowered back into the caller's `retptr`. The caller (A) does not consume B's
    // async result yet; delivering it into `retptr` on synchronous RETURNED is the d-b
    // slice (cross-component async-result lowering). Until then the result lives in the
    // subtask's per-task slot, readable via `ComponentGraph.taskResult`.
    // TODO(p17 d-b): lower the resolved subtask result into `retptr` for a caller that reads it.
    _ = retptr;
    return enqueueCalleeSubtask(caller.data(BoundaryCtx));
}

/// Shared enqueue body: invoke the callee's async entry once, mint its subtask,
/// fold the packed result into the subtask state, return the async-call status.
fn enqueueCalleeSubtask(bctx: *BoundaryCtx) BoundaryError!u32 {
    const as = bctx.async_state orelse return error.OutOfBoundsLoad; // wired only for async boundaries

    // Reserve the callee subtask's id BEFORE invoking its entry, so the
    // graph-level task.return host func (ADR-0195 d-a) routes the callee's
    // `task.return(value)` into THIS task's `result` slot. A placeholder
    // descriptor is folded to its real state from the entry's packed return.
    const task_id = as.tasks.add(.{ .callback_funcidx = bctx.async_cb_funcidx }) catch return error.OutOfMemory;
    const prev = as.current_task_id;
    as.current_task_id = task_id;
    defer as.current_task_id = prev;

    var res = [_]Value{.{ .i32 = 0 }};
    try bctx.core_inst.invoke(bctx.core_func_name, &.{}, &res);
    const initial: u32 = @bitCast(res[0].i32);

    const seed = async_mod.seedTask(initial) catch return error.OutOfBoundsLoad; // bad callback code = guest fault
    const task = as.tasks.get(task_id) catch return error.OutOfBoundsLoad;
    task.state = seed.state;
    task.set_index = seed.set_index;
    return SUBTASK_RETURNED;
}

/// The graph-level `canon task.return` host func's flattened core signature:
/// `(value:i32) -> ()` (the minimal single-`u32`-lowered-result form). Returns
/// `BoundaryError!void` so a wiring fault propagates as a trap, never silently.
const TaskReturnSig = fn (*Caller, i32) BoundaryError!void;

/// Host trampoline for a graph child's `canon task.return(value)` (ADR-0195 d-a):
/// store the delivered value into the CURRENTLY-EXECUTING task's per-task `result`
/// slot. The graph runner sets `current_task_id` immediately before each guest
/// entry/callback invoke, so the value lands in the right subtask even with many
/// concurrent graph tasks (the per-task slot avoids the single-ctx-slot collision
/// the P3 runner's `WasiP2Ctx.task_return` would have across tasks). A
/// task.return with no executing task, or a stale task id, is a wiring fault →
/// trap (never a silent drop).
fn graphTaskReturn(caller: *Caller, value: i32) BoundaryError!void {
    const as = caller.data(GraphAsync);
    const task = as.tasks.get(as.current_task_id) catch return error.OutOfBoundsStore;
    task.result = @bitCast(value);
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

/// The error set a boundary trampoline returns: the callee-invoke's full
/// `InvokeError` (every guest `Trap` + `ProcExit`) plus the host-side
/// out-of-memory of the snapshot copy. Every variant is one `mapDispatchErr`
/// already narrows back to a `Trap` (or `ProcExit`), so a returned error becomes
/// a guest trap — NOT a silent fallback. The marshalling-failure cases map onto
/// the memory trap they are (`OutOfBoundsLoad`/`Store`), per the Canonical ABI +
/// untrusted-component sandboxing: a bad `(ptr,len)` must trap.
const BoundaryError = Instance.InvokeError || error{OutOfMemory};

/// The flattened core signature the boundary trampoline binds to:
/// `(w0:i32, w1:i32) -> i32`, returning `BoundaryError!u32` so a marshalling
/// failure PROPAGATES as a guest trap. `defineFuncCtx`'s thunk handles the
/// error-union form natively (a returned error becomes `anyerror!void` out of
/// the thunk), exactly like the WASI-P2 host trampolines. The two words are
/// interpreted per the WIT param list at call time — a string's (ptr,len) or two
/// flat scalars.
const BoundarySig = fn (*Caller, u32, u32) BoundaryError!u32;

/// Host trampoline: marshal the two flat words across the boundary per the
/// importer's WIT signature, invoke the callee's core func, return its flat
/// result. A `string` param is copied importer-memory → callee-memory via the
/// callee's realloc (canon lower → core → lift); flat scalars pass through. A
/// marshalling failure (out-of-bounds (ptr,len), invalid UTF-8, realloc
/// overflow) propagates as a trap — never a silent fallback.
fn boundaryTrampoline(caller: *Caller, w0: u32, w1: u32) BoundaryError!u32 {
    const bctx = caller.data(BoundaryCtx);
    return boundaryMarshal(caller, bctx, w0, w1);
}

fn boundaryMarshal(caller: *Caller, bctx: *BoundaryCtx, w0: u32, w1: u32) BoundaryError!u32 {
    const params = bctx.func_type.params;
    var args = [_]Value{ .{ .i32 = @bitCast(w0) }, .{ .i32 = @bitCast(w1) } };

    if (bctx.list_elem_size > 0) {
        // list<primitive>: w0=ptr, w1=COUNT in the IMPORTER's memory. Copy
        // count*elem_size bytes into the CALLEE's memory via its realloc
        // (aligned to the element size), since the callee reads its OWN memory.
        const caller_mem: Memory = caller.memory() orelse return error.OutOfBoundsLoad;
        const byte_count: u32 = w1 * bctx.list_elem_size;
        const src = try caller_mem.sliceAt(w0, byte_count); // OOB read → OutOfBoundsLoad trap
        const tmp = try caller.allocator().dupe(u8, src);
        defer caller.allocator().free(tmp);
        const cx = bctx.callee.canonContext();
        const ptr = cx.realloc(0, 0, bctx.list_elem_size, byte_count) catch return error.OutOfBoundsStore;
        if (@as(usize, ptr) + byte_count > cx.mem().len) return error.OutOfBoundsStore;
        @memcpy(cx.mem()[ptr..][0..byte_count], tmp);
        args[0] = .{ .i32 = @bitCast(ptr) };
        args[1] = .{ .i32 = @bitCast(w1) }; // count unchanged
    } else if (params.len == 1 and isString(params[0].ty)) {
        // Single string: w0=ptr, w1=len in the IMPORTER's memory. Snapshot the
        // bytes, then lower them into the CALLEE's memory via its realloc — the
        // callee reads its OWN memory, so the string must physically move.
        const caller_mem: Memory = caller.memory() orelse return error.OutOfBoundsLoad;
        const src = try caller_mem.sliceAt(w0, w1); // OOB read → OutOfBoundsLoad trap
        const tmp = try caller.allocator().dupe(u8, src);
        defer caller.allocator().free(tmp);
        const cx = bctx.callee.canonContext();
        const lowered = canon.lowerString(cx, tmp) catch |e| return stringErrToTrap(e);
        args[0] = .{ .i32 = @bitCast(lowered.ptr) };
        args[1] = .{ .i32 = @bitCast(lowered.packed_length) };
    }
    // else: two flat scalars pass straight through (no memory marshalling).

    var res = [_]Value{.{ .i32 = 0 }};
    try bctx.core_inst.invoke(bctx.core_func_name, &args, &res);
    return @bitCast(res[0].i32);
}

/// Map a Canonical-ABI string marshalling failure onto the memory trap it is:
/// an out-of-bounds (ptr,len) or invalid/over-long string crossing the boundary
/// is a guest fault → a memory trap (Canonical ABI traps, never silently coerces).
fn stringErrToTrap(e: canon.StringError) BoundaryError {
    return switch (e) {
        error.OutOfBounds, error.AllocFailed => error.OutOfBoundsStore,
        error.InvalidUtf8, error.StringTooLong, error.UnsupportedEncoding => error.OutOfBoundsLoad,
    };
}

/// The retptr-result trampoline's flattened core signature: `(retptr:i32) ->
/// ()`, returning `BoundaryError!void` so a marshalling failure PROPAGATES as a
/// guest trap (NOT a silent untouched-return-area fallback). A `string` RESULT
/// can't be a flat return word, so the importer passes a return-area pointer
/// (into its OWN memory) where the boundary writes the A-side `(ptr, len)` pair.
const RetPtrSig = fn (*Caller, u32) BoundaryError!void;

/// Host trampoline for `() -> string`: invoke the callee's core func (writing
/// the result string into the CALLEE's memory via a callee-side return area),
/// lift that string, then lower it into the IMPORTER's memory and write the
/// A-side `(ptr, len)` at the importer's retptr. A marshalling failure (out-of-
/// bounds return area, invalid UTF-8) propagates as a trap.
fn retPtrTrampoline(caller: *Caller, retptr: u32) BoundaryError!void {
    const bctx = caller.data(BoundaryCtx);
    return retPtrMarshal(caller, bctx, retptr);
}

fn retPtrMarshal(caller: *Caller, bctx: *BoundaryCtx, retptr: u32) BoundaryError!void {
    // 1. Allocate a return area in the CALLEE's memory and invoke its core func,
    //    which writes the result string (ptr,len) there (B writes B's memory).
    const callee_cx = bctx.callee.canonContext();
    const callee_ret = callee_cx.realloc(0, 0, 4, 8) catch return error.OutOfBoundsStore;
    var args = [_]Value{.{ .i32 = @bitCast(callee_ret) }};
    var res = [_]Value{};
    try bctx.core_inst.invoke(bctx.core_func_name, &args, &res);

    // 2. Lift the result string from the CALLEE's memory at its return area.
    if (@as(usize, callee_ret) + 8 > callee_cx.mem().len) return error.OutOfBoundsLoad;
    const b_ptr = std.mem.readInt(u32, callee_cx.mem()[callee_ret..][0..4], .little);
    const b_len = std.mem.readInt(u32, callee_cx.mem()[callee_ret + 4 ..][0..4], .little);
    const lifted = canon.liftString(callee_cx, b_ptr, b_len) catch |e| return stringErrToTrap(e);

    // 3. Lower the string into the IMPORTER's memory (snapshot first: the lift
    //    borrows callee memory, the lower realloc may move it). Then write the
    //    A-side (ptr,len) at the importer's retptr in the importer's memory.
    const importer = bctx.importer orelse return error.OutOfBoundsStore;
    const tmp = try caller.allocator().dupe(u8, lifted);
    defer caller.allocator().free(tmp);
    const importer_cx = importer.canonContext();
    const lowered = canon.lowerString(importer_cx, tmp) catch |e| return stringErrToTrap(e);
    if (@as(usize, retptr) + 8 > importer_cx.mem().len) return error.OutOfBoundsStore;
    std.mem.writeInt(u32, importer_cx.mem()[retptr..][0..4], lowered.ptr, .little);
    std.mem.writeInt(u32, importer_cx.mem()[retptr + 4 ..][0..4], lowered.packed_length, .little);
}

/// The `(string) -> string` boundary's flattened core signature:
/// `(param_ptr:i32, param_len:i32, retptr:i32) -> ()`, returning
/// `BoundaryError!void` so a marshalling failure PROPAGATES as a guest trap. It
/// composes the string PARAM lower (importer-memory → callee-memory) with the
/// string RESULT lift+lower (callee-memory → importer-memory, written at retptr).
const StrRetStrSig = fn (*Caller, u32, u32, u32) BoundaryError!void;

/// Host trampoline for `(string) -> string`: lower the caller's string param
/// into the CALLEE's memory (via the callee's realloc), invoke the callee core
/// func with `(callee_ptr, callee_len, callee_retptr)`, then lift the callee's
/// returned string and lower it into the IMPORTER's memory, writing the A-side
/// `(ptr,len)` at the importer's retptr. A marshalling failure (out-of-bounds
/// (ptr,len), invalid UTF-8, realloc overflow) propagates as a trap — never a
/// silent fallback.
fn strRetStrTrampoline(caller: *Caller, param_ptr: u32, param_len: u32, retptr: u32) BoundaryError!void {
    const bctx = caller.data(BoundaryCtx);
    const callee_cx = bctx.callee.canonContext();

    // 1. Lower the caller's string param into the CALLEE's memory (snapshot the
    //    caller bytes first: the callee realloc may grow/move its own memory).
    const caller_mem: Memory = caller.memory() orelse return error.OutOfBoundsLoad;
    const src = try caller_mem.sliceAt(param_ptr, param_len); // OOB read → trap
    const param_tmp = try caller.allocator().dupe(u8, src);
    defer caller.allocator().free(param_tmp);
    const lowered_param = canon.lowerString(callee_cx, param_tmp) catch |e| return stringErrToTrap(e);

    // 2. Allocate the callee's return area and invoke its core func, which writes
    //    the result string (ptr,len) there (B writes B's memory).
    const callee_ret = callee_cx.realloc(0, 0, 4, 8) catch return error.OutOfBoundsStore;
    var args = [_]Value{
        .{ .i32 = @bitCast(lowered_param.ptr) },
        .{ .i32 = @bitCast(lowered_param.packed_length) },
        .{ .i32 = @bitCast(callee_ret) },
    };
    var res = [_]Value{};
    try bctx.core_inst.invoke(bctx.core_func_name, &args, &res);

    // 3. Lift the result string from the CALLEE's memory at its return area.
    if (@as(usize, callee_ret) + 8 > callee_cx.mem().len) return error.OutOfBoundsLoad;
    const b_ptr = std.mem.readInt(u32, callee_cx.mem()[callee_ret..][0..4], .little);
    const b_len = std.mem.readInt(u32, callee_cx.mem()[callee_ret + 4 ..][0..4], .little);
    const lifted = canon.liftString(callee_cx, b_ptr, b_len) catch |e| return stringErrToTrap(e);

    // 4. Lower the string into the IMPORTER's memory (snapshot first: the lift
    //    borrows callee memory, the lower realloc may move it). Then write the
    //    A-side (ptr,len) at the importer's retptr in the importer's memory.
    const importer = bctx.importer orelse return error.OutOfBoundsStore;
    const tmp = try caller.allocator().dupe(u8, lifted);
    defer caller.allocator().free(tmp);
    const importer_cx = importer.canonContext();
    const lowered = canon.lowerString(importer_cx, tmp) catch |e| return stringErrToTrap(e);
    if (@as(usize, retptr) + 8 > importer_cx.mem().len) return error.OutOfBoundsStore;
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
