//! Wasm function-body **type-stack + control-stack validator**
//! (Phase 1 / §9.1 / 1.5).
//!
//! Single-pass over a function body's expression bytes. Tracks the
//! operand stack and the control stack per Wasm 1.0 spec §3.3
//! (validation) and §3.3.5 (polymorphic stack after `unreachable`,
//! `br`, `return`). Uses bounded inline stacks per ROADMAP §P3
//! (cold-start) — no per-call allocation.
//!
//! Scope is the MVP opcode subset needed to wire the validator into
//! the Phase 1 pipeline. The full Wasm 1.0 opcode set lands when
//! per-feature modules register opcode-typing handlers via
//! `DispatchTable` in §9.1 / 1.7. The current `dispatch` switch
//! marks each not-yet-implemented MVP opcode with `error.NotImplemented`
//! rather than silently passing — once 1.7 lands the giant switch
//! migrates to a dispatch-table lookup per ROADMAP §A12.
//!
//! Zone 1 (`src/frontend/`) — may import Zone 0 (`src/support/leb128.zig`)
//! and Zone 1 (`src/ir/`). No upward imports.

const std = @import("std");

const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");

const ValType = zir.ValType;
const FuncType = zir.FuncType;
const BlockKind = zir.BlockKind;

/// Either a concrete ValType, or `bot` (polymorphic-any) used during
/// the unreachable-stack window per spec §3.3.5.
pub const TypeOrBot = union(enum) {
    known: ValType,
    bot,
};

pub const Error = error{
    StackUnderflow,
    StackTypeMismatch,
    UnexpectedEnd,
    UnexpectedOpcode,
    InvalidOpcode,
    BadBlockType,
    BadValType,
    InvalidLocalIndex,
    InvalidFuncIndex,
    InvalidGlobalIndex,
    ImmutableGlobal,
    InvalidBranchDepth,
    UnclosedFrames,
    TrailingBytes,
    OperandStackOverflow,
    ControlStackOverflow,
    ArityMismatch,
    NotImplemented,
} || leb128.Error;

pub const GlobalEntry = struct {
    valtype: ValType,
    mutable: bool,
};

pub const max_operand_stack: usize = 1024;
pub const max_control_stack: usize = 1024;

/// Block result type. Wasm 1.0 binary block-types are `empty` (0x40)
/// or `single` (one valtype byte). Wasm 2.0 multivalue extends this
/// to `multi` via an s33 typeidx referencing a FuncType — both for
/// function frames whose signature has > 1 result, and for blocks /
/// loops / ifs whose `(param ...)` and / or `(result ...)` lists
/// have multi-value shape (D-035 chunk-d035-a).
pub const BlockType = union(enum) {
    empty,
    single: ValType,
    multi: []const ValType,
};

/// Composite block signature: the `(param ...)` / `(result ...)`
/// lists Wasm 2.0 typeidx blocktypes carry. Wasm 1.0 forms always
/// have `start = .empty`; only the `end` slot is populated. For
/// loops, `start` is the label type (br to a loop transfers the
/// param values); for blocks / ifs, `end` is the label type.
pub const BlockTypeFull = struct {
    start: BlockType,
    end: BlockType,
};

/// Map a slice of valtypes to the corresponding `BlockType` form:
/// 0-length → `.empty`, 1-length → `.single`, ≥2 → `.multi`.
fn blockTypeOfSlice(types: []const ValType) BlockType {
    return switch (types.len) {
        0 => .empty,
        1 => .{ .single = types[0] },
        else => .{ .multi = types },
    };
}

const ControlFrame = struct {
    kind: BlockKind,
    /// Block's `(param ...)` types — popped from the outer stack
    /// when the block opens, and re-pushed as the block body's
    /// initial operand-stack contents. Wasm 1.0 → always `.empty`.
    /// Loops use this as their label type so a `br` target re-
    /// transfers the params (Wasm 2.0 §3.4.4).
    start_type: BlockType,
    /// Block's `(result ...)` types — popped from the inner stack
    /// at `end` (verifying the body produced them) and re-pushed
    /// onto the outer stack. Blocks / ifs use this as their label
    /// type. Single-result Wasm 1.0 forms use `.single`; empty
    /// uses `.empty`; multi-value 2.0 typeidx may use `.multi`.
    end_type: BlockType,
    /// Operand-stack height at frame entry, **after** params have
    /// been popped + re-pushed (i.e. the height seen from outside
    /// the block, before the block's own params land on the
    /// stack). `popAny` floor checks against this so the block
    /// body cannot pop below the outer stack.
    height: u32,
    /// True after `unreachable` / `br` / `return` until this frame's
    /// `end` (or `else`, which resets it for the alternate branch).
    unreachable_flag: bool,

    /// Types popped by `br` to this label. Wasm 2.0 §3.4.4: blocks
    /// / ifs use the frame's *end* types; loops use the frame's
    /// *start* types.
    fn labelType(self: ControlFrame) BlockType {
        return switch (self.kind) {
            .loop => self.start_type,
            .block, .if_then, .else_open => self.end_type,
        };
    }

    /// Types pushed back onto the operand stack at `end`.
    fn endType(self: ControlFrame) BlockType {
        return self.end_type;
    }
};

/// Validate a single function body expression.
///
/// `sig.params` and `locals` together index `local.get` / `local.set`
/// (params first, then declared locals). `body` is the raw expression
/// bytes — opcode stream terminated by an outermost `end` that closes
/// the implicit function frame. `func_types` carries the module-wide
/// per-function signature table so `call N` can type-check; pass an
/// empty slice for the standalone-function case.
pub fn validateFunction(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
) Error!void {
    var v = Validator{
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
    };
    try v.run();
}

const Validator = struct {
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    pos: usize,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,

    operand_buf: [max_operand_stack]TypeOrBot = undefined,
    operand_len: usize = 0,

    control_buf: [max_control_stack]ControlFrame = undefined,
    control_len: usize = 0,

    fn run(self: *Validator) Error!void {
        // Implicit function frame: a `block` with the function's result type.
        // The frame's start_type stays `.empty` — the function's params live
        // as locals (not on the operand stack at entry), so `return` pops
        // the result types and `br depth=N-1` does the same. (Wasm 2.0
        // §3.4.10 retains this convention even with multi-value.)
        const fn_end_type: BlockType = blockTypeOfSlice(self.sig.results);

        try self.pushFrame(.block, .empty, fn_end_type);

        while (self.control_len > 0) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const op = self.body[self.pos];
            self.pos += 1;
            try self.dispatch(op);
        }

        if (self.pos != self.body.len) return Error.TrailingBytes;
    }

    // ----------------------------------------------------------------
    // Operand-stack helpers
    // ----------------------------------------------------------------

    fn pushType(self: *Validator, t: ValType) Error!void {
        if (self.operand_len == max_operand_stack) return Error.OperandStackOverflow;
        self.operand_buf[self.operand_len] = .{ .known = t };
        self.operand_len += 1;
    }

    fn pushBot(self: *Validator) Error!void {
        if (self.operand_len == max_operand_stack) return Error.OperandStackOverflow;
        self.operand_buf[self.operand_len] = .bot;
        self.operand_len += 1;
    }

    /// Pop one operand and assert it has the expected type. In an
    /// unreachable region pop returns `bot` (synthesised) instead of
    /// underflowing.
    fn popExpect(self: *Validator, expected: ValType) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (t != expected) return Error.StackTypeMismatch,
        }
    }

    fn popAny(self: *Validator) Error!TypeOrBot {
        const frame = &self.control_buf[self.control_len - 1];
        if (self.operand_len == frame.height) {
            if (frame.unreachable_flag) return .bot;
            return Error.StackUnderflow;
        }
        self.operand_len -= 1;
        return self.operand_buf[self.operand_len];
    }

    // ----------------------------------------------------------------
    // Control-stack helpers
    // ----------------------------------------------------------------

    fn pushFrame(
        self: *Validator,
        kind: BlockKind,
        start_bt: BlockType,
        end_bt: BlockType,
    ) Error!void {
        if (self.control_len == max_control_stack) return Error.ControlStackOverflow;
        self.control_buf[self.control_len] = .{
            .kind = kind,
            .start_type = start_bt,
            .end_type = end_bt,
            .height = @intCast(self.operand_len),
            .unreachable_flag = false,
        };
        self.control_len += 1;
    }

    fn topFrame(self: *Validator) *ControlFrame {
        return &self.control_buf[self.control_len - 1];
    }

    /// Index 0 = innermost frame.
    fn frameAt(self: *Validator, depth: u32) ?*ControlFrame {
        if (depth >= self.control_len) return null;
        return &self.control_buf[self.control_len - 1 - depth];
    }

    fn markUnreachable(self: *Validator) void {
        const frame = self.topFrame();
        frame.unreachable_flag = true;
        // Drop everything pushed inside this frame; `bot` reads will
        // synthesise types as the polymorphic-stack rule demands.
        self.operand_len = frame.height;
    }

    // ----------------------------------------------------------------
    // Local-index helpers
    // ----------------------------------------------------------------

    fn localType(self: *Validator, idx: u32) ?ValType {
        const params_len = self.sig.params.len;
        if (idx < params_len) return self.sig.params[idx];
        const local_idx = idx - params_len;
        if (local_idx >= self.locals.len) return null;
        return self.locals[local_idx];
    }

    // ----------------------------------------------------------------
    // Block-type decoder (Wasm 1.0 forms + Wasm 2.0 typeidx)
    // ----------------------------------------------------------------

    /// Wasm spec §5.4.X (block type) — encoded as an s33 LEB. Negative
    /// values are well-known type abbreviations (-64 = empty, -1..-4 =
    /// single valtype); positive values are typeidx into the module's
    /// type section (Wasm 2.0 multivalue per §3.4.4).
    ///
    /// Returns the block's full signature (`start` = params, `end` =
    /// results). Wasm 1.0 forms always have `start = .empty`.
    /// D-035 chunk-d035-a lifts the previous `params.len != 0`
    /// rejection so multi-param + multi-result blocks (block.wast,
    /// br_*.wast, call.wast) round-trip through validate + lower.
    fn readBlockType(self: *Validator) Error!BlockTypeFull {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const sleb = leb128.readSleb128(i32, self.body, &self.pos) catch
            return Error.BadBlockType;
        if (sleb < 0) {
            const end: BlockType = switch (sleb) {
                -64 => .empty, // 0x40
                -1 => .{ .single = .i32 }, // 0x7F
                -2 => .{ .single = .i64 }, // 0x7E
                -3 => .{ .single = .f32 }, // 0x7D
                -4 => .{ .single = .f64 }, // 0x7C
                -5 => .{ .single = .v128 }, // 0x7B (§9.9 / 9.9-f-2)
                else => return Error.BadBlockType,
            };
            return .{ .start = .empty, .end = end };
        }
        const idx: u32 = @intCast(sleb);
        if (idx >= self.module_types.len) return Error.BadBlockType;
        const ft = self.module_types[idx];
        return .{
            .start = blockTypeOfSlice(ft.params),
            .end = blockTypeOfSlice(ft.results),
        };
    }

    // ----------------------------------------------------------------
    // Opcode dispatch
    // ----------------------------------------------------------------

    fn dispatch(self: *Validator, op: u8) Error!void {
        switch (op) {
            // Control flow
            0x00 => try self.opUnreachable(),
            0x01 => {}, // nop
            0x02 => try self.opBlock(.block),
            0x03 => try self.opBlock(.loop),
            0x04 => try self.opIf(),
            0x05 => try self.opElse(),
            0x0B => try self.opEnd(),
            0x0C => try self.opBr(),
            0x0D => try self.opBrIf(),
            0x0E => try self.opBrTable(),
            0x0F => try self.opReturn(),
            0x10 => try self.opCall(),
            0x11 => try self.opCallIndirect(),

            // Parametric
            0x1A => try self.opDrop(),
            0x1B => try self.opSelect(),
            0x1C => try self.opSelectTyped(),

            // Variables
            0x20 => try self.opLocalGet(),
            0x21 => try self.opLocalSet(),
            0x22 => try self.opLocalTee(),
            0x23 => try self.opGlobalGet(),
            0x24 => try self.opGlobalSet(),

            // Tables (Wasm 2.0 §9.2 / 2.3 chunk 5c)
            0x25 => try self.opTableGet(),
            0x26 => try self.opTableSet(),

            // Loads (memarg → align uleb32 + offset uleb32)
            0x28 => try self.opLoad(.i32),
            0x29 => try self.opLoad(.i64),
            0x2A => try self.opLoad(.f32),
            0x2B => try self.opLoad(.f64),
            0x2C, 0x2D, 0x2E, 0x2F => try self.opLoad(.i32),
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35 => try self.opLoad(.i64),

            // Stores
            0x36 => try self.opStore(.i32),
            0x37 => try self.opStore(.i64),
            0x38 => try self.opStore(.f32),
            0x39 => try self.opStore(.f64),
            0x3A, 0x3B => try self.opStore(.i32),
            0x3C, 0x3D, 0x3E => try self.opStore(.i64),

            // memory.size / memory.grow (each carries a reserved 0x00 byte)
            0x3F => try self.opMemorySize(),
            0x40 => try self.opMemoryGrow(),

            // Constants
            0x41 => try self.opIxxConst(.i32),
            0x42 => try self.opIxxConst(.i64),
            0x43 => try self.opFxxConst(.f32),
            0x44 => try self.opFxxConst(.f64),

            // i32 testop / relops
            0x45 => try self.opTestop(.i32),
            0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F => try self.opRelop(.i32),

            // i64 testop / relops
            0x50 => try self.opTestop(.i64),
            0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A => try self.opRelop(.i64),

            // f32 / f64 relops
            0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60 => try self.opRelop(.f32),
            0x61, 0x62, 0x63, 0x64, 0x65, 0x66 => try self.opRelop(.f64),

            // Unops + binops by group
            0x67, 0x68, 0x69 => try self.opUnop(.i32),
            0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78 => try self.opBinop(.i32),
            0x79, 0x7A, 0x7B => try self.opUnop(.i64),
            0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A => try self.opBinop(.i64),
            0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x91 => try self.opUnop(.f32),
            0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98 => try self.opBinop(.f32),
            0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F => try self.opUnop(.f64),
            0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6 => try self.opBinop(.f64),

            // Numeric conversions (from → to)
            0xA7 => try self.opCvt(.i64, .i32), // wrap
            0xA8, 0xA9 => try self.opCvt(.f32, .i32),
            0xAA, 0xAB => try self.opCvt(.f64, .i32),
            0xAC, 0xAD => try self.opCvt(.i32, .i64),
            0xAE, 0xAF => try self.opCvt(.f32, .i64),
            0xB0, 0xB1 => try self.opCvt(.f64, .i64),
            0xB2, 0xB3 => try self.opCvt(.i32, .f32),
            0xB4, 0xB5 => try self.opCvt(.i64, .f32),
            0xB6 => try self.opCvt(.f64, .f32), // demote
            0xB7, 0xB8 => try self.opCvt(.i32, .f64),
            0xB9, 0xBA => try self.opCvt(.i64, .f64),
            0xBB => try self.opCvt(.f32, .f64), // promote
            0xBC => try self.opCvt(.f32, .i32), // reinterpret
            0xBD => try self.opCvt(.f64, .i64),
            0xBE => try self.opCvt(.i32, .f32),
            0xBF => try self.opCvt(.i64, .f64),

            // Wasm 2.0 sign extension (§9.2 / 2.3 chunk 1)
            0xC0, 0xC1 => try self.opUnop(.i32),
            0xC2, 0xC3, 0xC4 => try self.opUnop(.i64),

            // Wasm 2.0 reference types (§9.2 / 2.3 chunk 5)
            0xD0 => try self.opRefNull(),
            0xD1 => try self.opRefIsNull(),
            0xD2 => try self.opRefFunc(),

            // Wasm 2.0 prefix opcodes (§9.2 / 2.3 chunk 2 onward)
            0xFC => try self.dispatchPrefixFC(),

            // Wasm SIMD-128 prefix (§9.9 / Phase 9 per ADR-0041).
            // The validator dispatches inline (mirroring 0xFC's
            // shape) per ADR-0041 Revision 2 — the central
            // DispatchTable's validator slot is not consumed
            // today; that's a Phase 14+ structural refactor.
            0xFD => try self.dispatchPrefixFD(),

            else => return Error.NotImplemented,
        }
    }

    // ----------------------------------------------------------------
    // Opcode handlers
    // ----------------------------------------------------------------

    fn opUnreachable(self: *Validator) Error!void {
        self.markUnreachable();
    }

    fn opBlock(self: *Validator, kind: BlockKind) Error!void {
        const bt = try self.readBlockType();
        // Wasm 2.0 §3.4.4: pop params from the outer stack (verifying
        // their types), push frame at the post-pop height, then re-
        // push params as the block body's initial operand stack so the
        // body sees them.
        try self.popLabelTypes(bt.start);
        try self.pushFrame(kind, bt.start, bt.end);
        switch (bt.start) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opIf(self: *Validator) Error!void {
        const bt = try self.readBlockType();
        // The cond i32 is popped *before* the params (it lives above
        // them on the outer stack — Wasm 2.0 §3.4.4 specifies the
        // structured-control encoding pops the cond first).
        try self.popExpect(.i32);
        try self.popLabelTypes(bt.start);
        try self.pushFrame(.if_then, bt.start, bt.end);
        switch (bt.start) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opElse(self: *Validator) Error!void {
        const frame = self.topFrame();
        if (frame.kind != .if_then) return Error.UnexpectedOpcode;
        // Verify the if-branch produced the expected end types.
        try self.expectFrameEndTypes(frame.*);
        // Reset stack to entry height; alternate branch starts fresh.
        self.operand_len = frame.height;
        frame.kind = .else_open;
        frame.unreachable_flag = false;
    }

    fn opEnd(self: *Validator) Error!void {
        const frame = self.topFrame().*;
        try self.expectFrameEndTypes(frame);
        self.control_len -= 1;
        // Restore stack height to entry, then push the frame's end types.
        self.operand_len = frame.height;
        switch (frame.endType()) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opBr(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        try self.popLabelTypes(target.labelType());
        self.markUnreachable();
    }

    fn opReturn(self: *Validator) Error!void {
        // Function frame is always at depth control_len - 1 (index 0 in our buffer).
        const fn_frame = &self.control_buf[0];
        try self.popLabelTypes(fn_frame.end_type);
        self.markUnreachable();
    }

    fn popLabelTypes(self: *Validator, lt: BlockType) Error!void {
        switch (lt) {
            .empty => {},
            .single => |t| try self.popExpect(t),
            .multi => |ts| {
                var i: usize = ts.len;
                while (i > 0) {
                    i -= 1;
                    try self.popExpect(ts[i]);
                }
            },
        }
    }

    fn opDrop(self: *Validator) Error!void {
        _ = try self.popAny();
    }

    fn opLocalGet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const t = self.localType(idx) orelse return Error.InvalidLocalIndex;
        try self.pushType(t);
    }

    fn opLocalSet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const t = self.localType(idx) orelse return Error.InvalidLocalIndex;
        try self.popExpect(t);
    }

    fn opLocalTee(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const t = self.localType(idx) orelse return Error.InvalidLocalIndex;
        try self.popExpect(t);
        try self.pushType(t);
    }

    fn opGlobalGet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.globals.len) return Error.InvalidGlobalIndex;
        try self.pushType(self.globals[idx].valtype);
    }

    fn opGlobalSet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.globals.len) return Error.InvalidGlobalIndex;
        const g = self.globals[idx];
        if (!g.mutable) return Error.ImmutableGlobal;
        try self.popExpect(g.valtype);
    }

    fn opIxxConst(self: *Validator, t: ValType) Error!void {
        // Skip the signed leb128 immediate (we do not range-check the
        // value here — that is the lowerer's concern in 1.6).
        if (t == .i32) {
            _ = try leb128.readSleb128(i32, self.body, &self.pos);
        } else {
            _ = try leb128.readSleb128(i64, self.body, &self.pos);
        }
        try self.pushType(t);
    }

    fn opFxxConst(self: *Validator, t: ValType) Error!void {
        const width: usize = if (t == .f32) 4 else 8;
        if (self.body.len - self.pos < width) return Error.UnexpectedEnd;
        self.pos += width;
        try self.pushType(t);
    }

    fn opTestop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.pushType(.i32);
    }

    fn opUnop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.pushType(t);
    }

    fn opBinop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.popExpect(t);
        try self.pushType(t);
    }

    fn opRelop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.popExpect(t);
        try self.pushType(.i32);
    }

    fn opCvt(self: *Validator, from: ValType, to: ValType) Error!void {
        try self.popExpect(from);
        try self.pushType(to);
    }

    /// Dispatch the Wasm 2.0+ prefix-0xFC opcode group. Sub-opcodes
    /// 0..7 are saturating truncations (§9.2 / 2.3 chunk 2); 10/11
    /// are memory.copy/memory.fill (chunk 4); 8/9/12+ land in later
    /// chunks (data section / table section dependencies).
    /// Encoding: 0xFC <uleb32 sub-opcode>.
    fn dispatchPrefixFC(self: *Validator) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            0, 1 => try self.opCvt(.f32, .i32), // i32.trunc_sat_f32_{s,u}
            2, 3 => try self.opCvt(.f64, .i32), // i32.trunc_sat_f64_{s,u}
            4, 5 => try self.opCvt(.f32, .i64), // i64.trunc_sat_f32_{s,u}
            6, 7 => try self.opCvt(.f64, .i64), // i64.trunc_sat_f64_{s,u}
            8 => try self.opMemoryInit(),
            9 => try self.opDataDrop(),
            12 => try self.opTableInit(),
            13 => try self.opElemDrop(),
            10 => try self.opMemoryCopy(),
            11 => try self.opMemoryFill(),
            14 => try self.opTableCopy(),
            15 => try self.opTableGrow(),
            16 => try self.opTableSize(),
            17 => try self.opTableFill(),
            else => return Error.NotImplemented,
        }
    }

    /// Wasm SIMD-128 prefix-`0xFD` sub-opcode dispatch (§9.9 per
    /// ADR-0041 + Revision 2). MVP catalogue lands the
    /// foundational op shapes; remaining sub-opcodes extend
    /// across §9.4 IR + 9.5-9.8 emit chunks per ADR-0041's
    /// chunk plan. Sub-opcode numbering follows the Wasm SIMD
    /// proposal (`~/Documents/OSS/WebAssembly/testsuite/
    /// proposals/simd/*.wast`).
    fn dispatchPrefixFD(self: *Validator) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            // Loads (memarg → align uleb32 + offset uleb32; pop i32 addr; push v128).
            0 => try self.opLoad(.v128), // v128.load
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10 => try self.opLoad(.v128), // load{8x8,16x4,32x2}_{s,u} + load{8,16,32,64}_splat
            92, 93 => try self.opLoad(.v128), // v128.load32_zero, v128.load64_zero

            // Store: pop v128 + i32 addr (memarg).
            11 => try self.opStore(.v128), // v128.store

            // v128.const: 16 immediate bytes; push v128.
            12 => try self.opSimdConst(),

            // i8x16.shuffle: 16 immediate lane bytes; pop 2× v128, push v128.
            13 => try self.opSimdShuffle(),

            // i8x16.swizzle: pop 2× v128, push v128.
            14 => try self.opSimdBinop(),

            // Splat ops: pop scalar (per shape), push v128.
            15 => try self.opSimdSplat(.i32), // i8x16.splat (i32 input, narrowed at runtime)
            16 => try self.opSimdSplat(.i32), // i16x8.splat
            17 => try self.opSimdSplat(.i32), // i32x4.splat
            18 => try self.opSimdSplat(.i64), // i64x2.splat
            19 => try self.opSimdSplat(.f32), // f32x4.splat
            20 => try self.opSimdSplat(.f64), // f64x2.splat

            // extract_lane / replace_lane: read 1-byte lane immediate.
            21, 22 => try self.opSimdExtractLane(.i32), // i8x16.extract_lane_{s,u}
            23 => try self.opSimdReplaceLane(.i32), // i8x16.replace_lane
            24, 25 => try self.opSimdExtractLane(.i32), // i16x8.extract_lane_{s,u}
            26 => try self.opSimdReplaceLane(.i32), // i16x8.replace_lane
            27 => try self.opSimdExtractLane(.i32), // i32x4.extract_lane
            28 => try self.opSimdReplaceLane(.i32), // i32x4.replace_lane
            29 => try self.opSimdExtractLane(.i64), // i64x2.extract_lane
            30 => try self.opSimdReplaceLane(.i64), // i64x2.replace_lane
            31 => try self.opSimdExtractLane(.f32), // f32x4.extract_lane
            32 => try self.opSimdReplaceLane(.f32), // f32x4.replace_lane
            33 => try self.opSimdExtractLane(.f64), // f64x2.extract_lane
            34 => try self.opSimdReplaceLane(.f64), // f64x2.replace_lane

            // Comparison ops (relops, sub 35..76): pop 2× v128, push
            // v128 mask. §9.9 / 9.9-f-1 splits the bitwise unop +
            // 3-op cases out of the binop range (was approximated
            // as binop in the 9.4 MVP; rejected the simd_bitwise.0
            // fixture's `not` / `bitselect` exports with
            // StackUnderflow because the operand-stack pop count
            // didn't match).
            35...76 => try self.opSimdBinop(),
            77 => try self.opSimdUnop(), // v128.not — pop 1 v128, push 1 v128
            78, 79, 80, 81 => try self.opSimdBinop(), // v128.{and, or, xor, andnot}
            82 => try self.opSimdBitselect(), // v128.bitselect — pop 3× v128, push v128

            // any_true (sub 83): pop v128, push i32.
            83 => try self.opSimdAllTrueOrAnyTrue(),

            // §9.7 / 9.7-ba — load_lane × 4, store_lane × 4.
            // memarg + lane byte; load_lane pops (i32, v128) + pushes
            // v128; store_lane pops (i32, v128) + pushes nothing.
            84, 85, 86, 87 => try self.opSimdLoadLane(),
            88, 89, 90, 91 => try self.opSimdStoreLane(),

            // §9.9 / 9.9-f-6 — int arith range (94..211). Split out
            // unop arms to fix StackUnderflow for `i*.neg / abs /
            // popcnt / extend_low/high / extadd_pairwise_*` (all
            // pop 1 v128, push 1 v128). Per Wasm SIMD spec opcode
            // table:
            //   96/97/98 i8x16.{abs,neg,popcnt}
            //   124/125 i16x8.extadd_pairwise_i8x16_{s,u}
            //   126/127 i32x4.extadd_pairwise_i16x8_{s,u}
            //   128/129 i16x8.{abs,neg}
            //   134..137 i16x8.extend_{low,high}_i8x16_{s,u}
            //   160/161 i32x4.{abs,neg}
            //   166..169 i32x4.extend_{low,high}_i16x8_{s,u}
            //   192/193 i64x2.{abs,neg}
            //   199..202 i64x2.extend_{low,high}_i32x4_{s,u}
            96, 97, 98,
            124, 125, 126, 127,
            128, 129,
            134, 135, 136, 137,
            160, 161,
            166, 167, 168, 169,
            192, 193,
            199, 200, 201, 202,
            => try self.opSimdUnop(),
            // Everything else in 94..211 stays binop (cmp / arith /
            // shifts / saturated arith / dot / extmul / etc.).
            94, 95, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111,
            112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123,
            130, 132, 133,
            138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149,
            150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
            162, 164, 165,
            170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183,
            184, 185, 186, 187, 188, 189, 190, 191,
            194, 196, 197, 198,
            203, 204, 205, 206, 207, 208, 209, 210, 211,
            213, // §9.9 / 9.9-f-8 — i64x2.mul (handler-side multi-instr synthesis on ARM64 since NEON has no MUL.2D).
            => try self.opSimdBinop(),

            // §9.9 / 9.9-g-2 — i64x2 comparison ops 214..219.
            // i64x2.{eq, ne, lt_s, gt_s, le_s, ge_s}; spec only
            // defines signed cmp for the 64-bit lane shape.
            214, 215, 216, 217, 218, 219 => try self.opSimdBinop(),

            // §9.9 / 9.9-g-3 — int all_true reductions (sub-ops 99 /
            // 131 / 163 / 195). i*x*.all_true pops v128, pushes i32.
            // bitmask (100/132/164/196) shares the same shape but
            // stays in the surrounding binop list until 9.9-g-4
            // wires its emit handlers — moving it here without
            // emit-side support would just shift the failure error
            // class without flipping any test.
            99, 131, 163, 195 => try self.opSimdAllTrueOrAnyTrue(),

            // §9.9 / 9.9-f-5 — split FP arith range. Sub-opcodes
            // 224..255 cover f32x4 + f64x2 ops; the 9.4 MVP
            // routed all as binop, miscounting unop arms (abs,
            // neg, sqrt) that pop only 1 v128.
            //   224 f32x4.abs / 225 f32x4.neg / 227 f32x4.sqrt
            //   236 f64x2.abs / 237 f64x2.neg / 239 f64x2.sqrt
            // are unops; 228..235 + 240..247 stay binops.
            224, 225, 227, 236, 237, 239 => try self.opSimdUnop(),
            226, 228...235, 238, 240...255 => try self.opSimdBinop(),

            else => return Error.NotImplemented,
        }
    }

    /// `v128.const`: 16 immediate bytes; push v128.
    fn opSimdConst(self: *Validator) Error!void {
        if (self.pos + 16 > self.body.len) return Error.UnexpectedEnd;
        self.pos += 16;
        try self.pushType(.v128);
    }

    /// `i8x16.shuffle`: 16 immediate lane bytes; pop 2× v128, push v128.
    /// Each lane byte must be < 32 (per spec; lane indices into the
    /// concatenated 32-byte input). Validator enforces lane-bound; emit
    /// pass uses the immediate at code-emit time.
    fn opSimdShuffle(self: *Validator) Error!void {
        if (self.pos + 16 > self.body.len) return Error.UnexpectedEnd;
        for (self.body[self.pos..][0..16]) |lane| {
            if (lane >= 32) return Error.BadValType;
        }
        self.pos += 16;
        try self.popExpect(.v128);
        try self.popExpect(.v128);
        try self.pushType(.v128);
    }

    /// SIMD splat (`i8x16.splat`, `i32x4.splat`, …): pop a scalar of
    /// the source-element type; push v128.
    fn opSimdSplat(self: *Validator, src: ValType) Error!void {
        try self.popExpect(src);
        try self.pushType(.v128);
    }

    /// SIMD extract_lane (`i8x16.extract_lane_s`, `f32x4.extract_lane`,
    /// …): read 1-byte lane immediate; pop v128; push scalar.
    fn opSimdExtractLane(self: *Validator, dst: ValType) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        self.pos += 1; // lane byte (bound-check deferred to emit per spec)
        try self.popExpect(.v128);
        try self.pushType(dst);
    }

    /// SIMD replace_lane (`i8x16.replace_lane`, `f64x2.replace_lane`,
    /// …): read 1-byte lane immediate; pop scalar + v128; push v128.
    fn opSimdReplaceLane(self: *Validator, src: ValType) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        self.pos += 1;
        try self.popExpect(src);
        try self.popExpect(.v128);
        try self.pushType(.v128);
    }

    /// SIMD load_lane: memarg (align uleb + offset uleb) + 1-byte
    /// lane immediate. Pop v128 + i32 idx; push v128 (modified).
    fn opSimdLoadLane(self: *Validator) Error!void {
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // align
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // offset
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        self.pos += 1; // lane byte
        try self.popExpect(.v128);
        try self.popExpect(.i32);
        try self.pushType(.v128);
    }

    /// SIMD store_lane: memarg + 1-byte lane immediate. Pop v128 +
    /// i32 idx; push nothing.
    fn opSimdStoreLane(self: *Validator) Error!void {
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // align
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // offset
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        self.pos += 1; // lane byte
        try self.popExpect(.v128);
        try self.popExpect(.i32);
    }

    /// Generic v128 binop (and/or/xor, integer add/sub/mul, shifts,
    /// comparisons, etc. — anything that pops 2 v128 and pushes 1).
    fn opSimdBinop(self: *Validator) Error!void {
        try self.popExpect(.v128);
        try self.popExpect(.v128);
        try self.pushType(.v128);
    }

    /// Generic v128 unop (`v128.not`, `i8x16.abs`, etc. — pop 1 v128,
    /// push 1 v128).
    fn opSimdUnop(self: *Validator) Error!void {
        try self.popExpect(.v128);
        try self.pushType(.v128);
    }

    /// `v128.bitselect`: pop 3× v128 (val1, val2, mask), push v128.
    /// Wasm spec §3.3.6.6 (bitselect).
    fn opSimdBitselect(self: *Validator) Error!void {
        try self.popExpect(.v128);
        try self.popExpect(.v128);
        try self.popExpect(.v128);
        try self.pushType(.v128);
    }

    /// `v128.any_true` / `i8x16.all_true` / etc.: pop v128, push i32.
    fn opSimdAllTrueOrAnyTrue(self: *Validator) Error!void {
        try self.popExpect(.v128);
        try self.pushType(.i32);
    }

    /// memory.copy: 0xFC 10 0x00 0x00 (two reserved memidx bytes).
    /// Pops three i32 (n, src, dst); pushes nothing.
    fn opMemoryCopy(self: *Validator) Error!void {
        if (self.pos + 2 > self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00 or self.body[self.pos + 1] != 0x00) {
            return Error.BadBlockType; // reserved bytes must be zero
        }
        self.pos += 2;
        try self.popExpect(.i32);
        try self.popExpect(.i32);
        try self.popExpect(.i32);
    }

    /// memory.init: 0xFC 8 dataidx 0x00 (one reserved memidx byte).
    /// Pops three i32 (n, src, dst); pushes nothing. dataidx must be
    /// less than the module's data segment count.
    fn opMemoryInit(self: *Validator) Error!void {
        const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dataidx >= self.data_count) return Error.InvalidFuncIndex;
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.BadBlockType;
        self.pos += 1;
        try self.popExpect(.i32);
        try self.popExpect(.i32);
        try self.popExpect(.i32);
    }

    /// data.drop: 0xFC 9 dataidx. No operand stack effects.
    fn opDataDrop(self: *Validator) Error!void {
        const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dataidx >= self.data_count) return Error.InvalidFuncIndex;
    }

    /// ref.null t: 0xD0 reftype. Reads a single byte: 0x70=funcref,
    /// 0x6F=externref. Pushes the corresponding reference type.
    fn opRefNull(self: *Validator) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const b = self.body[self.pos];
        self.pos += 1;
        const t: ValType = switch (b) {
            0x70 => .funcref,
            0x6F => .externref,
            else => return Error.BadValType,
        };
        try self.pushType(t);
    }

    /// ref.is_null: pop any reftype, push i32. Polymorphic over
    /// funcref / externref.
    fn opRefIsNull(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (t != .funcref and t != .externref) return Error.StackTypeMismatch,
        }
        try self.pushType(.i32);
    }

    /// ref.func funcidx: read funcidx, validate it's within the
    /// module's function index space, push funcref. The strict
    /// declaration-scope check (§5.4.1.4) is deferred — chunk 5
    /// allows any valid funcidx.
    fn opRefFunc(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.func_types.len) return Error.InvalidFuncIndex;
        try self.pushType(.funcref);
    }

    /// table.get x: pop i32 idx, push tables[x].elem_type.
    fn opTableGet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(.i32);
        try self.pushType(self.tables[idx].elem_type);
    }

    /// table.set x: pop tables[x].elem_type, pop i32 idx.
    fn opTableSet(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(self.tables[idx].elem_type);
        try self.popExpect(.i32);
    }

    /// table.size x (0xFC 16): push i32.
    fn opTableSize(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.pushType(.i32);
    }

    /// table.grow x (0xFC 15): pop n:i32, init:elem_type; push i32.
    fn opTableGrow(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(.i32);
        try self.popExpect(self.tables[idx].elem_type);
        try self.pushType(.i32);
    }

    /// table.init x y (0xFC 12): elemidx + tableidx; pops three i32
    /// (n, src, dst). For chunk 5d-2 we accept any (elemidx, tableidx)
    /// in range — the spec also requires the elem_type to match the
    /// table's elem_type, but that requires per-segment type tracking
    /// that we omit here (always funcref in chunk 5d-2 corpus).
    fn opTableInit(self: *Validator) Error!void {
        const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const tableidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (elemidx >= self.elem_count) return Error.InvalidFuncIndex;
        if (tableidx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(.i32);
        try self.popExpect(.i32);
        try self.popExpect(.i32);
    }

    /// elem.drop x (0xFC 13): no operand-stack effects. Validates
    /// elemidx in range.
    fn opElemDrop(self: *Validator) Error!void {
        const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (elemidx >= self.elem_count) return Error.InvalidFuncIndex;
    }

    /// table.copy x y (0xFC 14): dst-tableidx, src-tableidx; pops
    /// three i32 (n, src, dst). Both tables must have the same
    /// elem_type.
    fn opTableCopy(self: *Validator) Error!void {
        const dst = try leb128.readUleb128(u32, self.body, &self.pos);
        const src = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dst >= self.tables.len or src >= self.tables.len) return Error.InvalidFuncIndex;
        if (self.tables[dst].elem_type != self.tables[src].elem_type) {
            return Error.StackTypeMismatch;
        }
        try self.popExpect(.i32);
        try self.popExpect(.i32);
        try self.popExpect(.i32);
    }

    /// table.fill x (0xFC 17): pop n:i32, val:elem_type, dst:i32.
    fn opTableFill(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.tables.len) return Error.InvalidFuncIndex;
        try self.popExpect(.i32);
        try self.popExpect(self.tables[idx].elem_type);
        try self.popExpect(.i32);
    }

    /// memory.fill: 0xFC 11 0x00 (one reserved memidx byte).
    /// Pops three i32 (n, val, dst); pushes nothing.
    fn opMemoryFill(self: *Validator) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.BadBlockType;
        self.pos += 1;
        try self.popExpect(.i32);
        try self.popExpect(.i32);
        try self.popExpect(.i32);
    }

    fn opBrTable(self: *Validator) Error!void {
        const n = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.popExpect(.i32); // selector
        var first: ?BlockType = null;
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            const depth = try leb128.readUleb128(u32, self.body, &self.pos);
            const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
            const lt = target.labelType();
            if (first) |prev| {
                if (!labelTypesEq(prev, lt)) return Error.ArityMismatch;
            } else first = lt;
        }
        if (first) |lt| try self.popLabelTypes(lt);
        self.markUnreachable();
    }

    fn opBrIf(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.popExpect(.i32);
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        // br_if pops the label values, then pushes them back (since the
        // taken branch consumes; the fall-through preserves them).
        const lt = target.labelType();
        try self.popLabelTypes(lt);
        switch (lt) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opCall(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.func_types.len) return Error.InvalidFuncIndex;
        const callee = self.func_types[idx];
        // Pop args in reverse order so the topmost popped value matches the
        // last param.
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        for (callee.results) |r| try self.pushType(r);
    }

    fn opCallIndirect(self: *Validator) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        // Wasm 2.0: table_idx is uleb32 (any table); Wasm 1.0
        // encoded a single 0x00 byte which decodes as uleb32(0).
        const table_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (table_idx >= self.tables.len) return Error.InvalidFuncIndex;
        if (type_idx >= self.module_types.len) return Error.InvalidFuncIndex;
        const callee = self.module_types[type_idx];
        // Pop the function-table index (i32), then args in reverse.
        try self.popExpect(.i32);
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        for (callee.results) |r| try self.pushType(r);
    }

    fn opSelect(self: *Validator) Error!void {
        // select (untyped, MVP): pop i32 cond; pop t2; pop t1; require
        // t1 == t2 (numeric); push t1.
        try self.popExpect(.i32);
        const a = try self.popAny();
        const b = try self.popAny();
        const result: TypeOrBot = blk: {
            switch (a) {
                .bot => break :blk b,
                .known => |ka| switch (b) {
                    .bot => break :blk a,
                    .known => |kb| {
                        if (ka != kb) return Error.StackTypeMismatch;
                        break :blk a;
                    },
                },
            }
        };
        switch (result) {
            .known => |t| try self.pushType(t),
            .bot => try self.pushBot(),
        }
    }

    /// select_typed (Wasm 2.0): 0x1C count valtype*. Wasm 2.0
    /// requires count = 1 (the result type). Pops i32 cond, two
    /// values of that type, pushes one of them.
    fn opSelectTyped(self: *Validator) Error!void {
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        if (count != 1) return Error.InvalidOpcode;
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const b = self.body[self.pos];
        self.pos += 1;
        const t: ValType = switch (b) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            0x70 => .funcref,
            0x6F => .externref,
            else => return Error.BadValType,
        };
        try self.popExpect(.i32);
        try self.popExpect(t);
        try self.popExpect(t);
        try self.pushType(t);
    }

    fn skipMemarg(self: *Validator) Error!void {
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // align
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // offset
    }

    fn opLoad(self: *Validator, t: ValType) Error!void {
        try self.skipMemarg();
        try self.popExpect(.i32); // address
        try self.pushType(t);
    }

    fn opStore(self: *Validator, t: ValType) Error!void {
        try self.skipMemarg();
        try self.popExpect(t); // value
        try self.popExpect(.i32); // address
    }

    fn opMemorySize(self: *Validator) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.InvalidOpcode;
        self.pos += 1;
        try self.pushType(.i32);
    }

    fn opMemoryGrow(self: *Validator) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.InvalidOpcode;
        self.pos += 1;
        try self.popExpect(.i32);
        try self.pushType(.i32);
    }

    // ----------------------------------------------------------------
    // Frame end-type assertion
    // ----------------------------------------------------------------

    fn expectFrameEndTypes(self: *Validator, frame: ControlFrame) Error!void {
        const end = frame.endType();
        const expected_len: usize = switch (end) {
            .empty => 0,
            .single => 1,
            .multi => |ts| ts.len,
        };
        if (frame.unreachable_flag and self.operand_len <= frame.height + expected_len) {
            // Unreachable region: missing values are synthesised on read.
            return;
        }
        if (self.operand_len != frame.height + expected_len) return Error.ArityMismatch;
        switch (end) {
            .empty => {},
            .single => |t| {
                const top = self.operand_buf[self.operand_len - 1];
                switch (top) {
                    .bot => {},
                    .known => |k| if (k != t) return Error.StackTypeMismatch,
                }
            },
            .multi => |ts| {
                for (ts, 0..) |t, idx| {
                    const slot = self.operand_buf[frame.height + idx];
                    switch (slot) {
                        .bot => {},
                        .known => |k| if (k != t) return Error.StackTypeMismatch,
                    }
                }
            },
        }
    }
};

fn labelTypesEq(a: BlockType, b: BlockType) bool {
    return switch (a) {
        .empty => b == .empty,
        .single => |t1| switch (b) {
            .single => |t2| t1 == t2,
            else => false,
        },
        .multi => |ts1| switch (b) {
            .multi => |ts2| std.mem.eql(ValType, ts1, ts2),
            else => false,
        },
    };
}
