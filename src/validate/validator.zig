// FILE-SIZE-EXEMPT: Wasm spec §3.3 validation single-pass walker (type-stack + control-stack); P1 spec-defined sub-language, intrinsically singular (splitting would create artificial seams across an unsplittable algorithm). (per ADR-0099) (cap=3200)
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
const init_expr = @import("../parse/init_expr.zig");
const dispatch_collector = @import("../ir/dispatch_collector.zig");
const wasm_byte_map = @import("../ir/wasm_byte_map.zig");
const validator_simd = @import("validator_simd.zig");
const diagnostic = @import("../diagnostic/diagnostic.zig");

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
    /// ADR-0125 — `struct.get`/`array.get` on a packed (i8/i16) field
    /// (must use get_s/get_u), or get_s/get_u on a non-packed field.
    PackedFieldAccess,
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
        // ADR-0123 (Cycle 2): legacy abstract-ref bytes map through
        // the nullable abstract head. Non-nullable / concrete refs
        // need the 0x63 / 0x64 multi-byte form (caller-side handled).
        .ref => |r| switch (r.heap_type) {
            .abstract => |a| switch (a) {
                .func => 0x70,
                .extern_ => 0x6F,
                .any => 0x6E,
                .eq => 0x6D,
                .i31 => 0x6C,
                .struct_ => 0x6B,
                .array => 0x6A,
                .exn => 0x69,
                .none => 0x71,
                .noextern => 0x72,
                .nofunc => 0x73,
                .noexn => 0x74,
            },
            // Concrete typed-ref (`(ref null? $idx)`) — single-byte
            // path returns a sentinel; multi-byte 0x63/0x64 encoding
            // owned by the binary writer's encode-RefType helper
            // when 10.R-valtype-widen Cycle 3 lands the parser side.
            .concrete => 0x40,
        },
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

/// ADR-0121 D5 (10.G op_gc cycle 15) — `validateFunction` variant
/// that threads the GC typedef side-tables. Used by tests + future
/// `frontendValidate` integration so struct.new / struct.new_default
/// (and forthcoming struct.get/set, array.new family) can resolve
/// typeidx → StructDef / ArrayDef.
pub fn validateFunctionWithGcTypes(
    sig: FuncType,
    locals: []const ValType,
    body: []const u8,
    func_types: []const FuncType,
    globals: []const GlobalEntry,
    module_types: []const FuncType,
    module_types_kinds: []const sections.TypeKind,
    struct_defs: []const ?sections.StructDef,
    array_defs: []const ?sections.ArrayDef,
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
        .module_types_kinds = module_types_kinds,
        .struct_defs = struct_defs,
        .array_defs = array_defs,
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
    memory_count: u32,
    memory0_idx_type: sections.MemoryEntry.IdxType,
    tags: []const sections.TagEntry,
    /// 10.R cycle 60 (D-195 sub-gap c) — Wasm spec §3.4.10
    /// declared-funcrefs bitset. When non-empty, `ref.func N` rejects
    /// if `N` is not declared (via globals init / elements / exports).
    /// Empty (`&.{}`) preserves the legacy pre-cycle-60 behaviour for
    /// callers that haven't been migrated yet — adopters pass the
    /// real bitset to enable the check.
    declared_funcs: []const bool,
    /// 10.R-funcrefs-tail — func-index → type-section-index map for
    /// ADR-0123 D4 typed `ref.func`. Empty → legacy abstract funcref.
    func_type_indices: []const u32,
    /// 10.G WasmGC — type-section kinds + sparse struct/array defs so
    /// struct.new/get/set + array.new/get/len resolve their typeidx.
    /// Empty (`&.{}`) → non-GC callers (struct/array ops then reject).
    module_types_kinds: []const sections.TypeKind,
    struct_defs: []const ?sections.StructDef,
    array_defs: []const ?sections.ArrayDef,
    supertypes: []const []const u32,
    /// 10.G cycle 158 — per-element-segment reftype for array.init_elem
    /// (segment <: array element) + table.init (segment == table elem).
    /// Empty (`&.{}`) → legacy callers skip the segment-reftype check.
    elem_types: []const ValType,
) Error!void {
    var v = Validator{
        .sig = sig,
        .locals = locals,
        .body = body,
        .pos = 0,
        .func_types = func_types,
        .globals = globals,
        .module_types = module_types,
        .module_types_kinds = module_types_kinds,
        .struct_defs = struct_defs,
        .array_defs = array_defs,
        .supertypes = supertypes,
        .data_count = data_count,
        .tables = tables,
        .elem_count = elem_count,
        .elem_types = elem_types,
        .memory_count = memory_count,
        .memory0_idx_type = memory0_idx_type,
        .tags = tags,
        .declared_funcs = declared_funcs,
        .func_type_indices = func_type_indices,
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
    /// 10.R-funcrefs-tail — func-index → type-section-index map
    /// (length = total funcs; imports first, then defined). ADR-0123
    /// D4: `ref.func N` yields the non-null typed ref `(ref
    /// func_type_indices[N])` instead of the abstract `funcref`, so it
    /// satisfies typed `(ref $sig)` params at `call` / `call_ref`.
    /// Empty (default) → legacy abstract `funcref` push for callers
    /// (unit tests, compileWasm) that don't thread it yet.
    func_type_indices: []const u32 = &.{},
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
    /// ADR-0121 D2 (10.G op_gc cycle 14) — parallel to
    /// `module_types`; tags each typeidx's kind so struct.new /
    /// array.new can look up the typedef shape. Empty slice
    /// (default) means struct/array ops reject as "unknown
    /// typeidx kind" — preserves the pre-cycle-15 behaviour
    /// for callers that don't thread the kinds slice.
    module_types_kinds: []const sections.TypeKind = &.{},
    /// ADR-0121 D2 — sparse typeidx → struct field list. Non-null
    /// iff `module_types_kinds[idx] == .structdef`. struct.new /
    /// struct.new_default consult this via `struct_defs[idx].?`.
    struct_defs: []const ?sections.StructDef = &.{},
    /// ADR-0121 D2 — sparse typeidx → array element type. Non-null
    /// iff `module_types_kinds[idx] == .arraydef`. array.new family
    /// consults this when those ops land.
    array_defs: []const ?sections.ArrayDef = &.{},

    /// ADR-0124 — per-typeidx declared supertype lists (parallel to
    /// `module_types`). Enables the concrete→concrete subtype rule in
    /// `subtypeCtx`: a `(ref $sub)` satisfies a `(ref $super)` operand
    /// (e.g. a `call` arg) when `$sub`'s declared supertype chain reaches
    /// `$super` (`gcConcreteReaches`). Empty (default) → concrete refs
    /// match only by identity, preserving pre-GC callers' behaviour.
    supertypes: []const []const u32 = &.{},

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
            const op_pos = self.pos;
            self.pos += 1;
            // ADR-0016 M3 — attribute the failing instruction on the cold
            // path: the body offset + opcode of the op that rejected.
            // `frontendValidate` patches `fn_idx` afterward. This is the
            // permanent replacement for the throwaway op-probe used during
            // GC corpus bring-up (lesson `gc-type-subtyping-is-rtt-blocked`).
            self.dispatch(op) catch |e| {
                diagnostic.setDiag(.validate, .other, .{ .validate = .{
                    .fn_idx = 0,
                    .body_offset = @intCast(op_pos),
                    .opcode = op,
                } }, "{s} at op 0x{x}", .{ @errorName(e), op });
                return e;
            };
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
    ///
    /// ADR-0123 Cycle 6 (10.R-funcrefs-tail bundle Cycle 2): the
    /// match is subtype-aware rather than strict-eql:
    /// - numeric / v128: must be identical (no subtyping)
    /// - ref types: `(ref ht)` (non-null) is a subtype of
    ///   `(ref null ht)` (nullable) — popping a non-null where
    ///   nullable is expected is OK.  Heap type must still match
    ///   exactly (full subtype lattice for heap types lands with
    ///   10.G — for now only nullability flexibility).
    /// Wasm spec 3.0 §3.3.4 subtype rules.
    // SIBLING-PUB: validator_simd.zig (per ADR-0083 extraction)
    pub fn popExpect(self: *Validator, expected: ValType) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!self.subtypeCtx(t, expected)) return Error.StackTypeMismatch,
        }
    }

    pub fn valTypeIsSubtype(actual: ValType, expected: ValType) bool {
        return valTypeIsSubtypeFree(actual, expected);
    }

    /// Subtype check WITH module-type context — extends the context-free
    /// `valTypeIsSubtypeFree` with the Wasm 3.0 GC §4.2.8 concrete→abstract
    /// rule: a concrete `(ref $t)` satisfies an abstract eq/any/struct/
    /// array head when `$t`'s kind matches (struct.new pushes `(ref $t)`;
    /// a func returning structref / anyref must accept it). Needs
    /// `module_types_kinds` (threaded by frontendValidate, 10.G cycle 135).
    pub fn subtypeCtx(self: *const Validator, actual: ValType, expected: ValType) bool {
        if (valTypeIsSubtypeFree(actual, expected)) return true;
        if (actual != .ref or expected != .ref) return false;
        if (actual.ref.nullable and !expected.ref.nullable) return false;
        return switch (actual.ref.heap_type) {
            .concrete => |idx| switch (expected.ref.heap_type) {
                .abstract => |e_abs| blk: {
                    const head: zir.AbstractHeapType = if (idx < self.module_types_kinds.len) switch (self.module_types_kinds[idx]) {
                        .func => .func,
                        .structdef => .struct_,
                        .arraydef => .array,
                    } else .func;
                    break :blk gcHeapAbstractSubtype(head, e_abs);
                },
                // ADR-0124 — concrete→concrete: `(ref $a)` <: `(ref $b)`
                // iff `$a`'s declared supertype chain reaches `$b`. Drives
                // call-arg / return / local.set coercion of narrowed GC
                // refs (gc/type-subtyping.6/7 fail at `call` without this).
                .concrete => |e_idx| gcConcreteReaches(idx, e_idx, self.supertypes),
            },
            // Wasm 3.0 GC §4.2.8 abstract heap-type hierarchy
            // (i31/struct/array <: eq <: any; bottoms <: all in their
            // hierarchy; cross-hierarchy rejected). e.g. a `(ref i31)`
            // value flowing into an anyref table.grow/fill/init
            // (i31.wast $anyref_table_of_i31ref). An abstract head is
            // never a subtype of a concrete type (the `none <: (ref $t)`
            // bottom edge isn't exercised by the current corpus).
            .abstract => |a_abs| switch (expected.ref.heap_type) {
                .abstract => |e_abs| gcHeapAbstractSubtype(a_abs, e_abs),
                .concrete => false,
            },
        };
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
                // Wasm 3.0 GC §5.3.4 — single-byte abstract reftype
                // shorthands as blocktypes (`(ref null <ht>)`). Mirrors
                // `init_expr.readValType`'s 0x6E..0x69 set; the gc
                // ref_test / ref_cast / br_on_cast fixtures open
                // `(block (result structref) ...)`. (10.G cycle 144)
                -18 => .{ .single = ValType.anyref }, // 0x6E
                -19 => .{ .single = ValType.eqref }, // 0x6D
                -20 => .{ .single = ValType.i31ref }, // 0x6C
                -21 => .{ .single = ValType.structref }, // 0x6B
                -22 => .{ .single = ValType.arrayref }, // 0x6A
                -23 => .{ .single = ValType.exnref }, // 0x69
                // function-references §5.3.4 + blocktype §5.4.1:
                // typed-ref result via `0x63 ht` (ref null ht) / `0x64
                // ht` (ref ht). The SLEB read above consumed the prefix
                // byte (0x63 → -29, 0x64 → -28); readTypedRefBlockType
                // decodes the heap-type that follows and bound-checks a
                // concrete type index.
                -29 => try self.readTypedRefBlockType(true), // 0x63
                -28 => try self.readTypedRefBlockType(false), // 0x64
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

    /// Wasm spec §5.3.4 — decode the heap-type following a typed-ref
    /// blocktype prefix (`0x63`/`0x64`, already consumed by
    /// readBlockType's SLEB read) into a `.single` BlockType. A
    /// concrete heap-type index must reference a declared type (spec
    /// §3.2.3); out-of-range or malformed → BadBlockType, mirroring the
    /// typeidx-blocktype bound check above. `readTypedRef` does not
    /// bound-check (it also serves index-free init-expr contexts), so
    /// the validator owns that check here. ref.9 / ref.10
    /// (function-references) exercise the out-of-range reject.
    fn readTypedRefBlockType(self: *Validator, nullable: bool) Error!BlockType {
        const vt = init_expr.readTypedRef(self.body, &self.pos, nullable) catch
            return Error.BadBlockType;
        if (vt == .ref and vt.ref.heap_type == .concrete and
            vt.ref.heap_type.concrete >= self.module_types.len)
        {
            return Error.BadBlockType;
        }
        return .{ .single = vt };
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

            // Wasm 3.0 GC §3.3.5.2 — ref.eq is the single-byte 0xD3 (NOT
            // 0xFB 0x13, which is array.init_elem; cyc156 mis-numbering fix).
            0xD3 => try self.opRefEq(),

            // Wasm 3.0 typed function references (function-references proposal).
            0xD4 => try self.opRefAsNonNull(),
            0xD5 => try self.opBrOnNull(),
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
            .known => |t| if (!t.isRef()) return Error.StackTypeMismatch,
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

    /// Validates a try_table's catch vec. Per Wasm 3.0 EH §3.3.10.6,
    /// each clause's branched-to label must accept the clause's
    /// pushed types:
    ///   - `catch tag depth`        → pushes `tag.params`
    ///   - `catch_ref tag depth`    → pushes `tag.params ++ [exnref]`
    ///   - `catch_all depth`        → pushes `[]`
    ///   - `catch_all_ref depth`    → pushes `[exnref]`
    /// Mismatch → `StackTypeMismatch`. (Tag-index + label-index
    /// range checks subsume the prior pre-cycle-61 surface.)
    ///
    /// `catch_ref` / `catch_all_ref` push an `exnref` as the last
    /// pushed value. Since cycle 112 landed `ValType.exnref` (bare
    /// `0x69`), these match structurally against the branch target's
    /// label type via `labelTypeEqParamsPlusExn` (was a blanket
    /// reject while `exnref` was un-decodable).
    fn validateCatchVec(self: *Validator) Error!void {
        const count = try leb128.readUleb128(u32, self.body, &self.pos);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.pos >= self.body.len) return Error.UnexpectedEnd;
            const kind = self.body[self.pos];
            self.pos += 1;
            switch (kind) {
                0x00 => {
                    // catch tag depth — pushes tag.params (= func type's
                    // params; results are required to be empty per spec
                    // but enforced at tag-decode time).
                    const tag_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (tag_idx >= self.tags.len) return Error.InvalidTagIndex;
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                    const target = &self.control_buf[self.control_len - 1 - label_idx];
                    const expected = target.labelType();
                    const typeidx = self.tags[tag_idx].typeidx;
                    if (typeidx >= self.module_types.len) return Error.InvalidTagIndex;
                    const tag_params = self.module_types[typeidx].params;
                    const pushed = blockTypeOfSlice(tag_params);
                    if (!labelTypesEq(pushed, expected)) return Error.StackTypeMismatch;
                },
                0x01 => {
                    // catch_ref tag depth — pushes tag.params ++ [exnref]
                    const tag_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (tag_idx >= self.tags.len) return Error.InvalidTagIndex;
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                    const target = &self.control_buf[self.control_len - 1 - label_idx];
                    const typeidx = self.tags[tag_idx].typeidx;
                    if (typeidx >= self.module_types.len) return Error.InvalidTagIndex;
                    const tag_params = self.module_types[typeidx].params;
                    if (!labelTypeEqParamsPlusExn(target.labelType(), tag_params)) return Error.StackTypeMismatch;
                },
                0x02 => {
                    // catch_all depth — pushes []
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                    const target = &self.control_buf[self.control_len - 1 - label_idx];
                    if (!labelTypesEq(.empty, target.labelType())) return Error.StackTypeMismatch;
                },
                0x03 => {
                    // catch_all_ref depth — pushes [exnref] (no tag params)
                    const label_idx = try leb128.readUleb128(u32, self.body, &self.pos);
                    if (label_idx >= self.control_len) return Error.InvalidBranchDepth;
                    const target = &self.control_buf[self.control_len - 1 - label_idx];
                    if (!labelTypeEqParamsPlusExn(target.labelType(), &.{})) return Error.StackTypeMismatch;
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
    /// Wasm 3.0 GC prefix (0xFB). Dispatches i31 sub-trio (28-30)
    /// + ref.test / ref.test_null (20 / 21; 10.G op_gc cycle 7)
    /// + ref.cast / ref.cast_null (22 / 23; 10.G op_gc cycle 8)
    /// + br_on_cast / br_on_cast_fail (24 / 25; 10.G op_gc cycle 9)
    /// + any.convert_extern / extern.convert_any (26 / 27; 10.G op_gc
    /// cycle 10); other GC sub-opcodes light up per 10.G heap /
    /// struct / array sub-chunks.
    fn dispatchPrefixFB(self: *Validator) Error!void {
        const sub = try leb128.readUleb128(u32, self.body, &self.pos);
        switch (sub) {
            // struct.new (sub-op 0): pop field-count Values per
            // declared struct, push .structref.
            0 => try self.opStructNew(false),
            // struct.new_default (sub-op 1): no pops, just typeidx;
            // push .structref.
            1 => try self.opStructNew(true),
            // struct.get (sub-op 2): pop structref, push field valtype.
            // Packed-type fields (i8/i16) reject — caller must use
            // struct.get_s/_u for those (deferred per ADR-0121 D3).
            2 => try self.opStructGet(),
            // struct.get_s / struct.get_u (sub-ops 3/4): packed-type
            // (i8/i16) field read, sign-/zero-extended to i32 (ADR-0125).
            3, 4 => try self.opStructGetPacked(),
            // struct.set (sub-op 5): pop value + structref, push nothing.
            5 => try self.opStructSet(),
            // array.new (sub-op 6): pop init Value + i32 size, push arrayref.
            6 => try self.opArrayNew(.with_init),
            // array.new_default (sub-op 7): pop i32 size only, push arrayref.
            7 => try self.opArrayNew(.default),
            // array.new_fixed (sub-op 8): pop N init values, push arrayref.
            8 => try self.opArrayNewFixed(),
            9 => try self.opArrayNewSeg(.data), // array.new_data $t $d
            10 => try self.opArrayNewSeg(.elem), // array.new_elem $t $e
            // array.get (sub-op 11): pop i32 idx + arrayref, push element.
            11 => try self.opArrayGet(),
            // array.get_s / array.get_u (sub-ops 12/13): packed element
            // (i8/i16) read, sign-/zero-extended to i32 (ADR-0125).
            12, 13 => try self.opArrayGetPacked(),
            // array.set (sub-op 14): pop value + i32 idx + arrayref.
            14 => try self.opArraySet(),
            // array.fill (sub-op 16): pop count + value + i32 idx + arrayref.
            16 => try self.opArrayFill(),
            // array.len (Wasm 3.0 GC §3.3.5.6.13): pop arrayref, push i32.
            15 => try self.opArrayLen(),
            // array.copy (sub-op 17): dst $t + src $t; pop len + src_off +
            // src_ref + dst_off + dst_ref (10.G cycle 157).
            17 => try self.opArrayCopy(),
            // array.init_data (18) / array.init_elem (19): segment → array
            // bulk init (10.G cycle 158). ref.eq is 0xD3, not 19.
            18 => try self.opArrayInitSeg(.data),
            19 => try self.opArrayInitSeg(.elem),
            // ref.test / ref.test_null share validator shape:
            // consume heap_type byte, pop reftype, push i32.
            20, 21 => try self.opRefTest(),
            // ref.cast (non-null target) / ref.cast_null (nullable):
            // consume heap_type byte, pop reftype, push the cast TARGET.
            22 => try self.opRefCast(false),
            23 => try self.opRefCast(true),
            // br_on_cast / br_on_cast_fail share validator shape:
            // consume flags + labelidx + ht1 + ht2, pop reftype,
            // pop+repush label types, push reftype back on fall-through.
            24 => try self.opBrOnCast(false), // br_on_cast
            25 => try self.opBrOnCast(true), // br_on_cast_fail
            // any.convert_extern (26): pop externref, push anyref.
            26 => try self.opConvertRef(.externref, .anyref),
            // extern.convert_any (27): pop anyref, push externref.
            27 => try self.opConvertRef(.anyref, .externref),
            28 => try self.opRefI31(),
            29, 30 => try self.opI31Get(), // .get_s / .get_u share validator shape
            else => return Error.NotImplemented,
        }
    }

    /// Wasm spec 3.0 §3.3.5.3 — `ref.test heap_type` /
    /// `ref.test_null heap_type`: consume heap_type byte (no
    /// validator constraint for cycle 7 — RTT lands later with
    /// type_hierarchy.zig); pop reftype; push i32.
    fn opRefTest(self: *Validator) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        // Heap-type byte consumed; runtime stores it via lower-
        // side payload. Validator-side range-check defers until
        // RTT (sub-chunks 5-7 of plan); for cycle 7 accept any
        // single-byte heap_type encoding.
        self.pos += 1;
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) return Error.StackTypeMismatch,
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.4 — `ref.cast (ref ht)` / `ref.cast null
    /// (ref null ht)`: pop a reftype; push the cast TARGET reftype
    /// `(ref ht)` (non-null) or `(ref null ht)` (nullable). The target
    /// type — not the wider operand — is what flows on; a block result
    /// like `(result (ref null $t))` fed by `(ref.cast (ref $t) …)`
    /// requires this narrowing (gc/type-subtyping.17). `null` heap-type
    /// byte (multi-byte index, not stored by lower) falls back to the
    /// operand type.
    fn opRefCast(self: *Validator, nullable: bool) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const ht_byte = self.body[self.pos];
        self.pos += 1;
        const top = try self.popAny();
        switch (top) {
            .bot => try self.pushBot(),
            .known => |t| {
                if (!t.isRef()) return Error.StackTypeMismatch;
                try self.pushType(castTargetType(ht_byte, nullable) orelse t);
            },
        }
    }

    /// Wasm spec 3.0 §3.3.5.6.1 — `struct.new typeidx` /
    /// `struct.new_default typeidx`: allocate a struct of the
    /// declared type. `struct.new` pops one Value per field (in
    /// reverse declared order so the topmost stack entry is the
    /// last field); `struct.new_default` skips the pops and
    /// zero-inits. Both push `.structref`.
    ///
    /// Pre-RTT cycle-15: the pushed reftype is the abstract
    /// `.structref` rather than a typed `(ref typeidx)` (typed-
    /// ref ValType narrowing lands with RTT TypeInfo per ADR-0116
    /// amendment). Caller-side cast ops re-validate against the
    /// expected concrete type.
    fn opStructNew(self: *Validator, is_default: bool) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .structdef) return Error.InvalidFuncIndex;
        const sd = self.struct_defs[typeidx] orelse return Error.InvalidFuncIndex;
        if (!is_default) {
            // Pop fields in reverse declared order: stack top = last field.
            var i: usize = sd.fields.len;
            while (i > 0) {
                i -= 1;
                try self.popExpect(sd.fields[i].storage.operandType());
            }
        }
        // Wasm 3.0 GC §3.3.5.6.1: struct.new $t : […] -> [(ref $t)] — the
        // result is the CONCRETE non-null typed ref, not abstract structref
        // (so a func returning `(ref $t)` accepts it; subtypeCtx widens to
        // structref/eqref/anyref slots).
        try self.pushType(.{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = typeidx } } });
    }

    /// Resolve a (typeidx, fieldidx) pair to a StructDef field. Used
    /// by struct.get / struct.set (cycle 17). Returns InvalidFuncIndex
    /// on unknown typeidx, wrong kind, or out-of-range fieldidx.
    fn lookupStructField(self: *Validator) Error!sections.StructFieldType {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const fieldidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .structdef) return Error.InvalidFuncIndex;
        const sd = self.struct_defs[typeidx] orelse return Error.InvalidFuncIndex;
        if (fieldidx >= sd.fields.len) return Error.InvalidFuncIndex;
        return sd.fields[fieldidx];
    }

    /// Wasm spec 3.0 §3.3.5.6.2 — `struct.get typeidx fieldidx`:
    /// pop structref, push the named field's valtype. Packed-type
    /// fields (i8/i16) rejected here — caller must use struct.get_s
    /// or struct.get_u (ADR-0121 D3 defers packed types).
    fn opStructGet(self: *Validator) Error!void {
        const field = try self.lookupStructField();
        // ADR-0125 — plain struct.get is invalid on a packed field; the
        // module must use struct.get_s / struct.get_u.
        if (field.storage.isPacked()) return Error.PackedFieldAccess;
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            // Accept abstract struct/eq/any heads OR a concrete `(ref $t)`
            // whose typedef is a struct (struct.new now pushes concrete).
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.structref))) return Error.StackTypeMismatch,
        }
        try self.pushType(field.storage.operandType());
    }

    /// Wasm spec 3.0 §3.3.5.6.3 — `struct.get_s` / `struct.get_u
    /// typeidx fieldidx`: pop structref, push i32 (the packed i8/i16
    /// field sign-/zero-extended). Valid ONLY on packed fields (ADR-0125).
    fn opStructGetPacked(self: *Validator) Error!void {
        const field = try self.lookupStructField();
        if (!field.storage.isPacked()) return Error.PackedFieldAccess;
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.structref))) return Error.StackTypeMismatch,
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.6.4 — `struct.set typeidx fieldidx`:
    /// pop value (matching field.storage.operandType()) + pop structref, push
    /// nothing. Field must be mutable.
    fn opStructSet(self: *Validator) Error!void {
        const field = try self.lookupStructField();
        if (!field.mutable) return Error.StackTypeMismatch;
        try self.popExpect(field.storage.operandType());
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.structref))) return Error.StackTypeMismatch,
        }
    }

    /// Resolve typeidx to an ArrayDef (cycle 18 helper). Returns
    /// InvalidFuncIndex on unknown typeidx or non-arraydef kind.
    fn lookupArrayDef(self: *Validator) Error!sections.ArrayDef {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        return self.array_defs[typeidx] orelse return Error.InvalidFuncIndex;
    }

    /// Wasm spec 3.0 §3.3.5.6.10 — `array.get typeidx`: pop i32 idx
    /// + arrayref, push element.valtype. Packed types (ADR-0121 D3)
    /// reject via get_s/_u routes in dispatch.
    fn opArrayGet(self: *Validator) Error!void {
        const ad = try self.lookupArrayDef();
        // ADR-0125 — plain array.get is invalid on a packed element.
        if (ad.element.storage.isPacked()) return Error.PackedFieldAccess;
        try self.popExpect(.i32);
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
        try self.pushType(ad.element.storage.operandType());
    }

    /// Wasm spec 3.0 §3.3.5.6.11 — `array.get_s` / `array.get_u
    /// typeidx`: pop i32 idx + arrayref, push i32 (packed i8/i16 element
    /// sign-/zero-extended). Valid ONLY on packed elements (ADR-0125).
    fn opArrayGetPacked(self: *Validator) Error!void {
        const ad = try self.lookupArrayDef();
        if (!ad.element.storage.isPacked()) return Error.PackedFieldAccess;
        try self.popExpect(.i32);
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.6.12 — `array.set typeidx`: pop value
    /// + i32 idx + arrayref. Element type must be mutable.
    fn opArraySet(self: *Validator) Error!void {
        const ad = try self.lookupArrayDef();
        if (!ad.element.mutable) return Error.StackTypeMismatch;
        try self.popExpect(ad.element.storage.operandType());
        try self.popExpect(.i32);
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
    }

    /// Wasm spec 3.0 §3.3.5.6.14 — `array.fill typeidx`: pop count
    /// (i32) + value + i32 idx + arrayref. Element type must be
    /// mutable. Stack effect (top first): count, value, idx, arrayref.
    fn opArrayFill(self: *Validator) Error!void {
        const ad = try self.lookupArrayDef();
        if (!ad.element.mutable) return Error.StackTypeMismatch;
        try self.popExpect(.i32); // count
        try self.popExpect(ad.element.storage.operandType()); // fill value
        try self.popExpect(.i32); // idx
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
    }

    /// True iff array element `src` is assignable to `dst` (covariant, as
    /// storage types): packed-ness must match (i8/i16 invariant), else the
    /// operand valtype must subtype. Mirrors gcFieldSubtype's covariant arm.
    fn arrayElemAssignable(self: *const Validator, src: sections.StructFieldType, dst: sections.StructFieldType) bool {
        if (src.storage.isPacked() != dst.storage.isPacked()) return false;
        if (src.storage.isPacked()) return src.storage.specByte() == dst.storage.specByte();
        return self.subtypeCtx(src.storage.operandType(), dst.storage.operandType());
    }

    fn popArrayRef(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!(t.isAnyRef() or t.isEqRef() or self.subtypeCtx(t, ValType.arrayref))) return Error.StackTypeMismatch,
        }
    }

    /// Wasm spec 3.0 §3.3.5.6.14 — `array.copy dst_typeidx src_typeidx`:
    /// pop [len:i32, src_off:i32, src_ref, dst_off:i32, dst_ref]. dst
    /// element must be mutable; src element must be assignable to dst's.
    fn opArrayCopy(self: *Validator) Error!void {
        const dst = try self.lookupArrayDef(); // dst typeidx (read first)
        const src = try self.lookupArrayDef(); // src typeidx
        if (!dst.element.mutable) return Error.StackTypeMismatch;
        if (!self.arrayElemAssignable(src.element, dst.element)) return Error.StackTypeMismatch;
        try self.popExpect(.i32); // len
        try self.popExpect(.i32); // src_off
        try self.popArrayRef(); // src_ref
        try self.popExpect(.i32); // dst_off
        try self.popArrayRef(); // dst_ref
    }

    /// Wasm spec 3.0 §3.3.5.6.16/17 — `array.init_data $t $d` /
    /// `array.init_elem $t $e`: pop [len:i32, src_off:i32, dst_off:i32,
    /// dst_ref]. $t element mutable; data variant needs a numeric/packed
    /// element + data-count section; elem variant needs the segment
    /// reftype assignable to the element.
    fn opArrayInitSeg(self: *Validator, kind: ArrayNewSegKind) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const segidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        const ad = self.array_defs[typeidx] orelse return Error.InvalidFuncIndex;
        if (!ad.element.mutable) return Error.StackTypeMismatch;
        switch (kind) {
            .data => {
                // data segments hold raw bytes → element must be numeric/packed.
                if (ad.element.storage.operandType().isRef()) return Error.StackTypeMismatch;
                if (!self.data_count_section_present) return Error.UnknownMemory;
                if (segidx >= self.data_count) return Error.InvalidFuncIndex;
            },
            .elem => {
                if (segidx >= self.elem_count) return Error.InvalidFuncIndex;
                if (segidx < self.elem_types.len and !self.subtypeCtx(self.elem_types[segidx], ad.element.storage.operandType())) return Error.StackTypeMismatch;
            },
        }
        try self.popExpect(.i32); // len
        try self.popExpect(.i32); // src_off
        try self.popExpect(.i32); // dst_off
        try self.popArrayRef(); // dst_ref
    }

    const ArrayNewVariant = enum { with_init, default };

    /// Wasm spec 3.0 §3.3.5.6.6 — `array.new typeidx` /
    /// `array.new_default typeidx`: allocate an array of the
    /// declared element type. `array.new` pops one init Value
    /// (matching ArrayDef.element.valtype) + i32 size; the
    /// `_default` variant skips the init pop. Both push `.arrayref`.
    ///
    /// Pre-RTT cycle-16: the pushed reftype is the abstract
    /// `.arrayref`; typed-ref ValType narrowing lands with RTT
    /// (ADR-0116 amendment).
    fn opArrayNew(self: *Validator, variant: ArrayNewVariant) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        const ad = self.array_defs[typeidx] orelse return Error.InvalidFuncIndex;
        // Pop order on the stack (top first): size:i32, then init (if any).
        try self.popExpect(.i32);
        if (variant == .with_init) {
            try self.popExpect(ad.element.storage.operandType());
        }
        // Wasm 3.0 GC: array.new $t : […] -> [(ref $t)] (concrete, non-null);
        // subtypeCtx widens it to arrayref/eqref/anyref slots (cycle 137).
        try self.pushType(.{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = typeidx } } });
    }

    /// Wasm spec 3.0 §3.3.5.6.8 — `array.new_fixed typeidx N`:
    /// allocate an N-element array of the declared element type;
    /// pop N init Values (last array element on top), push
    /// `.arrayref`. N is an in-stream uleb32 immediate (not a
    /// typeidx-side length).
    fn opArrayNewFixed(self: *Validator) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        const ad = self.array_defs[typeidx] orelse return Error.InvalidFuncIndex;
        const n = try leb128.readUleb128(u32, self.body, &self.pos);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            try self.popExpect(ad.element.storage.operandType());
        }
        try self.pushType(.{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = typeidx } } });
    }

    const ArrayNewSegKind = enum { data, elem };

    /// Wasm 3.0 GC §3.3.5.6.7/8 — `array.new_data $t $d` /
    /// `array.new_elem $t $e`: pop `[offset:i32, size:i32]`, build a new
    /// array of type `$t` whose elements come from data segment `$d`
    /// (data) / element segment `$e` (elem); push the concrete `(ref $t)`.
    /// Validate-only this cut: typeidx is arraydef, segment index in
    /// range (data needs the DataCount section, mirroring memory.init);
    /// runtime copy lands in the exec follow-on.
    fn opArrayNewSeg(self: *Validator, kind: ArrayNewSegKind) Error!void {
        const typeidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const segidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (typeidx >= self.module_types_kinds.len) return Error.InvalidFuncIndex;
        if (self.module_types_kinds[typeidx] != .arraydef) return Error.InvalidFuncIndex;
        if (self.array_defs[typeidx] == null) return Error.InvalidFuncIndex;
        switch (kind) {
            .data => {
                if (!self.data_count_section_present) return Error.UnknownMemory;
                if (segidx >= self.data_count) return Error.InvalidFuncIndex;
            },
            .elem => if (segidx >= self.elem_count) return Error.InvalidFuncIndex,
        }
        try self.popExpect(.i32); // size
        try self.popExpect(.i32); // offset
        try self.pushType(.{ .ref = .{ .nullable = false, .heap_type = .{ .concrete = typeidx } } });
    }

    /// Wasm spec 3.0 §3.3.5.6.13 — `array.len`: pop an arrayref
    /// (`(ref null array)`), push i32. Pre-RTT we accept any
    /// reftype on the operand (the spec restricts to arrayref-
    /// subtypes; runtime traps NullReference until array creation
    /// ops land).
    fn opArrayLen(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) return Error.StackTypeMismatch,
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.2 — `ref.eq`: pop two operands, each a
    /// subtype of `eqref` (the internal-eq hierarchy: i31 / struct /
    /// array / eq / none — NOT func / extern / any), push i32. Operands
    /// outside the eq hierarchy (funcref, externref, anyref) are a type
    /// error (cyc156 — was a lenient any-ref accept that let the
    /// ref_eq invalid fixtures through).
    fn opRefEq(self: *Validator) Error!void {
        var i: u32 = 0;
        while (i < 2) : (i += 1) {
            const top = try self.popAny();
            switch (top) {
                .bot => {},
                .known => |t| if (!self.subtypeCtx(t, ValType.eqref)) return Error.StackTypeMismatch,
            }
        }
        try self.pushType(.i32);
    }

    /// Wasm spec 3.0 §3.3.5.7 — `any.convert_extern` /
    /// `extern.convert_any`: reinterpret a reftype between the
    /// `any` and `extern` hierarchies. Stack effect: pop `from`,
    /// push `to`. Pre-RTT both directions are unconditional (no
    /// runtime check); the validator narrows the type for the
    /// fall-through, mirroring the spec's static signature.
    fn opConvertRef(self: *Validator, from: ValType, to: ValType) Error!void {
        try self.popExpect(from);
        try self.pushType(to);
    }

    /// Wasm spec 3.0 §3.3.5.5 — `br_on_cast flags l ht1 ht2` /
    /// `br_on_cast_fail flags l ht1 ht2`. Immediate: flags (bit 0 = ht1
    /// nullable, bit 1 = ht2 nullable) + labelidx (uleb32) + ht1 + ht2
    /// (heap-type encodings). `rt1 = (ref null1? ht1)` is the source
    /// type; `rt2 = (ref null2? ht2)` is the cast target.
    ///
    /// `br_on_cast` branches to l when the operand matches rt2 (carrying
    /// rt2), and falls through with `rt1 \ rt2`. `br_on_cast_fail`
    /// inverts it: branches with `rt1 \ rt2`, falls through with rt2.
    /// The difference `rt1 \ rt2` keeps ht1 but drops nullability when
    /// rt2 is nullable (the null case is consumed by the match). The
    /// label's last type must be a supertype of the carried reftype
    /// (subtypeCtx, NOT the cycle-9 stub's `eql(operand)` which wrongly
    /// compared the source operand instead of the cast target).
    fn opBrOnCast(self: *Validator, is_fail: bool) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const flags = self.body[self.pos];
        self.pos += 1;
        const depth = try leb128.readUleb128(u32, self.body, &self.pos);
        const ht1_nullable = (flags & 0x01) != 0;
        const ht2_nullable = (flags & 0x02) != 0;
        const rt1 = init_expr.readTypedRef(self.body, &self.pos, ht1_nullable) catch return Error.BadValType;
        const rt2 = init_expr.readTypedRef(self.body, &self.pos, ht2_nullable) catch return Error.BadValType;
        // Spec §3.3.5.5 validity: rt2 <: rt1 (the cast target is a
        // subtype of the source) — FULL reftype subtyping, including
        // nullability. Rejects `eqref anyref` / `structref arrayref` /
        // `funcref (ref $struct)` (heap mismatch) AND `(ref any)` source
        // with a `(ref null $t)` target (nullable ⊄ non-null). All six
        // br_on_cast{,_fail} assert_invalid fixtures hinge on this.
        if (!self.subtypeCtx(rt2, rt1)) return Error.StackTypeMismatch;
        // Operand: a ref subtype of rt1 (coarse isRef check pre-RTT).
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) return Error.StackTypeMismatch,
        }
        const diff: ValType = .{ .ref = .{
            .nullable = ht1_nullable and !ht2_nullable,
            .heap_type = rt1.ref.heap_type,
        } };
        const label_carry: ValType = if (is_fail) diff else rt2;
        const fallthrough: ValType = if (is_fail) rt2 else diff;
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        switch (target.labelType()) {
            .empty => return Error.StackTypeMismatch,
            .single => |t| {
                if (!self.subtypeCtx(label_carry, t)) return Error.StackTypeMismatch;
            },
            .multi => |ts| {
                if (ts.len == 0) return Error.StackTypeMismatch;
                if (!self.subtypeCtx(label_carry, ts[ts.len - 1])) return Error.StackTypeMismatch;
                const prefix = ts[0 .. ts.len - 1];
                var i: usize = prefix.len;
                while (i > 0) {
                    i -= 1;
                    try self.popExpect(prefix[i]);
                }
                for (prefix) |t| try self.pushType(t);
            },
        }
        try self.pushType(fallthrough);
    }

    /// Wasm spec 3.0 §3.x (GC) — `ref.i31`: pop i32, push an
    /// i31-tagged reftype. Push `.i31ref` per ADR-0115 §6
    /// Revision 2026-05-29 (cycle 1 of 10.G-op_gc bundle).
    /// Previously stood in with `.funcref` while the typed-ref
    /// catalogue extension was pending; this cycle (5) wires the
    /// proper type so `i31.get_*` validator-pops match.
    fn opRefI31(self: *Validator) Error!void {
        try self.popExpect(.i32);
        // Wasm 3.0 GC: `ref.i31 : [i32] -> [(ref i31)]` — the result is
        // NON-NULL (an i31 ref is never null). Pushing the nullable
        // `.i31ref` abbreviation breaks `global.set` / returns into a
        // non-null `(ref i31)` slot (StackTypeMismatch).
        try self.pushType(.{ .ref = zir.RefType.abs(.i31, false) });
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
            .known => |t| if (!t.isRef()) return Error.StackTypeMismatch,
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
        // 10.M cycle 67 — relax multi-memory: dst + src memidx are
        // now real LEBs (were reserved 0x00). Range-check both
        // against memory_count.
        const dst_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        const src_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dst_memidx >= self.memory_count or src_memidx >= self.memory_count) {
            return Error.UnknownMemory;
        }
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
        // 10.M cycle 67 — relax multi-memory dst memidx LEB
        // (was reserved 0x00). Range-check against memory_count.
        const dst_memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (dst_memidx >= self.memory_count) return Error.UnknownMemory;
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

    /// ref.null heaptype: 0xD0 + heaptype. Heaptype is a single
    /// byte for the 12 abstract heads (Wasm 3.0 §5.3.5) OR a signed
    /// LEB128 type-section index for concrete typed null refs
    /// (function-references proposal §3.3.10.5).
    fn opRefNull(self: *Validator) Error!void {
        if (self.pos >= self.body.len) return Error.UnexpectedEnd;
        const b = self.body[self.pos];
        // Single-byte abstract heads — consume one byte, build the
        // matching abstract `(ref null ht)`.
        const abstract: ?zir.AbstractHeapType = switch (b) {
            0x70 => .func,
            0x6F => .extern_,
            0x6E => .any,
            0x6D => .eq,
            0x6C => .i31,
            0x6B => .struct_,
            0x6A => .array,
            0x69 => .exn,
            0x71 => .none,
            0x72 => .noextern,
            0x73 => .nofunc,
            0x74 => .noexn,
            else => null,
        };
        if (abstract) |ht| {
            self.pos += 1;
            try self.pushType(.{ .ref = .{ .nullable = true, .heap_type = .{ .abstract = ht } } });
            return;
        }
        // Concrete typed null ref: signed LEB128 type-section index
        // (ADR-0123 Cycle 5). Index must be in [0, module_types.len).
        const idx_signed = leb128.readSleb128(i33, self.body, &self.pos) catch return Error.BadValType;
        if (idx_signed < 0) return Error.BadValType;
        const idx: u32 = @intCast(idx_signed);
        if (idx >= self.module_types.len) return Error.BadValType;
        try self.pushType(.{ .ref = .{ .nullable = true, .heap_type = .{ .concrete = idx } } });
    }

    /// ref.is_null: pop any reftype, push i32. Polymorphic over
    /// funcref / externref.
    fn opRefIsNull(self: *Validator) Error!void {
        const top = try self.popAny();
        switch (top) {
            .bot => {},
            .known => |t| if (!t.isRef()) return Error.StackTypeMismatch,
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
                // Unreachable/polymorphic stack: the result type is
                // unknown, so stay polymorphic (.bot) rather than
                // collapsing to a concrete funcref — else a typed
                // downstream consumer (e.g. `call` expecting `(ref $t)`)
                // mismatches the abstract funcref (ref_as_non_null.0
                // func 6: `unreachable; ref.as_non_null; call 0`).
                try self.pushBot();
            },
            .known => |t| {
                if (!t.isRef()) return Error.StackTypeMismatch;
                // ADR-0123 D2 (cycle 93 / 10.R-valtype-widen Cycle 4):
                // narrow the popped ref's `nullable` flag to false.
                // `ref.as_non_null` traps at runtime on null; on the
                // fall-through path the result is statically known
                // non-null.
                const narrowed: ValType = .{ .ref = .{
                    .nullable = false,
                    .heap_type = t.ref.heap_type,
                } };
                try self.pushType(narrowed);
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
                if (!t.isRef()) return Error.StackTypeMismatch;
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
        // ADR-0123 D2 (cycle 93 / 10.R-valtype-widen Cycle 4):
        // `br_on_null` narrows the fall-through path's reftype to
        // non-null (the branch only fires when the ref IS null, so
        // post-branch the value must be non-null). Branch-target
        // path still receives the original ref kind via label_types.
        const narrowed: ValType = if (reftype.isRef()) .{ .ref = .{
            .nullable = false,
            .heap_type = reftype.ref.heap_type,
        } } else reftype;
        try self.pushType(narrowed);
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
        // Unreachable/polymorphic stack: the popped ref type is unknown
        // and unifies with whatever ref the label expects, so the ref↔
        // label subtype checks below are skipped (br_on_non_null.0 func
        // 6: `block (result (ref 0)); unreachable; br_on_non_null 0`).
        const is_bot = (top == .bot);
        const reftype: ValType = switch (top) {
            .bot => .funcref, // polymorphic; pick any reftype
            .known => |t| blk: {
                if (!t.isRef()) return Error.StackTypeMismatch;
                break :blk t;
            },
        };
        const target = self.frameAt(depth) orelse return Error.InvalidBranchDepth;
        const lt = target.labelType();
        // Label l must take [t1*, (ref ht)] where the popped
        // reftype is (ref null ht). The branch only fires when the
        // ref is non-null at runtime — so the narrowed (non-null)
        // form is what flows to the label. Per Wasm 3.0 §3.3.10.9.
        const narrowed_ref: ValType = if (reftype.isRef()) .{ .ref = .{
            .nullable = false,
            .heap_type = reftype.ref.heap_type,
        } } else reftype;
        switch (lt) {
            .empty => return Error.StackTypeMismatch,
            .single => |t| {
                if (!is_bot and !valTypeIsSubtypeFree(narrowed_ref, t)) {
                    return Error.StackTypeMismatch;
                }
                // Prefix is empty; no further pop/push.
            },
            .multi => |ts| {
                if (ts.len == 0) return Error.StackTypeMismatch;
                if (!is_bot and !valTypeIsSubtypeFree(narrowed_ref, ts[ts.len - 1])) return Error.StackTypeMismatch;
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
            .known => |t| if (!t.isRef()) return Error.StackTypeMismatch,
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
            .known => |t| if (!t.isRef()) return Error.StackTypeMismatch,
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
                if (callee_results.len != 1 or !callee_results[0].eql(t)) return Error.StackTypeMismatch;
            },
            .multi => |ts| {
                if (callee_results.len != ts.len) return Error.StackTypeMismatch;
                for (callee_results, ts) |a, b| if (!a.eql(b)) return Error.StackTypeMismatch;
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
        if (!self.tables[table_idx].elem_type.isFuncref()) return Error.InvalidFuncIndex;
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
        // ADR-0123 D4: `ref.func N` yields the non-null typed ref `(ref
        // func_type_indices[N])` so it satisfies typed `(ref $sig)`
        // params at `call` / `call_ref`. Callers that don't thread the
        // func→typeidx map (unit tests, compileWasm pre-migration) fall
        // back to the abstract `funcref`.
        if (idx < self.func_type_indices.len) {
            try self.pushType(.{ .ref = .{
                .nullable = false,
                .heap_type = .{ .concrete = self.func_type_indices[idx] },
            } });
        } else {
            try self.pushType(.funcref);
        }
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
            // Wasm §3.3.5.20 — segment reftype must be a SUBTYPE of the
            // table's reftype (not exact-equal): an i31ref elem segment
            // initialising an anyref table is valid (i31.wast
            // $anyref_table_of_i31ref).
            if (!self.subtypeCtx(self.elem_types[elemidx], self.tables[tableidx].elem_type)) {
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
        if (!self.tables[dst].elem_type.eql(self.tables[src].elem_type)) {
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
        // 10.M cycle 67 — relax multi-memory memidx LEB (was
        // reserved 0x00). Range-check against memory_count.
        const memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (memidx >= self.memory_count) return Error.UnknownMemory;
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
        if (!self.tables[table_idx].elem_type.isFuncref()) return Error.InvalidFuncIndex;
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
                    .ref => false,
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
                        if (!ka.eql(kb)) return Error.StackTypeMismatch;
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
        // 10.M cycle 66 — Wasm 3.0 multi-memory: was `if (body[pos]
        // != 0x00) reject` (single reserved byte). Now LEB-decode
        // memidx + range-check against memory_count. Pushed type
        // uses memAddrType() which is currently memory0's idx_type;
        // mixed i32/i64 multi-memory modules need per-memory
        // idx_type plumbing (separate cycle).
        const memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (memidx >= self.memory_count) return Error.UnknownMemory;
        try self.pushType(self.memAddrType());
    }

    fn opMemoryGrow(self: *Validator) Error!void {
        if (self.memory_count == 0) return Error.UnknownMemory;
        const memidx = try leb128.readUleb128(u32, self.body, &self.pos);
        if (memidx >= self.memory_count) return Error.UnknownMemory;
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
        // ADR-0123 Cycle 3 (10.R-funcrefs-tail) — subtype-aware
        // result-type check per Wasm 3.0 §3.3.4: a `(ref ht)`
        // pushed onto a block whose declared end-type is
        // `(ref null ht)` is valid.
        switch (end) {
            .empty => {},
            .single => |t| {
                if (have == 1) {
                    const top = self.operand_buf[frame.height];
                    switch (top) {
                        .bot => {},
                        .known => |k| if (!self.subtypeCtx(k, t)) return Error.StackTypeMismatch,
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
                        .known => |k| if (!self.subtypeCtx(k, expected_t)) return Error.StackTypeMismatch,
                    }
                }
            },
        }
    }
};

/// Returns true iff `actual` is assignment-compatible with `expected`
/// per the Wasm 3.0 subtype rules subset implemented for 10.R:
/// - Identical types match.
/// - Non-null ref is a subtype of nullable ref of the same heap_type.
/// - Full heap-type subtype lattice (any > eq > struct/array/i31; etc.)
///   deferred to 10.G.
fn valTypeIsSubtypeFree(actual: ValType, expected: ValType) bool {
    if (actual.eql(expected)) return true;
    if (actual != .ref or expected != .ref) return false;
    // Non-null actual satisfies a nullable expected; not vice-versa.
    if (actual.ref.nullable and !expected.ref.nullable) return false;
    const ah = actual.ref.heap_type;
    const eh = expected.ref.heap_type;
    return switch (ah) {
        .concrete => |a_idx| switch (eh) {
            .concrete => |e_idx| a_idx == e_idx,
            // ADR-0123: a concrete typed ref `(ref $sig)` is a subtype
            // of the abstract `func` head — `ref.func N` (typed) must
            // still satisfy `funcref` globals/tables/params (ref_func.1).
            // Pre-GC the type section holds only func types, so every
            // concrete ref is a funcref; 10.G refines this once
            // struct/array defs (non-func heads) enter module_types.
            .abstract => |e_abs| e_abs == .func,
        },
        // An abstract head never narrows to a concrete type. Abstract→
        // abstract follows the Wasm 3.0 GC §4.2.8 heap-type lattice
        // (i31/eq/struct/array <: any, etc.), so (ref i31) satisfies an
        // anyref slot — global.set/table-init/return into anyref of i31
        // (gc/i31.5, i31.6). Pre-GC heads (func/extern) are disjoint, so
        // this is identity for them (no regression).
        .abstract => |a_abs| switch (eh) {
            .abstract => |e_abs| gcHeapAbstractSubtype(a_abs, e_abs),
            .concrete => false,
        },
    };
}

// ============================================================
// WasmGC structural subtype validation (ADR-0124).
// ============================================================

/// Wasm 3.0 GC §4.2.8 abstract heap-type lattice: is `a <: e`?
/// `any`/`eq`/`struct`/`array`/`i31`/`none` are one hierarchy
/// (none = bottom, any = top); `func`/`nofunc`, `extern`/`noextern`,
/// `exn`/`noexn` are disjoint hierarchies.
fn gcHeapAbstractSubtype(a: zir.AbstractHeapType, e: zir.AbstractHeapType) bool {
    if (a == e) return true;
    return switch (e) {
        .any => switch (a) {
            .eq, .i31, .struct_, .array, .none => true,
            .func, .extern_, .any, .noextern, .nofunc, .exn, .noexn => false,
        },
        .eq => switch (a) {
            .i31, .struct_, .array, .none => true,
            .func, .extern_, .any, .eq, .noextern, .nofunc, .exn, .noexn => false,
        },
        .struct_ => a == .none,
        .array => a == .none,
        .i31 => a == .none,
        .func => a == .nofunc,
        .extern_ => a == .noextern,
        .exn => a == .noexn,
        // Bottoms have no proper subtypes.
        .none, .nofunc, .noextern, .noexn => false,
    };
}

/// Decode a single heap-type byte (the form `lower.zig` stores for
/// ref.cast / ref.test targets — abstract 0x69..0x74 or a concrete
/// typeidx < 0x40) into the cast-target `ValType`. `null` for an
/// unrecognised byte (multi-byte index); the caller keeps the operand.
fn castTargetType(byte: u8, nullable: bool) ?ValType {
    const abs: ?zir.AbstractHeapType = switch (byte) {
        0x70 => .func,
        0x6F => .extern_,
        0x6E => .any,
        0x6D => .eq,
        0x6C => .i31,
        0x6B => .struct_,
        0x6A => .array,
        0x69 => .exn,
        0x71 => .none,
        0x72 => .noextern,
        0x73 => .nofunc,
        0x74 => .noexn,
        else => null,
    };
    if (abs) |a| return .{ .ref = .{ .nullable = nullable, .heap_type = .{ .abstract = a } } };
    if (byte < 0x40) return .{ .ref = .{ .nullable = nullable, .heap_type = .{ .concrete = byte } } };
    return null;
}

/// True if concrete type `super_idx` is reachable from `sub_idx` via
/// its declared supertype chain (transitive). Visited-bounded against
/// malformed cycles (chains are shallow in practice).
fn gcConcreteReaches(sub_idx: u32, super_idx: u32, supertypes: []const []const u32) bool {
    if (sub_idx == super_idx) return true;
    if (sub_idx >= supertypes.len) return false;
    var depth: u32 = 0;
    var cur = sub_idx;
    // Single-supertype chains dominate the corpus; walk the first
    // declared supertype up to a small bound, also scanning the
    // declared set at each level.
    while (depth < 64) : (depth += 1) {
        if (cur >= supertypes.len) return false;
        const supers = supertypes[cur];
        if (supers.len == 0) return false;
        for (supers) |s| if (s == super_idx) return true;
        cur = supers[0];
        if (cur == sub_idx) return false; // cycle guard
    }
    return false;
}

/// Wasm 3.0 GC §4.2.8 valtype subtyping (lattice + concrete chain).
/// Extends `valTypeIsSubtypeFree` with the GC heap lattice + the
/// declared-supertype chain for concrete refs.
fn gcValTypeSubtype(actual: ValType, expected: ValType, types: *const sections.Types) bool {
    if (actual.eql(expected)) return true;
    if (actual != .ref or expected != .ref) return false;
    if (actual.ref.nullable and !expected.ref.nullable) return false;
    const ah = actual.ref.heap_type;
    const eh = expected.ref.heap_type;
    return switch (ah) {
        .concrete => |a_idx| switch (eh) {
            // Declared-chain reach OR iso-recursive canonical equality
            // (ADR-0126): a raw index that does not reach the target by
            // declared supertypes may still be the same canonical type
            // (cross-rec-group structural identity, Wasm 3.0 GC §3.3).
            .concrete => |e_idx| gcConcreteReaches(a_idx, e_idx, types.supertypes) or
                sections.canonicalEqual(types, a_idx, e_idx),
            .abstract => |e_abs| blk: {
                // A concrete ref's head is the kind of its typedef.
                const head: zir.AbstractHeapType = if (a_idx >= types.kinds.len) .any else switch (types.kinds[a_idx]) {
                    .func => .func,
                    .structdef => .struct_,
                    .arraydef => .array,
                };
                break :blk gcHeapAbstractSubtype(head, e_abs);
            },
        },
        .abstract => |a_abs| switch (eh) {
            .abstract => |e_abs| gcHeapAbstractSubtype(a_abs, e_abs),
            .concrete => false,
        },
    };
}

/// Field/element subtyping: mutability must match; a `var` (mutable)
/// field is INVARIANT (types equal), a `const` field is COVARIANT.
fn gcFieldSubtype(sub_f: sections.StructFieldType, sup_f: sections.StructFieldType, types: *const sections.Types) bool {
    if (sub_f.mutable != sup_f.mutable) return false;
    // ADR-0125 — storage class must match: a packed field is never a
    // subtype of a non-packed one, and packed types are invariant
    // (i8 <: i8, i16 <: i16; no cross/widening). Compare the wire byte.
    const sub_p = sub_f.storage.isPacked();
    if (sub_p != sup_f.storage.isPacked()) return false;
    if (sub_p) return sub_f.storage.specByte() == sup_f.storage.specByte();
    const sub_v = sub_f.storage.operandType();
    const sup_v = sup_f.storage.operandType();
    if (sub_f.mutable) return sub_v.eql(sup_v); // invariant
    return gcValTypeSubtype(sub_v, sup_v, types); // covariant
}

/// ADR-0124 — does typedef `sub` structurally conform to its declared
/// supertype `sup`? (Same comptype kind; struct width+depth, array
/// element, func param-contravariant/result-covariant.) Used at
/// type-section validation to reject non-conformant `sub`/`sub final`
/// declarations.
pub fn typeDefIsSubtype(sub: u32, sup: u32, types: *const sections.Types) bool {
    if (sub == sup) return true;
    if (sub >= types.kinds.len or sup >= types.kinds.len) return false;
    if (types.kinds[sub] != types.kinds[sup]) return false;
    return switch (types.kinds[sub]) {
        .func => blk: {
            const a = types.items[sub];
            const b = types.items[sup];
            if (a.params.len != b.params.len or a.results.len != b.results.len) break :blk false;
            // params contravariant, results covariant.
            for (a.params, b.params) |ap, bp| if (!gcValTypeSubtype(bp, ap, types)) break :blk false;
            for (a.results, b.results) |ar, br| if (!gcValTypeSubtype(ar, br, types)) break :blk false;
            break :blk true;
        },
        .structdef => blk: {
            const a = (types.struct_defs[sub] orelse break :blk false).fields;
            const b = (types.struct_defs[sup] orelse break :blk false).fields;
            if (a.len < b.len) break :blk false; // width
            for (b, 0..) |bf, i| if (!gcFieldSubtype(a[i], bf, types)) break :blk false; // depth
            break :blk true;
        },
        .arraydef => blk: {
            const a = (types.array_defs[sub] orelse break :blk false).element;
            const b = (types.array_defs[sup] orelse break :blk false).element;
            break :blk gcFieldSubtype(a, b, types);
        },
    };
}

/// ADR-0124 — validate every declared subtype relationship in a type
/// section. For each typedef carrying declared supertype(s) (`sub` /
/// `sub final`): at most one supertype (Wasm 3.0 GC MVP), the supertype
/// index defined earlier (no `rec` forward refs in the flattened form),
/// the supertype not final (`sub final` / bare comptype can't be
/// extended), and the subtype structurally conforms. Returns false on
/// any violation. Empty supertypes (bare comptype) are always OK.
pub fn validateTypeSection(types: *const sections.Types) bool {
    for (types.supertypes, 0..) |supers, i| {
        if (supers.len == 0) continue;
        if (supers.len > 1) return false; // GC MVP allows ≤1 supertype
        const s = supers[0];
        if (s >= types.kinds.len) return false; // supertype index out of bounds
        if (s >= i) return false; // supertype must be declared earlier
        if (s < types.finals.len and types.finals[s]) return false; // extending a final type
        if (!typeDefIsSubtype(@intCast(i), s, types)) return false; // structural conformance
    }
    return true;
}

/// True iff `expected` (a branch target's label type) structurally
/// equals `tag_params ++ [exnref]` — the tuple a `catch_ref` clause
/// pushes. `catch_all_ref` passes empty `tag_params`, so the pushed
/// tuple is just `[exnref]`. Avoids materialising the concatenated
/// slice (the validator has no scratch allocator on this path).
fn labelTypeEqParamsPlusExn(expected: BlockType, tag_params: []const ValType) bool {
    const n = tag_params.len;
    if (n == 0) {
        // pushed = [exnref] → single element.
        return switch (expected) {
            .single => |t| t.eql(ValType.exnref),
            .empty, .multi => false,
        };
    }
    // n >= 1 → pushed has n+1 (≥2) elements → must be `.multi`.
    return switch (expected) {
        .multi => |ts| blk: {
            if (ts.len != n + 1) break :blk false;
            for (tag_params, ts[0..n]) |p, e| if (!p.eql(e)) break :blk false;
            break :blk ts[n].eql(ValType.exnref);
        },
        .empty, .single => false,
    };
}

fn labelTypesEq(a: BlockType, b: BlockType) bool {
    return switch (a) {
        .empty => b == .empty,
        .single => |t1| switch (b) {
            .single => |t2| t1.eql(t2),
            else => false,
        },
        .multi => |ts1| switch (b) {
            .multi => |ts2| blk: {
                // ADR-0123 Cycle 2: ValType is union(enum); std.mem.eql
                // can't derive == for unions whose inner types are
                // also unions. Manual loop via ValType.eql.
                if (ts1.len != ts2.len) break :blk false;
                for (ts1, ts2) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            else => false,
        },
    };
}
