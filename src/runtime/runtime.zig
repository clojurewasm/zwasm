//! WASM Spec §4.2 "Runtime Structure" — Runtime central handle.
//!
//! Per ADR-0023 §3 P-A (single source of truth) and §3 P-D (vertical
//! slicing within `runtime/`): this file owns the `Runtime` struct
//! itself plus the small support types (`TableInstance`, `HostCall`)
//! that don't yet justify their own files. Spec §4.2 concepts that
//! do justify their own files are extracted to siblings:
//!
//! - `value.zig` — `Value`, `FuncEntity`
//! - `trap.zig`  — `Trap`, `TraceEvent`, `TraceCallback`
//! - `frame.zig` — `Frame`, `Label`, `max_*` stack-bound constants
//!
//! Module / Engine / Store / per-instance types follow in
//! ADR-0023 §7 items 4–6. Until they land, `instance` is an opaque
//! back-pointer (the `?*anyopaque` field below).
//!
//! Memory discipline: bounded inline buffers for both operand
//! stack (4096 slots) and frame stack (256 frames) per ROADMAP
//! §P3 — no allocation per call. Linear memory and global slots
//! are heap-allocated once at instance construction.
//!
//! Zone 1 (`src/runtime/`) — may import Zone 0 (`util/leb128.zig`)
//! and Zone 1 (`ir/`). MUST NOT import Zone 2+ (`interp/`, `jit*/`,
//! `wasi/`, `c_api/`, `cli/`).

const std = @import("std");

pub const zir = @import("../ir/zir.zig");
pub const dispatch_table = @import("../ir/dispatch_table.zig");

const value_mod = @import("value.zig");
const trap_mod = @import("trap.zig");
const frame_mod = @import("frame.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;
const FuncType = zir.FuncType;
const InterpCtx = dispatch_table.InterpCtx;

// ============================================================
// Re-exports — keep `runtime.X` callsites stable across the
// sub-file split. Each sibling file is the source of truth; this
// file presents the unified `Runtime`-package surface.
// ============================================================

pub const Value = value_mod.Value;
pub const FuncEntity = value_mod.FuncEntity;

pub const Trap = trap_mod.Trap;
pub const TraceEvent = trap_mod.TraceEvent;
pub const TraceCallback = trap_mod.TraceCallback;

pub const Frame = frame_mod.Frame;
pub const Label = frame_mod.Label;
pub const max_operand_stack = frame_mod.max_operand_stack;
pub const max_frame_stack = frame_mod.max_frame_stack;
pub const max_label_stack = frame_mod.max_label_stack;

pub const Module = @import("module.zig").Module;
pub const Engine = @import("engine.zig").Engine;
pub const Store = @import("store.zig").Store;
pub const Zombie = @import("store.zig").Zombie;
pub const Instance = @import("instance/instance.zig").Instance;
pub const ExportType = @import("instance/instance.zig").ExportType;

/// Free a typed slice via `Allocator.rawFree`, skipping the
/// `@memset(slice, undefined)` poisoning that `Allocator.free`
/// performs. Required by `Runtime.deinit` per ADR-0014 §2.2 /
/// 6.K.2 to keep cross-module-imported slices intact when an
/// importer tears down.
inline fn rawFreeOwned(alloc: Allocator, comptime T: type, slice: []T) void {
    if (slice.len == 0) return;
    const bytes = std.mem.sliceAsBytes(slice);
    const non_const = @constCast(bytes);
    alloc.rawFree(
        non_const,
        std.mem.Alignment.fromByteUnits(@alignOf(T)),
        @returnAddress(),
    );
}

/// Runtime counterpart of `zir.TableEntry` — actually holds the
/// reference cells. The runner allocates `refs` and threads the
/// instance via `Runtime.tables`.
pub const TableInstance = struct {
    refs: []Value,
    elem_type: zir.ValType,
    max: ?u32 = null,
};

/// One host-call binding — stored at `Runtime.host_calls[i]`
/// for each `i` that corresponds to an imported function. The
/// `call <i>` instruction short-circuits to `fn_ptr(rt, ctx)`
/// when this slot is non-null. The C-API binding (Phase 4)
/// builds these for `(import "wasi_snapshot_preview1" ...)`
/// entries; ctx is typically a `*wasi.Host`.
pub const HostCall = struct {
    fn_ptr: *const fn (*Runtime, *anyopaque) anyerror!void,
    ctx: *anyopaque,
};

/// Per-instance interpreter state. Owns linear memory + globals
/// (heap-backed); operand and frame stacks are inline.
pub const Runtime = struct {
    /// Allocator that backs every runtime-owned slice (memory,
    /// globals, tables.refs, elems, func_entities, dropped flags).
    /// In the c_api path this is the per-instance arena allocator
    /// (per ADR-0014 §2.2 / 6.K.2) — `Runtime.deinit`'s `free` calls
    /// then degrade to no-ops and the arena reclaims everything
    /// uniformly when `Instance.arena.deinit()` runs at instance
    /// teardown. Tests may pass `testing.allocator` directly when
    /// they manage their own slices; `deinit` then performs real
    /// frees.
    alloc: Allocator,
    /// Optional back-pointer to the owning `c_api/instance.Instance`,
    /// stored as `?*anyopaque` to keep Zone 1 (`src/runtime/`) free
    /// of any Zone 3 import. Used by §9.6 / 6.K.3 cross-module
    /// dispatch to recover the source instance from a FuncEntity's
    /// runtime back-ref. Not consulted on the hot path.
    instance: ?*anyopaque = null,
    memory: []u8 = &.{},
    /// Module global slots. **Pointer-per-entry** so cross-module
    /// global imports alias the source instance's storage (per
    /// ADR-0014 §2.1 / 6.K.3). Defined globals point at slots in
    /// `globals_storage`; imported globals point at the source
    /// instance's slot. global.get / global.set dereference.
    globals: []*Value = &.{},
    /// Owning storage for **defined** globals. Imported globals
    /// alias source storage and don't touch this slice. Arena-
    /// owned in the c_api path; tests construct in-place.
    globals_storage: []Value = &.{},
    /// Module function table — `funcs[i]` is the ZirFunc for the
    /// i-th function in the module's index space (imports first,
    /// then defined). The `call` handler indexes into this; the
    /// runner sets it before invoking the entry function.
    funcs: []const *const zir.ZirFunc = &.{},
    /// Parallel-to-`funcs` FuncEntity array (Wasm 2.0 funcref
    /// encoding per ADR-0014 §2.1 / 6.K.1). `ref.func i` /
    /// element-segment init resolve to `&func_entities[i]` and
    /// store its address in `Value.ref`. `call_indirect` reverses
    /// the cast to recover the source runtime + func_idx.
    /// Allocated in `instantiateRuntime` on the per-instance
    /// arena; tests construct stub slices directly.
    func_entities: []FuncEntity = &.{},
    /// Parallel-to-`funcs` host-call table. When the dispatch
    /// loop's `call` op routes to index `i` and `host_calls[i]`
    /// is non-null, the host thunk runs instead of dispatching
    /// the ZirFunc body. Length 0 (empty) when no imports
    /// resolved through the binding.
    host_calls: []const ?HostCall = &.{},
    /// Module data segments. Borrowed; the runner keeps the
    /// decoded data alive for as long as `Runtime` references it.
    /// Used by `memory.init` (Wasm 2.0 §9.2 / 2.3 chunk 4b).
    datas: []const []const u8 = &.{},
    /// Per-segment dropped flag. `data.drop` flips entries here so
    /// later `memory.init` calls trap. Owned (heap-allocated when
    /// `datas.len > 0`); freed in deinit.
    data_dropped: []bool = &.{},
    /// Module tables (Wasm 2.0 §9.2 / 2.3 chunks 5c / 5c-2).
    /// Mutable so `table.grow` can swap a TableInstance's `refs`
    /// slice header for a longer one. The owner of each refs
    /// slice (typically the runner / test setup) is responsible
    /// for using the same allocator that grow ends up reallocating
    /// against (`rt.alloc`) and for freeing the final slice after
    /// runtime tear-down.
    tables: []TableInstance = &.{},
    /// Module element segments resolved to runtime ref values
    /// (Wasm 2.0 §9.2 / 2.3 chunk 5d-2). Borrowed; the runner
    /// translates funcidxs from the decoded ElementSegment into
    /// these slices at instantiation time.
    elems: []const []const Value = &.{},
    /// Per-segment dropped flag for `elem.drop`. Owned (heap-
    /// allocated when `elems.len > 0`); freed in deinit.
    elem_dropped: []bool = &.{},
    /// Module type section. `call_indirect` reads expected
    /// signatures here at runtime to raise
    /// IndirectCallTypeMismatch when the table cell's resolved
    /// callee disagrees. Borrowed by the runner.
    module_types: []const zir.FuncType = &.{},
    /// Dispatch table used by the active interp run. Set by
    /// `src/interp/dispatch.zig`'s `run`; the `call` handler
    /// needs it to recursively dispatch the callee body.
    table: ?*const dispatch_table.DispatchTable = null,

    operand_buf: [max_operand_stack]Value = undefined,
    operand_len: u32 = 0,

    frame_buf: [max_frame_stack]Frame = undefined,
    frame_len: u32 = 0,

    /// Optional per-instruction trace hook (Phase 6 / §9.6 / 6.A
    /// per ADR-0013). When non-null, `dispatch.step` invokes
    /// `trace_cb(trace_ctx, event)` after each handler call.
    /// Zero-cost when null.
    trace_cb: ?TraceCallback = null,
    trace_ctx: ?*anyopaque = null,

    pub fn init(alloc: Allocator) Runtime {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Runtime) void {
        // Per ADR-0014 §2.2 / 6.K.2: all resources are arena-owned
        // in the c_api path; tests pass `testing.allocator` directly.
        //
        // Critically, this routes through `rawFree` rather than
        // `Allocator.free`. The wrapper at `Allocator.free`
        // `@memset(slice, undefined)`s the bytes (= 0xAA) BEFORE
        // delegating to the underlying allocator's `rawFree` — and
        // that poisoning lands on the *bytes themselves*. For arena
        // allocators whose `rawFree` is the no-op trailing-shrink
        // check, that means a cross-module import that aliased the
        // source instance's memory slice would see its bytes
        // overwritten with 0xAA whenever any importer's runtime
        // tears down. `rawFree` skips the wrapper's poisoning, so
        // arena-owned slices stay intact while testing.allocator-
        // owned slices still release without leaking.
        rawFreeOwned(self.alloc, u8, self.memory);
        rawFreeOwned(self.alloc, *Value, self.globals);
        rawFreeOwned(self.alloc, Value, self.globals_storage);
        rawFreeOwned(self.alloc, bool, self.data_dropped);
        rawFreeOwned(self.alloc, bool, self.elem_dropped);
    }

    pub fn pushOperand(self: *Runtime, v: Value) Trap!void {
        if (self.operand_len == max_operand_stack) return Trap.StackOverflow;
        self.operand_buf[self.operand_len] = v;
        self.operand_len += 1;
    }

    pub fn popOperand(self: *Runtime) Value {
        std.debug.assert(self.operand_len > 0);
        self.operand_len -= 1;
        return self.operand_buf[self.operand_len];
    }

    pub fn topOperand(self: *const Runtime) Value {
        std.debug.assert(self.operand_len > 0);
        return self.operand_buf[self.operand_len - 1];
    }

    pub fn pushFrame(self: *Runtime, frame: Frame) Trap!void {
        if (self.frame_len == max_frame_stack) return Trap.CallStackExhausted;
        self.frame_buf[self.frame_len] = frame;
        self.frame_len += 1;
    }

    pub fn popFrame(self: *Runtime) Frame {
        std.debug.assert(self.frame_len > 0);
        self.frame_len -= 1;
        return self.frame_buf[self.frame_len];
    }

    pub fn currentFrame(self: *Runtime) *Frame {
        std.debug.assert(self.frame_len > 0);
        return &self.frame_buf[self.frame_len - 1];
    }

    pub fn toOpaque(self: *Runtime) *InterpCtx {
        return @ptrCast(self);
    }

    pub fn fromOpaque(p: *InterpCtx) *Runtime {
        return @ptrCast(@alignCast(p));
    }
};

// ============================================================
// Tests — Runtime / sub-file integration.
// Per-type tests live in the owning sub-files (value.zig /
// trap.zig / frame.zig).
// ============================================================

const testing = std.testing;

test "Runtime.init / deinit clean (no allocations)" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.memory.len);
    try testing.expectEqual(@as(usize, 0), r.globals.len);
    try testing.expectEqual(@as(u32, 0), r.operand_len);
    try testing.expectEqual(@as(u32, 0), r.frame_len);
}

test "Runtime: push/pop operand stack round-trip" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    try r.pushOperand(Value.fromI32(1));
    try r.pushOperand(Value.fromI32(2));
    try r.pushOperand(Value.fromI64(0x123456789));

    try testing.expectEqual(@as(u32, 3), r.operand_len);
    try testing.expectEqual(@as(i64, 0x123456789), r.popOperand().i64);
    try testing.expectEqual(@as(i32, 2), r.popOperand().i32);
    try testing.expectEqual(@as(i32, 1), r.popOperand().i32);
    try testing.expectEqual(@as(u32, 0), r.operand_len);
}

test "Runtime: push/pop frame stack round-trip" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    try r.pushFrame(.{
        .sig = sig,
        .locals = &.{},
        .operand_base = 0,
        .pc = 0,
    });
    try r.pushFrame(.{
        .sig = sig,
        .locals = &.{},
        .operand_base = 7,
        .pc = 42,
    });
    try testing.expectEqual(@as(u32, 2), r.frame_len);

    const f1 = r.popFrame();
    try testing.expectEqual(@as(u32, 7), f1.operand_base);
    try testing.expectEqual(@as(u32, 42), f1.pc);

    const f0 = r.popFrame();
    try testing.expectEqual(@as(u32, 0), f0.pc);
}

test "Runtime: operand-stack overflow trips StackOverflow" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    var i: u32 = 0;
    while (i < max_operand_stack) : (i += 1) {
        try r.pushOperand(Value.zero);
    }
    try testing.expectError(Trap.StackOverflow, r.pushOperand(Value.zero));
}

test "Runtime: frame-stack overflow trips CallStackExhausted" {
    var r = Runtime.init(testing.allocator);
    defer r.deinit();

    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var i: u32 = 0;
    while (i < max_frame_stack) : (i += 1) {
        try r.pushFrame(.{ .sig = sig, .locals = &.{}, .operand_base = 0, .pc = 0 });
    }
    try testing.expectError(
        Trap.CallStackExhausted,
        r.pushFrame(.{ .sig = sig, .locals = &.{}, .operand_base = 0, .pc = 0 }),
    );
}

test "Trap: error set carries the spec-conformant trap conditions" {
    // Compile-time spot-check that the named tags exist on the Trap
    // error set. Returning each value would discard it; storing into
    // an `anyerror` slot keeps the code path live.
    const traps: [9]anyerror = .{
        Trap.Unreachable,            Trap.DivByZero,
        Trap.IntOverflow,            Trap.InvalidConversionToInt,
        Trap.OutOfBoundsLoad,        Trap.OutOfBoundsStore,
        Trap.OutOfBoundsTableAccess, Trap.UninitializedElement,
        Trap.IndirectCallTypeMismatch,
    };
    try testing.expectEqual(@as(usize, 9), traps.len);
}
