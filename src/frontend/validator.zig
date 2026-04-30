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
//! Zone 1 (`src/frontend/`) — may import Zone 0 (`src/util/leb128.zig`)
//! and Zone 1 (`src/ir/`). No upward imports.

const std = @import("std");

const leb128 = @import("../util/leb128.zig");
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
    InvalidLocalIndex,
    InvalidBranchDepth,
    UnclosedFrames,
    TrailingBytes,
    OperandStackOverflow,
    ControlStackOverflow,
    ArityMismatch,
    NotImplemented,
} || leb128.Error;

pub const max_operand_stack: usize = 1024;
pub const max_control_stack: usize = 256;

/// Block result type — Wasm 1.0 supports empty (0x40) or a single
/// `ValType`. Multivalue (Wasm 2.0) replaces this with a type index;
/// not handled in 1.5.
pub const BlockType = union(enum) {
    empty,
    single: ValType,
};

const ControlFrame = struct {
    kind: BlockKind,
    block_type: BlockType,
    /// Operand-stack height at frame entry (length, not byte index).
    height: u32,
    /// True after `unreachable` / `br` / `return` until this frame's
    /// `end` (or `else`, which resets it for the alternate branch).
    unreachable_flag: bool,

    /// Types popped by `br` to this label. Spec: blocks/ifs use the
    /// frame's *end* types; loops use the frame's *start* types
    /// (which are empty in MVP).
    fn labelType(self: ControlFrame) BlockType {
        return switch (self.kind) {
            .loop => .empty,
            else => self.block_type,
        };
    }

    /// Types pushed back onto the operand stack at `end`.
    fn endType(self: ControlFrame) BlockType {
        return self.block_type;
    }
};

/// Validate a single function body expression.
///
/// `sig.params` and `locals` together index `local.get` / `local.set`
/// (params first, then declared locals). `body` is the raw expression
/// bytes — opcode stream terminated by an outermost `end` that closes
/// the implicit function frame.
pub fn validateFunction(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
) Error!void {
    var v = Validator{ .sig = sig, .locals = locals, .body = body, .pos = 0 };
    try v.run();
}

const Validator = struct {
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    pos: usize,

    operand_buf: [max_operand_stack]TypeOrBot = undefined,
    operand_len: usize = 0,

    control_buf: [max_control_stack]ControlFrame = undefined,
    control_len: usize = 0,

    fn run(self: *Validator) Error!void {
        // Implicit function frame: a `block` with the function's result type.
        const fn_block_type: BlockType = if (self.sig.results.len == 0)
            .empty
        else if (self.sig.results.len == 1)
            .{ .single = self.sig.results[0] }
        else
            return Error.NotImplemented; // multivalue lands later

        try self.pushFrame(.block, fn_block_type);

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

    fn pushFrame(self: *Validator, kind: BlockKind, bt: BlockType) Error!void {
        if (self.control_len == max_control_stack) return Error.ControlStackOverflow;
        self.control_buf[self.control_len] = .{
            .kind = kind,
            .block_type = bt,
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
    // Block-type decoder (Wasm 1.0 only)
    // ----------------------------------------------------------------

    fn readBlockType(self: *Validator) Error!BlockType {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const b = self.body[self.pos];
        self.pos += 1;
        return switch (b) {
            0x40 => .empty,
            0x7F => .{ .single = .i32 },
            0x7E => .{ .single = .i64 },
            0x7D => .{ .single = .f32 },
            0x7C => .{ .single = .f64 },
            else => Error.BadBlockType,
        };
    }

    // ----------------------------------------------------------------
    // Opcode dispatch
    // ----------------------------------------------------------------

    fn dispatch(self: *Validator, op: u8) Error!void {
        switch (op) {
            0x00 => try self.opUnreachable(),
            0x01 => {}, // nop
            0x02 => try self.opBlock(.block),
            0x03 => try self.opBlock(.loop),
            0x04 => try self.opIf(),
            0x05 => try self.opElse(),
            0x0B => try self.opEnd(),
            0x0C => try self.opBr(),
            0x0F => try self.opReturn(),
            0x1A => try self.opDrop(),
            0x20 => try self.opLocalGet(),
            0x21 => try self.opLocalSet(),
            0x22 => try self.opLocalTee(),
            0x41 => try self.opIxxConst(.i32),
            0x42 => try self.opIxxConst(.i64),
            0x43 => try self.opFxxConst(.f32),
            0x44 => try self.opFxxConst(.f64),
            0x45 => try self.opUnopTest(.i32), // i32.eqz
            0x6A => try self.opBinop(.i32), // i32.add
            0x6B => try self.opBinop(.i32), // i32.sub
            0x6C => try self.opBinop(.i32), // i32.mul
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
        // Wasm 1.0 block-type has no params, so nothing pops here.
        try self.pushFrame(kind, bt);
    }

    fn opIf(self: *Validator) Error!void {
        const bt = try self.readBlockType();
        try self.popExpect(.i32);
        try self.pushFrame(.if_then, bt);
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
        }
    }

    fn opBr(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        switch (target.labelType()) {
            .empty => {},
            .single => |t| try self.popExpect(t),
        }
        self.markUnreachable();
    }

    fn opReturn(self: *Validator) Error!void {
        // Function frame is always at depth control_len - 1 (index 0 in our buffer).
        const fn_frame = &self.control_buf[0];
        switch (fn_frame.block_type) {
            .empty => {},
            .single => |t| try self.popExpect(t),
        }
        self.markUnreachable();
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

    fn opUnopTest(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.pushType(.i32);
    }

    fn opBinop(self: *Validator, t: ValType) Error!void {
        try self.popExpect(t);
        try self.popExpect(t);
        try self.pushType(t);
    }

    // ----------------------------------------------------------------
    // Frame end-type assertion
    // ----------------------------------------------------------------

    fn expectFrameEndTypes(self: *Validator, frame: ControlFrame) Error!void {
        switch (frame.endType()) {
            .empty => {
                if (self.operand_len != frame.height and !frame.unreachable_flag) {
                    return Error.ArityMismatch;
                }
            },
            .single => |t| {
                if (frame.unreachable_flag and self.operand_len <= frame.height) {
                    // Unreachable region: the missing value will be synthesised
                    // by `bot` semantics if anyone reads it; nothing to assert.
                    return;
                }
                if (self.operand_len != frame.height + 1) return Error.ArityMismatch;
                const top = self.operand_buf[self.operand_len - 1];
                switch (top) {
                    .bot => {},
                    .known => |k| if (k != t) return Error.StackTypeMismatch,
                }
            },
        }
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const empty_sig: FuncType = .{ .params = &.{}, .results = &.{} };
const i32_result_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
const i32_arr = [_]ValType{.i32};

test "validate: empty function (() -> ()) with bare `end`" {
    try validateFunction(empty_sig, &.{}, &[_]u8{0x0B});
}

test "validate: i32.const 0 + drop + end on () -> ()" {
    // 0x41 0x00  -> i32.const 0
    // 0x1A       -> drop
    // 0x0B       -> end
    try validateFunction(empty_sig, &.{}, &[_]u8{ 0x41, 0x00, 0x1A, 0x0B });
}

test "validate: i32.const + end produces declared i32 result" {
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x41, 0x07, 0x0B });
}

test "validate: empty body for () -> i32 fails arity" {
    const r = validateFunction(i32_result_sig, &.{}, &[_]u8{0x0B});
    try testing.expectError(Error.ArityMismatch, r);
}

test "validate: type mismatch — i64 where i32 expected" {
    // i64.const 1 ; i32.add  -> type mismatch (i32.add expects i32 i32)
    const body = [_]u8{ 0x42, 0x01, 0x42, 0x02, 0x6A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: nested block with i32 result" {
    // (block (result i32) i32.const 1) end
    // 0x02 0x7F -> block i32
    //   0x41 0x01 -> i32.const 1
    // 0x0B -> end (block)
    // 0x0B -> end (function frame)
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x02, 0x7F, 0x41, 0x01, 0x0B, 0x0B });
}

test "validate: nested block leaving wrong type at end fails" {
    // (block (result i32) i64.const 1) end -> i32.const? — fails
    const body = [_]u8{ 0x02, 0x7F, 0x42, 0x01, 0x0B, 0x0B };
    const r = validateFunction(i32_result_sig, &.{}, &body);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: unreachable polymorphism — () -> i32 satisfied by `unreachable`" {
    // unreachable; end
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x00, 0x0B });
}

test "validate: br to outer block consumes labeled type" {
    // outer block (result i32) { i32.const 5 ; br 0 } end
    // function sig () -> i32, expected to validate.
    const body = [_]u8{
        0x02, 0x7F, // block i32
        0x41, 0x05, // i32.const 5
        0x0C, 0x00, // br 0 (target = innermost block)
        0x0B, // end block
        0x0B, // end function
    };
    try validateFunction(i32_result_sig, &.{}, &body);
}

test "validate: br to invalid depth fails" {
    // br 5 with only function frame -> InvalidBranchDepth
    const body = [_]u8{ 0x0C, 0x05, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body);
    try testing.expectError(Error.InvalidBranchDepth, r);
}

test "validate: local.get / local.set — params and locals indexed correctly" {
    // params: (i32, i64)  locals: (f32)
    // local.get 0 (i32) -> drop ; local.get 1 (i64) -> drop ;
    // local.get 2 (f32) -> drop ; end
    const params = [_]ValType{ .i32, .i64 };
    const sig: FuncType = .{ .params = &params, .results = &.{} };
    const locals = [_]ValType{.f32};
    const body = [_]u8{
        0x20, 0x00, 0x1A,
        0x20, 0x01, 0x1A,
        0x20, 0x02, 0x1A,
        0x0B,
    };
    try validateFunction(sig, &locals, &body);
}

test "validate: local.get out of range fails" {
    const body = [_]u8{ 0x20, 0x05, 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body);
    try testing.expectError(Error.InvalidLocalIndex, r);
}

test "validate: local.set type mismatch fails" {
    // local.set 0 expects i32; we push i64.
    const params = [_]ValType{.i32};
    const sig: FuncType = .{ .params = &params, .results = &.{} };
    const body = [_]u8{ 0x42, 0x07, 0x21, 0x00, 0x0B };
    const r = validateFunction(sig, &.{}, &body);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: if/else with matching i32 results" {
    // i32.const 1 ; if (result i32) i32.const 10 else i32.const 20 end ; end-fn
    const body = [_]u8{
        0x41, 0x01, // i32.const 1
        0x04, 0x7F, // if i32
        0x41, 0x0A,
        0x05, // else
        0x41, 0x14,
        0x0B, // end if
        0x0B, // end fn
    };
    try validateFunction(i32_result_sig, &.{}, &body);
}

test "validate: if/else with mismatched branch types fails" {
    // if (result i32) i32.const 1 else i64.const 2 end -> mismatch on else end
    const body = [_]u8{
        0x41, 0x01,
        0x04, 0x7F,
        0x41, 0x0A,
        0x05,
        0x42, 0x14,
        0x0B,
        0x0B,
    };
    const r = validateFunction(i32_result_sig, &.{}, &body);
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: unclosed frame (truncated body) fails" {
    // block (no end)
    const body = [_]u8{ 0x02, 0x40, 0x0B }; // opens block, ends block, but not function frame
    const r = validateFunction(empty_sig, &.{}, &body);
    try testing.expectError(Error.UnexpectedEnd, r);
}

test "validate: trailing bytes after function `end` are rejected" {
    const body = [_]u8{ 0x0B, 0x00 };
    const r = validateFunction(empty_sig, &.{}, &body);
    try testing.expectError(Error.TrailingBytes, r);
}

test "validate: stack underflow on drop with empty operand stack" {
    const body = [_]u8{ 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body);
    try testing.expectError(Error.StackUnderflow, r);
}

test "validate: i32.add binop — correct typing" {
    const body = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6A, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body);
}

test "validate: i32.eqz unary test — pops i32, pushes i32" {
    const body = [_]u8{ 0x41, 0x01, 0x45, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body);
}

test "validate: return polymorphism" {
    // i32.const 7 ; return ; end
    const body = [_]u8{ 0x41, 0x07, 0x0F, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body);
}

test "validate: NotImplemented for unknown opcode (e.g. 0xFF)" {
    const body = [_]u8{ 0xFF, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body);
    try testing.expectError(Error.NotImplemented, r);
}
