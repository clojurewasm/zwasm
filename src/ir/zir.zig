//! ZIR (Zwasm Intermediate Representation) — container types only.
//!
//! Phase 1 / task 1.1 declares the **type identities** required by
//! ROADMAP §4.2's `ZirFunc` pseudocode. Per ROADMAP §P13 ("type
//! up-front, slots over flags") every `?T` analysis / regalloc /
//! optimisation slot is reserved day 1; later phases populate the
//! fields without touching the struct shape (the W54 lesson —
//! see `~/Documents/MyProducts/zwasm/.dev/archive/w54-redesign-postmortem.md`).
//!
//! `ZirOp` itself is an open enum here; task 1.2 declares the full
//! Wasm 3.0 + JIT pseudo-op catalogue per ROADMAP §4.2.
//!
//! Zone 1 (`src/ir/`) — may import Zone 0 only. No upward imports.

const std = @import("std");

const Allocator = std.mem.Allocator;

const trace = @import("../diagnostic/trace.zig");

pub const ValType = enum(u8) {
    i32,
    i64,
    f32,
    f64,
    v128,
    funcref,
    externref,
    /// Wasm 3.0 GC `i31ref` — low-bit-tagged i32 carried in
    /// `Value.anyref` (offset stored via i31_pack tag encoding,
    /// per ADR-0116 §135-149). i31 has NO heap allocation —
    /// it's the only Internal-hierarchy ValType that doesn't
    /// reach into the per-Store GC slab. Added per ADR-0115 §6
    /// Revision 2026-05-29 (cycle 2 of 10.G-op_gc bundle). The
    /// other 4 Internal-hierarchy types (anyref / eqref /
    /// structref / arrayref) land in subsequent cycles via the
    /// same closed-enum + per-site arm-out cascade pattern.
    i31ref,
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// Module table entry (Wasm 2.0 §9.2 / 2.3 chunk 5c). Carries
/// only the static metadata the validator needs; the runtime
/// counterpart `TableInstance` (in `runtime/runtime.zig`) holds the
/// actual reference values.
pub const TableEntry = struct {
    elem_type: ValType,
    min: u32,
    max: ?u32 = null,
};

pub const BlockKind = enum(u8) {
    block,
    loop,
    if_then,
    else_open,
    /// Wasm 3.0 exception-handling proposal (§3.3.10.6 / §4.5):
    /// `try_table` introduces a control frame that establishes
    /// exception handlers via its catch vec. Label types follow
    /// the `block` rule (end_type) — branches to the try_table
    /// label arrive on `end`, not on `throw` (catch dispatch
    /// uses the catch's own label_idx). Foundation entry for
    /// 10.E-N opcode/validator/interp wiring.
    try_table,
};

pub const BlockInfo = struct {
    kind: BlockKind,
    start_inst: u32,
    end_inst: u32,
    /// Position of the matching `else` opcode for `if` frames that
    /// have one. The interp routes `if cond=0` to `else_inst + 1`
    /// or, when `null`, to `end_inst + 1`. Set by the lowerer on
    /// `else` emission; remains `null` for plain blocks / loops /
    /// if-without-else.
    else_inst: ?u32 = null,
};

// ZirOp catalog extracted to `zir_ops.zig` per ADR-0087 (pure
// tag enum, 684 LOC). Re-exported here so callers reach `zir.ZirOp`
// unchanged.
const zir_ops = @import("zir_ops.zig");
pub const ZirOp = zir_ops.ZirOp;

pub const ZirInstr = struct {
    op: ZirOp,
    payload: u64 = 0,
    extra: u32 = 0,
};

/// Per Wasm 3.0 §5.4.6 / ADR-0111 D3, memarg-bearing ops
/// (load*/store*/load_lane/store_lane) carry alignment + an
/// explicit memidx through `ZirInstr.extra`. Encoded as a
/// packed-u32 so the existing `extra: u32` field stays
/// byte-identical for non-memarg ops. `_pad` is reserved zero
/// (future memory64-related extensions: page-size hint, etc.).
pub const MemArgExtra = packed struct(u32) {
    /// log2 of byte alignment (Wasm spec §5.4.6 memarg align;
    /// always ≤ natural alignment of the op — i32: ≤ 2 /
    /// i64: ≤ 3 / v128: ≤ 4). 5 bits permits 0..31, well
    /// beyond any Wasm-permitted op.
    align_pow2: u5 = 0,
    /// Memory index (Wasm 3.0 multi-memory). 0 for legacy
    /// single-memory modules; 1..255 for multi-memory enabled
    /// modules (parser+validator support at 10.M-3; runtime
    /// instantiate still rejects > 1 until codegen wires
    /// per-memidx access at 10.M-4).
    memidx: u8 = 0,
    _pad: u19 = 0,

    pub fn pack(align_pow2: u5, memidx: u8) u32 {
        const m: MemArgExtra = .{ .align_pow2 = align_pow2, .memidx = memidx };
        return @bitCast(m);
    }

    pub fn unpack(extra: u32) MemArgExtra {
        return @bitCast(extra);
    }
};

/// Returns true if `op` is a SIMD-128 ZirOp (operates on or
/// produces v128 vregs). Per ADR-0041 §"Decision" / 1
/// (shape-as-variant), the predicate uses tag-name prefix
/// matching: any op whose textual name starts with `v128.`,
/// `i8x16.`, `i16x8.`, `i32x4.`, `i64x2.`, `f32x4.`, or
/// `f64x2.` is a SIMD op.
///
/// Used by `regalloc.compute()` to populate
/// `Allocation.shape_tags` per ADR-0041 §"Decision" / 2 +
/// §14 (single_slot_dual_meaning). Emit pass queries the
/// resulting shape tag to select 16-byte vs 8-byte spill
/// stride and Q vs D/S register view.
pub fn isSimdZirOp(op: ZirOp) bool {
    const name = @tagName(op);
    return std.mem.startsWith(u8, name, "v128.") or
        std.mem.startsWith(u8, name, "i8x16.") or
        std.mem.startsWith(u8, name, "i16x8.") or
        std.mem.startsWith(u8, name, "i32x4.") or
        std.mem.startsWith(u8, name, "i64x2.") or
        std.mem.startsWith(u8, name, "f32x4.") or
        std.mem.startsWith(u8, name, "f64x2.");
}

// Forward-declared "slot" types — identities reserved day 1 per
// P13 / W54 lesson. Fields land in the populating phase
// (commented at each declaration). Adding fields later is OK;
// renaming or removing the type would be a §4.2 deviation
// requiring an ADR (§18).

/// Phase 5+: per-function liveness analysis result. Populated
/// by `src/ir/liveness.zig`. Per-vreg live ranges; vreg ids are
/// assigned in def order (0, 1, 2 …) as the analysis walks the
/// instr stream simulating the operand stack. Slices borrowed —
/// caller owns lifetime, mirrors `LoopInfo`.
pub const Liveness = struct {
    /// One entry per defined vreg. `ranges[v].def_pc` is the
    /// instr index that pushed the value; `last_use_pc` is the
    /// final consuming instr (pop-side or function-level end).
    ranges: []const LiveRange = &.{},
};

pub const LiveRange = struct {
    def_pc: u32,
    last_use_pc: u32,
};

/// Phase 5+: loop nesting + branch target resolution. Populated
/// by `src/ir/loop_info.zig` from `ZirFunc.blocks` after the
/// lowerer fills the block table. Slices borrowed; lifetime is
/// the caller's (typically the per-instance arena, or
/// `loop_info.deinit` on free).
pub const LoopInfo = struct {
    /// Instruction indices of `loop` opcodes in this function.
    /// Parallel to `loop_end`. Empty for non-looping functions.
    loop_headers: []const u32 = &.{},
    /// Instruction indices of the matching `end` for each loop in
    /// `loop_headers`. Same length as `loop_headers`.
    loop_end: []const u32 = &.{},
};

/// Phase 5+: hoisted-constant pool seed. Populated by
/// `src/ir/const_prop.zig`. Each entry records a peephole-foldable
/// binop site: the two `i*.const` def pcs that supplied the
/// operands, the binop pc itself, and the constant-evaluated
/// result encoded as a `(lo, hi)` `u32` pair (`result_lo` carries
/// 32-bit results; `result_hi` carries the upper 32 bits for i64).
/// Slice borrowed; lifetime is the caller's, mirrors LoopInfo /
/// Liveness.
pub const ConstantPool = struct {
    folds: []const ConstantFold = &.{},
};

pub const ConstantFold = struct {
    def_pc_a: u32,
    def_pc_b: u32,
    op_pc: u32,
    result_lo: u32,
    result_hi: u32 = 0,
};

/// Per-vreg register-class identity. The IR carries the class
/// so the regalloc IR shape is per-arch-independent (the W54
/// post-mortem identified per-arch IR drift as the v1 D117
/// dual-entry-self-call workaround's root cause). Per-class
/// invariants (width, spill alignment, special-cache discipline)
/// live in `src/jit/reg_class.zig` (Zone 2); the per-arch
/// physical register inventory lives in
/// `src/jit_<arch>/abi.zig` (Phase 7.2). This 3-way split is the
/// "split class identity from per-arch register inventory" rule
/// made structural.
///
/// The three `*_special` variants are the W54-class day-1 slot
/// fill (ROADMAP §4.2 + §9.7 / 7.0) — they reserve regalloc IR
/// slots that the v1 design discovered late and patched with
/// per-callsite workarounds:
///   - `inst_ptr_special`  — the `inst_ptr` cache that v1's
///     D117 workaround proved must be expressible in regalloc
///     IR, not the per-arch emit pass.
///   - `vm_ptr_special`    — the runtime base pointer.
///   - `simd_base_special` — the SIMD-lane base pointer.
pub const RegClass = enum(u8) {
    gpr,
    fpr,
    simd,
    inst_ptr_special,
    vm_ptr_special,
    simd_base_special,
    _,
};

/// Phase 7+: spilled-vreg stack slot record.
pub const SpillSlot = struct {};

/// Phase 7+: special-purpose register cache layout (inst_ptr /
/// vm_ptr / simd_base, per ROADMAP §4.2 RegClass.*_special).
pub const CacheLayout = struct {};

/// Phase 9+: SIMD lane-routing metadata.
pub const LaneRouting = struct {};

/// Phase 10+: GC-managed reference root map.
pub const GcRootMap = struct {};

/// Wasm 3.0 EH §4.5 — catch clause kind discriminator. Encoded in the
/// `try_table` instruction's catch-vec; preserved on `CatchEntry`
/// for the interp unwinder to decide payload shape at catch time.
///   - `catch_` / `catch_ref`: match exception by `tag_idx` equality.
///     `_ref` variants additionally push the originating `exnref` on
///     entry to the catch label.
///   - `catch_all` / `catch_all_ref`: match any exception (no
///     `tag_idx`). `_ref` pushes the `exnref`.
pub const CatchKind = enum(u8) {
    catch_ = 0x00,
    catch_ref = 0x01,
    catch_all = 0x02,
    catch_all_ref = 0x03,
};

/// One catch clause inside a `try_table`'s catch-vec. Stored flat in
/// `ZirFunc.eh_catch_entries`; each `LandingPad` references a
/// `[catches_start, catches_end)` slice. `tag_idx` is unused (zeroed)
/// for the `catch_all` / `catch_all_ref` kinds.
///
/// Wasm spec 3.0 §4.5 — try_table catch encoding.
pub const CatchEntry = struct {
    kind: CatchKind,
    tag_idx: u32,
    label_idx: u32,
};

/// Phase 10+: exception-handling landing pad. One per `try_table`
/// instruction in the function body. `block_idx` keys into
/// `ZirFunc.blocks` (the `.try_table` BlockInfo); the interp
/// unwinder uses this to associate a try_table label on the
/// label stack with its catch-vec when `Trap.UncaughtException`
/// propagates. `catches_start` / `catches_end` form a half-open
/// slice into `ZirFunc.eh_catch_entries`.
///
/// Wasm spec 3.0 §3.3.10.6 — try_table catch metadata.
pub const LandingPad = struct {
    block_idx: u32,
    catches_start: u32,
    catches_end: u32,
};

/// Phase 10+: tail-call site record.
pub const TailCallSite = struct {};

/// Phase 8+: hoisted constant placement record (per ADR-0031).
/// Populated by `src/ir/hoist/pass.zig` when a `*.const` opcode
/// inside a loop is rewritten via the local-set/local-get
/// pattern: `*.const K; local.set N` is inserted before the loop
/// header; the in-loop `*.const K` becomes `local.get N`.
/// `original_pc` is the const's PC in the pre-hoist instr stream;
/// `prologue_const_pc` and `prologue_set_pc` are the post-hoist
/// PCs of the inserted prologue pair; `in_loop_pc` is the
/// post-hoist PC of the replacement `local.get`. `local_idx` is
/// the absolute Wasm-space local index allocated for this hoist
/// (= original `num_params + locals.len + synthetic_offset`).
/// `op` + `payload` + `extra` mirror the original ZirInstr fields.
pub const HoistedConst = struct {
    original_pc: u32,
    prologue_const_pc: u32,
    prologue_set_pc: u32,
    in_loop_pc: u32,
    local_idx: u32,
    op: ZirOp,
    payload: u64,
    extra: u32,
};

/// Phase 15+: bounds-check elision proof.
pub const ElisionRecord = struct {};

/// Phase 8+ (§9.8b / 8b.1; ADR-0035): post-regalloc slot-
/// aliasing coalescer record. Emit pass queries
/// `func.coalesced_movs` for each MOV-shaped emission site
/// and skips emission when a record's `instr_pc` matches
/// the current dispatch index. Side-table metadata only —
/// neither ZIR nor `regalloc.Allocation` is mutated.
pub const CoalesceRecord = struct {
    /// PC of the ZIR instr in `func.instrs.items` whose
    /// emit-time MOV is redundant (src_slot == dst_slot
    /// AND dst is consumed via that slot OR is dead before
    /// next write).
    instr_pc: u32,
    /// The slot id involved (informational; both src and
    /// dst share this slot — that's the alias).
    slot: u16,
    /// Detection class. Open enum (`_` extension) so
    /// future detection passes can add new reasons without
    /// breaking existing emit-side consumers.
    reason: Reason,

    pub const Reason = enum(u8) {
        /// `slots[src_vreg] == slots[dst_vreg]` AND not
        /// across a call boundary AND not at a branch
        /// target (per ADR-0035 detection algorithm).
        same_slot_alias = 0,
        _,
    };
};

/// Phase 8+: per-function per-pass diagnostic record (per
/// ADR-0033). Populated by the compile pipeline's `passExit`
/// wrapper at each pipeline stage. The `extra` field is
/// per-pass (documented at the call site to avoid the
/// `single_slot_dual_meaning.md` anti-pattern):
///   - `lower`: resulting `instrs.len`
///   - `loop_info`: 0
///   - `hoist`: synthetic locals added
///   - `liveness`: range-table length
///   - `regalloc`: high-water slot id
///   - `emit`: bytes emitted
pub const PassRecord = struct {
    pass: trace.PassId,
    applied: u32,
    skipped: u32,
    extra: u32,
};

/// Phase 8+: per-function pass-diagnostics slot (per ADR-0033).
/// Borrowed slice; lifetime mirrors `Liveness` / `LoopInfo`.
/// Populated when `trace.enabled == true`; otherwise the slot
/// stays `null` and is dead state. Freed via
/// `deinitPassDiagnostics` from the same allocator that built
/// the slice.
pub const PassDiagnostics = struct {
    entries: []const PassRecord = &.{},
};

/// Free a `PassDiagnostics`'s entries slice. No-op when the
/// slice is empty (default-initialised case).
pub fn deinitPassDiagnostics(allocator: Allocator, pd: PassDiagnostics) void {
    if (pd.entries.len != 0) allocator.free(pd.entries);
}

pub const ZirFunc = struct {
    func_idx: u32,
    sig: FuncType,
    locals: []const ValType,
    instrs: std.ArrayList(ZirInstr),
    blocks: std.ArrayList(BlockInfo),
    branch_targets: std.ArrayList(u32),

    // Phase 5+ — analysis layer.
    loop_info: ?LoopInfo = null,
    liveness: ?Liveness = null,
    constant_pool: ?ConstantPool = null,

    // Phase 7+ — JIT register allocator.
    reg_class_hints: ?[]RegClass = null,
    spill_slots: ?[]SpillSlot = null,
    inst_ptr_cache_layout: ?CacheLayout = null,
    vm_ptr_cache_layout: ?CacheLayout = null,
    simd_base_cache_layout: ?CacheLayout = null,

    // Phase 9+ — SIMD additional state.
    simd_lane_routing: ?LaneRouting = null,

    /// Phase 9+ — SIMD 16-byte literal pool (per ADR-0042). Each
    /// entry is the raw 16-byte immediate of a `v128.const` or
    /// `i8x16.shuffle` op. Indexed by the producing op's
    /// `ZirInstr.payload`. Lower-time owner: `Lowerer.simd_consts`
    /// builder; flushed to `func.simd_consts` at lower close.
    /// Caller-owned: freed by `ZirFunc.deinit`.
    simd_consts: ?[]const [16]u8 = null,

    // Phase 10+ — GC / EH / tail-call additional state.
    gc_root_map: ?GcRootMap = null,
    /// One entry per `try_table` in body order (per ADR-0114 EH design,
    /// interp-side metadata; codegen consumes the same data via
    /// `engine/codegen/shared/exception_table.zig` at JIT time).
    /// Owned slice; freed by `ZirFunc.deinit`.
    eh_landing_pads: ?[]const LandingPad = null,
    /// Flat backing store for all catch clauses across the function.
    /// `LandingPad.catches_start..catches_end` indexes into this.
    eh_catch_entries: ?[]const CatchEntry = null,
    tail_call_sites: ?[]TailCallSite = null,

    // Phase 8+ — optimisation passes.
    hoisted_constants: ?[]HoistedConst = null,
    /// Synthetic locals appended by post-lowering passes (notably
    /// the §9.8 / 8.4 hoist pass per ADR-0031, which reserves new
    /// local indices to host hoisted-constant cache values).
    /// Indexed at `local_idx >= func.locals.len`. Caller-owned;
    /// freed by the pass that allocates it (see
    /// `src/ir/hoist/pass.zig:deinitSynthetic`).
    synthetic_locals: ?[]ValType = null,
    bounds_check_elision_map: ?[]ElisionRecord = null,
    coalesced_movs: ?[]CoalesceRecord = null,

    /// Phase 8+ — per-function per-pass diagnostic record
    /// (per ADR-0033 + §9.8a / 8a.1). Populated only when
    /// `trace.enabled == true`; otherwise stays `null` and
    /// folds out as dead state. Freed via
    /// `deinitPassDiagnostics`.
    pass_diagnostics: ?PassDiagnostics = null,

    pub fn init(func_idx: u32, sig: FuncType, locals: []const ValType) ZirFunc {
        return .{
            .func_idx = func_idx,
            .sig = sig,
            .locals = locals,
            .instrs = .empty,
            .blocks = .empty,
            .branch_targets = .empty,
        };
    }

    pub fn deinit(self: *ZirFunc, alloc: Allocator) void {
        self.instrs.deinit(alloc);
        self.blocks.deinit(alloc);
        self.branch_targets.deinit(alloc);
        if (self.simd_consts) |sc| alloc.free(sc);
        if (self.eh_landing_pads) |lps| alloc.free(lps);
        if (self.eh_catch_entries) |ces| alloc.free(ces);
    }

    /// Total declared-locals count = original `func.locals.len`
    /// plus any `synthetic_locals` appended by post-lowering
    /// passes. Use this anywhere `func.locals.len` was the
    /// authoritative count for stack-frame sizing or local-index
    /// validation.
    pub fn totalLocalCount(self: *const ZirFunc) u32 {
        const base: u32 = @intCast(self.locals.len);
        const extra: u32 = if (self.synthetic_locals) |s| @intCast(s.len) else 0;
        return base + extra;
    }

    /// Look up a local's `ValType` by its absolute Wasm-space
    /// local index (parameter 0..num_params-1, then declared
    /// locals num_params..num_params+totalLocalCount-1).
    /// Caller has already validated the index range.
    pub fn localValType(self: *const ZirFunc, local_idx: u32) ValType {
        const num_params: u32 = @intCast(self.sig.params.len);
        if (local_idx < num_params) return self.sig.params[local_idx];
        const decl_idx: u32 = local_idx - num_params;
        const orig_len: u32 = @intCast(self.locals.len);
        if (decl_idx < orig_len) return self.locals[@intCast(decl_idx)];
        return self.synthetic_locals.?[@intCast(decl_idx - orig_len)];
    }
};

test "ZirFunc.init: required fields populated, slots null" {
    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(7, sig, &.{});
    defer f.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), f.func_idx);
    try std.testing.expectEqual(@as(usize, 0), f.sig.params.len);
    try std.testing.expectEqual(@as(usize, 0), f.sig.results.len);
    try std.testing.expectEqual(@as(usize, 0), f.locals.len);
    try std.testing.expectEqual(@as(usize, 0), f.instrs.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.branch_targets.items.len);

    try std.testing.expect(f.loop_info == null);
    try std.testing.expect(f.liveness == null);
    try std.testing.expect(f.constant_pool == null);
    try std.testing.expect(f.reg_class_hints == null);
    try std.testing.expect(f.spill_slots == null);
    try std.testing.expect(f.inst_ptr_cache_layout == null);
    try std.testing.expect(f.vm_ptr_cache_layout == null);
    try std.testing.expect(f.simd_base_cache_layout == null);
    try std.testing.expect(f.simd_lane_routing == null);
    try std.testing.expect(f.gc_root_map == null);
    try std.testing.expect(f.eh_landing_pads == null);
    try std.testing.expect(f.eh_catch_entries == null);
    try std.testing.expect(f.tail_call_sites == null);
    try std.testing.expect(f.hoisted_constants == null);
    try std.testing.expect(f.bounds_check_elision_map == null);
    try std.testing.expect(f.coalesced_movs == null);
    try std.testing.expect(f.pass_diagnostics == null);
}

test "ZirFunc: instrs grow via per-call allocator" {
    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(std.testing.allocator);

    const op0: ZirOp = @enumFromInt(0);
    try f.instrs.append(std.testing.allocator, .{ .op = op0, .payload = 42, .extra = 0 });
    try f.instrs.append(std.testing.allocator, .{ .op = op0, .payload = 0, .extra = 7 });

    try std.testing.expectEqual(@as(usize, 2), f.instrs.items.len);
    try std.testing.expectEqual(@as(u32, 42), f.instrs.items[0].payload);
    try std.testing.expectEqual(@as(u32, 7), f.instrs.items[1].extra);
}

test "ValType / BlockKind: enum tags are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ValType.i32));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ValType.i64));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(BlockKind.block));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(BlockKind.loop));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(BlockKind.if_then));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(BlockKind.else_open));
    // Wasm 3.0 EH addition: try_table comes after the pre-existing
    // 4 control-frame kinds (per ADR-0114 EH design; foundation
    // wiring at 10.E-3).
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(BlockKind.try_table));
}

test "FuncType holds slices without copying" {
    const params = [_]ValType{ .i32, .i64 };
    const results = [_]ValType{.f64};
    const sig: FuncType = .{ .params = &params, .results = &results };
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqual(ValType.f64, sig.results[0]);
}

test "ZirOp: MVP opcodes are declared" {
    // Spot-check a representative slice of MVP entries.
    const mvp = [_]ZirOp{
        .@"unreachable", .nop,          .block,         .loop,           .@"if",
        .@"else",        .end,          .br,            .br_if,          .br_table,
        .@"return",      .call,         .call_indirect, .drop,           .select,
        .select_typed,   .@"local.get", .@"local.set",  .@"local.tee",   .@"global.get",
        .@"global.set",  .@"i32.const", .@"i32.add",    .@"i32.sub",     .@"i32.mul",
        .@"i64.const",   .@"f32.const", .@"f64.const",  .@"memory.size", .@"memory.grow",
    };
    inline for (mvp) |op| {
        _ = @intFromEnum(op);
    }
}

test "ZirOp: Wasm 2.0 / SIMD / 3.0 entries declared" {
    const v2 = [_]ZirOp{ .@"i32.extend8_s", .@"memory.copy", .@"ref.null", .@"table.get" };
    const simd = [_]ZirOp{ .@"v128.load", .@"v128.const", .@"i8x16.add", .@"f64x2.add" };
    const v3 = [_]ZirOp{
        .try_table,         .throw,        .return_call, .call_ref,
        .@"struct.new",     .@"array.new", .@"ref.test", .@"ref.i31",
        .@"memory.discard",
    };
    const phase34 = [_]ZirOp{ .@"atomic.fence", .@"i32.atomic.load", .@"cont.new", .@"resume" };
    const pseudo = [_]ZirOp{
        .@"__pseudo.const_in_reg",        .@"__pseudo.loop_header",
        .@"__pseudo.bounds_check_elided", .@"__pseudo.spill_to_slot",
        .@"__pseudo.frame_setup",
    };
    inline for (v2 ++ simd ++ v3 ++ phase34 ++ pseudo) |op| {
        _ = @intFromEnum(op);
    }
}

test "ZirOp: tag count meets §4.2 baseline" {
    // §4.2 declares ~280 named tags (Wasm 1.0 + 2.0 + SIMD + 3.0
    // + Phase 3-4 reserved + JIT pseudo-ops). Treat 250 as a
    // conservative floor — the assertion guards against a future
    // accidental deletion of a swath of tags.
    const fields = @typeInfo(ZirOp).@"enum".fields;
    try std.testing.expect(fields.len >= 250);
}

test "PassDiagnostics: empty default + deinit no-op + populated free" {
    // Empty default: deinit is a no-op (zero-length slice ≠ allocation).
    const empty: PassDiagnostics = .{};
    deinitPassDiagnostics(std.testing.allocator, empty);

    // Populated: allocate a slice via the test allocator, attach to
    // a fresh slot, and verify deinit frees cleanly (the leak
    // detector in std.testing.allocator catches any escape).
    const records = try std.testing.allocator.alloc(PassRecord, 3);
    records[0] = .{ .pass = .lower, .applied = 12, .skipped = 0, .extra = 12 };
    records[1] = .{ .pass = .hoist, .applied = 4, .skipped = 8, .extra = 2 };
    records[2] = .{ .pass = .emit, .applied = 12, .skipped = 0, .extra = 96 };
    const pd: PassDiagnostics = .{ .entries = records };
    try std.testing.expectEqual(@as(usize, 3), pd.entries.len);
    try std.testing.expectEqual(trace.PassId.hoist, pd.entries[1].pass);
    try std.testing.expectEqual(@as(u32, 8), pd.entries[1].skipped);
    deinitPassDiagnostics(std.testing.allocator, pd);
}

test "ZirFunc: pass_diagnostics slot attaches + detaches without leak" {
    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(99, sig, &.{});
    defer f.deinit(std.testing.allocator);

    try std.testing.expect(f.pass_diagnostics == null);

    const records = try std.testing.allocator.alloc(PassRecord, 1);
    records[0] = .{ .pass = .liveness, .applied = 5, .skipped = 0, .extra = 7 };
    f.pass_diagnostics = .{ .entries = records };

    try std.testing.expect(f.pass_diagnostics != null);
    try std.testing.expectEqual(@as(usize, 1), f.pass_diagnostics.?.entries.len);

    // Caller-owned slot: deinit before f.deinit (mirrors compile.zig's
    // deinitFuncResult ordering — pass_diagnostics is freed before
    // ZirFunc.deinit, same as Liveness / LoopInfo).
    deinitPassDiagnostics(std.testing.allocator, f.pass_diagnostics.?);
    f.pass_diagnostics = null;
}

// ============================================================
// §9.9 / 9.5-b — isSimdZirOp predicate tests (per ADR-0041
// §"Decision" / 1 — shape-as-variant)
// ============================================================

test "isSimdZirOp: v128.* prefix matches" {
    try std.testing.expect(isSimdZirOp(.@"v128.load"));
    try std.testing.expect(isSimdZirOp(.@"v128.store"));
    try std.testing.expect(isSimdZirOp(.@"v128.const"));
    try std.testing.expect(isSimdZirOp(.@"v128.not"));
}

test "isSimdZirOp: per-shape prefixes match" {
    try std.testing.expect(isSimdZirOp(.@"i8x16.splat"));
    try std.testing.expect(isSimdZirOp(.@"i16x8.splat"));
    try std.testing.expect(isSimdZirOp(.@"i32x4.add"));
    try std.testing.expect(isSimdZirOp(.@"i64x2.splat"));
    try std.testing.expect(isSimdZirOp(.@"f32x4.splat"));
    try std.testing.expect(isSimdZirOp(.@"f64x2.splat"));
}

test "isSimdZirOp: scalar ops do not match" {
    try std.testing.expect(!isSimdZirOp(.@"i32.const"));
    try std.testing.expect(!isSimdZirOp(.@"i64.add"));
    try std.testing.expect(!isSimdZirOp(.@"f32.const"));
    try std.testing.expect(!isSimdZirOp(.@"f64.add"));
    try std.testing.expect(!isSimdZirOp(.end));
    try std.testing.expect(!isSimdZirOp(.@"local.get"));
    try std.testing.expect(!isSimdZirOp(.call));
}
