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
const sections = @import("../../../parse/sections.zig");
const regalloc = @import("../shared/regalloc.zig");
const exception_table = @import("../shared/exception_table.zig");
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

/// Pending `LDR Q<rt>, <label>` site requiring const-pool patch
/// (per ADR-0042). At function close, after the trap stub, the
/// per-function const-pool is appended (16-byte aligned) and the
/// imm19 field of every SimdConstFixup is patched to the
/// PC-relative offset of `func.simd_consts[const_idx]`.
pub const SimdConstFixup = struct {
    byte_offset: u32, // location of the LDR-Q-literal placeholder
    const_idx: u32, // index into func.simd_consts
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
    /// §9.9-III D-144 γ.4 cycle 4 — call_indirect bounds-check
    /// (B.HS) fixups. Patched to a dedicated trap stub that writes
    /// `trap_kind = 2`. Permanent diagnostic infra: every future
    /// call_indirect bounds trap localises its source via
    /// `printCallTrap`'s `kind=` emit.
    cind_bounds_fixups: *std.ArrayList(u32),
    /// §9.9-III D-144 γ.4 cycle 4 — call_indirect sig-mismatch
    /// (B.NE) fixups. Patched to a dedicated trap stub that
    /// writes `trap_kind = 3`. See `cind_bounds_fixups`.
    cind_sig_fixups: *std.ArrayList(u32),
    /// `return` / `br <function-depth>` placeholders; patched at
    /// function-final `end` to share the regular epilogue path.
    return_fixups: *std.ArrayList(u32),
    /// `BL` fixups exposed via `EmitOutput` for the post-emit
    /// linker.
    call_fixups: *std.ArrayList(CallFixup),
    /// SIMD const-pool fixups (per ADR-0042). Each entry records
    /// the byte offset of an LDR-Q-literal placeholder and a
    /// global const_idx into the flat per-function pool. The pool
    /// concatenates `func.simd_consts` (lower-time literals) and
    /// `extra_consts` (emit-time derived constants per ADR-0051);
    /// const_idx ∈ [0, simd_consts_base) addresses the former,
    /// const_idx ∈ [simd_consts_base, ...) the latter. Patched at
    /// function close after both lists are appended (16-byte
    /// aligned) past the trap stub.
    simd_const_fixups: *std.ArrayList(SimdConstFixup),
    /// Emit-time-derived 16-byte SIMD constants discovered by
    /// per-op handlers (per ADR-0051; mirror of x86_64's
    /// `extra_consts`). Per-shape masks, magic constants, LUTs.
    /// Appended to the flat const-pool *after* lower-time entries
    /// at function close. Handlers register entries via
    /// `op_simd.lookupOrAppendExtraConst`.
    extra_consts: *std.ArrayList([16]u8),
    /// Number of lower-time entries in the flat const-pool.
    /// Equals `func.simd_consts.?.len` when non-null, 0 otherwise.
    /// Handlers compute global const_idx as `simd_consts_base +
    /// position-in-extra_consts`.
    simd_consts_base: u32,
    /// Absolute SP-relative byte offset of local slot 0.
    /// §9.7 / 7.9-d-11: equals `outgoing_max_bytes`, the bottom-of-
    /// frame region pre-allocated for caller-side stack args. Zero
    /// for functions that make no calls or whose every callee fits
    /// args in X1..X7 + V0..V7. Locals at `[SP, #(local_base_off +
    /// p_idx*8)]`.
    local_base_off: u32,
    /// Absolute SP-relative byte offset of spill slot 0.
    /// §9.7 / 7.9-d-11: equals `local_base_off + locals_bytes`;
    /// the spill region sits above locals which sits above the
    /// outgoing-args region. Read by `gprLoadSpilled` /
    /// `gprStoreSpilled` to address spill slots.
    spill_base_off: u32,
    /// §9.9 / 9.9-II chunk (b)-e-1/2 (ADR-0017 2026-05-18 amend;
    /// ADR-0069 §Phase 2): true iff this function's return tuple
    /// is MEMORY-class per AAPCS64 §6.8.2 — caller passes a hidden
    /// indirect-result-pointer in X8 which the prologue captures
    /// to `[SP, #indirect_result_slot_off]` and the epilogue
    /// (`marshalFunctionReturn`) writes each result to
    /// `[X8, #(i*8)]` via X16. v2 classifies MEMORY-class as
    /// `sig.results.len > 2` (each FuncRet_* field 8 B per
    /// ADR-0069 Class A convention; 3+ results force struct > 16 B).
    return_is_memory_class: bool,
    /// SP-relative byte offset of the captured X8 slot when
    /// `return_is_memory_class` is true; meaningless otherwise.
    /// Slot sits above the spill region inside the function frame.
    indirect_result_slot_off: u32,
    /// Leading wasm-space function indices that name imports
    /// (chunk 7.9-b foundation). `op_call.emitCall` checks
    /// `ins.payload < num_imports` to decide between a normal
    /// BL + CallFixup (defined function call) and an
    /// import-as-trap branch (B → trap stub via bounds_fixups).
    num_imports: u32,
    /// 10.E-codegen-4b: per-function EH handler-entry accumulator.
    /// `op_exception_handling.try_table` appends one `HandlerEntry`
    /// per catch clause (per ADR-0114 D2); the post-emit linker
    /// finalises into the per-Instance ExceptionTable consumed by
    /// the FP-walk unwinder. Optional: null for functions that
    /// contain no try_table (back-compat for every existing
    /// EmitCtx construction site).
    exception_table_builder: ?*exception_table.Builder = null,
    /// 10.E-codegen IT-2: stack of open `try_table` blocks; one
    /// `OpenTryTable` entry per try_table currently between its
    /// emit and its matching `end`. The end-op patches pc_end of
    /// the `entry_start..entry_start+entry_count` Builder rows
    /// when popping a label whose stack position matches
    /// `labels_depth`. Optional: null for functions without any
    /// try_table; non-null iff `exception_table_builder` is non-null.
    open_try_tables: ?*std.ArrayList(exception_table.OpenTryTable) = null,
    /// 10.E-codegen IT-6 prep: per-catch landing_pad_pc forward
    /// fixup list. `try_table.emit` appends one per catch clause
    /// (key = labels-stack depth of the target br-label); the
    /// matching label's `end` patches `Builder.entries[entry_idx]
    /// .landing_pad_pc` to the post-end buf offset. Non-null iff
    /// `exception_table_builder` is non-null.
    landing_pad_fixups: ?*std.ArrayList(exception_table.LandingPadFixup) = null,
    /// Per-defined-global metadata (ADR-0052; §9.9 / 9.9-h-2).
    /// Indexed by **defined** global idx (= wasm-space global
    /// idx minus the leading imported-global count). Parallel
    /// arrays: `globals_offsets[i]` is the byte offset of
    /// global i inside the runtime's globals byte buffer;
    /// `globals_valtypes[i]` selects the JIT emit path
    /// (i32/i64/f32/f64/ref → 8-byte slot via existing
    /// `globals_base: [*]Value`; v128 → 16-byte slot via
    /// `LDR Q [X23, #off]`). Empty slices when the module has
    /// no defined globals. v128 globals as cross-module imports
    /// are out of scope this chunk (D-079 follow-up); imported
    /// global idx beyond `globals_offsets.len` falls back to
    /// the i32 emit shape with `idx*8` byte offset.
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    /// Memory 0's address-space discriminator (Wasm 3.0 §5.4.4
    /// memory64 proposal; ADR-0111 D2/D4). `.i32` for legacy
    /// (≤ 4 GiB) modules — the byte-identical fast path; `.i64`
    /// for memory64 modules — triggers the 64-bit offset
    /// materialise + wrap-check emit shape in `op_memory.zig::
    /// emitMemOp`. Multi-memory (`memories[memidx]` for memidx > 0)
    /// is rejected at runtime instantiate today; codegen only sees
    /// memory 0 per the `MemArgExtra.memidx == 0` assert in 10.M-4a.
    /// Default `.i32` keeps the 36 existing compile() call sites
    /// behaviour-preserving when they pass struct-literal default.
    memory0_idx_type: sections.MemoryEntry.IdxType = .i32,
    /// Wasm 3.0 EH (10.E-payload-prop Cycle 3; ADR-0120) — per-tag
    /// param count threaded from `CompiledWasm.tag_param_counts`
    /// (compile.zig). Indexed by `tag_idx`. `throw.emit` /
    /// `try_table.emit` consume this to know how many operand
    /// values to marshal between the regalloc stack and the
    /// per-Runtime `eh_payload_buf`. Default-empty preserves the
    /// existing EmitCtx construction sites (entry / linker /
    /// wrapper_thunk test helpers and any pre-EH compile path).
    tag_param_counts: []const u32 = &.{},

    /// Pop two operands + allocate a result vreg. Shared header
    /// for every binary op-handler. Returns the lhs / rhs / result
    /// vreg ids or `AllocationMissing` (stack underflow) /
    /// `SlotOverflow` (allocator out of slots).
    pub fn popBinary(self: *EmitCtx) Error!struct { lhs: u32, rhs: u32, result: u32 } {
        if (self.pushed_vregs.items.len < 2) return Error.AllocationMissing;
        const rhs = self.pushed_vregs.pop().?;
        const lhs = self.pushed_vregs.pop().?;
        const result = self.next_vreg.*;
        self.next_vreg.* += 1;
        if (result >= self.alloc.slots.len) {
            std.debug.print(
                "arm64/ctx: popBinary SlotOverflow at func[{d}]: next_vreg={d} >= slots.len={d}\n",
                .{ self.func.func_idx, result, self.alloc.slots.len },
            );
            return Error.SlotOverflow;
        }
        return .{ .lhs = lhs, .rhs = rhs, .result = result };
    }

    /// Pop one operand + allocate a result vreg. Shared header
    /// for every unary op-handler.
    pub fn popUnary(self: *EmitCtx) Error!struct { src: u32, result: u32 } {
        if (self.pushed_vregs.items.len < 1) return Error.AllocationMissing;
        const src = self.pushed_vregs.pop().?;
        const result = self.next_vreg.*;
        self.next_vreg.* += 1;
        if (result >= self.alloc.slots.len) {
            std.debug.print(
                "arm64/ctx: popUnary SlotOverflow at func[{d}]: next_vreg={d} >= slots.len={d}\n",
                .{ self.func.func_idx, result, self.alloc.slots.len },
            );
            return Error.SlotOverflow;
        }
        return .{ .src = src, .result = result };
    }
};
