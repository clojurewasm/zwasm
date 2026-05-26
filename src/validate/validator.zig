// FILE-SIZE-EXEMPT: Wasm spec §3.3 validation single-pass walker (type-stack + control-stack); P1 spec-defined sub-language, intrinsically singular (splitting would create artificial seams across an unsplittable algorithm) (per ADR-0099)
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
const sections = @import("../parse/sections.zig");
const dispatch_collector = @import("../ir/dispatch_collector.zig");
const wasm_byte_map = @import("../ir/wasm_byte_map.zig");
const validator_simd = @import("validator_simd.zig");

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
    /// Wasm spec §3.4.4 / §3.3.5.7-8: a memory op (load/store/
    /// memory.size / memory.grow / memory.fill / memory.copy /
    /// memory.init) appears in a function body but the module
    /// declares no memory (no memory section and no memory
    /// import).
    UnknownMemory,
    /// Wasm spec §3.4.7.3 / §3.4.10: a `ref.func x` in a function
    /// body names a function index x that is not in the module's
    /// declared-funcrefs set (= the set of funcidxs that appear
    /// in any global initializer, element segment, or export, but
    /// excluding occurrences inside function code bodies and the
    /// start function). Spec error text: "undeclared function
    /// reference".
    UndeclaredFuncRef,
    InvalidBranchDepth,
    UnclosedFrames,
    TrailingBytes,
    OperandStackOverflow,
    ControlStackOverflow,
    ArityMismatch,
    /// Wasm SIMD spec §3.3.6.X (lane-index range): an
    /// `extract_lane*` / `replace_lane*` / load_lane / store_lane
    /// op's 1-byte lane-index immediate is ≥ the shape's lane
    /// count (16 / 8 / 4 / 2 depending on i8x16 / i16x8 / i32x4 /
    /// i64x2 / f32x4 / f64x2). Per spec, this is a validation-time
    /// reject (`assert_invalid`), not a deferred runtime trap.
    InvalidLaneIndex,
    /// Wasm spec §3.3.7 (memarg alignment): a memory op's
    /// alignment immediate (log2 of byte alignment) exceeds the
    /// op's natural alignment. Covers both scalar and SIMD memory
    /// ops. Naturals: v128.load / store ≤ 4 (16-byte); v128.load64_splat
    /// / load64_lane / store64_lane / load64_zero / loadXxY ≤ 3
    /// (8-byte); i64/f64 ≤ 3; 32-bit ≤ 2; 16-bit ≤ 1; 8-bit ≤ 0.
    /// Validation-time reject (spec assert_invalid).
    InvalidAlignment,
    /// Wasm 3.0 EH §3.3.10.7: a `throw tag_idx` op (or a
    /// `try_table` catch / catch_ref clause) references a tag
    /// index outside `module.tags[]`. Reported by `opThrow` and
    /// `validateCatchVec` once `Module.tags` reaches the validator
    /// (10.E-N).
    InvalidTagIndex,
    NotImplemented,
    OutOfMemory,
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

/// Wasm spec §5.3.1 valtype encoding bytes.
fn valTypeByte(t: ValType) u8 {
    return switch (t) {
        .i32 => 0x7F,
        .i64 => 0x7E,
        .f32 => 0x7D,
        .f64 => 0x7C,
        .v128 => 0x7B,
        .funcref => 0x70,
        .externref => 0x6F,
        // Wasm 3.0 GC §5.3.1 — i31ref byte = 0x6C per ADR-0116.
        .i31ref => 0x6C,
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
            // try_table: branches to the try_table label arrive
            // on `end` (catch dispatch uses the catch's own
            // label_idx, not this frame's label), so use the
            // block end_type rule. Per Wasm 3.0 EH §3.3.10.6.
            .block, .if_then, .else_open, .try_table => self.end_type,
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

/// Wasm 3.0 memory64 — `validateFunction` variant that threads
/// `memory0_idx_type` so memory ops (load/store) pop the correct
/// address valtype (i32 for default memory, i64 for memory64 per
/// the memory section's flag bit 0x04 / ADR-0111 D1). Used by
/// `frontendValidate` in `runtime/instance/instantiate.zig` so
/// modules declaring an i64 memory validate cleanly instead of
/// rejecting their load/store bodies with StackTypeMismatch.
pub fn validateFunctionWithMemIdx(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    memory0_idx_type: sections.MemoryEntry.IdxType,
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
        .memory0_idx_type = memory0_idx_type,
    };
    try v.run();
}

/// 10.E EH module-compile path — `frontendValidate` variant that
/// threads both `memory0_idx_type` AND `tags`. Used by
/// `runtime/instance/instantiate.zig::frontendValidate` so the
/// CLI / c_api compile path validates `throw` / `try_table` ops
/// without rejecting them on the empty-tags default.
pub fn validateFunctionWithMemIdxAndTags(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    memory0_idx_type: sections.MemoryEntry.IdxType,
    tags: []const sections.TagEntry,
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
        .memory0_idx_type = memory0_idx_type,
        .tags = tags,
    };
    try v.run();
}

/// Wasm 3.0 EH (10.E-N-1) — `validateFunction` variant that also
/// threads the decoded tag section so `throw` and try_table catch
/// clauses range-check `tag_idx` against `module.tags[]`. Used
/// by EH unit tests; production `compileWasm` threads tags into
/// `validateFunctionAndCollectSelectTypesWithMemory` directly.
pub fn validateFunctionWithTags(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    tags: []const sections.TagEntry,
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
        .tags = tags,
    };
    try v.run();
}

/// Same as `validateFunction`, but additionally collects per-untyped-
/// `select` (opcode 0x1B) resolved operand valtype bytes into
/// `out_select_types`, in body-walk order. Used by the lower / emit
/// pipeline (D-115) to populate `ZirInstr.extra` for untyped select so
/// emit dispatches FCSEL / FpSelect on FP-class operands instead of
/// silently defaulting to GPR-class CSEL (Wasm spec §3.3.2.2).
///
/// Wasm spec §3.3.2.2 — untyped select infers t1 == t2 from the
/// validator's value-stack; the type byte stored here is the canonical
/// valtype encoding (0x7F i32 / 0x7E i64 / 0x7D f32 / 0x7C f64 /
/// 0x70 funcref / 0x6F externref). Polymorphic-bottom resolves to
/// 0x7F (the harmless default; pre-d-39 fall-through).
pub fn validateFunctionAndCollectSelectTypes(
    allocator: std.mem.Allocator,
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    out_select_types: *std.ArrayList(u8),
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
        .out_select_types = out_select_types,
        .out_allocator = allocator,
    };
    try v.run();
}

/// §9.9 / 9.9-l-1b-d093-d79 — variant that also threads
/// `memory_count` so the validator can reject memory ops
/// (load/store/size/grow/fill/copy/init) in function bodies
/// when the module declares no memory. Production callers
/// in `compileWasm` use this variant; the original
/// `validateFunctionAndCollectSelectTypes` keeps the
/// legacy default (`memory_count = 0`) for tests that
/// don't exercise memory ops.
pub fn validateFunctionAndCollectSelectTypesWithMemory(
    allocator: std.mem.Allocator,
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    data_count: u32,
    tables: []const zir.TableEntry,
    elem_count: u32,
    memory_count: u32,
    declared_funcs: []const bool,
    elem_types: []const ValType,
    data_count_section_present: bool,
    out_select_types: *std.ArrayList(u8),
    memory0_idx_type: sections.MemoryEntry.IdxType,
    tags: []const sections.TagEntry,
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
        .memory_count = memory_count,
        .memory0_idx_type = memory0_idx_type,
        .declared_funcs = declared_funcs,
        .elem_types = elem_types,
        .data_count_section_present = data_count_section_present,
        .out_select_types = out_select_types,
        .out_allocator = allocator,
        .tags = tags,
    };
    try v.run();
}

pub const Validator = struct {
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
    /// §9.9 / 9.9-l-1b-d093-d79 — count of memories (imports +
    /// defined) reachable at function-body validation time.
    /// Wasm 2.0 §3.4.4 caps total memories at 1; this is
    /// either 0 or 1 in practice. Memory ops in function bodies
    /// (load/store/size/grow + bulk variants) require memory_count
    /// >= 1; absent memory → `Error.UnknownMemory`.
    ///
    /// Default = 1: legacy `validateFunction` /
    /// `validateFunctionAndCollectSelectTypes` callers (unit
    /// tests, wast_runner) don't thread memory_count and
    /// assume memory ops are valid — preserving pre-d-79
    /// behaviour. Production `compileWasm` uses
    /// `validateFunctionAndCollectSelectTypesWithMemory`
    /// which sets memory_count explicitly per module.
    memory_count: u32 = 1,
    /// ADR-0111 D2 — memory 0's idx_type for Wasm 3.0 memory64.
    /// Determines the address operand type at opLoad/opStore
    /// (i32-indexed memory → pop i32 addr; i64-indexed → pop
    /// i64 addr). Default `.i32` keeps legacy `validateFunction`
    /// / `validateFunctionAndCollectSelectTypes` callers behaviour
    /// -preserving (they don't thread memory64 state); production
    /// `compileWasm` uses the WithMemory entry which sets it
    /// explicitly per module.
    memory0_idx_type: sections.MemoryEntry.IdxType = .i32,
    /// §9.9 / 9.9-l-1b-d093-d82 — declared-funcrefs bitset per
    /// Wasm spec §3.4.10. Length = total funcs (imports +
    /// defined); entry `true` iff that funcidx appears in some
    /// global initializer, element segment (funcidx or init expr),
    /// or export (kind=func). Function code bodies and the start
    /// function do NOT contribute. Empty slice (default) disables
    /// enforcement so legacy callers (unit tests, wast_runner)
    /// keep prior behaviour; production `compileWasm` passes a
    /// populated slice.
    declared_funcs: []const bool = &.{},
    /// §9.9 / 9.9-l-1b-d093-d83 — per-element-segment reftype
    /// (parallel to `elem_count`; length = elem_count when
    /// populated). Used by `opTableInit` to enforce Wasm spec
    /// §3.3.5.20: `table.init x y` requires
    /// `elem_types[x] == tables[y].elem_type`. Empty slice
    /// (default) disables the per-elem reftype check so legacy
    /// callers retain prior behaviour (chunk 5d-2 era accepted
    /// any in-range elemidx/tableidx pair).
    elem_types: []const ValType = &.{},
    /// §9.9 / 9.9-l-1b-d093-d84 — Wasm spec §5.5.10: when any
    /// function body uses `memory.init` (0xFC 0x08) or
    /// `data.drop` (0xFC 0x09), the module MUST contain the
    /// optional `data count` section (id 12). False ↔ section
    /// absent; the two opcodes' validation paths reject.
    /// Default `true` keeps legacy callers / unit tests
    /// unaffected.
    data_count_section_present: bool = true,
    /// Wasm 3.0 EH §4.5 — decoded tag section. `throw tag_idx`
    /// and try_table catch (0x00 / 0x01) reference this by index
    /// to look up the tag's params (= the FuncType at
    /// `module_types[tags[tag_idx].typeidx]`). Default `&.{}`
    /// preserves the pre-10.E-N behaviour for callers that
    /// didn't thread the tag section through (their `throw`
    /// will now reject with `Error.InvalidTagIndex` — the
    /// existing test surface migrated at 10.E-N-1; production
    /// `compileWasm` passes the decoded section).
    tags: []const sections.TagEntry = &.{},

    operand_buf: [max_operand_stack]TypeOrBot = undefined,
    operand_len: usize = 0,

    control_buf: [max_control_stack]ControlFrame = undefined,
    control_len: usize = 0,

    /// D-115 d-39: when non-null, `opSelect` appends the resolved
    /// operand valtype byte per untyped `select` (0x1B). Body-walk
    /// order; consumed by `lower.zig` to populate `ZirInstr.extra`
    /// so emit can dispatch FCSEL / FpSelect on FP-class operands.
    out_select_types: ?*std.ArrayList(u8) = null,
    out_allocator: ?std.mem.Allocator = null,

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

    // SIBLING-PUB: validator_simd.zig (per ADR-0083 extraction)
    pub fn pushType(self: *Validator, t: ValType) Error!void {
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
    // SIBLING-PUB: validator_simd.zig (per ADR-0083 extraction)
    pub fn popExpect(self: *Validator, expected: ValType) Error!void {
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
                // §9.9 / 9.9-l-1b-d093-d45 (D-118): reftype block-
                // results per Wasm 2.0 §5.3.5 (`valtype` for block
                // types includes funcref / externref). `br_table.wast`'s
                // `meet-funcref` / `meet-externref` exports declare
                // `(block (result <ref>) ...)` blocks. Reftype-class
                // codegen plumbing (d-33) aliases these onto the
                // i64 8-byte gpr-class scalar path.
                -16 => .{ .single = .funcref }, // 0x70
                -17 => .{ .single = .externref }, // 0x6F
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
        // §9.12-B / B7: route through dispatch_collector before the
        // legacy switch. Per ADR-0073 + `.dev/dispatcher_wire_design.md`
        // §2.1 option B: `wasm_byte_map.byteToZirOp(op)` translates the
        // Wasm bytecode to the ZirOp tag; then
        // `dispatch_collector.dispatcher(.validate)` routes to per-op
        // file. NotMigrated / UnsupportedOpForBuildLevel → fall
        // through to legacy switch. Bytes not yet in the map (null
        // return) also fall through silently.
        if (wasm_byte_map.byteToZirOp(op)) |zir_tag| {
            if (dispatch_collector.dispatcher(.validate)(zir_tag, .{})) |_| {
                // Migrated op handled by per-op file.
                return;
            } else |err| switch (err) {
                error.NotMigrated, error.UnsupportedOpForBuildLevel => {},
            }
        }
        switch (op) {
            // Control flow
            0x00 => try self.opUnreachable(),
            0x01 => {}, // nop
            0x02 => try self.opBlock(.block),
            0x03 => try self.opBlock(.loop),
            0x04 => try self.opIf(),
            // Wasm 3.0 EH `try_table` (§3.3.10.6 / §4.5).
            0x1F => try self.opTryTable(),
            // Wasm 3.0 EH `throw tag_idx` (§3.3.10.7).
            0x08 => try self.opThrow(),
            // Wasm 3.0 EH `throw_ref` (§3.3.10.8).
            0x0A => try self.opThrowRef(),
            0x05 => try self.opElse(),
            0x0B => try self.opEnd(),
            0x0C => try self.opBr(),
            0x0D => try self.opBrIf(),
            0x0E => try self.opBrTable(),
            0x0F => try self.opReturn(),
            0x10 => try self.opCall(),
            0x11 => try self.opCallIndirect(),
            // Wasm 3.0 tail-call proposal.
            0x12 => try self.opReturnCall(),
            0x13 => try self.opReturnCallIndirect(),

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
            // §3.3.7 natural-alignment caps: load8≤0, load16≤1,
            // load32≤2, load64≤3 (log2 of byte width).
            0x28 => try self.opLoad(.i32, 2), // i32.load
            0x29 => try self.opLoad(.i64, 3), // i64.load
            0x2A => try self.opLoad(.f32, 2), // f32.load
            0x2B => try self.opLoad(.f64, 3), // f64.load
            0x2C => try self.opLoad(.i32, 0), // i32.load8_s
            0x2D => try self.opLoad(.i32, 0), // i32.load8_u
            0x2E => try self.opLoad(.i32, 1), // i32.load16_s
            0x2F => try self.opLoad(.i32, 1), // i32.load16_u
            0x30 => try self.opLoad(.i64, 0), // i64.load8_s
            0x31 => try self.opLoad(.i64, 0), // i64.load8_u
            0x32 => try self.opLoad(.i64, 1), // i64.load16_s
            0x33 => try self.opLoad(.i64, 1), // i64.load16_u
            0x34 => try self.opLoad(.i64, 2), // i64.load32_s
            0x35 => try self.opLoad(.i64, 2), // i64.load32_u

            // Stores
            0x36 => try self.opStore(.i32, 2), // i32.store
            0x37 => try self.opStore(.i64, 3), // i64.store
            0x38 => try self.opStore(.f32, 2), // f32.store
            0x39 => try self.opStore(.f64, 3), // f64.store
            0x3A => try self.opStore(.i32, 0), // i32.store8
            0x3B => try self.opStore(.i32, 1), // i32.store16
            0x3C => try self.opStore(.i64, 0), // i64.store8
            0x3D => try self.opStore(.i64, 1), // i64.store16
            0x3E => try self.opStore(.i64, 2), // i64.store32

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

            // Wasm 3.0 typed function references (function-references proposal).
            0xD3 => try self.opRefAsNonNull(),
            0xD4 => try self.opBrOnNull(),
            0xD6 => try self.opBrOnNonNull(),
            0x14 => try self.opCallRef(),
            0x15 => try self.opReturnCallRef(),

            // Wasm 2.0 prefix opcodes (§9.2 / 2.3 chunk 2 onward)
            0xFC => try self.dispatchPrefixFC(),

            // Wasm 3.0 GC prefix.
            0xFB => try self.dispatchPrefixFB(),

            // Wasm SIMD-128 prefix (§9.9 / Phase 9 per ADR-0041).
            // The validator dispatches inline (mirroring 0xFC's
            // shape) per ADR-0041 Revision 2 — the central
            // DispatchTable's validator slot is not consumed
            // today; that's a Phase 14+ structural refactor.
            0xFD => try validator_simd.dispatchPrefixFD(self),

            else => return Error.NotImplemented,
        }
    }

    // ----------------------------------------------------------------
    // Opcode handlers
    // ----------------------------------------------------------------

    fn opUnreachable(self: *Validator) Error!void {
        self.markUnreachable();
    }

    /// Wasm 3.0 EH §3.3.10.6 — `try_table blocktype vec(catch) ...
    /// end`. Pushes a `.try_table` control frame; body validates
    /// like `block`. The catch vec is validated for label-index
    /// range (each catch's branch target must reference an
    /// existing outer label) but NOT for label-type compatibility
    /// — full type checking lands at 10.E-5 alongside the interp
    /// unwind path. Catch encoding per §4.5: 0x00 catch / 0x01
    /// catch_ref carry tag_idx + label_idx; 0x02 catch_all / 0x03
    /// catch_all_ref carry label_idx only.
    /// Wasm spec 3.0 §3.3.10.7 — `throw tag_idx`: raise an
    /// exception with the tag's payload. Range-checks tag_idx
    /// against `self.tags`, looks up the tag's typeidx →
    /// `module_types[typeidx]`, pops the params (last-first)
    /// from the operand stack, then marks unreachable
    /// (terminator).
    fn opThrow(self: *Validator) Error!void {
        const tag_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (tag_idx >= self.tags.len) return Error.InvalidTagIndex;
        const tag = self.tags[tag_idx];
        if (tag.typeidx >= self.module_types.len) return Error.InvalidFuncIndex;
        const ft = self.module_types[tag.typeidx];
        try self.popLabelTypes(blockTypeOfSlice(ft.params));
        self.markUnreachable();
    }

    /// Wasm spec 3.0 §3.3.10.8 — `throw_ref`: re-raise an
    /// exception via an `exnref` on the operand stack.
    /// Polymorphic-stack from here. v2.0 catalogue can't express
    /// the (ref null exn) type so we accept any reftype as the
    /// popped value (same caveat as 10.R-1..5 typed-ref
    /// catalogue limitation).
    fn opThrowRef(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (t != .funcref and t != .externref) return Error.StackTypeMismatch,
        }
        self.markUnreachable();
    }

    fn opTryTable(self: *Validator) Error!void {
        const bt = try self.readBlockType();
        try self.validateCatchVec();
        try self.popLabelTypes(bt.start);
        try self.pushFrame(.try_table, bt.start, bt.end);
        switch (bt.start) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    /// Validates a try_table's catch vec — currently just label
    /// range. Tag-index range validation lands when Module.tags[]
    /// reaches the validator (10.E-N). Label-type matching lands
    /// at 10.E-5 with the interp unwind path.
    fn validateCatchVec(self: *Validator) Error!void {
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const kind = self.body[self.pos];
            self.pos += 1;
            switch (kind) {
                0x00, 0x01 => {
                    const tag_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (tag_idx >= self.tags.len) return Error.InvalidTagIndex;
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                },
                0x02, 0x03 => {
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                },
                else => return Error.BadBlockType,
            }
        }
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
        // D-093 (d-10) — Wasm spec §3.4.4: the else-arm starts with
        // the if-frame's `start` (param) types pushed back onto the
        // operand stack (same shape the then-arm saw at entry).
        // Pre-d-10 omitted this, surfacing as `if.wast:param`
        // StackUnderflow because the else-arm body's `(i32.add)`
        // expected param + const but found only const.
        // `start_type` mirrors `BlockType bt.start` from opIf — for
        // Wasm 1.0 blocktypes it's `.empty`; for Wasm 2.0 typeidx
        // blocktypes it's `blockTypeOfSlice(ft.params)`.
        switch (frame.start_type) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
    }

    fn opEnd(self: *Validator) Error!void {
        const frame = self.topFrame().*;
        // §9.9 / 9.9-l-1b-d093-d81 — Wasm spec §3.3.5
        // "ifelse" validation: an `if` block without an `else`
        // is equivalent to an empty `else` body. For the empty
        // else to be type-correct, the `if`'s start type
        // (params) must equal its end type (results). Drains
        // `if` corpus SKIP-VALIDATOR-GAP entries where
        // `if (result T)` lacks an else branch.
        if (frame.kind == .if_then) {
            if (!labelTypesEq(frame.start_type, frame.end_type)) {
                return Error.StackTypeMismatch;
            }
        }
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
    /// Wasm 3.0 GC prefix (0xFB). Currently dispatches only the
    /// i31 sub-trio (28 / 29 / 30); other GC sub-opcodes light up
    /// per 10.G heap / struct / array sub-chunks.
    fn dispatchPrefixFB(self: *Validator) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            28 => try self.opRefI31(),
            29, 30 => try self.opI31Get(), // .get_s / .get_u share validator shape
            else => return Error.NotImplemented,
        }
    }

    /// Wasm spec 3.0 §3.x (GC) — `ref.i31`: pop i32, push an
    /// i31-tagged reftype. v2.0 reftype catalogue can't express
    /// the (ref i31) precision; we push `.funcref` as the
    /// validator stand-in (same caveat as 10.R-1..5 typed-ref
    /// catalogue limitation — typed precision deferred to 10.G
    /// typed-ref catalogue extension).
    fn opRefI31(self: *Validator) Error!void {
        try self.popExpect(.i32);
        try self.pushType(.funcref);
    }

    /// Wasm spec 3.0 §3.x (GC) — `i31.get_s` / `i31.get_u`: pop a
    /// reftype (must be an i31 ref at runtime; runtime checks
    /// `isI31Ref` and traps otherwise), push i32. Validator
    /// shape identical for both ops (sign vs unsign disambiguation
    /// is runtime-side).
    fn opI31Get(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (t != .funcref and t != .externref) return Error.StackTypeMismatch,
        }
        try self.pushType(.i32);
    }

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

    /// memory.copy: 0xFC 10 0x00 0x00 (two reserved memidx bytes).
    /// Pops three idx-type values (n, src, dst); pushes nothing.
    /// For memory64 the three are i64 per Wasm 3.0 §3.4.7
    /// (multi-memory cross-memory copies use the destination
    /// memory's idx_type per spec; single-memory case uses memory 0).
    fn opMemoryCopy(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        if (self.pos + 2 > self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00 or self.body[self.pos + 1] != 0x00) {
            return Error.BadBlockType; // reserved bytes must be zero
        }
        self.pos += 2;
        const addr = self.memAddrType();
        try self.popExpect(addr); // n
        try self.popExpect(addr); // src
        try self.popExpect(addr); // dst
    }

    /// memory.init: 0xFC 8 dataidx 0x00 (one reserved memidx byte).
    /// Pops three values (n:i32, src:i32, dst:idx_type); pushes
    /// nothing. dataidx must be < module's data segment count.
    /// Wasm 3.0 §3.4.7: dst uses the memory's idx_type (i64 for
    /// memory64); src + n are always i32 (data-segment offsets).
    fn opMemoryInit(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        if (!self.data_count_section_present) return Error.UnknownMemory;
        const dataidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dataidx >= self.data_count) return Error.InvalidFuncIndex;
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.BadBlockType;
        self.pos += 1;
        try self.popExpect(.i32); // n (data-segment byte count)
        try self.popExpect(.i32); // src (data-segment offset)
        try self.popExpect(self.memAddrType()); // dst (memory addr)
    }

    /// data.drop: 0xFC 9 dataidx. No operand stack effects.
    fn opDataDrop(self: *Validator) Error!void {
        if (!self.data_count_section_present) return Error.UnknownMemory;
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

    /// Wasm spec 3.0 §3.3.8.5 (function-references proposal):
    /// `ref.as_non_null` — pop reftype; if null, trap at runtime.
    /// Statically, narrows `(ref null T)` to `(ref T)` — same Wasm
    /// valtype here since v2.0 reftype catalogue does NOT yet
    /// model the typed-ref nullability axis (the .funcref /
    /// .externref enum is opaque to nullability). Push the same
    /// reftype back. Validator surface preserves backward-compat
    /// for legacy reftype callers; nullability tightening lands
    /// at 10.G (WasmGC) where `(ref $sig)` typed refs need their
    /// own typed-ref module per `phase10_design_plan_ja.md` §3.2.
    fn opRefAsNonNull(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {
                try self.pushType(.funcref);
            },
            .known => |t| {
                if (t != .funcref and t != .externref) return Error.StackTypeMismatch;
                try self.pushType(t);
            },
        }
    }

    /// Wasm spec 3.0 §3.3.8.6 (function-references proposal):
    /// `br_on_null l` — pop reftype; if null at runtime, branch
    /// to label l (consume l.label_types from stack as branch
    /// values). Otherwise the (non-null) reftype is preserved on
    /// the fall-through path. Stack effect: precondition
    /// `[t1*, reftype]` where label l takes `[t1*]`; postcondition
    /// (fall-through) `[t1*, reftype]` (reftype narrowed to
    /// non-null, but v2.0 catalogue can't express the narrowing).
    /// Branch path destination expects `[t1*]`.
    fn opBrOnNull(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        // Pop reftype first (it's the topmost value, the null-test
        // condition that the branch consumes).
        const top = try self.popAny();
        const reftype: ValType = switch (top) {
            .bot => .funcref, // polymorphic; pick any reftype
            .known => |t| blk: {
                if (t != .funcref and t != .externref) return Error.StackTypeMismatch;
                break :blk t;
            },
        };
        // Resolve target label; verify stack carries label's types.
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        const lt = target.labelType();
        try self.popLabelTypes(lt);
        // Fall-through: push label types back + reftype back.
        switch (lt) {
            .empty => {},
            .single => |t| try self.pushType(t),
            .multi => |ts| for (ts) |t| try self.pushType(t),
        }
        try self.pushType(reftype);
    }

    /// Wasm spec 3.0 §3.3.8.7 (function-references proposal):
    /// `br_on_non_null l` — pop reftype; if non-null at runtime,
    /// branch to label l (consume l.label_types — which include
    /// the reftype as the last entry — from stack as branch
    /// values, ref passed at top). Otherwise the (null) reftype
    /// is consumed and the fall-through path has just the
    /// prefix on stack. Stack effect: precondition
    /// `[t1*, reftype]` where label l takes `[t1*, reftype]`;
    /// postcondition (fall-through) `[t1*]` (ref consumed).
    /// Branch path destination expects `[t1*, reftype]` (non-null
    /// narrowed, but v2.0 catalogue can't express the narrowing).
    fn opBrOnNonNull(self: *Validator) Error!void {
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        const top = try self.popAny();
        const reftype: ValType = switch (top) {
            .bot => .funcref, // polymorphic; pick any reftype
            .known => |t| blk: {
                if (t != .funcref and t != .externref) return Error.StackTypeMismatch;
                break :blk t;
            },
        };
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        const lt = target.labelType();
        // Label l must take [t1*, reftype]; the last entry of lt
        // must match the popped reftype. Pop the prefix t1* from
        // stack + push back (fall-through has just [t1*]).
        switch (lt) {
            .empty => return Error.StackTypeMismatch,
            .single => |t| {
                if (t != reftype) return Error.StackTypeMismatch;
                // Prefix is empty; no further pop/push.
            },
            .multi => |ts| {
                if (ts.len == 0) return Error.StackTypeMismatch;
                if (ts[ts.len - 1] != reftype) return Error.StackTypeMismatch;
                const prefix = ts[0 .. ts.len - 1];
                var i: usize = prefix.len;
                while (i > 0) {
                    i -= 1;
                    try self.popExpect(prefix[i]);
                }
                for (prefix) |t| try self.pushType(t);
            },
        }
    }

    /// Wasm spec 3.0 §3.3.8.10 (function-references proposal):
    /// `call_ref typeidx` — pop a funcref (whose typed signature
    /// must match `module_types[typeidx]`); pop the args matching
    /// that signature's params; push the signature's results.
    /// Runtime separately traps if the funcref is null
    /// (Trap.NullReference) or its actual sig mismatches
    /// (Trap.IndirectCallTypeMismatch).
    ///
    /// v2.0 reftype catalogue can't express the per-funcref typed
    /// signature, so the validator only checks that the topmost
    /// stack entry is a reftype (funcref / externref / .bot). The
    /// runtime side enforces the sig-equality. Typed `(ref $sig)`
    /// validation arrives with 10.G.
    fn opCallRef(self: *Validator) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (type_idx >= self.module_types.len) return Error.InvalidFuncIndex;
        const callee = self.module_types[type_idx];
        // Pop topmost funcref (polymorphic over funcref/externref/.bot
        // per the v2.0 catalogue limitation).
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (t != .funcref and t != .externref) return Error.StackTypeMismatch,
        }
        // Pop args in reverse, then push results.
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        for (callee.results) |r| try self.pushType(r);
    }

    /// Wasm spec 3.0 §3.3.10.5 (function-references + tail-call):
    /// `return_call_ref typeidx` — tail-call variant of call_ref.
    /// Pop a funcref + the typeidx-determined params; verify that
    /// the callee's results match the **enclosing function's**
    /// return type (else the tail call would lose values); mark
    /// the stack polymorphic-from-here (= unreachable) per spec.
    /// Runtime trap semantics inherit call_ref's null + sig-mismatch
    /// behaviour.
    ///
    /// Same v2.0 catalogue limitation as call_ref: the validator
    /// can't enforce typed `(ref $sig)` precision; the runtime sig
    /// check supplies that strictness.
    fn opReturnCallRef(self: *Validator) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (type_idx >= self.module_types.len) return Error.InvalidFuncIndex;
        const callee = self.module_types[type_idx];
        // Pop topmost funcref (polymorphic over funcref/externref/.bot).
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (t != .funcref and t != .externref) return Error.StackTypeMismatch,
        }
        // Pop callee params in reverse (the tail-call args).
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        try self.checkResultsMatchFnReturn(callee.results);
        // Polymorphic-stack from here (terminator).
        self.markUnreachable();
    }

    /// Tail-call result-type check used by `return_call*` family
    /// (Wasm 3.0 §3.3.10.3-5). The callee's results MUST match the
    /// enclosing function's return type element-wise — otherwise the
    /// tail call would lose values and the function would
    /// type-violate at its `end`.
    fn checkResultsMatchFnReturn(self: *Validator, callee_results: []const ValType) Error!void {
        const fn_frame = &self.control_buf[0];
        switch (fn_frame.end_type) {
            .empty => if (callee_results.len != 0) return Error.StackTypeMismatch,
            .single => |t| {
                if (callee_results.len != 1 or callee_results[0] != t) return Error.StackTypeMismatch;
            },
            .multi => |ts| {
                if (callee_results.len != ts.len) return Error.StackTypeMismatch;
                for (callee_results, ts) |a, b| if (a != b) return Error.StackTypeMismatch;
            },
        }
    }

    /// Wasm spec 3.0 §3.3.10.3 (tail-call): `return_call funcidx` —
    /// tail-call variant of `call`. Pop callee's params + verify
    /// callee's results match the enclosing function's return type;
    /// then polymorphic-stack (terminator).
    fn opReturnCall(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.func_types.len) return Error.InvalidFuncIndex;
        const callee = self.func_types[idx];
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        try self.checkResultsMatchFnReturn(callee.results);
        self.markUnreachable();
    }

    /// Wasm spec 3.0 §3.3.10.4 (tail-call): `return_call_indirect
    /// typeidx tableidx` — tail-call variant of `call_indirect`.
    /// Pop i32 selector + callee's params; verify callee's results
    /// match the enclosing function's return type; polymorphic-stack.
    /// Table must be `funcref` (same constraint as call_indirect).
    fn opReturnCallIndirect(self: *Validator) Error!void {
        const type_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        const table_idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (table_idx >= self.tables.len) return Error.InvalidFuncIndex;
        if (self.tables[table_idx].elem_type != .funcref) return Error.InvalidFuncIndex;
        if (type_idx >= self.module_types.len) return Error.InvalidFuncIndex;
        const callee = self.module_types[type_idx];
        try self.popExpect(.i32);
        var i: usize = callee.params.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(callee.params[i]);
        }
        try self.checkResultsMatchFnReturn(callee.results);
        self.markUnreachable();
    }

    /// Wasm spec §3.4.7.3 / §3.4.10 (ref.func x): read funcidx,
    /// validate it's within the module's function index space and
    /// — when the caller supplied a non-empty `declared_funcs`
    /// bitset — that the funcidx is in the module's declared set.
    /// The declared set captures funcidxs referenced from globals
    /// / elements / exports but NOT from other function bodies or
    /// the start function. Pushes funcref.
    fn opRefFunc(self: *Validator) Error!void {
        const idx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (idx >= self.func_types.len) return Error.InvalidFuncIndex;
        if (self.declared_funcs.len != 0) {
            if (idx >= self.declared_funcs.len or !self.declared_funcs[idx]) {
                return Error.UndeclaredFuncRef;
            }
        }
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

    /// Wasm spec §3.3.5.20 (table.init x y, 0xFC 12): pop three
    /// i32 (n, src, dst). The elemidx and tableidx must both be
    /// in range, and the elem segment's reftype must equal the
    /// destination table's reftype. The per-elem reftype check
    /// fires only when `elem_types` is populated (production
    /// `compileWasm` path); legacy callers without the slice
    /// retain pre-d-83 behaviour.
    fn opTableInit(self: *Validator) Error!void {
        const elemidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const tableidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (elemidx >= self.elem_count) return Error.InvalidFuncIndex;
        if (tableidx >= self.tables.len) return Error.InvalidFuncIndex;
        if (self.elem_types.len != 0) {
            if (self.elem_types[elemidx] != self.tables[tableidx].elem_type) {
                return Error.StackTypeMismatch;
            }
        }
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
    /// Pops three values (n:idx_type, val:i32, dst:idx_type);
    /// pushes nothing. Wasm 3.0 §3.4.7: dst + n use the memory's
    /// idx_type (i64 for memory64); val is always i32.
    fn opMemoryFill(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.BadBlockType;
        self.pos += 1;
        const addr = self.memAddrType();
        try self.popExpect(addr); // n
        try self.popExpect(.i32); // val
        try self.popExpect(addr); // dst
    }

    fn opBrTable(self: *Validator) Error!void {
        const n = try leb128.readUleb128(u32, self.body, &self.pos);
        try self.popExpect(.i32); // selector
        // Wasm 2.0 §3.3.5.8 (br_table):
        //   - All targets' label types must have the same arity
        //     (§9.9 / 9.9-l-1b-d093-d85 — even in polymorphic
        //     stack mode, arity mismatch cannot unify via .bot).
        //   - Numeric-type equality across targets is enforced in
        //     reachable code only; in polymorphic (post-
        //     unreachable / br / return) code the joined type
        //     collapses to `bot` so per-target type may differ
        //     (the `meet-bottom` fixture in `unreached-valid.wast`
        //     exercises `block f32` vs `block f64` targets).
        //   - The label-type pop happens unconditionally — in
        //     polymorphic code the operand stack may still carry
        //     concrete values pushed AFTER unreachable, and those
        //     must match the joined label type just as in
        //     reachable code (drains `unreached-invalid.85` =
        //     `block (result i32); unreachable; f32.const 0;
        //     i32.const 1; br_table 0; end` where the f32 must
        //     reject against the inner block's i32 result type).
        const polymorphic = self.topFrame().unreachable_flag;
        const arityOf = struct {
            fn f(bt: BlockType) usize {
                return switch (bt) {
                    .empty => 0,
                    .single => 1,
                    .multi => |ts| ts.len,
                };
            }
        }.f;
        var first: ?BlockType = null;
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            const depth = try leb128.readUleb128(u32, self.body, &self.pos);
            const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
            const lt = target.labelType();
            if (first) |prev| {
                if (arityOf(prev) != arityOf(lt)) return Error.ArityMismatch;
                if (!polymorphic and !labelTypesEq(prev, lt)) return Error.StackTypeMismatch;
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
        // §9.9 / 9.9-l-1b-d093-d80 — Wasm spec §3.3.5.6:
        // call_indirect requires the referenced table to have
        // reftype `funcref`. Externref tables cannot back
        // call_indirect.
        if (self.tables[table_idx].elem_type != .funcref) return Error.InvalidFuncIndex;
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
        // §9.9 / 9.9-l-1b-d093-d81 — Wasm spec §3.3.2.2:
        // untyped `select` requires the value operands to have
        // a *numeric* type (i32/i64/f32/f64/v128). Reftype
        // operands (funcref / externref) must use `select_typed`
        // (0x1C). Rejecting reftype operands here drains the
        // `select.4` SKIP-VALIDATOR-GAP case where untyped select
        // appears with externref params.
        try self.popExpect(.i32);
        const a = try self.popAny();
        const b = try self.popAny();
        const isNumeric = struct {
            fn check(t: ValType) bool {
                return switch (t) {
                    .i32, .i64, .f32, .f64, .v128 => true,
                    // 10.G op_gc cycle 2: i31ref is a reftype per
                    // Wasm 3.0 spec — untyped select rejects ref
                    // operands per Wasm 2.0 §3.3.2.2.
                    .funcref, .externref, .i31ref => false,
                };
            }
        }.check;
        switch (a) {
            .known => |ka| if (!isNumeric(ka)) return Error.StackTypeMismatch,
            .bot => {},
        }
        switch (b) {
            .known => |kb| if (!isNumeric(kb)) return Error.StackTypeMismatch,
            .bot => {},
        }
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
        // D-115 d-39: emit the resolved valtype byte for the lower /
        // emit pipeline. Polymorphic-bottom (only reachable in dead
        // code after `unreachable` / `br`) resolves to 0x7F i32 — the
        // default CSEL Wd path, harmless because the bytes are
        // unreachable at runtime per Wasm spec §3.3.5.
        if (self.out_select_types) |list| {
            const byte: u8 = switch (result) {
                .known => |t| valTypeByte(t),
                .bot => 0x7F,
            };
            try list.append(self.out_allocator.?, byte);
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

    /// Wasm 3.0 §5.4.6 — memarg align uleb bit 6 (0x40) signals
    /// an explicit memidx LEB follows. Mirrors `lower.zig::emitMemarg`
    /// byte consumption so validator + lowerer stay in sync; without
    /// this the validator's position desyncs on bit-6-set memargs
    /// and subsequent opcodes parse from wrong offsets.
    fn skipMemarg(self: *Validator) Error!void {
        const raw_align = try leb128.readUleb128(u32, self.body, &self.pos);
        if ((raw_align & 0x40) != 0) {
            _ = try leb128.readUleb128(u32, self.body, &self.pos); // memidx
        }
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // offset
    }

    /// Wasm spec §3.3.7 (memarg alignment) — read the memarg
    /// align uleb (mask off bit 6 multi-memory flag), validate
    /// the actual alignExp ≤ `max_align_log2` (the op's natural
    /// alignment exponent). Then consume the optional memidx +
    /// offset uleb just like `skipMemarg`. Rejects with
    /// `Error.InvalidAlignment` on out-of-range align.
    fn readMemargCheckAlign(self: *Validator, max_align_log2: u32) Error!void {
        const raw_align = try leb128.readUleb128(u32, self.body, &self.pos);
        const align_log2 = raw_align & ~@as(u32, 0x40);
        if (align_log2 > max_align_log2) return Error.InvalidAlignment;
        if ((raw_align & 0x40) != 0) {
            _ = try leb128.readUleb128(u32, self.body, &self.pos); // memidx
        }
        _ = try leb128.readUleb128(u32, self.body, &self.pos); // offset
    }

    /// Address operand type for memory ops per Wasm 3.0 §3.4.7 —
    /// `.i32` for legacy i32-indexed memory; `.i64` for memory64.
    /// Determined by `self.memory0_idx_type` (multi-memory still
    /// rejected at instantiate; codegen sees only memory 0 per
    /// 10.M-4a `MemArgExtra.memidx == 0` assert).
    fn memAddrType(self: *const Validator) ValType {
        return switch (self.memory0_idx_type) {
            .i32 => .i32,
            .i64 => .i64,
        };
    }

    fn opLoad(self: *Validator, t: ValType, max_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        try self.readMemargCheckAlign(max_align_log2);
        try self.popExpect(self.memAddrType()); // address (i32 or i64)
        try self.pushType(t);
    }

    fn opStore(self: *Validator, t: ValType, max_align_log2: u32) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        try self.readMemargCheckAlign(max_align_log2);
        try self.popExpect(t); // value
        try self.popExpect(self.memAddrType()); // address (i32 or i64)
    }

    fn opMemorySize(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.InvalidOpcode;
        self.pos += 1;
        // Wasm 3.0 memory64 — result is the memory's idx_type
        // (i32 for default memory, i64 for memory64 per
        // ADR-0111 D1).
        try self.pushType(self.memAddrType());
    }

    fn opMemoryGrow(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        if (self.body[self.pos] != 0x00) return Error.InvalidOpcode;
        self.pos += 1;
        // Wasm 3.0 memory64 — delta + result use memory's idx_type.
        try self.popExpect(self.memAddrType());
        try self.pushType(self.memAddrType());
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
        const have: usize = self.operand_len - frame.height;
        // §9.9 / 9.9-l-1b-d093-d85 — Wasm spec §3.3.5
        // (polymorphic stack): in unreachable code, MISSING values
        // are synthesised on read (i.e. `have < expected_len` is
        // OK), but PRESENT values must still type-check against
        // the corresponding expected slot. Excess values (`have >
        // expected_len`) is an unconsumed-result error even in
        // unreachable code (spec §3.3.5.4: "the validator must
        // ensure that no unused values remain on the stack"). The
        // pre-d-85 form bailed out entirely whenever
        // `unreachable_flag` was set, which silently accepted
        // unreached-invalid.{5,18,20,22,28,30,32,40,42,44,82,85,86,115}
        // — concrete pushes after `unreachable` that contradicted
        // the surrounding function / block's declared result
        // types.
        if (frame.unreachable_flag) {
            if (have > expected_len) return Error.StackTypeMismatch;
        } else {
            if (have != expected_len) return Error.ArityMismatch;
        }
        // The `have` present values occupy the TOP of the
        // conceptual full result tuple. With expected types
        // `[e_0, ..., e_{N-1}]` (e_0 = bottom, e_{N-1} = top), the
        // first present slot (operand_buf[frame.height]) maps to
        // expected[N - have].
        const offset = expected_len - have;
        switch (end) {
            .empty => {},
            .single => |t| {
                if (have == 1) {
                    const top = self.operand_buf[frame.height];
                    switch (top) {
                        .bot => {},
                        .known => |k| if (k != t) return Error.StackTypeMismatch,
                    }
                }
            },
            .multi => |ts| {
                var i: usize = 0;
                while (i < have) : (i += 1) {
                    const slot = self.operand_buf[frame.height + i];
                    const expected_t = ts[offset + i];
                    switch (slot) {
                        .bot => {},
                        .known => |k| if (k != expected_t) return Error.StackTypeMismatch,
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
