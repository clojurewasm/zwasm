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
pub const max_control_stack: usize = 256;

/// Block result type. Wasm 1.0 binary block-types are `empty` (0x40)
/// or `single` (one valtype byte). Wasm 2.0 multivalue extends this
/// to `multi` (an s33 typeidx referencing a FuncType). Phase 1 only
/// uses `multi` for function frames whose signature has > 1 result;
/// the binary block-type decoder still rejects s33 references in
/// `readBlockType` so block-level multivalue stays out of scope.
pub const BlockType = union(enum) {
    empty,
    single: ValType,
    multi: []const ValType,
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

    operand_buf: [max_operand_stack]TypeOrBot = undefined,
    operand_len: usize = 0,

    control_buf: [max_control_stack]ControlFrame = undefined,
    control_len: usize = 0,

    fn run(self: *Validator) Error!void {
        // Implicit function frame: a `block` with the function's result type.
        const fn_block_type: BlockType = switch (self.sig.results.len) {
            0 => .empty,
            1 => .{ .single = self.sig.results[0] },
            else => .{ .multi = self.sig.results },
        };

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
        const sleb = leb128.readSleb128(i32, self.body, &self.pos) catch
            return Error.BadBlockType;
        if (sleb < 0) {
            return switch (sleb) {
                -64 => .empty, // 0x40
                -1 => .{ .single = .i32 }, // 0x7F
                -2 => .{ .single = .i64 }, // 0x7E
                -3 => .{ .single = .f32 }, // 0x7D
                -4 => .{ .single = .f64 }, // 0x7C
                else => Error.BadBlockType,
            };
        }
        // Wasm 2.0 multivalue: positive value is a typeidx into the
        // module's type section (§9.2 / 2.3 chunk 3). Multi-param
        // blocks are deferred — chunk 3 supports multi-result only.
        const idx: u32 = @intCast(sleb);
        if (idx >= self.module_types.len) return Error.BadBlockType;
        const ft = self.module_types[idx];
        if (ft.params.len != 0) return Error.BadBlockType;
        return switch (ft.results.len) {
            0 => .empty,
            1 => .{ .single = ft.results[0] },
            else => .{ .multi = ft.results },
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
        try self.popLabelTypes(fn_frame.block_type);
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
            10 => try self.opMemoryCopy(),
            11 => try self.opMemoryFill(),
            15 => try self.opTableGrow(),
            16 => try self.opTableSize(),
            17 => try self.opTableFill(),
            else => return Error.NotImplemented,
        }
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
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        // MVP table_idx must be 0.
        if (self.body[self.pos] != 0x00) return Error.InvalidOpcode;
        self.pos += 1;
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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const empty_sig: FuncType = .{ .params = &.{}, .results = &.{} };
const i32_result_sig: FuncType = .{ .params = &.{}, .results = &i32_arr };
const i64_result_sig: FuncType = .{ .params = &.{}, .results = &i64_arr };
const i32_arr = [_]ValType{.i32};
const i64_arr = [_]ValType{.i64};

test "validate: empty function (() -> ()) with bare `end`" {
    try validateFunction(empty_sig, &.{}, &[_]u8{0x0B}, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i32.const 0 + drop + end on () -> ()" {
    // 0x41 0x00  -> i32.const 0
    // 0x1A       -> drop
    // 0x0B       -> end
    try validateFunction(empty_sig, &.{}, &[_]u8{ 0x41, 0x00, 0x1A, 0x0B }, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i32.const + end produces declared i32 result" {
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x41, 0x07, 0x0B }, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: empty body for () -> i32 fails arity" {
    const r = validateFunction(i32_result_sig, &.{}, &[_]u8{0x0B}, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.ArityMismatch, r);
}

test "validate: type mismatch — i64 where i32 expected" {
    // i64.const 1 ; i32.add  -> type mismatch (i32.add expects i32 i32)
    const body = [_]u8{ 0x42, 0x01, 0x42, 0x02, 0x6A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: nested block with i32 result" {
    // (block (result i32) i32.const 1) end
    // 0x02 0x7F -> block i32
    //   0x41 0x01 -> i32.const 1
    // 0x0B -> end (block)
    // 0x0B -> end (function frame)
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x02, 0x7F, 0x41, 0x01, 0x0B, 0x0B }, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: nested block leaving wrong type at end fails" {
    // (block (result i32) i64.const 1) end -> i32.const? — fails
    const body = [_]u8{ 0x02, 0x7F, 0x42, 0x01, 0x0B, 0x0B };
    const r = validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: unreachable polymorphism — () -> i32 satisfied by `unreachable`" {
    // unreachable; end
    try validateFunction(i32_result_sig, &.{}, &[_]u8{ 0x00, 0x0B }, &.{}, &.{}, &.{}, 0, &.{});
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
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: br to invalid depth fails" {
    // br 5 with only function frame -> InvalidBranchDepth
    const body = [_]u8{ 0x0C, 0x05, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
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
    try validateFunction(sig, &locals, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: local.get out of range fails" {
    const body = [_]u8{ 0x20, 0x05, 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.InvalidLocalIndex, r);
}

test "validate: local.set type mismatch fails" {
    // local.set 0 expects i32; we push i64.
    const params = [_]ValType{.i32};
    const sig: FuncType = .{ .params = &params, .results = &.{} };
    const body = [_]u8{ 0x42, 0x07, 0x21, 0x00, 0x0B };
    const r = validateFunction(sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
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
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
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
    const r = validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: unclosed frame (truncated body) fails" {
    // block (no end)
    const body = [_]u8{ 0x02, 0x40, 0x0B }; // opens block, ends block, but not function frame
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.UnexpectedEnd, r);
}

test "validate: trailing bytes after function `end` are rejected" {
    const body = [_]u8{ 0x0B, 0x00 };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.TrailingBytes, r);
}

test "validate: stack underflow on drop with empty operand stack" {
    const body = [_]u8{ 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.StackUnderflow, r);
}

test "validate: i32.add binop — correct typing" {
    const body = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6A, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i32.eqz unary test — pops i32, pushes i32" {
    const body = [_]u8{ 0x41, 0x01, 0x45, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: return polymorphism" {
    // i32.const 7 ; return ; end
    const body = [_]u8{ 0x41, 0x07, 0x0F, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: NotImplemented for unknown opcode (e.g. 0xFF)" {
    const body = [_]u8{ 0xFF, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.NotImplemented, r);
}

test "validate: i32.extend8_s — pops i32, pushes i32" {
    // i32.const 0x7F ; i32.extend8_s ; end
    const body = [_]u8{ 0x41, 0x7F, 0xC0, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i32.extend16_s — pops i32, pushes i32" {
    const body = [_]u8{ 0x41, 0x7F, 0xC1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i64.extend8_s — pops i64, pushes i64" {
    // i64.const 0x7F ; i64.extend8_s ; end
    const body = [_]u8{ 0x42, 0x7F, 0xC2, 0x0B };
    try validateFunction(i64_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i64.extend16_s — pops i64, pushes i64" {
    const body = [_]u8{ 0x42, 0x7F, 0xC3, 0x0B };
    try validateFunction(i64_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i64.extend32_s — pops i64, pushes i64" {
    const body = [_]u8{ 0x42, 0x7F, 0xC4, 0x0B };
    try validateFunction(i64_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i32.trunc_sat_f32_s (0xFC 00) — pops f32, pushes i32" {
    // f32.const 0.0 ; i32.trunc_sat_f32_s ; end
    const body = [_]u8{ 0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: i64.trunc_sat_f64_u (0xFC 07) — pops f64, pushes i64" {
    // f64.const 0.0 ; i64.trunc_sat_f64_u ; end
    const body = [_]u8{
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFC, 0x07,
        0x0B,
    };
    try validateFunction(i64_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: multivalue block via s33 typeidx — empty params, two i32 results" {
    // module_types[0] = ([] -> [i32, i32])
    const empty_arr = [_]ValType{};
    const i32_pair = [_]ValType{ .i32, .i32 };
    const types = [_]FuncType{.{ .params = &empty_arr, .results = &i32_pair }};
    // function: () -> () body =
    //   block (typeidx 0) ; i32.const 1 ; i32.const 2 ; end ; drop ; drop ; end
    // The block pushes two i32, consumed by two drops outside.
    const body = [_]u8{
        0x02, 0x00, // block (typeidx 0; sleb 0 = 0x00)
        0x41, 0x01, // i32.const 1
        0x41, 0x02, // i32.const 2
        0x0B, // end (block)
        0x1A, 0x1A, // drop, drop
        0x0B, // end (function)
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &types, 0, &.{});
}

test "validate: multivalue block typeidx with non-empty params → BadBlockType" {
    // module_types[0] = ([i32] -> [i32]) — multi-param case deferred
    const i32_arr_local = [_]ValType{.i32};
    const types = [_]FuncType{.{ .params = &i32_arr_local, .results = &i32_arr_local }};
    const body = [_]u8{
        0x41, 0x07, // i32.const 7 (push the param)
        0x02, 0x00, // block (typeidx 0)
        0x0B, // end (block)
        0x0B, // end (function)
    };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &types, 0, &.{});
    try testing.expectError(Error.BadBlockType, r);
}

test "validate: memory.copy (0xFC 10) — pops three i32" {
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; memory.copy ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0A, 0x00, 0x00,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: memory.fill (0xFC 11) — pops three i32" {
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0B, 0x00,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: memory.copy with non-zero reserved byte → BadBlockType" {
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x0A, 0x01, 0x00,
        0x0B,
    };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.BadBlockType, r);
}

test "validate: memory.init (0xFC 8) with valid dataidx" {
    // i32.const 0 ; i32.const 0 ; i32.const 0 ; memory.init 0 ; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x08, 0x00, 0x00,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{});
}

test "validate: memory.init dataidx out of range → InvalidFuncIndex" {
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00,
        0xFC, 0x08, 0x05, 0x00,
        0x0B,
    };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{});
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: data.drop (0xFC 9) with valid dataidx" {
    // data.drop 0 ; end
    const body = [_]u8{ 0xFC, 0x09, 0x00, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{});
}

test "validate: data.drop dataidx out of range → InvalidFuncIndex" {
    const body = [_]u8{ 0xFC, 0x09, 0x03, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 1, &.{});
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: ref.null funcref pushes funcref; ref.is_null consumes + pushes i32" {
    // ref.null funcref ; ref.is_null ; end
    const body = [_]u8{ 0xD0, 0x70, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: ref.null externref pushes externref; drop ; end" {
    const body = [_]u8{ 0xD0, 0x6F, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: ref.null with bad reftype byte → BadValType" {
    const body = [_]u8{ 0xD0, 0x55, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.BadValType, r);
}

test "validate: ref.func with valid funcidx pushes funcref" {
    const types = [_]FuncType{empty_sig};
    // ref.func 0 ; ref.is_null ; end
    const body = [_]u8{ 0xD2, 0x00, 0xD1, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &types, &.{}, &.{}, 0, &.{});
}

test "validate: ref.func with out-of-range funcidx → InvalidFuncIndex" {
    const body = [_]u8{ 0xD2, 0x05, 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: select_typed (0x1C) — i32 result, two i32 vals + cond" {
    // i32.const 1 ; i32.const 2 ; i32.const 0 ; select_typed [i32] ; drop ; end
    const body = [_]u8{
        0x41, 0x01,
        0x41, 0x02,
        0x41, 0x00,
        0x1C, 0x01, 0x7F,
        0x1A,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: select_typed with funcref result" {
    // ref.null funcref ; ref.null funcref ; i32.const 0 ; select_typed [funcref] ; drop ; end
    const body = [_]u8{
        0xD0, 0x70,
        0xD0, 0x70,
        0x41, 0x00,
        0x1C, 0x01, 0x70,
        0x1A,
        0x0B,
    };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
}

test "validate: select_typed with count != 1 → InvalidOpcode" {
    const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0x1C, 0x02, 0x7F, 0x7F, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.InvalidOpcode, r);
}

test "validate: select_typed type mismatch → StackTypeMismatch" {
    // i64.const 0 ; i32.const 0 ; i32.const 0 ; select_typed [i32] ...
    const body = [_]u8{ 0x42, 0x00, 0x41, 0x00, 0x41, 0x00, 0x1C, 0x01, 0x7F, 0x1A, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: ref.is_null on i32 → StackTypeMismatch" {
    const body = [_]u8{ 0x41, 0x00, 0xD1, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.StackTypeMismatch, r);
}

test "validate: table.get pops i32 + pushes elem_type (funcref)" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // i32.const 0 ; table.get 0 ; drop ; end
    const body = [_]u8{ 0x41, 0x00, 0x25, 0x00, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables);
}

test "validate: table.set pops elem_type then i32 idx" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // i32.const 0 ; ref.null funcref ; table.set 0 ; end
    const body = [_]u8{ 0x41, 0x00, 0xD0, 0x70, 0x26, 0x00, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables);
}

test "validate: table.size pushes i32" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // table.size 0 ; end
    const body = [_]u8{ 0xFC, 0x10, 0x00, 0x0B };
    try validateFunction(i32_result_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables);
}

test "validate: table.get with out-of-range tableidx → InvalidFuncIndex" {
    const body = [_]u8{ 0x41, 0x00, 0x25, 0x05, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.InvalidFuncIndex, r);
}

test "validate: table.grow pops i32 + reftype, pushes i32" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // ref.null funcref ; i32.const 1 ; table.grow 0 ; drop ; end
    const body = [_]u8{ 0xD0, 0x70, 0x41, 0x01, 0xFC, 0x0F, 0x00, 0x1A, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables);
}

test "validate: table.fill pops i32 + reftype + i32" {
    const tables = [_]zir.TableEntry{.{ .elem_type = .funcref, .min = 0 }};
    // i32.const 0 ; ref.null funcref ; i32.const 0 ; table.fill 0 ; end
    const body = [_]u8{ 0x41, 0x00, 0xD0, 0x70, 0x41, 0x00, 0xFC, 0x11, 0x00, 0x0B };
    try validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &tables);
}

test "validate: 0xFC unknown sub-opcode → NotImplemented" {
    // f32.const 0.0 ; 0xFC 0xFF ... ; end — sub-op 0xFF is past
    // chunk-2 scope. Should return NotImplemented (chunks 4+ wire
    // the rest).
    const body = [_]u8{ 0x43, 0x00, 0x00, 0x00, 0x00, 0xFC, 0xFF, 0x01, 0x0B };
    const r = validateFunction(empty_sig, &.{}, &body, &.{}, &.{}, &.{}, 0, &.{});
    try testing.expectError(Error.NotImplemented, r);
}
