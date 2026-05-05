//! ARM64 emit pass — shared error set, output types, and the
//! per-function emit context.
//!
//! Per ADR-0023 §3 reference table + ADR-0021 sub-deliverable b
//! (§9.7 / 7.5d sub-b emit.zig 9-module split): EmitCtx is the
//! parameter bundle that op-handler modules (`op_const.zig`,
//! `op_alu.zig`, …) take as their sole context argument. Fields
//! are *pointers* into compile()'s local state so that any
//! handler — whether already extracted or still inlined in
//! emit.zig — observes the same backing storage. This permits
//! incremental migration of one op-group at a time without
//! forcing a single big-bang refactor.
//!
//! `Error` and `CallFixup` live here (not in emit.zig) so that
//! op-handler modules can reach for them without circular
//! imports back to emit.zig.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const label_mod = @import("label.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const Label = label_mod.Label;

/// Errors raised by the ARM64 emit pass and its op-handler
/// modules. `OutOfMemory` is propagated from buffer growth and
/// fixup-list appends.
pub const Error = error{
    AllocationMissing,
    UnsupportedOp,
    SlotOverflow,
    OutOfMemory,
};

/// Pending `BL` site requiring linker patch. The post-emit
/// caller (linker / runtime harness) computes the target
/// address relative to `byte_offset` and rewrites the imm26
/// field. `target_func_idx` is the Wasm function index the call
/// targets.
pub const CallFixup = struct {
    byte_offset: u32,
    target_func_idx: u32,
};

/// Per-function emit context. Built by `compile()` once after
/// the function prologue lands; threaded as `*EmitCtx` to every
/// op-handler module so each handler can append code, manage the
/// pushed-vreg stack, register fixups, and look up call targets
/// uniformly. All mutable fields are pointers; this lets
/// compile()'s local state and the EmitCtx view coexist while
/// op-groups migrate one by one.
pub const EmitCtx = struct {
    allocator: Allocator,
    /// Output instruction stream. Handlers append `u32` words
    /// (little-endian) via the standard `writeU32` helper.
    buf: *std.ArrayList(u8),
    /// Source ZIR function (read-only).
    func: *const ZirFunc,
    /// Register allocation for `func` (read-only).
    alloc: regalloc.Allocation,
    /// `func_sigs[k]` is the FuncType of function index `k`;
    /// consulted by `call N` to pick the result register class.
    func_sigs: []const zir.FuncType,
    /// `module_types[t]` is the FuncType for type index `t`;
    /// consulted by `call_indirect type_idx`.
    module_types: []const zir.FuncType,
    /// Operand stack of pushed vreg ids. Handlers pop their
    /// operands and append the result vreg.
    pushed_vregs: *std.ArrayList(u32),
    /// Cursor for the next vreg id to allocate.
    next_vreg: *u32,
    /// Control-stack frames (block / loop / if / else).
    labels: *std.ArrayList(Label),
    /// Memory-bounds-trap fixups awaiting trap-stub emission at
    /// function-final `end`.
    bounds_fixups: *std.ArrayList(u32),
    /// `BL` fixups exposed via `EmitOutput` for the post-emit
    /// linker.
    call_fixups: *std.ArrayList(CallFixup),
    /// Absolute SP-relative byte offset of spill slot 0.
    /// Computed in the prologue (locals_bytes); read by
    /// `gprLoadSpilled` / `gprStoreSpilled` to address spill
    /// slots.
    spill_base_off: u32,
};
