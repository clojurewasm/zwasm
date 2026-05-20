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
const liveness = @import("../../../ir/analysis/liveness.zig");
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

/// Per-op scratch reservation lookup (ADR-0077).
///
/// Returns the regalloc slot ids that the op's emit handler
/// will clobber internally as op-internal scratch. Empty slice
/// = no reservation (the common case). The shared regalloc
/// stays arch-agnostic — per-arch tables live in `arm64/abi.zig`
/// / `x86_64/abi.zig` and the emit pipeline supplies the lookup
/// fn at `computeWith` call time. `null` disables the fence
/// (preserves pre-ADR-0077 semantics for callers not yet wired).
///
/// Returned slot ids MUST be `< force_spill_threshold` (= the
/// per-arch `allocatable_gprs.len`); ids ≥ threshold name spill
/// region, which is unreachable via op-internal clobber. The
/// per-arch comptime `validate_op_scratch_reservation_table`
/// (B124) enforces this at build time; runtime
/// `slotForbidden` defensively ignores out-of-range ids.
pub const ScratchReservationFn = *const fn (op: zir.ZirOp) []const u16;

/// Build a u16 bitmask of forbidden slot ids for a vreg by
/// union-ing the reservation tables of every op strictly inside
/// the vreg's live range (`def_pc < pc < last_use_pc`).
///
/// Strict-strict PC shape mirrors ADR-0060's `spans_call`: a
/// vreg consumed AT the op's PC is read by the op's emit
/// prologue before any internal clobber; a vreg defined AT the
/// op's PC materialises in a result register post-clobber.
/// Neither case needs the fence. Spike-validated at B121
/// (private/spikes/regalloc-live-fence/fence.zig).
fn forbiddenMaskForVreg(
    instrs: []const zir.ZirInstr,
    r: LiveRange,
    fence: ScratchReservationFn,
) u16 {
    var mask: u16 = 0;
    var pc: u32 = r.def_pc + 1;
    while (pc < r.last_use_pc) : (pc += 1) {
        if (pc >= instrs.len) break;
        for (fence(instrs[pc].op)) |sid| {
            if (sid < 16) mask |= @as(u16, 1) << @intCast(sid);
        }
    }
    return mask;
}

inline fn slotForbidden(mask: u16, slot_id: u16, force_spill_threshold: u16) bool {
    if (slot_id >= force_spill_threshold) return false;
    if (slot_id >= 16) return false;
    return (mask & (@as(u16, 1) << @intCast(slot_id))) != 0;
}

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
    /// Per-slot byte offset table for spill slots (§9.9 / 9.9-h-9
    /// per ADR-0053 Part 1). When non-null, indexed by `slot_id -
    /// max_reg_slots_gpr` (so `spill_offsets[0]` is the byte offset
    /// of the first spill slot). Populated post-`compute()` when
    /// `shape_tags` is non-null AND at least one slot is occupied
    /// by a v128 vreg — gives v128 spill slots 16-byte alignment +
    /// 16-byte stride, scalar spill slots stay 8-byte. `null` means
    /// "use the legacy uniform `(id - max_reg_slots_gpr) * 8` formula"
    /// — the all-scalar or no-spill case where v128 alignment is
    /// vacuously satisfied.
    spill_offsets: ?[]const u32 = null,

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
        // ADR-0053 Part 1: when `spill_offsets` is populated, consult
        // the per-slot byte offset table (shape-aware: v128 slots
        // get 16-byte alignment + stride; scalar slots stay 8-byte).
        // Falls back to the legacy uniform 8-byte formula when null
        // — the all-scalar / no-v128-spill case.
        if (self.spill_offsets) |offsets| {
            const spill_idx = id - self.max_reg_slots_gpr;
            return .{ .spill = offsets[spill_idx] };
        }
        return .{ .spill = (@as(u32, id) - self.max_reg_slots_gpr) * 8 };
    }

    /// Total spill-frame bytes required by this allocation.
    /// Adds to the function's stack frame in the prologue.
    /// Uses the GPR boundary as the conservative origin — see
    /// `slot()`'s doc for the per-class accounting subtlety.
    pub fn spillBytes(self: Allocation) u32 {
        if (self.n_slots <= self.max_reg_slots_gpr) return 0;
        // ADR-0053 Part 1: shape-aware total when `spill_offsets`
        // is populated — the last slot's offset plus its own size.
        // Size is 16 for v128 slots, 8 otherwise; recover from the
        // gap between consecutive offsets (or from spill_total when
        // we add it). Cheaper recovery: the last offset + the
        // tail-slot size as recorded at compute time. Embedded
        // here as `offsets[last] + tail_size`; tail_size derives
        // from offsets[last+1] - offsets[last] for non-last slots,
        // but for the final slot we re-read shape via slot id. The
        // shorter approach: keep an implicit assumption that the
        // total is captured by the prologue as
        // `spillBytesFromOffsets(offsets, n_slots, max_reg_slots_gpr,
        // shape_tags)`. To keep the API surface tight today, the
        // 16-byte-rounded total is `align_up(last_offset + 16, 16)`
        // — slightly conservative when the last slot is scalar, but
        // safe (over-allocates by ≤ 8 bytes once per function).
        if (self.spill_offsets) |offsets| {
            if (offsets.len == 0) return 0;
            const last = offsets[offsets.len - 1];
            return std.mem.alignForward(u32, last + 16, 16);
        }
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
    return computeWith(allocator, func, max_reg_slots_gpr_default, null);
}

/// D-095 / d-16 (ADR-0060): force-spill call-crossing vregs.
///
/// `force_spill_threshold` is the per-arch `allocatable_gprs.len`
/// (arm64 = 8, x86_64 = 4). Vregs whose live range strictly
/// contains a call PC are assigned slot ids ≥ this threshold so
/// the per-arch `slotToReg` resolves them to `.spill`. The
/// existing spill-class emit path (STR-before-call / LDR-after-
/// call) then carries the value through the call without
/// involving any caller-clobbered register. Callers that don't
/// care about call-crossing semantics (in-source tests) call the
/// thin `compute()` wrapper which passes the arm64 default.
pub fn computeWith(
    allocator: Allocator,
    func: *const ZirFunc,
    force_spill_threshold: u16,
    scratch_reservations: ?ScratchReservationFn,
) Error!Allocation {
    const live = func.liveness orelse return Error.LivenessMissing;
    if (live.ranges.len == 0) return .{ .slots = &.{}, .n_slots = 0 };

    // ADR-0060: collect callout PCs once. Strict-strict
    // `def_pc < cp < last_use_pc` is intentional — when a call IS
    // the vreg's last use, the value is read into the arg register
    // before the BLR/CALL clobbers; when the call IS the vreg's
    // def, the value materialises post-call from the return reg.
    // Buffer is fixed-size (256 calls) for stack discipline; on
    // overflow we conservatively mark every vreg as spans_call
    // (force-spill all). Real Wasm functions rarely exceed this.
    var call_pc_buf: [256]u32 = undefined;
    var call_pc_len: u32 = 0;
    var call_pc_overflow = false;
    for (func.instrs.items, 0..) |ins, pc| {
        const is_call = switch (ins.op) {
            .call, .call_indirect, .@"memory.grow" => true,
            else => false,
        };
        if (!is_call) continue;
        if (call_pc_len < call_pc_buf.len) {
            call_pc_buf[call_pc_len] = @intCast(pc);
            call_pc_len += 1;
        } else {
            call_pc_overflow = true;
        }
    }
    const call_pcs = call_pc_buf[0..call_pc_len];

    var slots = try allocator.alloc(u16, live.ranges.len);
    errdefer allocator.free(slots);
    // §9.9 / 9.5-b-ii (per ADR-0041 §"Decision" / 2): populate
    // shape_tags before slot allocation so the errdefer-on-failure
    // path can clean both. populateShapeTags returns null when no
    // SIMD ops appear (the all-scalar case).
    const shape_tags = try populateShapeTags(allocator, func, live.ranges.len);
    errdefer if (shape_tags) |t| allocator.free(t);

    // ADR-0060: non-spans_call vregs keep the pre-d-16 LIFO mint /
    // free-pool semantics unchanged. spans_call vregs mint at a
    // dedicated `n_spill_minted` counter starting at the per-arch
    // `force_spill_threshold` so their slot id resolves to `.spill`
    // via `Allocation.slot()` on the host arch. Mixing the two
    // counters' id ranges is correct because the non-spans_call
    // path never reads/writes the spill-only id range and vice
    // versa, modulo free-pool sharing which is bounded by the
    // verifier's overlap-free invariant.
    var n_slots: u16 = 0;
    var n_spill_minted: u16 = 0;

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

        const spans_call = blk: {
            if (call_pc_overflow) break :blk true;
            for (call_pcs) |cp| {
                if (r.def_pc < cp and cp < r.last_use_pc) break :blk true;
            }
            break :blk false;
        };

        // ADR-0077: per-vreg op-scratch fence mask. When the
        // function has no fence supplier, `forbidden` stays 0
        // and `slotForbidden` is a no-op — preserves pre-fence
        // behaviour bit-for-bit.
        const forbidden: u16 = if (scratch_reservations) |fence|
            forbiddenMaskForVreg(func.instrs.items, r, fence)
        else
            0;

        const assigned: u16 = blk: {
            if (spans_call) {
                // Scan free pool for an already-minted spill slot.
                // Keeps the spill region tight when many call-
                // crossing vregs share lifetimes. Spill ids are
                // ≥ force_spill_threshold so the fence cannot
                // apply (slotForbidden short-circuits there).
                var fi: u16 = 0;
                while (fi < free_len) : (fi += 1) {
                    if (free_buf[fi] >= force_spill_threshold) {
                        const s = free_buf[fi];
                        free_buf[fi] = free_buf[free_len - 1];
                        free_len -= 1;
                        break :blk s;
                    }
                }
                // Mint a fresh spill slot.
                const s_u32: u32 = @as(u32, force_spill_threshold) + n_spill_minted;
                if (s_u32 >= max_slots) {
                    std.debug.print("regalloc: SlotOverflow (spill mint) at func[{d}] vreg={d} ranges.len={d}\n", .{ func.func_idx, vreg, live.ranges.len });
                    return Error.SlotOverflow;
                }
                n_spill_minted += 1;
                break :blk @as(u16, @intCast(s_u32));
            }
            // LIFO pop, filtered by the ADR-0077 fence mask:
            // walk free pool from the top down, take the first
            // non-forbidden entry. Stable swap-and-pop maintains
            // the compact array. When `forbidden == 0` (the
            // overwhelming common case), the top entry passes
            // immediately — same cost as pre-fence behaviour.
            if (free_len > 0) {
                var fi: i32 = @as(i32, free_len) - 1;
                while (fi >= 0) : (fi -= 1) {
                    const idx: u16 = @intCast(fi);
                    if (!slotForbidden(forbidden, free_buf[idx], force_spill_threshold)) {
                        const s = free_buf[idx];
                        free_buf[idx] = free_buf[free_len - 1];
                        free_len -= 1;
                        break :blk s;
                    }
                }
            }
            // Mint: advance past forbidden ids.
            while (slotForbidden(forbidden, n_slots, force_spill_threshold)) {
                if (n_slots >= max_slots) {
                    std.debug.print("regalloc: SlotOverflow (mint past fence) at func[{d}] vreg={d} ranges.len={d}\n", .{ func.func_idx, vreg, live.ranges.len });
                    return Error.SlotOverflow;
                }
                n_slots += 1;
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
        if (assigned + 1 > n_slots) n_slots = assigned + 1;
        active_buf[active_len] = .{ .slot = assigned, .last_use_pc = r.last_use_pc };
        active_len += 1;
    }

    // ADR-0053 Part 1 (§9.9 / 9.9-h-9): when shape_tags exists,
    // compute per-slot byte offsets so v128 spill slots get 16-byte
    // alignment + stride. Skips the alloc on the all-scalar /
    // no-spill case so `Allocation.slot()`'s legacy formula still
    // fires uniformly there.
    const spill_offsets = if (shape_tags) |tags|
        try computeSpillOffsets(allocator, slots, n_slots, max_reg_slots_gpr_default, tags)
    else
        null;
    errdefer if (spill_offsets) |so| allocator.free(so);

    return .{ .slots = slots, .n_slots = n_slots, .shape_tags = shape_tags, .spill_offsets = spill_offsets };
}

/// ADR-0053 Part 1 — compute per-slot spill byte offsets.
///
/// Walks `slots[]` to determine each slot id's shape (a slot's
/// shape is v128 iff ANY vreg assigned to that slot is v128; lifetime
/// non-overlap is guaranteed by the regalloc's verifier so the
/// max-over-vregs is well-defined). Then walks slot ids in order:
/// each v128 slot pads up to the next 16-byte boundary and consumes
/// 16 bytes; each scalar spill slot consumes 8 bytes. The resulting
/// `offsets[slot_id - max_reg_slots_gpr]` is the byte offset of that
/// slot from the spill-region base.
///
/// Returns `null` when no slot is occupied by a v128 vreg (the
/// legacy uniform 8-byte formula remains correct in that case, so
/// we avoid the allocation). Caller pairs `free` with
/// `regalloc.deinit`.
fn computeSpillOffsets(
    allocator: Allocator,
    slots: []const u16,
    n_slots: u16,
    max_reg_slots_gpr: u16,
    shape_tags: []const ShapeTag,
) Error!?[]u32 {
    if (n_slots <= max_reg_slots_gpr) return null;
    const n_spill: usize = @intCast(n_slots - max_reg_slots_gpr);

    // Per-slot shape: 0 = unset, 1 = scalar, 2 = v128. The shapes
    // array packs the max-shape seen per spill slot id. Stack-
    // allocated for typical sizes (≤ max_slots ≈ 32k).
    var any_v128: bool = false;
    const shapes = try allocator.alloc(u2, n_spill);
    defer allocator.free(shapes);
    @memset(shapes, 0);
    for (slots, 0..) |s, vreg| {
        if (s < max_reg_slots_gpr) continue;
        const idx: usize = @intCast(s - max_reg_slots_gpr);
        const t = if (vreg < shape_tags.len) shape_tags[vreg] else .scalar;
        const this_shape: u2 = switch (t) {
            .v128 => 2,
            .scalar, _ => 1,
        };
        if (this_shape > shapes[idx]) shapes[idx] = this_shape;
        if (this_shape == 2) any_v128 = true;
    }
    if (!any_v128) return null;

    const offsets = try allocator.alloc(u32, n_spill);
    errdefer allocator.free(offsets);
    var byte_off: u32 = 0;
    var i: usize = 0;
    while (i < n_spill) : (i += 1) {
        if (shapes[i] == 2) {
            byte_off = std.mem.alignForward(u32, byte_off, 16);
            offsets[i] = byte_off;
            byte_off += 16;
        } else {
            // Scalar (or unused: still place an 8-byte slot to
            // preserve dense indexing; unused slots cost 8 bytes
            // each, an acceptable rounding for functions with
            // dead-but-allocated slot ids).
            offsets[i] = byte_off;
            byte_off += 8;
        }
    }
    return offsets;
}

const max_reg_slots_gpr_default: u16 = 8;

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
    if (alloc.spill_offsets) |so| if (so.len != 0) allocator.free(so);
}

/// Populate `Allocation.shape_tags` for a function whose
/// `func.instrs` contains SIMD-128 ZirOps OR whose signature /
/// locals declare v128 (§9.9 / 9.5-b per ADR-0041 §"Decision" /
/// 2). Walks the instr stream once mirroring liveness's
/// def-order vreg numbering (each push increments `next_vreg`);
/// the produced vreg's tag is determined by the op:
///
/// - `local.get` / `local.tee`: tag = `func.localValType(payload)`
///   (v128 if the local was declared with valtype 0x7B).
/// - SIMD-producing ops (per the explicit list below): `.v128`.
/// - All other producers: `.scalar` (the @memset default), with
///   the push count taken from `liveness.stackEffect` for
///   accurate vreg-id counting.
///
/// The any_simd trigger expands to v128 in
/// `func.sig.params`/`results` and `func.locals` so a function
/// whose body is `local.get v128; local.get v128; local.get i32;
/// select` (the `simd_select.0` fixture's shape — D-061
/// discharge) still produces shape_tags, allowing the v128-aware
/// emit dispatch to fire on the local.get-pushed vregs.
///
/// Returns a freshly-allocated slice; caller stores in
/// `alloc.shape_tags` and pairs free with `regalloc.deinit`.
/// Returns `null` when no v128 indicators are present — the
/// caller treats that as all-scalar.
pub fn populateShapeTags(allocator: Allocator, func: *const ZirFunc, n_vregs: usize) Error!?[]ShapeTag {
    // Quick bail: trigger when any v128 indicator is present —
    // a SIMD ZirOp in the body OR a v128-typed param / local /
    // result. The `local.get v128 / select` shape (no inline
    // SIMD op) needs the latter trigger or it would silently
    // fall back to all-scalar shape_tags.
    var any_simd: bool = false;
    for (func.instrs.items) |ins| {
        if (zir.isSimdZirOp(ins.op)) {
            any_simd = true;
            break;
        }
    }
    if (!any_simd) {
        for (func.sig.params) |p| if (p == .v128) {
            any_simd = true;
            break;
        };
    }
    if (!any_simd) {
        for (func.sig.results) |r| if (r == .v128) {
            any_simd = true;
            break;
        };
    }
    if (!any_simd) {
        for (func.locals) |l| if (l == .v128) {
            any_simd = true;
            break;
        };
    }
    if (!any_simd) return null;

    const tags = try allocator.alloc(ShapeTag, n_vregs);
    errdefer allocator.free(tags);
    @memset(tags, .scalar);

    // Walk instrs mirroring liveness.compute's def-order vreg
    // numbering (each push increments next_vreg, and the produced
    // vreg gets a per-op shape tag).
    var next_vreg: usize = 0;
    for (func.instrs.items) |ins| {
        // local.get pushes one vreg whose type comes from the
        // indexed local. v128 locals (params / declared locals)
        // flow through here; D-061 discharge.
        if (ins.op == .@"local.get") {
            if (next_vreg < tags.len) {
                if (func.localValType(ins.payload) == .v128) tags[next_vreg] = .v128;
            }
            next_vreg += 1;
            continue;
        }
        // local.tee — operand-stack-transparent (see
        // liveness.zig `local.tee` arm in compute()). No new
        // vreg; the existing top vreg keeps its shape tag.
        if (ins.op == .@"local.tee") continue;
        // Per ADR-0041 §"Decision" / 1: extract_lane ops produce
        // scalar (i32 / i64 / f32 / f64) from v128. v128.const +
        // v128.load* / splat / binop / unop / shuffle / swizzle
        // produce v128.
        const is_simd_producer: bool = switch (ins.op) {
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
            // §9.7 / 9.7-ba — load_lane: pop idx + v128, push merged v128.
            .@"v128.load8_lane",
            .@"v128.load16_lane",
            .@"v128.load32_lane",
            .@"v128.load64_lane",
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
            .@"i32x4.extmul_low_i16x8_s",
            .@"i32x4.extmul_high_i16x8_s",
            .@"i32x4.extmul_low_i16x8_u",
            .@"i32x4.extmul_high_i16x8_u",
            .@"i64x2.extmul_low_i32x4_s",
            .@"i64x2.extmul_high_i32x4_s",
            .@"i64x2.extmul_low_i32x4_u",
            .@"i64x2.extmul_high_i32x4_u",
            .@"i16x8.extadd_pairwise_i8x16_s",
            .@"i16x8.extadd_pairwise_i8x16_u",
            .@"i32x4.extadd_pairwise_i16x8_s",
            .@"i32x4.extadd_pairwise_i16x8_u",
            .@"i8x16.popcnt",
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
            // §9.7 / 9.7-au — int min/max + sat arith + avgr_u (22 ops, all 2-in 1-out v128).
            .@"i8x16.min_s",
            .@"i8x16.min_u",
            .@"i8x16.max_s",
            .@"i8x16.max_u",
            .@"i16x8.min_s",
            .@"i16x8.min_u",
            .@"i16x8.max_s",
            .@"i16x8.max_u",
            .@"i32x4.min_s",
            .@"i32x4.min_u",
            .@"i32x4.max_s",
            .@"i32x4.max_u",
            .@"i8x16.add_sat_s",
            .@"i8x16.add_sat_u",
            .@"i8x16.sub_sat_s",
            .@"i8x16.sub_sat_u",
            .@"i16x8.add_sat_s",
            .@"i16x8.add_sat_u",
            .@"i16x8.sub_sat_s",
            .@"i16x8.sub_sat_u",
            .@"i8x16.avgr_u",
            .@"i16x8.avgr_u",
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
            => true,
            else => false,
        };
        if (is_simd_producer) {
            if (next_vreg < tags.len) tags[next_vreg] = .v128;
            next_vreg += 1;
            continue;
        }
        // All other producers: tag stays `.scalar` (memset
        // default); push count comes from `liveness.stackEffect`.
        // stackEffect returns null for control-flow ops
        // (block / loop / if / else / end / br / br_if /
        // br_table / return / unreachable) and for call /
        // call_indirect — both of which need different handling
        // in liveness.compute. Control-flow ops do not push;
        // call / call_indirect's variadic-results push count
        // would require func_sigs / module_types threading and
        // is deferred (call-with-v128-result fixtures aren't in
        // §9.9 scope).
        if (liveness.stackEffect(ins.op)) |eff| {
            next_vreg += eff.pushes;
        }
    }

    return tags;
}

// reg_class is the upstream-class-aware refinement hook used by
// §9.7 / 7.2's per-arch wiring; reference it so `no_unused`
// linting is happy until the wiring lands.
comptime {
    _ = reg_class;
}

/// D-097 / d-17: classify a vreg's storage class (GPR / FPR / v128)
/// by walking `func.instrs.items`, counting pushed vregs in
/// liveness order, and inspecting the op (or local valtype for
/// `local.get`) that defined the target vreg.
///
/// Used by the if-frame merge MOV path in `op_control.zig` to
/// dispatch FP-class merges through FMOV / MOVAPS instead of the
/// GPR MOV that silently corrupts f32/f64 values. The merge
/// MOV's pre-d-17 shape only dispatched on `.v128` shape_tag;
/// FP scalar (f32/f64) fell through to the GPR path and never
/// transferred the value through the FP register file.
///
/// Returns `.gpr` as the conservative default for vregs whose
/// origin couldn't be determined (e.g. malformed instr stream);
/// the merge MOV is then no worse than pre-d-17 for that vreg.
pub const VregClass = enum { gpr, fpr, v128 };

pub fn vregClassByDef(func: *const ZirFunc, target_vreg: usize) VregClass {
    var next_vreg: usize = 0;
    for (func.instrs.items) |ins| {
        const class_or_null: ?VregClass = vregClassOfOp(ins, func);
        const c = class_or_null orelse continue;
        if (next_vreg == target_vreg) return c;
        next_vreg += 1;
    }
    return .gpr;
}

/// Returns the storage class of the vreg the op pushes, or `null`
/// when the op doesn't push a result. v128 ops + FP-scalar ops are
/// enumerated; everything else defaults to `.gpr` (the existing
/// pre-d-17 merge-MOV path). The full SIMD producer list lives in
/// `populateShapeTags`; this function keeps the v128 branch
/// minimal (`zir.isSimdZirOp`) because the merge MOV's v128 path
/// is already covered via `shape_tags`.
fn vregClassOfOp(ins: zir.ZirInstr, func: *const ZirFunc) ?VregClass {
    return switch (ins.op) {
        // FP-producing scalar ops.
        .@"f32.const",
        .@"f32.abs",
        .@"f32.neg",
        .@"f32.ceil",
        .@"f32.floor",
        .@"f32.trunc",
        .@"f32.nearest",
        .@"f32.sqrt",
        .@"f32.add",
        .@"f32.sub",
        .@"f32.mul",
        .@"f32.div",
        .@"f32.min",
        .@"f32.max",
        .@"f32.copysign",
        .@"f64.const",
        .@"f64.abs",
        .@"f64.neg",
        .@"f64.ceil",
        .@"f64.floor",
        .@"f64.trunc",
        .@"f64.nearest",
        .@"f64.sqrt",
        .@"f64.add",
        .@"f64.sub",
        .@"f64.mul",
        .@"f64.div",
        .@"f64.min",
        .@"f64.max",
        .@"f64.copysign",
        .@"f32.convert_i32_s",
        .@"f32.convert_i32_u",
        .@"f32.convert_i64_s",
        .@"f32.convert_i64_u",
        .@"f32.demote_f64",
        .@"f64.convert_i32_s",
        .@"f64.convert_i32_u",
        .@"f64.convert_i64_s",
        .@"f64.convert_i64_u",
        .@"f64.promote_f32",
        .@"f32.reinterpret_i32",
        .@"f64.reinterpret_i64",
        .@"f32.load",
        .@"f64.load",
        => .fpr,
        // local.get: from local valtype.
        .@"local.get" => switch (func.localValType(ins.payload)) {
            .f32, .f64 => VregClass.fpr,
            .v128 => VregClass.v128,
            .i32, .i64, .funcref, .externref => VregClass.gpr,
        },
        // Ops that don't push (advance the vreg counter).
        .@"local.tee",
        .end,
        .@"else",
        .block,
        .loop,
        .@"if",
        .br,
        .br_if,
        .br_table,
        .@"return",
        .@"unreachable",
        .nop,
        .drop,
        .@"local.set",
        .@"global.set",
        .@"memory.fill",
        .@"memory.copy",
        .@"memory.init",
        .@"data.drop",
        .@"table.copy",
        .@"table.init",
        .@"elem.drop",
        .@"table.set",
        .@"v128.store",
        .@"v128.store8_lane",
        .@"v128.store16_lane",
        .@"v128.store32_lane",
        .@"v128.store64_lane",
        .@"i32.store",
        .@"i64.store",
        .@"f32.store",
        .@"f64.store",
        .@"i32.store8",
        .@"i32.store16",
        .@"i64.store8",
        .@"i64.store16",
        .@"i64.store32",
        => null,
        // Default: GPR (covers i32 / i64 const + binops + compares,
        // i32.* / i64.* ops, ref ops, table.get GPR-result).
        else => .gpr,
    };
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

test "populateShapeTags: D-061 — v128 params trigger populate via local.get tagging" {
    // simd_select.0 fixture shape: (v128, v128, i32) → v128 with
    // body `local.get 0; local.get 1; local.get 2; select; end`.
    // Without D-061 fix populateShapeTags would return null
    // (no SIMD op in body) and arm64/emit's select handler would
    // dispatch through the .scalar branch — UnsupportedOp.
    const params = [_]zir.ValType{ .v128, .v128, .i32 };
    const results = [_]zir.ValType{.v128};
    const sig: zir.FuncType = .{ .params = &params, .results = &results };
    var f = zir.ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .select });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 4);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    try testing.expectEqual(@as(usize, 4), tags.?.len);
    try testing.expectEqual(ShapeTag.v128, tags.?[0]); // local.get 0 → v128 param
    try testing.expectEqual(ShapeTag.v128, tags.?[1]); // local.get 1 → v128 param
    try testing.expectEqual(ShapeTag.scalar, tags.?[2]); // local.get 2 → i32 param
    // tags[3] is `select`'s result; left .scalar today
    // (per-vreg type-flow tracking via operand-stack simulation
    // is a separate enhancement — see populateShapeTags doc).
}

test "populateShapeTags: scalar binop between SIMD ops keeps vreg numbering aligned" {
    // i32x4.splat (v128 vreg 0)
    // i32.const   (scalar vreg 1)
    // i32.add     (scalar vreg 2 — pre-D-061 walk would NOT
    //              increment, drifting tags[3] for the next push)
    // i32x4.splat (v128 vreg 3)
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.splat" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .drop });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32x4.splat" });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    const tags = try populateShapeTags(testing.allocator, &f, 7);
    try testing.expect(tags != null);
    defer testing.allocator.free(tags.?);
    // vreg layout (def-order): 0=i32.const, 1=i32x4.splat,
    // 2=i32.const, 3=i32.const, 4=i32.add, 5=i32.const, 6=i32x4.splat.
    // Seven pushes; tags[1] = v128, tags[6] = v128.
    try testing.expectEqual(ShapeTag.scalar, tags.?[0]);
    try testing.expectEqual(ShapeTag.v128, tags.?[1]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[2]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[3]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[4]);
    try testing.expectEqual(ShapeTag.scalar, tags.?[5]);
    try testing.expectEqual(ShapeTag.v128, tags.?[6]);
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

test "spill_offsets: scalar-only allocation keeps legacy 8-byte stride" {
    // Manually-constructed Allocation: scalar shape_tags, slot ids
    // crossing the GPR threshold. spill_offsets stays null so
    // slot() falls back to `(id - max_reg_slots_gpr) * 8`.
    const slots = [_]u16{ 0, 1, 8, 9 }; // last two are spill on the 8-reg GPR boundary
    const tags = [_]ShapeTag{ .scalar, .scalar, .scalar, .scalar };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 10,
        .max_reg_slots_gpr = 8,
        .shape_tags = &tags,
        .spill_offsets = null,
    };
    // vreg 0 + 1 in registers.
    try testing.expectEqual(@as(u32, 0), alloc.slot(0, .gpr).reg);
    try testing.expectEqual(@as(u32, 1), alloc.slot(1, .gpr).reg);
    // vreg 2 spill at slot id 8 → offset (8-8)*8 = 0.
    try testing.expectEqual(@as(u32, 0), alloc.slot(2, .gpr).spill);
    // vreg 3 spill at slot id 9 → offset (9-8)*8 = 8.
    try testing.expectEqual(@as(u32, 8), alloc.slot(3, .gpr).spill);
}

test "spill_offsets: v128 spill slot gets 16-byte alignment + stride" {
    // Allocation with one scalar spill slot followed by one v128
    // spill slot. The v128 must land at a 16-byte boundary; the
    // following slot (if any) starts at v128_offset + 16.
    const slots = [_]u16{ 8, 9, 10 }; // 3 spill slots
    const tags = [_]ShapeTag{ .scalar, .v128, .scalar };
    const offsets = [_]u32{ 0, 16, 32 };
    const alloc: Allocation = .{
        .slots = &slots,
        .n_slots = 11,
        .max_reg_slots_gpr = 8,
        .shape_tags = &tags,
        .spill_offsets = &offsets,
    };
    try testing.expectEqual(@as(u32, 0), alloc.slot(0, .gpr).spill); // scalar at 0
    try testing.expectEqual(@as(u32, 16), alloc.slot(1, .gpr).spill); // v128 at 16-aligned
    try testing.expectEqual(@as(u32, 32), alloc.slot(2, .gpr).spill); // next scalar
    // spillBytes: align_up(last_offset + 16, 16) = align_up(48, 16) = 48.
    try testing.expectEqual(@as(u32, 48), alloc.spillBytes());
}

test "computeSpillOffsets: bumps scalar-then-v128 to 16-byte alignment" {
    // 3 spill slots: scalar (id 8) → v128 (id 9) → scalar (id 10).
    // Slot 8: scalar at offset 0 (size 8 → next byte_off = 8).
    // Slot 9: v128 aligns 8 → 16, lands at 16, consumes 16 → 32.
    // Slot 10: scalar at offset 32.
    const slots_arr = [_]u16{ 8, 9, 10 };
    const tags = [_]ShapeTag{ .scalar, .v128, .scalar };
    const result = (try computeSpillOffsets(testing.allocator, &slots_arr, 11, 8, &tags)).?;
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u32, &.{ 0, 16, 32 }, result);
}

test "computeSpillOffsets: returns null when no v128 vreg spills" {
    // 2 spill slots, both scalar → legacy formula suffices.
    const slots_arr = [_]u16{ 8, 9 };
    const tags = [_]ShapeTag{ .scalar, .scalar };
    const result = try computeSpillOffsets(testing.allocator, &slots_arr, 10, 8, &tags);
    try testing.expect(result == null);
}

test "computeSpillOffsets: v128 alignment with leading scalar pads correctly" {
    // Slot 8 scalar (size 8) → byte_off advances to 8.
    // Slot 9 v128 needs 16-aligned: padded to 16, consumes 16 → 32.
    const slots_arr = [_]u16{ 8, 9 };
    const tags = [_]ShapeTag{ .scalar, .v128 };
    const result = (try computeSpillOffsets(testing.allocator, &slots_arr, 10, 8, &tags)).?;
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u32, &.{ 0, 16 }, result);
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

// ADR-0077 fence integration tests. The shared regalloc stays
// arch-agnostic; the per-arch reservation table lands at B125.
// These tests use a stub fence fn that reserves slots {0..4}
// for `.@"table.fill"` (mirrors the production reservation set
// per the B119 live-scratch census).

fn testFenceTableFill(op: zir.ZirOp) []const u16 {
    const reservation = [_]u16{ 0, 1, 2, 3, 4 };
    return if (op == .@"table.fill") &reservation else &.{};
}

test "fence: null reservation is bit-for-bit identical to pre-fence walker" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    };
    f.liveness = .{ .ranges = &ranges };
    // Even with .@"table.fill" inside the live range, a null
    // reservation fn skips the fence — vreg gets slot 0.
    const alloc = try computeWith(testing.allocator, &f, max_reg_slots_gpr_default, null);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try verify(&f, alloc);
}

test "fence: vreg crossing reserving op is forced past slots 0..4" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 3 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try computeWith(testing.allocator, &f, max_reg_slots_gpr_default, testFenceTableFill);
    defer deinit(testing.allocator, alloc);
    try testing.expect(alloc.slots[0] >= 5);
    try verify(&f, alloc);
}

test "fence is PC-local: non-crossing vreg keeps slot 0 even with fence active" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    // v0 dies before table.fill; v1 born after it. Neither
    // crosses; both should reuse slot 0.
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 3, .last_use_pc = 4 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try computeWith(testing.allocator, &f, max_reg_slots_gpr_default, testFenceTableFill);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try testing.expectEqual(@as(u16, 0), alloc.slots[1]);
    try verify(&f, alloc);
}

test "fence: boundary PC (vreg ending AT reserving op) is safe on slot 0" {
    var f = freshFunc();
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .nop });
    try f.instrs.append(testing.allocator, .{ .op = .@"table.fill" });
    // v0 last_use AT the table.fill PC — consumed before any
    // clobber. Strict-strict shape (def_pc < pc < last_use_pc)
    // excludes pc=2 from the fence range.
    const ranges = [_]LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    };
    f.liveness = .{ .ranges = &ranges };
    const alloc = try computeWith(testing.allocator, &f, max_reg_slots_gpr_default, testFenceTableFill);
    defer deinit(testing.allocator, alloc);
    try testing.expectEqual(@as(u16, 0), alloc.slots[0]);
    try verify(&f, alloc);
}
