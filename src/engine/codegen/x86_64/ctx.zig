//! x86_64 emit pass — per-function emit context (Zone 2 backbone).
//!
//! Mirror of `arm64/ctx.zig::EmitCtx` per ADR-0075 (x86_64
//! `(ctx, ins)` shape unification): bundles the per-function state
//! that op-handler modules (`op_alu_int.zig`, `op_memory.zig`, …)
//! need so the per-arch dispatcher signature in
//! `src/engine/codegen/dispatch_collector.zig::ArchAxis = .x86_64`
//! can collapse from the current positional 7-arg form to the
//! 2-arg `(ctx: *EmitCtx, ins: *const ZirInstr)` form once B54+
//! migrate handlers one cohort at a time.
//!
//! B53 (§9.12-B): introduce the struct + initialise at the top of
//! `emit.zig::compile()`. NO per-op handler signature change yet —
//! existing positional calls keep working; the struct is the
//! substrate for the upcoming migration. `Error`, `CallFixup`,
//! `SimdConstFixup` continue to live in `types.zig` to avoid
//! breaking external re-exports from `emit.zig`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const sections = @import("../../../parse/sections.zig");
const regalloc = @import("../shared/regalloc.zig");
const exception_table = @import("../shared/exception_table.zig");
const label_mod = @import("label.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const Label = label_mod.Label;

pub const Error = types.Error;
pub const CallFixup = types.CallFixup;
pub const SimdConstFixup = types.SimdConstFixup;

/// Init parameter bundle for `EmitCtx.init` — mirrors the
/// EmitCtx fields supplied by `compile()` (the `simd_consts_base`
/// + `func_idx` fields are derived inside `init` from `func`).
pub const InitArgs = struct {
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    labels: *std.ArrayList(Label),
    bounds_fixups: *std.ArrayList(u32),
    unreach_fixups: *std.ArrayList(u32),
    call_fixups: *std.ArrayList(CallFixup),
    simd_const_fixups: *std.ArrayList(SimdConstFixup),
    extra_consts: *std.ArrayList([16]u8),
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    return_is_memory_class: bool,
    indirect_result_slot_neg_off: u32,
    num_imports: u32,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    dead_code: *bool,
    frame_bytes: u32,
    uses_runtime_ptr: bool,
    total_locals: u32,
    local_disps: []const i32,
    /// ADR-0105 D2/D3 — see EmitCtx field of the same name.
    stack_probe_fixup: u32,
    /// ADR-0111 D4 — see EmitCtx field of the same name.
    memory0_idx_type: sections.MemoryEntry.IdxType = .i32,
    /// EH integration IT-1 — see EmitCtx field of the same name.
    /// Defaults to `null`; populated by `compile()` only when the
    /// function contains a `try_table` op.
    exception_table_builder: ?*exception_table.Builder = null,
    /// EH integration IT-2 — see EmitCtx field of the same name.
    /// Non-null iff `exception_table_builder` is non-null.
    open_try_tables: ?*std.ArrayList(exception_table.OpenTryTable) = null,
    /// EH integration IT-6 prep — see EmitCtx field of the same
    /// name. Non-null iff `exception_table_builder` is non-null.
    landing_pad_fixups: ?*std.ArrayList(exception_table.LandingPadFixup) = null,
    /// Phase 10.E-payload-prop Cycle 3 (ADR-0120) — see EmitCtx
    /// field of the same name. Default-empty preserves existing
    /// InitArgs construction sites.
    tag_param_counts: []const u32 = &.{},
    /// D-235 — see the EmitCtx field of the same name. Default `false`
    /// preserves existing InitArgs construction sites.
    uses_type_subtyping: bool = false,
};

/// Per-function emit context for x86_64. Threaded as `*EmitCtx`
/// to per-op handler modules once B54+ migrate them to the
/// `(ctx, ins)` signature. All mutable fields are pointers into
/// `compile()`'s local state so the legacy positional-arg
/// handlers and the new ctx-shape handlers can coexist during
/// migration.
pub const EmitCtx = struct {
    allocator: Allocator,
    /// Output instruction stream. Handlers append bytes via the
    /// `inst.*` encoder helpers + `buf.appendSlice(allocator, …)`.
    buf: *std.ArrayList(u8),
    /// Source ZIR function (read-only).
    func: *const ZirFunc,
    /// Register allocation for `func` (read-only).
    alloc: regalloc.Allocation,
    /// `func_sigs[k]` is the FuncType of function index `k`;
    /// consulted by `call N` to pick result reg class.
    func_sigs: []const zir.FuncType,
    /// `module_types[t]` is the FuncType for type index `t`;
    /// consulted by `call_indirect type_idx`.
    module_types: []const zir.FuncType,
    /// Operand stack of pushed vreg ids.
    pushed_vregs: *std.ArrayList(u32),
    /// Cursor for the next vreg id to allocate.
    next_vreg: *u32,
    /// Control-stack frames (block / loop / if / else).
    labels: *std.ArrayList(Label),
    /// Memory-bounds-trap fixups awaiting trap-stub emission at
    /// function-final `end`. `JAE rel32` placeholders (6 bytes:
    /// `0x0F 0x83 <disp32>`).
    bounds_fixups: *std.ArrayList(u32),
    /// `unreachable` placeholders — `JMP rel32` (5 bytes:
    /// `0xE9 <disp32>`). Distinct from `bounds_fixups` because
    /// the disp formula differs by 1 byte. Patched alongside
    /// `bounds_fixups` at function-end trap-stub block.
    unreach_fixups: *std.ArrayList(u32),
    /// `CALL rel32` fixups exposed via `EmitOutput` for the
    /// post-emit linker.
    call_fixups: *std.ArrayList(CallFixup),
    /// SIMD const-pool fixups (per ADR-0042; mirror of arm64's
    /// `simd_const_fixups`). Each entry records a MOVUPS-RIP-rel
    /// placeholder's disp32 byte offset + post-instruction byte
    /// + flat const_idx. Patched at function close after both
    /// `func.simd_consts` (lower-time literals) and
    /// `extra_consts` (emit-time derived) are appended past the
    /// trap stub (16-byte aligned).
    simd_const_fixups: *std.ArrayList(SimdConstFixup),
    /// Emit-time-derived 16-byte SIMD constants discovered by
    /// per-op handlers (per ADR-0051; popcnt LUTs, broadcast
    /// masks, per-shape magic constants). Appended to the flat
    /// const-pool *after* lower-time entries at function close.
    extra_consts: *std.ArrayList([16]u8),
    /// Number of lower-time entries in the flat const-pool.
    /// Equals `func.simd_consts.?.len` when non-null, 0 otherwise.
    /// Handlers compute the global const_idx as `simd_consts_base
    /// + position-in-extra_consts`.
    simd_consts_base: u32,
    /// Absolute SP-relative byte offset of spill slot 0. Equals
    /// `locals_bytes + r15_save_bytes + 8`; the +8 puts spill
    /// slot 0 in the next 8-byte cell below the deepest local.
    /// `gpr.zig`'s `rbpDispNegI8` consumes it as `disp =
    /// -(spill_base_off + spill_off)`.
    spill_base_off: u32,
    /// §9.7 / 7.10-f outgoing-args region pre-allocated at the
    /// BOTTOM of the frame. For SysV: pure overflow bytes; for
    /// Win64: includes the 32-byte shadow space when any call
    /// exists. Consumed by `op_call.emitCall` to decide whether
    /// the per-call `emitShadowAlloc` / `Free` are no-ops.
    outgoing_max_bytes: u32,
    /// True iff this function's return tuple is MEMORY-class per
    /// SysV §3.2.3 (v2 trigger: `sig.results.len > 2` under SysV;
    /// Win64 MEMORY-class deferred to §9.13-0).
    return_is_memory_class: bool,
    /// RBP-negative byte offset (= absolute value) of the
    /// captured-RDI slot when `return_is_memory_class` is true;
    /// meaningless otherwise. Slot sits below the spill region.
    /// `compile()` stores RDI at `[RBP - indirect_result_slot_neg_off]`
    /// after the SUB-RSP prologue.
    indirect_result_slot_neg_off: u32,
    /// Leading wasm-space function indices that name imports.
    /// `op_call.emitCall` checks `callee_idx < num_imports` to
    /// switch between host-import dispatch and a normal
    /// `CALL rel32 + CallFixup`.
    num_imports: u32,
    /// 10.E-codegen-4b: per-function EH handler-entry accumulator.
    /// `op_exception_handling.try_table` appends one `HandlerEntry`
    /// per catch clause (per ADR-0114 D2); the post-emit linker
    /// finalises into the per-Instance ExceptionTable consumed by
    /// the FP-walk unwinder. Optional: null for functions that
    /// contain no try_table (back-compat for every existing
    /// EmitCtx construction site).
    exception_table_builder: ?*exception_table.Builder = null,
    /// 10.E-codegen IT-2: see arm64/ctx.zig field of the same name.
    open_try_tables: ?*std.ArrayList(exception_table.OpenTryTable) = null,
    /// 10.E-codegen IT-6 prep: see arm64/ctx.zig field.
    landing_pad_fixups: ?*std.ArrayList(exception_table.LandingPadFixup) = null,
    /// Per-defined-global metadata (ADR-0052; §9.9 / 9.9-h-2).
    /// Indexed by **defined** global idx (= wasm-space global
    /// idx minus the leading imported-global count). Parallel
    /// arrays: `globals_offsets[i]` is the byte offset of
    /// global i inside the runtime's globals byte buffer;
    /// `globals_valtypes[i]` selects the emit path
    /// (i32/i64/f32/f64/ref → 8-byte slot; v128 → 16-byte slot).
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    /// Cached `func.func_idx`. Consumed by trace.writeBounds /
    /// trace.writeCallTrap and the per-arch trap-stub epilogue.
    func_idx: u32,
    /// §9.12-B / B73: pointer to compile()'s dead_code local.
    /// Set true by `unreachable` (and select arm) to skip
    /// emitting until the next control-flow boundary resets it.
    dead_code: *bool,
    /// §9.12-B / B74: per-function frame size in bytes (set once
    /// at function entry; consumed by return + br family for
    /// `ADD RSP, frame_bytes` in the epilogue).
    frame_bytes: u32,
    /// §9.12-B / B74: whether the function reserves R15 for the
    /// runtime_ptr_save (set once at function entry; consumed by
    /// the epilogue to decide POP R15).
    uses_runtime_ptr: bool,
    /// §9.12-B / B78: total local count (= num_params +
    /// num_declared_locals). Set once at function entry;
    /// consumed by emitLocalGet/Set/Tee for the bound check.
    total_locals: u32,
    /// §9.12-B / B78: per-local RBP-relative disps. Set once at
    /// function entry from `layout.disps`; consumed by
    /// emitLocalGet/Set/Tee.
    local_disps: []const i32,
    /// ADR-0105 D2/D3 — byte offset of the JIT-prologue stack-probe's
    /// `JBE rel32` placeholder. `0` = probe not emitted (no
    /// uses_runtime_ptr → function cannot recurse → no probe needed).
    /// When non-zero, the function-end handler in op_control.zig
    /// emits a dedicated stack-overflow trap stub with fb=0 (probe
    /// fires BEFORE the SUB RSP) and patches this fixup to its
    /// disp32.
    stack_probe_fixup: u32,
    /// ADR-0111 D4 — memory 0's idx_type. `.i32` (legacy ≤ 4 GiB;
    /// byte-identical fast path) or `.i64` (memory64 64-bit MOV
    /// + u64 offset materialise). Per-module constant; codegen
    /// branches on it at emitMemOp's entry. Default `.i32` keeps
    /// existing init args ergonomic.
    memory0_idx_type: sections.MemoryEntry.IdxType = .i32,
    /// Phase 10.E-payload-prop Cycle 3 (ADR-0120) — per-tag param
    /// count threaded from `CompiledWasm.tag_param_counts` for
    /// `throw.emit` / `try_table.emit` payload-marshalling.
    /// Default-empty preserves existing EmitCtx construction sites.
    tag_param_counts: []const u32 = &.{},
    /// D-235 — true iff this module declares func subtyping. When true,
    /// `op_call.emitCallIndirect` replaces the inline D-111 structural sig
    /// `CMP` with a `jitCallIndirectSubtypeOk` trampoline call. Default
    /// `false` keeps non-subtyping modules + test helpers on the
    /// byte-identical inline path.
    uses_type_subtyping: bool = false,

    pub fn init(args: InitArgs) EmitCtx {
        const simd_consts_base: u32 =
            if (args.func.simd_consts) |sc| @intCast(sc.len) else 0;
        return .{
            .allocator = args.allocator,
            .buf = args.buf,
            .func = args.func,
            .alloc = args.alloc,
            .func_sigs = args.func_sigs,
            .module_types = args.module_types,
            .pushed_vregs = args.pushed_vregs,
            .next_vreg = args.next_vreg,
            .labels = args.labels,
            .bounds_fixups = args.bounds_fixups,
            .unreach_fixups = args.unreach_fixups,
            .call_fixups = args.call_fixups,
            .simd_const_fixups = args.simd_const_fixups,
            .extra_consts = args.extra_consts,
            .simd_consts_base = simd_consts_base,
            .spill_base_off = args.spill_base_off,
            .outgoing_max_bytes = args.outgoing_max_bytes,
            .return_is_memory_class = args.return_is_memory_class,
            .indirect_result_slot_neg_off = args.indirect_result_slot_neg_off,
            .num_imports = args.num_imports,
            .globals_offsets = args.globals_offsets,
            .globals_valtypes = args.globals_valtypes,
            .func_idx = args.func.func_idx,
            .dead_code = args.dead_code,
            .frame_bytes = args.frame_bytes,
            .uses_runtime_ptr = args.uses_runtime_ptr,
            .total_locals = args.total_locals,
            .local_disps = args.local_disps,
            .stack_probe_fixup = args.stack_probe_fixup,
            .memory0_idx_type = args.memory0_idx_type,
            .exception_table_builder = args.exception_table_builder,
            .open_try_tables = args.open_try_tables,
            .landing_pad_fixups = args.landing_pad_fixups,
            .tag_param_counts = args.tag_param_counts,
            .uses_type_subtyping = args.uses_type_subtyping,
        };
    }

    /// Pop two operands + allocate a result vreg. Shared header
    /// for every binary op-handler post-migration.
    pub fn popBinary(self: *EmitCtx) Error!struct { lhs: u32, rhs: u32, result: u32 } {
        if (self.pushed_vregs.items.len < 2) return Error.AllocationMissing;
        const rhs = self.pushed_vregs.pop().?;
        const lhs = self.pushed_vregs.pop().?;
        const result = self.next_vreg.*;
        self.next_vreg.* += 1;
        if (result >= self.alloc.slots.len) {
            std.debug.print(
                "x86_64/ctx: popBinary SlotOverflow at func[{d}]: next_vreg={d} >= slots.len={d}\n",
                .{ self.func_idx, result, self.alloc.slots.len },
            );
            return Error.SlotOverflow;
        }
        return .{ .lhs = lhs, .rhs = rhs, .result = result };
    }

    /// Pop one operand + allocate a result vreg.
    pub fn popUnary(self: *EmitCtx) Error!struct { src: u32, result: u32 } {
        if (self.pushed_vregs.items.len < 1) return Error.AllocationMissing;
        const src = self.pushed_vregs.pop().?;
        const result = self.next_vreg.*;
        self.next_vreg.* += 1;
        if (result >= self.alloc.slots.len) {
            std.debug.print(
                "x86_64/ctx: popUnary SlotOverflow at func[{d}]: next_vreg={d} >= slots.len={d}\n",
                .{ self.func_idx, result, self.alloc.slots.len },
            );
            return Error.SlotOverflow;
        }
        return .{ .src = src, .result = result };
    }
};
