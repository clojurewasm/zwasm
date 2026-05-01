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

    pub const zero: Value = .{ .bits64 = 0 };

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

/// Control-label record. `block` / `if` push a label whose
/// `target_pc` points one past the matching `end`; `loop` pushes a
/// label whose `target_pc` points just after the `loop` opcode (so
/// that `br` to a loop re-enters the body). `arity` is the number
/// of result values transferred to the operand stack on branch
/// (0 for blocks/loops without a result type, 1 for the MVP
/// single-valtype block-types).
pub const Label = struct {
    height: u32,
    arity: u32,
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

/// Per-instance interpreter state. Owns linear memory + globals
/// (heap-backed); operand and frame stacks are inline.
pub const Runtime = struct {
    alloc: Allocator,
    memory: []u8 = &.{},
    globals: []Value = &.{},
    /// Module function table — `funcs[i]` is the ZirFunc for the
    /// i-th function in the module's index space (imports first,
    /// then defined). The `call` handler indexes into this; the
    /// runner sets it before invoking the entry function.
    funcs: []const *const zir.ZirFunc = &.{},
    /// Dispatch table used by the active interp run. Set by
    /// `src/interp/dispatch.zig`'s `run`; the `call` handler
    /// needs it to recursively dispatch the callee body.
    table: ?*const dispatch_table.DispatchTable = null,

    operand_buf: [max_operand_stack]Value = undefined,
    operand_len: u32 = 0,

    frame_buf: [max_frame_stack]Frame = undefined,
    frame_len: u32 = 0,

    pub fn init(alloc: Allocator) Runtime {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Runtime) void {
        if (self.memory.len > 0) self.alloc.free(self.memory);
        if (self.globals.len > 0) self.alloc.free(self.globals);
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
