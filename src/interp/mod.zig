//! Threaded-code interpreter scaffold (Phase 2 / §9.2 / 2.0).
//!
//! 2.0 declares the runtime data shapes only — no dispatch loop,
//! no opcode semantics. Per ROADMAP §P13 (type up-front), the
//! invariants of operand-stack / frame-stack / Value / Trap are
//! fixed here so later tasks (2.1 dispatch, 2.2 MVP handlers,
//! 2.3 Wasm-2.0 features, 2.4 trap semantics) can populate
//! behaviour without redesigning the substrate.
//!
//! Memory discipline: bounded inline buffers for both operand
//! stack (4096 slots) and frame stack (256 frames) per ROADMAP
//! §P3 — no allocation per call. Linear memory and global slots
//! are heap-allocated once at instance construction.
//!
//! Zone 2 (`src/interp/`) — may import Zone 0 (`util/leb128.zig`)
//! and Zone 1 (`ir/`). MUST NOT import Zone 2-other (`jit*/`,
//! `wasi/`) or Zone 3 (`c_api/`, `cli/`).

const std = @import("std");

pub const zir = @import("../ir/zir.zig");
pub const dispatch_table = @import("../ir/dispatch_table.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;
const FuncType = zir.FuncType;
const InterpCtx = dispatch_table.InterpCtx;

/// 64-bit value slot. The dispatch loop knows the type from the
/// `ZirOp`; the union never carries a runtime tag (per §P3
/// cold-start: no per-slot type byte). Float values are stored as
/// their IEEE-754 bit pattern via `bits64` on entry/exit so NaN
/// canonicalisation can be deferred to the boundary opcodes that
/// need it (Wasm 1.0 §6.2.3).
pub const Value = extern union {
    i32: i32,
    u32: u32,
    i64: i64,
    u64: u64,
    f32: f32,
    f64: f64,
    bits64: u64,
    /// Reference value (Wasm 2.0 §9.2 / 2.3 chunk 5). Funcref:
    /// `@intFromPtr(*const FuncEntity)` — the pointer carries
    /// source-runtime identity so cross-module `call_indirect`
    /// can route to the source's function table without a
    /// separate routing layer (per ADR-0014 §2.1 / 6.K.1).
    /// Externref: opaque 64-bit host handle (unchanged). The
    /// sentinel `null_ref` represents the spec null reference;
    /// it equals literal `0` because `c_allocator.alloc` cannot
    /// return address 0 on any of the three target platforms
    /// (Mac aarch64 darwin, Linux x86_64 glibc/musl, Windows
    /// x86_64 ucrt) per the C-standard `malloc` contract.
    ref: u64,

    pub const zero: Value = .{ .bits64 = 0 };
    pub const null_ref: u64 = 0;

    pub fn fromI32(v: i32) Value {
        return .{ .i32 = v };
    }
    pub fn fromI64(v: i64) Value {
        return .{ .i64 = v };
    }
    pub fn fromF32Bits(b: u32) Value {
        return .{ .bits64 = b };
    }
    pub fn fromF64Bits(b: u64) Value {
        return .{ .bits64 = b };
    }
    pub fn fromRef(r: u64) Value {
        return .{ .ref = r };
    }

    /// Encode a `*FuncEntity` as a funcref `Value`. The pointer
    /// must outlive every read of this Value (its lifetime is
    /// tied to the owning Runtime's `func_entities` array, which
    /// the per-instance arena holds for the Runtime's lifetime).
    pub fn fromFuncRef(fe: *const FuncEntity) Value {
        return .{ .ref = @intFromPtr(fe) };
    }

    /// Decode a funcref `Value` to its `*const FuncEntity` source,
    /// or `null` if the cell holds the null reference.
    pub fn refAsFuncEntity(v: Value) ?*const FuncEntity {
        if (v.ref == null_ref) return null;
        return @ptrFromInt(v.ref);
    }
};

comptime {
    // Locks in the platform contract above: any future change to
    // null_ref must re-survey the malloc guarantees on all three
    // target hosts. A change here without an ADR is a §18 deviation.
    std.debug.assert(Value.null_ref == 0);
}

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

/// Per-runtime function handle. One entry per index in
/// `Runtime.funcs`; allocated in `instantiateRuntime`. A funcref
/// `Value` stores `@intFromPtr(*const FuncEntity)` so dereference
/// reveals which Runtime owns the callee body — the encoding
/// 6.K.3 needs to drop the cross-module-import error returns.
///
/// Per ADR-0014 §2.1 / 6.K.1: the source runtime back-ref lives
/// here (rather than baked into the Runtime via 6.K.2's Instance
/// back-ref) because the Value's encoding contract is what matters
/// for the table cell — every consumer dereferences the FuncEntity
/// and reads `runtime` + `func_idx` from a single cache line.
pub const FuncEntity = struct {
    /// Runtime whose `funcs[func_idx]` (and `host_calls[func_idx]`
    /// when imported) describes the callee body.
    runtime: *Runtime,
    /// Index into `runtime.funcs`.
    func_idx: u32,
};

/// Trap conditions. The dispatch loop returns one of these on the
/// `Trap!` error union when a runtime-checked invariant fails.
/// `OutOfMemory` is included so allocator-backed paths can bubble
/// up uniformly.
pub const Trap = error{
    Unreachable,
    DivByZero,
    IntOverflow,
    InvalidConversionToInt,
    OutOfBoundsLoad,
    OutOfBoundsStore,
    OutOfBoundsTableAccess,
    UninitializedElement,
    IndirectCallTypeMismatch,
    StackOverflow,
    CallStackExhausted,
    OutOfMemory,
};

pub const max_operand_stack: u32 = 4096;
pub const max_frame_stack: u32 = 256;
pub const max_label_stack: u32 = 128;

/// Per-instruction trace event (Phase 6 / §9.6 / 6.A per ADR-0013).
/// Emitted post-handler when `Runtime.trace_cb` is set; consumed by
/// the runtime-asserting WAST runner's `--trace` mode and by §9.6 /
/// 6.E interp behaviour bug investigation. Zero-cost when disabled
/// (one predicted-not-taken branch in the dispatch loop).
pub const TraceEvent = struct {
    pc: u32,
    op: zir.ZirOp,
    /// Top-of-stack value AFTER the handler ran. `null` when the
    /// stack is empty (e.g. after a `drop` that empties it).
    operand_top: ?Value,
    frame_depth: u32,
};

pub const TraceCallback = *const fn (ctx: *anyopaque, ev: TraceEvent) void;

/// Control-label record. `block` / `if` push a label whose
/// `target_pc` points one past the matching `end`; `loop` pushes a
/// label whose `target_pc` points just after the `loop` opcode (so
/// that `br` to a loop re-enters the body).
///
/// Two arities because `loop` distinguishes them: `arity` is the
/// number of result values the matching `end` transfers (i.e. the
/// blocktype's result count); `branch_arity` is the number a `br`
/// to this label transfers (= results for block/if; = params for
/// loop, which is 0 in Wasm 1.0 — multivalue loop-with-params is
/// a Phase 2 carry-over per ROADMAP §9.2 chunk 3b).
pub const Label = struct {
    height: u32,
    arity: u32,
    branch_arity: u32,
    target_pc: u32,
};

/// Per-call activation record. `locals` holds params followed by
/// declared locals (validator's local-index space). `operand_base`
/// is the operand-stack height at frame entry — `end` / `return`
/// pop the stack down to this height before pushing results.
/// `pc` is the instruction index into the corresponding
/// `ZirFunc.instrs` array.
pub const Frame = struct {
    sig: FuncType,
    locals: []Value,
    operand_base: u32,
    pc: u32,
    /// Borrowed pointer to the active `ZirFunc` so control-flow
    /// handlers can resolve `instr.payload` (a block index) into
    /// `BlockInfo` (`start_inst`, `end_inst`, `else_inst`). Set
    /// by `call` / external runner; left null for ad-hoc test
    /// frames that don't exercise control flow.
    func: ?*const zir.ZirFunc = null,
    /// Set by `end` / `return` handlers to signal the dispatch
    /// loop to break out of the body. Distinct from `pc >=
    /// instrs.len` so handlers can stop early without computing
    /// the bound themselves.
    done: bool = false,

    label_buf: [max_label_stack]Label = undefined,
    label_len: u32 = 0,

    pub fn pushLabel(self: *Frame, l: Label) Trap!void {
        if (self.label_len == max_label_stack) return Trap.StackOverflow;
        self.label_buf[self.label_len] = l;
        self.label_len += 1;
    }

    pub fn popLabel(self: *Frame) Label {
        std.debug.assert(self.label_len > 0);
        self.label_len -= 1;
        return self.label_buf[self.label_len];
    }

    /// Index 0 = innermost. Caller must ensure depth < label_len.
    pub fn labelAt(self: *Frame, depth: u32) Label {
        std.debug.assert(depth < self.label_len);
        return self.label_buf[self.label_len - 1 - depth];
    }
};

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
    /// stored as `?*anyopaque` to keep Zone 2 (`src/interp/`) free
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
// Tests
// ============================================================

const testing = std.testing;

test "Value: extern union slot is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Value));
}

test "Value.fromI32 / fromI64 round-trip" {
    const a = Value.fromI32(-7);
    try testing.expectEqual(@as(i32, -7), a.i32);

    const b = Value.fromI64(0x7FFF_FFFF_FFFF_FFFF);
    try testing.expectEqual(@as(i64, 0x7FFF_FFFF_FFFF_FFFF), b.i64);
}

test "Value.fromF32Bits / fromF64Bits store IEEE bits" {
    const f32_one_bits: u32 = 0x3F800000;
    const a = Value.fromF32Bits(f32_one_bits);
    try testing.expectEqual(@as(u64, f32_one_bits), a.bits64);

    const f64_one_bits: u64 = 0x3FF0_0000_0000_0000;
    const b = Value.fromF64Bits(f64_one_bits);
    try testing.expectEqual(f64_one_bits, b.bits64);
}

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
