//! JIT greedy-local register allocator (§9.7 / 7.1).
//!
//! Reads `ZirFunc.liveness.?.ranges` (populated upstream by
//! `src/ir/liveness.zig` per §9.5 / 5.4) and assigns each vreg
//! the smallest physical slot id not held by any earlier vreg
//! whose live range overlaps. Output is a dense
//! `Allocation { slots, n_slots }` consumed by §9.7 / 7.3's
//! emit pass (which maps slot id → physical register via the
//! per-arch ABI table from §9.7 / 7.2).
//!
//! W54-class lesson made structural (per `textbook_survey.md`
//! Guard 4 + ROADMAP §4.2 / P13): liveness drives regalloc, not
//! the other way around. Liveness is a **const input** here;
//! `verify` then asserts the post-condition (no two overlapping
//! live ranges share a slot) before downstream emit ever sees
//! the allocation. v1's W54 root cause was regalloc-stage IR
//! shape implicitly assuming an absent liveness invariant; the
//! split-input + post-condition shape here makes that
//! impossible by construction.
//!
//! Phase 7.1 scope: slot-only assignment + verifier. All vregs
//! treated as a single pool; per-class slot pools land alongside
//! §9.7 / 7.2 ABI work (`reg_class.zig`'s `RegClassInfo` table
//! becomes load-bearing then). Spilling is a §9.7 / 7.3
//! follow-up — the allocator may grow `n_slots` up to
//! `max_slots`; `SlotOverflow` surfaces when the validator's
//! max_operand_stack would otherwise exceed it.
//!
//! Lifetime: caller-allocated; pair `compute` with `deinit`.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const reg_class = @import("reg_class.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const LiveRange = zir.LiveRange;
const RegClass = zir.RegClass;

pub const Error = error{
    LivenessMissing,
    OutOfMemory,
    SlotOverflow,
};

pub const VerifyError = error{
    SlotsLengthMismatch,
    SlotIndexExceedsCount,
    OverlappingVregsShareSlot,
};

/// Cap on distinct slots before `compute` returns `SlotOverflow`.
/// Mirrors the validator's `max_operand_stack` (1024) — bounded
/// in straight-line code. Slot ids are u16 so the hard cap reaches
/// 4095. Originally 1023 (matching the validator's
/// `max_operand_stack`), bumped in chunk d-9 because long Go
/// binaries (goroutine state-machine functions, deeply-inlined
/// allocators) can have more than 1023 simultaneously-live
/// vregs across their long bodies. The bound is now driven by
/// the prologue's `frame_bytes` imm12 budget (4095 bytes for
/// SUB SP imm12; widened multi-instr SUB SP would lift further).
/// `busy: [max_slots+1]bool` stays under 4 KiB on the stack —
/// well within the default 8 MiB thread stack.
pub const max_slots: u16 = 4095;

/// Resolved slot — what physical home a vreg lives in.
/// `reg`'s u8 indexes the per-arch `allocatable_gprs` /
/// `allocatable_v_regs` table (interpreted by per-arch
/// `slotToReg` / `fpSlotToReg`). `spill`'s u32 is a byte
/// offset within the function's spill frame (8-aligned).
pub const Slot = union(enum) {
    reg: u8,
    spill: u32,
};

/// Per-vreg shape tag (§9.9 SIMD-128 per ADR-0041
/// §"Decision" / 2). The slot id alone cannot encode whether
/// a vreg occupies an 8-byte (scalar) or 16-byte (v128)
/// spill stride — per `single_slot_dual_meaning.md` (§14
/// enforcement), shape lives on a separate axis from the
/// slot id. ARM64 NEON `LDR Q<n>` / x86_64 SSE4.1 `MOVDQA`
/// require 16-byte alignment for fast paths; the spill-frame
/// layout queries this tag to size the per-vreg stride.
///
/// 9.4 MVP: `shapeTag(vreg)` returns `.scalar` by default (no
/// per-vreg shape storage yet). 9.5 ARM64 NEON emit will
/// populate `Allocation.shape_tags` from ZirOp metadata when
/// `compute()` runs over a function containing SIMD ops.
pub const ShapeTag = enum(u2) { scalar, v128, _ };

pub const Allocation = struct {
    /// `slots[v]` is the dense physical slot id assigned to
    /// vreg `v`. Length matches `func.liveness.?.ranges.len`.
    /// Slot ids are 0..n_slots-1 (no holes).
    ///
    /// **Class interpretation is up to the caller.** The
    /// allocator is class-blind — a single contiguous slot id
    /// space spans every vreg. Per-class boundaries (this struct's
    /// `max_reg_slots_gpr` / `max_reg_slots_fp`) decide whether a
    /// given id resolves to a register or to a spill slot, and
    /// the per-arch `slotToReg` / `fpSlotToReg` decide which
    /// physical register. A future class-aware allocator (Phase 8
    /// follow-up — D-036 §"option (b)") may reuse slot ids
    /// across disjoint classes; today the worst-case spill frame
    /// covers any slot id ≥ `max_reg_slots_gpr`.
    slots: []const u16,
    /// Distinct slots used. `max(slots) + 1`, or 0 for the
    /// empty-function case. Drives stack-frame sizing in the
    /// per-arch emit pass.
    n_slots: u16,
    /// GPR-class boundary: slot ids `< max_reg_slots_gpr` resolve
    /// to `Slot.reg` for class `.gpr`; ids `>= max_reg_slots_gpr`
    /// resolve to `Slot.spill` (per ADR-0018). Default = 8 (ARM64
    /// `allocatable_gprs.len` post-ADR-0027: caller-scratch
    /// X9..X13 (5) + allocatable callee-saved X20..X22 (3) = 8;
    /// X14/X15 reserved as spill stages, X19 / X23..X28 reserved
    /// as runtime invariants).
    max_reg_slots_gpr: u8 = 8,
    /// FP-class boundary: slot ids `< max_reg_slots_fp` resolve to
    /// `Slot.reg` for class `.fpr`; ids `>= max_reg_slots_fp`
    /// resolve to `Slot.spill`. Default = 13 (ARM64
    /// `allocatable_v_regs.len` post-D-037: V16..V28; V29/V30 are
    /// reserved as FP spill stages, V31 reserved for popcnt's
    /// V-register pipeline). Per ADR-0018 amendment
    /// "class-aware boundaries" (D-036): this field replaces the
    /// chunk-q `resolveFp` shim that read `slots[]` directly to
    /// bypass the GPR threshold. The default tracks the per-arch
    /// `allocatable_v_regs.len` manually — `slotToReg` /
    /// `fpSlotToReg` remain authoritative for null-return spill
    /// detection, so a default-default mismatch surfaces as a test
    /// failure rather than silent miscompile.
    max_reg_slots_fp: u8 = 13,
    /// Per-vreg shape tags (§9.9 / 9.4 per ADR-0041 §"Decision" / 2).
    /// `null` means all vregs are `.scalar` (no SIMD ops in the
    /// function); a populated slice indexes by vreg id. Length when
    /// non-null equals `slots.len`. 9.4 MVP leaves this `null`;
    /// 9.5 ARM64 NEON emit populates it during `compute()` when
    /// the function's ZirInstr stream contains v128 ops.
    shape_tags: ?[]const ShapeTag = null,

    /// Resolve a vreg's home for the given register class: physical
    /// register slot or spill offset. The class selects which
    /// boundary applies — a slot id ≥ `max_reg_slots_gpr` is spill
    /// for `.gpr` but may still be a V-register for `.fpr` (id ≤
    /// `max_reg_slots_fp - 1`).
    ///
    /// Spill offsets always use the GPR boundary as origin so the
    /// shared spill frame is class-agnostic; spillBytes() returns
    /// `(n_slots - max_reg_slots_gpr) * 8` (worst case — all slots
    /// past the GPR boundary count, even if some are FP regs that
    /// don't actually spill). Tighter accounting lands when the
    /// allocator becomes class-aware (D-036 §"option (b)").
    ///
    /// Special-cache classes (inst_ptr_special / vm_ptr_special /
    /// simd_base_special) and `simd` are not yet handled by the
    /// regalloc — caller passes `.gpr` or `.fpr`. The non-
    /// exhaustive `_` arm of `RegClass` triggers the spec-citation
    /// rule's `else` ban only when these classes start being
    /// allocated; today asserting the supported set is
    /// sufficient.
    pub fn slot(self: Allocation, vreg: usize, class: RegClass) Slot {
        const id = self.slots[vreg];
        const threshold: u16 = switch (class) {
            .gpr => self.max_reg_slots_gpr,
            .fpr => self.max_reg_slots_fp,
            .simd, .inst_ptr_special, .vm_ptr_special, .simd_base_special => self.max_reg_slots_gpr,
            _ => self.max_reg_slots_gpr,
        };
        // `id < threshold` ⇒ id < pool size (≤ 16 today), so the
        // u8 narrowing is provably safe.
        if (id < threshold) return .{ .reg = @intCast(id) };
        return .{ .spill = (@as(u32, id) - self.max_reg_slots_gpr) * 8 };
    }

    /// Total spill-frame bytes required by this allocation.
    /// Adds to the function's stack frame in the prologue.
    /// Uses the GPR boundary as the conservative origin — see
    /// `slot()`'s doc for the per-class accounting subtlety.
    pub fn spillBytes(self: Allocation) u32 {
        if (self.n_slots <= self.max_reg_slots_gpr) return 0;
        return (@as(u32, self.n_slots) - self.max_reg_slots_gpr) * 8;
    }

    /// Per-vreg shape tag query (§9.9 / 9.4 per ADR-0041
    /// §"Decision" / 2). Returns `.scalar` when `shape_tags`
    /// is `null` (no SIMD vregs in the function) or when the
    /// per-vreg slot is unmarked; `.v128` when the vreg's
    /// ZirOp metadata indicates v128. Used by 9.5+ ARM64 NEON
    /// emit + 9.7+ x86_64 SSE4.1 emit for spill-frame stride
    /// selection (8-byte vs 16-byte) and for `LDR Q` / `MOVDQA`
    /// instruction selection vs scalar `LDR D` / `MOVSD`.
    pub fn shapeTag(self: Allocation, vreg: usize) ShapeTag {
        const tags = self.shape_tags orelse return .scalar;
        if (vreg >= tags.len) return .scalar;
        return tags[vreg];
    }
};

/// Active-list entry: a currently-live vreg and the slot it
/// holds. The expire pass at each new vreg's def_pc returns
/// the slots of expired entries to the free pool.
const ActiveEntry = struct { slot: u16, last_use_pc: u32 };

/// Linear-scan allocation with LIFO free-pool reuse on dead
/// vregs (§9.8b / 8b.2-c per ADR-0037).
///
/// `func.liveness` MUST be populated (call `liveness.compute`
/// and assign first); otherwise returns `LivenessMissing`.
///
/// **Algorithm**: walk vregs in def_pc order (vreg ids are
/// def-order by `liveness.compute`'s contract). At each
/// vreg, expire actives whose `last_use_pc <= r.def_pc`,
/// returning their slots to the LIFO free pool; then
/// allocate by popping the free pool (if non-empty) or
/// minting a fresh slot id (`n_slots += 1`).
///
/// Edge convention: a vreg dying at pc=N (last_use_pc=N) and
/// a vreg born at pc=N (def_pc=N) do NOT overlap — the use
/// happens before the def at that instr (e.g. `i32.add`
/// pops two and pushes one; result reuses a popped slot).
/// Standard LSRA practice.
///
/// **8b.2-c discovery (per ADR-0037 Revision 2)**: the prior
/// busy-mask scan (`busy[slots[ev]] = true if earlier.last_
/// use_pc > r.def_pc`) was already an inline slot-reuse
/// mechanism — same semantic as this LIFO free-pool. The
/// refactor's value is algorithmic (no per-vreg
/// `@memset(&busy, false)` over 4 KiB; reduced constant
/// factor) + Phase 15 substrate (free-pool pops produce
/// explicit same-slot reuse events the coalescer per
/// ADR-0035 + ADR-0036 can subscribe to). Bench-delta is
/// 0% by construction. Existing tests are regression
/// checks; functional behaviour is preserved (specific slot
/// id assignments may differ — LIFO reuses recently-freed
/// slots vs the prior "smallest free" picker — but
/// `n_slots` and the overlap-free verifier post-condition
/// are unchanged).
pub fn compute(allocator: Allocator, func: *const ZirFunc) Error!Allocation {
    const live = func.liveness orelse return Error.LivenessMissing;
    if (live.ranges.len == 0) return .{ .slots = &.{}, .n_slots = 0 };

    var slots = try allocator.alloc(u16, live.ranges.len);
    errdefer allocator.free(slots);
    // §9.9 / 9.5-b-ii (per ADR-0041 §"Decision" / 2): populate
    // shape_tags before slot allocation so the errdefer-on-failure
    // path can clean both. populateShapeTags returns null when no
    // SIMD ops appear (the all-scalar case).
    const shape_tags = try populateShapeTags(allocator, func, live.ranges.len);
    errdefer if (shape_tags) |t| allocator.free(t);
    var n_slots: u16 = 0;

    var active_buf: [@as(usize, max_slots) + 1]ActiveEntry = undefined;
    var active_len: u16 = 0;
    var free_buf: [@as(usize, max_slots) + 1]u16 = undefined;
    var free_len: u16 = 0;

    for (live.ranges, 0..) |r, vreg| {
        // Expire actives whose last_use_pc <= r.def_pc; return
        // their slots to the free pool. Swap-remove walk so
        // the active list stays compact without preserving
        // insertion order (the verifier's correctness check
        // doesn't depend on it).
        var i: u16 = 0;
        while (i < active_len) {
            if (active_buf[i].last_use_pc <= r.def_pc) {
                free_buf[free_len] = active_buf[i].slot;
                free_len += 1;
                active_len -= 1;
                if (i < active_len) active_buf[i] = active_buf[active_len];
            } else {
                i += 1;
            }
        }
        // Allocate: pop from free pool (LIFO) or mint fresh.
        const assigned: u16 = blk: {
            if (free_len > 0) {
                free_len -= 1;
                break :blk free_buf[free_len];
            }
            if (n_slots >= max_slots) {
                std.debug.print("regalloc: SlotOverflow at func[{d}] vreg={d} ranges.len={d} (>{d} simultaneously live)\n", .{ func.func_idx, vreg, live.ranges.len, max_slots });
                return Error.SlotOverflow;
            }
            const new = n_slots;
            n_slots += 1;
            break :blk new;
        };
        slots[vreg] = assigned;
        active_buf[active_len] = .{ .slot = assigned, .last_use_pc = r.last_use_pc };
        active_len += 1;
    }

    return .{ .slots = slots, .n_slots = n_slots, .shape_tags = shape_tags };
}

/// Post-condition: every pair of overlapping live ranges holds
/// distinct slot assignments AND every slot id is < n_slots AND
/// the slot vector matches the live-range count. Run after every
/// `compute` so a regalloc bug surfaces immediately, not in
/// downstream emit.
///
/// O(n²) pairwise check. Acceptable at Phase 7 sizes (validator
/// caps max_operand_stack at 1024, so at most ~1024 vregs in
/// straight-line code). Interval-tree refinement is a §9.7 / 7.3
/// follow-up if a profile demands it.
pub fn verify(func: *const ZirFunc, alloc: Allocation) VerifyError!void {
    const live = func.liveness orelse return;
    if (alloc.slots.len != live.ranges.len) return VerifyError.SlotsLengthMismatch;
    for (alloc.slots) |s| {
        if (s >= alloc.n_slots) return VerifyError.SlotIndexExceedsCount;
    }
    for (live.ranges, 0..) |a, ai| {
        for (live.ranges[ai + 1 ..], ai + 1..) |b, bi| {
            // Strict half-open overlap: [a.def, a.use) ∩ [b.def, b.use).
            const overlaps = (a.def_pc < b.last_use_pc) and (b.def_pc < a.last_use_pc);
            if (overlaps and alloc.slots[ai] == alloc.slots[bi]) {
                return VerifyError.OverlappingVregsShareSlot;
            }
        }
    }
}

pub fn deinit(allocator: Allocator, alloc: Allocation) void {
    if (alloc.slots.len != 0) allocator.free(alloc.slots);
    if (alloc.shape_tags) |tags| if (tags.len != 0) allocator.free(tags);
}

/// Populate `Allocation.shape_tags` for a function whose
/// `func.instrs` contains SIMD-128 ZirOps (§9.9 / 9.5-b per
/// ADR-0041 §"Decision" / 2). Walks the instr stream once
/// simulating the operand-stack vreg-numbering (def-order
/// matching liveness's contract): each instr that produces a
/// vreg increments a running `next_vreg` counter; SIMD ops
/// (per `zir.isSimdZirOp`) mark their pushed vreg as `.v128`.
///
/// Conservative MVP: pure tag-prefix matching on the producing
/// op. A vreg's shape is determined by the op that defined it;
/// downstream consumers (binops) are assumed to preserve shape
/// (which they do by construction — `i32x4.add` pops 2 v128
/// and pushes 1 v128). Tighter shape-flow tracking (e.g.
/// extract_lane producing scalar from v128) defers to a 9.5-b
/// follow-on once emit-side handlers exercise the catalogue.
///
/// Returns a freshly-allocated slice; caller stores in
/// `alloc.shape_tags` and pairs free with `regalloc.deinit`.
/// Returns `null`-equivalent (zero-length slice via the caller's
/// `?[]const ShapeTag` field) when no SIMD ops appear; the
/// caller leaves `shape_tags = null` in that case.
pub fn populateShapeTags(allocator: Allocator, func: *const ZirFunc, n_vregs: usize) Error!?[]ShapeTag {
    // Quick bail: if no SIMD ops appear, leave shape_tags null
    // (matches the §"Decision" / 2 framing — `null` means all
    // vregs are scalar by default).
    var any_simd: bool = false;
    for (func.instrs.items) |ins| {
        if (zir.isSimdZirOp(ins.op)) {
            any_simd = true;
            break;
        }
    }
    if (!any_simd) return null;

    const tags = try allocator.alloc(ShapeTag, n_vregs);
    errdefer allocator.free(tags);
    @memset(tags, .scalar);

    // Walk instrs simulating liveness's def-order vreg numbering.
    // For the MVP catalogue (matching 9.4 lower):
    // - Pushing ops (const/load/splat/binop): consume `pop_count`
    //   operand-stack values, push 1 producing a fresh vreg.
    // - For each pushing op that is a SIMD op, mark the produced
    //   vreg as `.v128`.
    var next_vreg: usize = 0;
    for (func.instrs.items) |ins| {
        // Per ADR-0041 §"Decision" / 1: extract_lane ops produce
        // scalar (i32 / i64 / f32 / f64) from v128. v128.const +
        // v128.load* / splat / binop / unop / shuffle / swizzle
        // produce v128. The MVP catalogue is small; expand as
        // emit handlers land in 9.5-c+.
        const produces_vreg: bool = switch (ins.op) {
            // SIMD ops that push a v128 result.
            .@"v128.const",
            .@"v128.load",
            .@"v128.load8x8_s",
            .@"v128.load8x8_u",
            .@"v128.load16x4_s",
            .@"v128.load16x4_u",
            .@"v128.load32x2_s",
            .@"v128.load32x2_u",
            .@"v128.load8_splat",
            .@"v128.load16_splat",
            .@"v128.load32_splat",
            .@"v128.load64_splat",
            .@"v128.load32_zero",
            .@"v128.load64_zero",
            .@"v128.not",
            .@"v128.and",
            .@"v128.or",
            .@"v128.xor",
            .@"v128.andnot",
            .@"v128.bitselect",
            .@"i16x8.shl",
            .@"i16x8.shr_s",
            .@"i16x8.shr_u",
            .@"i32x4.shl",
            .@"i32x4.shr_s",
            .@"i32x4.shr_u",
            .@"i64x2.shl",
            .@"i64x2.shr_u",
            .@"i64x2.shr_s",
            .@"i8x16.shl",
            .@"i8x16.shr_u",
            .@"i8x16.shr_s",
            .@"i8x16.abs",
            .@"i16x8.abs",
            .@"i32x4.abs",
            .@"i64x2.abs",
            .@"i8x16.neg",
            .@"i16x8.neg",
            .@"i32x4.neg",
            .@"i64x2.neg",
            .@"i8x16.splat",
            .@"i16x8.splat",
            .@"i32x4.splat",
            .@"i64x2.splat",
            .@"f32x4.splat",
            .@"f64x2.splat",
            .@"i8x16.shuffle",
            .@"i8x16.swizzle",
            .@"i8x16.add",
            .@"i8x16.sub",
            .@"i16x8.add",
            .@"i16x8.sub",
            .@"i16x8.mul",
            .@"i16x8.q15mulr_sat_s",
            .@"i32x4.dot_i16x8_s",
            .@"i16x8.extmul_low_i8x16_s",
            .@"i16x8.extmul_high_i8x16_s",
            .@"i16x8.extmul_low_i8x16_u",
            .@"i16x8.extmul_high_i8x16_u",
            .@"i32x4.add",
            .@"i32x4.sub",
            .@"i32x4.mul",
            .@"i64x2.add",
            .@"i64x2.sub",
            .@"i64x2.mul",
            .@"f32x4.add",
            .@"f32x4.sub",
            .@"f32x4.mul",
            .@"f32x4.div",
            .@"f64x2.add",
            .@"f64x2.sub",
            .@"f64x2.mul",
            .@"f64x2.div",
            .@"f32x4.abs",
            .@"f32x4.neg",
            .@"f32x4.sqrt",
            .@"f32x4.ceil",
            .@"f32x4.floor",
            .@"f32x4.trunc",
            .@"f32x4.nearest",
            .@"f64x2.abs",
            .@"f64x2.neg",
            .@"f64x2.sqrt",
            .@"f64x2.ceil",
            .@"f64x2.floor",
            .@"f64x2.trunc",
            .@"f64x2.nearest",
            .@"f32x4.min",
            .@"f32x4.max",
            .@"f64x2.min",
            .@"f64x2.max",
            .@"f32x4.pmin",
            .@"f32x4.pmax",
            .@"f64x2.pmin",
            .@"f64x2.pmax",
            .@"i8x16.eq",
            .@"i8x16.ne",
            .@"i8x16.lt_s",
            .@"i8x16.lt_u",
            .@"i8x16.gt_s",
            .@"i8x16.gt_u",
            .@"i8x16.le_s",
            .@"i8x16.le_u",
            .@"i8x16.ge_s",
            .@"i8x16.ge_u",
            .@"i16x8.eq",
            .@"i16x8.ne",
            .@"i16x8.lt_s",
            .@"i16x8.lt_u",
            .@"i16x8.gt_s",
            .@"i16x8.gt_u",
            .@"i16x8.le_s",
            .@"i16x8.le_u",
            .@"i16x8.ge_s",
            .@"i16x8.ge_u",
            .@"i32x4.eq",
            .@"i32x4.ne",
            .@"i32x4.lt_s",
            .@"i32x4.lt_u",
            .@"i32x4.gt_s",
            .@"i32x4.gt_u",
            .@"i32x4.le_s",
            .@"i32x4.le_u",
            .@"i32x4.ge_s",
            .@"i32x4.ge_u",
            .@"i64x2.eq",
            .@"i64x2.ne",
            .@"i64x2.lt_s",
            .@"i64x2.gt_s",
            .@"i64x2.le_s",
            .@"i64x2.ge_s",
            .@"f32x4.eq",
            .@"f32x4.ne",
            .@"f32x4.lt",
            .@"f32x4.gt",
            .@"f32x4.le",
            .@"f32x4.ge",
            .@"f64x2.eq",
            .@"f64x2.ne",
            .@"f64x2.lt",
            .@"f64x2.gt",
            .@"f64x2.le",
            .@"f64x2.ge",
            .@"i16x8.extend_low_i8x16_s",
            .@"i16x8.extend_high_i8x16_s",
            .@"i16x8.extend_low_i8x16_u",
            .@"i16x8.extend_high_i8x16_u",
            .@"i32x4.extend_low_i16x8_s",
            .@"i32x4.extend_high_i16x8_s",
            .@"i32x4.extend_low_i16x8_u",
            .@"i32x4.extend_high_i16x8_u",
            .@"i64x2.extend_low_i32x4_s",
            .@"i64x2.extend_high_i32x4_s",
            .@"i64x2.extend_low_i32x4_u",
            .@"i64x2.extend_high_i32x4_u",
            .@"i8x16.narrow_i16x8_s",
            .@"i8x16.narrow_i16x8_u",
            .@"i16x8.narrow_i32x4_s",
            .@"i16x8.narrow_i32x4_u",
            .@"f32x4.convert_i32x4_s",
            .@"f32x4.convert_i32x4_u",
            .@"f64x2.convert_low_i32x4_s",
            .@"f64x2.convert_low_i32x4_u",
            .@"f64x2.promote_low_f32x4",
            .@"f32x4.demote_f64x2_zero",
            .@"i32x4.trunc_sat_f32x4_s",
            .@"i32x4.trunc_sat_f32x4_u",
            .@"i32x4.trunc_sat_f64x2_s_zero",
            .@"i32x4.trunc_sat_f64x2_u_zero",
            .@"i8x16.replace_lane",
            .@"i16x8.replace_lane",
            .@"i32x4.replace_lane",
            .@"i64x2.replace_lane",
            .@"f32x4.replace_lane",
            .@"f64x2.replace_lane",
            => blk: {
                if (next_vreg < tags.len) tags[next_vreg] = .v128;
                break :blk true;
            },
            // Scalar-producing ops (mark as .scalar — already the
            // memset default, but listed to make def-order
            // bookkeeping explicit).
            .@"i32.const",
            .@"i64.const",
            .@"f32.const",
            .@"f64.const",
            .@"i8x16.extract_lane_s",
            .@"i8x16.extract_lane_u",
            .@"i16x8.extract_lane_s",
            .@"i16x8.extract_lane_u",
            .@"i32x4.extract_lane",
            .@"i64x2.extract_lane",
            .@"f32x4.extract_lane",
            .@"f64x2.extract_lane",
            .@"v128.any_true",
            .@"i8x16.all_true",
            .@"i16x8.all_true",
            .@"i32x4.all_true",
            .@"i64x2.all_true",
            .@"i8x16.bitmask",
            .@"i16x8.bitmask",
            .@"i32x4.bitmask",
            .@"i64x2.bitmask",
            => true,
            // All other ops: not handled by this MVP. Conservative
            // default — neither produces nor consumes from our
            // counter. (Liveness's actual numbering for non-SIMD
            // ops happens elsewhere; this helper only needs to
            // track v128 vreg ids accurately for emit's spill-
            // stride decision.) When a non-SIMD op produces a
            // vreg, the wider scalar pool already handles it
            // correctly via the .scalar default.
            else => false,
        };
        if (produces_vreg) next_vreg += 1;
    }

    return tags;
}

// reg_class is the upstream-class-aware refinement hook used by
// §9.7 / 7.2's per-arch wiring; reference it so `no_unused`
// linting is happy until the wiring lands.
comptime {
    _ = reg_class;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn freshFunc() ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    return ZirFunc.init(0, sig, &.{});
}

test "compute: empty liveness yields empty allocation" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(usize, 0), alloc.slots.len);
    try testing.expectEqual(@as(u16, 0), alloc.n_slots);
}

test "compute: missing liveness returns LivenessMissing" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try testing.expectError(Error.LivenessMissing, compute(testing.allocator, &f));
}

test "compute: two non-overlapping ranges share slot 0" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 1), alloc.n_slots);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 0), alloc.slots[1]);
    try verify(&f, alloc);
}

test "compute: two overlapping ranges get distinct slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 5 },
        .{ .def_pc = 1, .last_use_pc = 4 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 2), alloc.n_slots);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 1), alloc.slots[1]);
    try verify(&f, alloc);
}

test "compute: shared-edge (use=def at same pc) does not count as overlap" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 5 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    // Second vreg born at pc=2 reuses first's slot since first
    // dies at pc=2.
    try testing.expectEqual(@as(u16, 1), alloc.n_slots);
    try testing.expectEqual(alloc.slots[0], alloc.slots[1]);
    try verify(&f, alloc);
}

// §9.8b / 8b.2-c (per ADR-0037): three sequential non-overlapping
// vregs collapse to a single slot via free-pool reuse. Regression
// check that slot reuse extends past the 2-vreg case in the
// "two non-overlapping ranges share slot 0" test above.
test "compute: three sequential non-overlapping ranges all share slot 0 (n_slots = 1)" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 3, .last_use_pc = 5 },
        .{ .def_pc = 6, .last_use_pc = 8 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 1), alloc.n_slots);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 0), alloc.slots[1]);
    try testing.expectEqual(@as(u16, 0), alloc.slots[2]);
    try verify(&f, alloc);
}

test "compute: three overlapping ranges fan out to distinct slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 9 },
        .{ .def_pc = 1, .last_use_pc = 9 },
        .{ .def_pc = 2, .last_use_pc = 9 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 3), alloc.n_slots);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 1), alloc.slots[1]);
    try testing.expectEqual(@as(u16, 2), alloc.slots[2]);
    try verify(&f, alloc);
}

test "verify: rejects allocation with slot index >= n_slots" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }};
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u16{5};
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 1 };
    try testing.expectError(VerifyError.SlotIndexExceedsCount, verify(&f, bad));
}

test "verify: rejects mismatched slot/range lengths" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }};
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u16{ 0, 1 };
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 2 };
    try testing.expectError(VerifyError.SlotsLengthMismatch, verify(&f, bad));
}

test "verify: rejects overlapping ranges sharing a slot" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 5 },
        .{ .def_pc = 1, .last_use_pc = 4 },
    };
    f.liveness = .{ .ranges = &ranges };
    const bad_slots = [_]u16{ 0, 0 };
    const bad: Allocation = .{ .slots = &bad_slots, .n_slots = 1 };
    try testing.expectError(VerifyError.OverlappingVregsShareSlot, verify(&f, bad));
}

// ========================================================
// ADR-0018: Slot resolution + spill-frame sizing
// ========================================================

test "Allocation.slot: id < max_reg_slots_gpr resolves to .reg for class .gpr" {
    const slots = [_]u16{ 0, 5, 9 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 10, .max_reg_slots_gpr = 10 };
    try testing.expectEqual(Slot{ .reg = 0 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .reg = 5 }, alloc.slot(1, .gpr));
    try testing.expectEqual(Slot{ .reg = 9 }, alloc.slot(2, .gpr));
}

test "Allocation.slot: id >= max_reg_slots_gpr resolves to .spill at 8-aligned offset" {
    const slots = [_]u16{ 9, 10, 11, 12 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 13, .max_reg_slots_gpr = 10 };
    try testing.expectEqual(Slot{ .reg = 9 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .spill = 0 }, alloc.slot(1, .gpr));
    try testing.expectEqual(Slot{ .spill = 8 }, alloc.slot(2, .gpr));
    try testing.expectEqual(Slot{ .spill = 16 }, alloc.slot(3, .gpr));
}

test "Allocation.spillBytes: 0 when n_slots fits in pool" {
    const slots = [_]u16{ 0, 1 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 2, .max_reg_slots_gpr = 10 };
    try testing.expectEqual(@as(u32, 0), alloc.spillBytes());
}

test "Allocation.spillBytes: 8-byte stride past pool size" {
    const slots = [_]u16{ 9, 10, 11, 12 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 13, .max_reg_slots_gpr = 10 };
    try testing.expectEqual(@as(u32, 24), alloc.spillBytes()); // (13-10)*8
}

// ========================================================
// D-036: Class-aware slot resolution (chunk-d036)
// ========================================================

test "Allocation.slot: same id resolves to .reg for .fpr but .spill for .gpr (class-aware boundaries)" {
    const slots = [_]u16{ 0, 7, 8, 12 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 13 };
    // class .gpr — boundary at 8 (default max_reg_slots_gpr)
    try testing.expectEqual(Slot{ .reg = 0 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .reg = 7 }, alloc.slot(1, .gpr));
    try testing.expectEqual(Slot{ .spill = 0 }, alloc.slot(2, .gpr));
    try testing.expectEqual(Slot{ .spill = 32 }, alloc.slot(3, .gpr)); // (12 - 8) * 8
    // class .fpr — boundary at 13 (default max_reg_slots_fp); same ids stay in regs
    try testing.expectEqual(Slot{ .reg = 0 }, alloc.slot(0, .fpr));
    try testing.expectEqual(Slot{ .reg = 7 }, alloc.slot(1, .fpr));
    try testing.expectEqual(Slot{ .reg = 8 }, alloc.slot(2, .fpr));
    try testing.expectEqual(Slot{ .reg = 12 }, alloc.slot(3, .fpr));
}

test "Allocation.slot: id >= max_reg_slots_fp resolves to .spill for .fpr" {
    const slots = [_]u16{ 12, 13, 14 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 15 };
    try testing.expectEqual(Slot{ .reg = 12 }, alloc.slot(0, .fpr));
    // FP spill: id >= 13 → .spill, offset uses GPR boundary as origin
    // so the shared spill frame is class-agnostic.
    try testing.expectEqual(Slot{ .spill = (13 - 8) * 8 }, alloc.slot(1, .fpr));
    try testing.expectEqual(Slot{ .spill = (14 - 8) * 8 }, alloc.slot(2, .fpr));
}

test "Allocation.slot: spill offset is class-agnostic (shared frame origin = max_reg_slots_gpr)" {
    // A function with mixed GPR/FP vregs sharing a spill frame:
    // GPR vreg at slot 8 → spill 0; FP vreg at slot 14 → spill 48.
    // Even though FP doesn't *actually* spill at slot 8..12
    // (those are V-regs), the offset formula stays consistent so
    // the prologue can size the frame from spillBytes() alone.
    const slots = [_]u16{ 8, 14 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 15 };
    try testing.expectEqual(Slot{ .spill = 0 }, alloc.slot(0, .gpr));
    try testing.expectEqual(Slot{ .spill = (14 - 8) * 8 }, alloc.slot(1, .fpr));
}

// ============================================================
// §9.9 / 9.4 — ShapeTag API tests (per ADR-0041 §"Decision" / 2)
// ============================================================

test "Allocation.shapeTag: returns .scalar when shape_tags is null" {
    const slots = [_]u16{ 0, 1, 2 };
    const alloc: Allocation = .{ .slots = &slots, .n_slots = 3 };
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(0));
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(1));
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(2));
}

test "Allocation.shapeTag: returns per-vreg tag from populated slice" {
    const slots = [_]u16{ 0, 1, 2 };
    const tags = [_]ShapeTag{ .scalar, .v128, .scalar };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 3,
        .shape_tags = &tags,
    };
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(0));
    try testing.expectEqual(ShapeTag.v128, alloc.shapeTag(1));
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(2));
}

test "Allocation.shapeTag: out-of-range vreg returns .scalar" {
    const slots = [_]u16{0};
    const tags = [_]ShapeTag{.v128};
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 1,
        .shape_tags = &tags,
    };
    try testing.expectEqual(ShapeTag.v128, alloc.shapeTag(0));
    // Out-of-range — defensive default, not a hard error.
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(99));
}

// ============================================================
// §9.9 / 9.5-b — populateShapeTags tests (per ADR-0041
// §"Decision" / 2)
// ============================================================

test "populateShapeTags: no SIMD ops returns null" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 1);
    try testing.expect(tags == null);
}

test "populateShapeTags: i32x4.splat produces a v128 vreg" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    // i32.const 7 (vreg 0, scalar) ; i32x4.splat (vreg 1, v128) ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.splat" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 2);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    try testing.expectEqual(@as(usize, 2), tags.?.len);
    try testing.expectEqual(ShapeTag.scalar, tags.?[0]);
    try testing.expectEqual(ShapeTag.v128, tags.?[1]);
}

test "populateShapeTags: v128.const + i32x4.add produces 2 v128 vregs" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    // v128.const (vreg 0) ; v128.const (vreg 1) ; i32x4.add (vreg 2) ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"v128.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"v128.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.add" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 3);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    try testing.expectEqual(@as(usize, 3), tags.?.len);
    try testing.expectEqual(ShapeTag.v128, tags.?[0]);
    try testing.expectEqual(ShapeTag.v128, tags.?[1]);
    try testing.expectEqual(ShapeTag.v128, tags.?[2]);
}

test "populateShapeTags: extract_lane produces scalar from v128" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    // v128.const (vreg 0, v128) ; i32x4.extract_lane (vreg 1, scalar) ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"v128.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.extract_lane" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 2);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    try testing.expectEqual(@as(usize, 2), tags.?.len);
    try testing.expectEqual(ShapeTag.v128, tags.?[0]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[1]);
}

test "populateShapeTags: empty func returns null (no SIMD)" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 0);
    try testing.expect(tags == null);
}

// ============================================================
// §9.9 / 9.5-b-ii — compute() shape_tags integration tests
// ============================================================

test "compute: empty liveness returns null shape_tags" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expect(alloc.shape_tags == null);
}

test "compute: scalar-only function has null shape_tags" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expect(alloc.shape_tags == null);
}

test "compute: SIMD function gets populated shape_tags" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    // Body: i32.const 7 ; i32x4.splat ; end
    // vreg 0 = scalar (i32.const), vreg 1 = v128 (splat).
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.splat" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try compute(testing.allocator, &f);
    defer deinit(testing.allocator, alloc);
    try testing.expect(alloc.shape_tags != null);
    try testing.expectEqual(ShapeTag.scalar, alloc.shapeTag(0));
    try testing.expectEqual(ShapeTag.v128, alloc.shapeTag(1));
}
