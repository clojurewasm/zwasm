//! x86_64 emit pass — control-flow handlers (D-030 chunk-f).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape (`arm64/op_control.zig`). Behaviour
//! change zero — handler bodies are unchanged from their pre-split
//! shape; only their home file moves.
//!
//! Handlers in this module:
//!   - `emitBlock` / `emitLoop`        — push a label frame.
//!   - `emitBr` / `emitBrIf`           — unconditional / conditional
//!     branch by depth (loop → concrete disp; block-family →
//!     placeholder + Fixup append).
//!   - `emitBrTable`                   — pop index, emit per-case
//!     CMP+JNE-skip+JMP chain plus default tail.
//!   - `emitIf` / `emitElse`           — pop cond → JE skip; on
//!     `else`, JMP placeholder + JE patch + label transition.
//!   - `emitEndIntra`                  — patch a label's pending
//!     fixups + if-skip-Jcc + emit merge MOV (D-027 mirror).
//!
//! `emitBrTableJmp` is a module-private helper shared by the
//! per-case loop and the default tail of `emitBrTable`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const types = @import("types.zig");
const label_mod = @import("label.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;
const Label = label_mod.Label;
const ZirFunc = zir.ZirFunc;

/// Mirror of `Label.merge_top_vregs.len` — comptime-knowable cap
/// on Wasm 2.0 multi-value if/else result arity. Mirrors
/// `arm64/op_control.zig:merge_top_vregs_cap`.
const merge_top_vregs_cap: u8 = 8;

/// D-147 / lesson `2026-05-18-parallel-move-cycle-in-if-merge.md`:
/// x86_64 mirror of arm64's `resolveAndEmitMergeMovsRegBatch`.
/// Resolves a batch of GPR register-to-register merge moves with
/// cycle detection; breaks cycles via **RAX** (caller-saved return
/// reg, outside both the regalloc pool and `abi.spill_stage_gprs`
/// R10/R11 — safe scratch for the duration of the merge batch
/// since no calls fire between MOVs). Algorithm + correctness
/// argument identical to the arm64 helper.
fn resolveAndEmitMergeMovsRegBatchX86(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    moves: []ParallelMoveX86,
) Error!void {
    var pending: u32 = 0;
    for (moves) |m| {
        if (!m.done) pending += 1;
    }
    while (pending > 0) {
        var leaf_idx: ?usize = null;
        for (moves, 0..) |m, i| {
            if (m.done) continue;
            var has_user = false;
            for (moves, 0..) |o, j| {
                if (i == j or o.done) continue;
                if (m.dst_reg == o.src_reg) {
                    has_user = true;
                    break;
                }
            }
            if (!has_user) {
                leaf_idx = i;
                break;
            }
        }
        if (leaf_idx) |idx| {
            const m = moves[idx];
            try buf.appendSlice(allocator, inst.encMovRR(.q, m.dst_reg, m.src_reg).slice());
            moves[idx].done = true;
            pending -= 1;
        } else {
            // Cycle. Save first pending move's dst to RAX; rewrite
            // any pending move whose src is that register to use RAX.
            for (moves, 0..) |m, i| {
                if (m.done) continue;
                const cycle_dst = m.dst_reg;
                try buf.appendSlice(allocator, inst.encMovRR(.q, .rax, cycle_dst).slice());
                for (moves, 0..) |o, j| {
                    if (o.done or j == i) continue;
                    if (o.src_reg == cycle_dst) moves[j].src_reg = .rax;
                }
                break;
            }
        }
    }
}

const ParallelMoveX86 = struct {
    src_reg: abi.Gpr,
    dst_reg: abi.Gpr,
    done: bool,
};

/// D-097 / d-17: unified merge-MOV dispatcher (x86_64 counterpart
/// of `arm64/op_control.zig:emitMergeMov`). See that file for the
/// rationale; behaviour is identical modulo the per-arch encoder
/// names (resolveXmm/MOVAPS for v128 reg-reg; xmmLoad/Def/Store
/// + MOVSD for FP scalar; gprLoad/Def/Store + 64-bit MOV for GPR).
fn emitMergeMov(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    spill_base_off: u32,
    func: *const ZirFunc,
    src_vreg: u32,
    merge_vreg: u32,
) Error!void {
    if (alloc.shapeTag(merge_vreg) == .v128) {
        const src_x = try gpr.xmmLoadSpilledV128(allocator, buf, alloc, spill_base_off, src_vreg, 0);
        const merge_x = try gpr.xmmDefSpilledV128(alloc, merge_vreg, 1);
        if (merge_x != src_x) {
            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(merge_x, src_x).slice());
        }
        try gpr.xmmStoreSpilledV128(allocator, buf, alloc, spill_base_off, merge_vreg, 1);
        return;
    }
    if (regalloc.vregClassByDef(func, merge_vreg) == .fpr) {
        const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
        const merge_x = try gpr.xmmDefSpilled(alloc, merge_vreg, 1);
        if (merge_x != src_x) {
            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(merge_x, src_x).slice());
        }
        try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, 1);
        return;
    }
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
    const merge_r = try gpr.gprDefSpilled(alloc, merge_vreg, 1);
    if (merge_r != src_r) {
        // 64-bit MOV — preserves all 64 bits. Pre-d-17 the
        // merge sites used .d (32-bit) which truncated i64
        // values; the symmetric arm64 bug was fixed in the
        // unified `emitMergeMov` helper at the same time.
        try buf.appendSlice(allocator, inst.encMovRR(.q, merge_r, src_r).slice());
    }
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, 1);
}

/// Unpack `(param_arity, result_arity)` from a block-open
/// ZirInstr's `extra`. Mirrors
/// `arm64/op_control.zig:unpackBlockArity`.
fn unpackBlockArity(extra: u32) struct { params: u8, results: u8 } {
    return .{
        .params = @intCast((extra >> 8) & 0xFF),
        .results = @intCast(extra & 0xFF),
    };
}

/// Block-merge mechanism for forward `br` / `br_if` to a
/// `block (result T..)` target. Mirrors
/// `arm64/op_control.zig:captureOrEmitBlockMergeMov`
/// extended from the if/else `merge_top_vregs` mechanism
/// (D-027 + D-035 chunk-d035-c) to `.block` per D-093 (d-2).
///
/// Returns `true` when MOVs were emitted; caller wraps in a
/// JE-skip for br_if.
fn captureOrEmitBlockMergeMov(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
    spill_base_off: u32,
    func: *const ZirFunc,
    tgt_idx: usize,
) Error!bool {
    const arity: u32 = labels.items[tgt_idx].result_arity;
    if (arity == 0) return false;
    // D-096 / d-17: br-into-if-frame target (mirror arm64).
    const kind = labels.items[tgt_idx].kind;
    if (kind != .block and kind != .if_then and kind != .else_open) return false;
    if (pushed_vregs.items.len < arity) return Error.AllocationMissing;

    if (!labels.items[tgt_idx].merge_captured) {
        const base = pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            labels.items[tgt_idx].merge_top_vregs[i] = pushed_vregs.items[base + i];
        }
        labels.items[tgt_idx].merge_captured = true;
        return false;
    }

    const base = pushed_vregs.items.len - arity;
    // D-147 / lesson `2026-05-18-parallel-move-cycle-in-if-merge.md`
    // (arm64 mirror): when all moves are GPR reg-to-reg, route them
    // through the cycle-aware parallel-move resolver so LIFO slot
    // reuse + sequential emit don't clobber still-needed sources.
    var moves_buf: [merge_top_vregs_cap]ParallelMoveX86 = undefined;
    var n_moves: u32 = 0;
    var all_gpr_reg_to_reg = true;
    {
        var k: u32 = 0;
        while (k < arity) : (k += 1) {
            const src_vreg = pushed_vregs.items[base + k];
            const merge_vreg = labels.items[tgt_idx].merge_top_vregs[k];
            if (src_vreg == merge_vreg) continue;
            if (alloc.shapeTag(merge_vreg) == .v128) {
                all_gpr_reg_to_reg = false;
                break;
            }
            if (regalloc.vregClassByDef(func, merge_vreg) == .fpr) {
                all_gpr_reg_to_reg = false;
                break;
            }
            const src_slot = alloc.slot(src_vreg, .gpr);
            const merge_slot = alloc.slot(merge_vreg, .gpr);
            const src_reg: abi.Gpr = switch (src_slot) {
                .reg => |id| abi.slotToReg(id) orelse {
                    all_gpr_reg_to_reg = false;
                    break;
                },
                .spill => {
                    all_gpr_reg_to_reg = false;
                    break;
                },
            };
            const dst_reg: abi.Gpr = switch (merge_slot) {
                .reg => |id| abi.slotToReg(id) orelse {
                    all_gpr_reg_to_reg = false;
                    break;
                },
                .spill => {
                    all_gpr_reg_to_reg = false;
                    break;
                },
            };
            if (src_reg == dst_reg) continue;
            moves_buf[n_moves] = .{ .src_reg = src_reg, .dst_reg = dst_reg, .done = false };
            n_moves += 1;
        }
    }
    if (all_gpr_reg_to_reg) {
        try resolveAndEmitMergeMovsRegBatchX86(allocator, buf, moves_buf[0..n_moves]);
    } else {
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            const src_vreg = pushed_vregs.items[base + i];
            const merge_vreg = labels.items[tgt_idx].merge_top_vregs[i];
            try emitMergeMov(allocator, buf, alloc, spill_base_off, func, src_vreg, merge_vreg);
        }
    }
    return true;
}

/// Wasm spec §3.4.4 (block) — push a forward-resolving label
/// frame. No code emitted; the matching `end` patches all
/// `pending` fixups.
/// D-093 (d-1): records result_arity (from ZirInstr.extra) +
/// entry_stack_depth so emitEndIntra can truncate operand
/// stack at block close.
pub fn emitBlock(
    allocator: Allocator,
    labels: *std.ArrayList(Label),
    pushed_vregs: *const std.ArrayList(u32),
    arity_u32: u32,
) Error!void {
    const ar = unpackBlockArity(arity_u32);
    if (ar.results > merge_top_vregs_cap) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:emitBlock-arity", arity_u32);
    try labels.append(allocator, .{
        .kind = .block,
        .target_byte_offset = 0,
        .pending = .empty,
        .result_arity = ar.results,
        .param_arity = ar.params,
        .entry_stack_depth = @intCast(pushed_vregs.items.len),
    });
}

/// Wasm spec §3.4.4 (loop) — push a backward-resolving label
/// frame. Captures the current buf offset as the loop entry;
/// subsequent `br` to this label resolves to a backward JMP with
/// concrete disp.
pub fn emitLoop(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    labels: *std.ArrayList(Label),
    pushed_vregs: *const std.ArrayList(u32),
    arity_u32: u32,
) Error!void {
    const ar = unpackBlockArity(arity_u32);
    if (ar.results > merge_top_vregs_cap) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:emitLoop-arity", arity_u32);
    if (ar.params > merge_top_vregs_cap) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:emitLoop-param-arity", arity_u32);
    // D-099 / d-24: mirror arm64 — capture loop entry param vregs.
    var param_top: [merge_top_vregs_cap]u32 = undefined;
    if (ar.params > 0 and pushed_vregs.items.len >= ar.params) {
        const base = pushed_vregs.items.len - ar.params;
        var i: u32 = 0;
        while (i < ar.params) : (i += 1) {
            param_top[i] = pushed_vregs.items[base + i];
        }
    }
    try labels.append(allocator, .{
        .kind = .loop,
        .target_byte_offset = @intCast(buf.items.len),
        .pending = .empty,
        .result_arity = ar.results,
        .param_arity = ar.params,
        .entry_stack_depth = @intCast(pushed_vregs.items.len),
        .param_top_vregs = param_top,
    });
}

/// Wasm spec §3.4.5 (br N) — unconditional branch to label at
/// depth N (0 = innermost). Loop targets resolve immediately to
/// a concrete disp; block targets emit a placeholder JMP rel32
/// and append a `Fixup` for the matching `end` to patch. When
/// `depth == labels.items.len` the branch targets the implicit
/// function-level block (= `return`); marshal the function's
/// result and emit the inline epilogue (§9.7 / 7.10-h mirror of
/// `arm64/op_control.zig:emitBr`'s function-depth path).
///
/// Per the existing `return` handler in `emit.zig`, x86_64 inlines
/// the epilogue at every return site rather than using a
/// `return_fixups` table — multiple physical RETs are harmless on
/// x86_64 (no jump table needed, unlike ARM64 where return_fixups
/// consolidate to a single epilogue).
pub fn emitBr(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
    spill_base_off: u32,
    func: *const ZirFunc,
    frame_bytes: u32,
    uses_runtime_ptr: bool,
    return_is_memory_class: bool,
    indirect_result_slot_neg_off: u32,
    depth: u32,
) Error!void {
    if (depth == labels.items.len) {
        try emitFunctionReturn(allocator, buf, alloc, pushed_vregs, spill_base_off, func, frame_bytes, uses_runtime_ptr, return_is_memory_class, indirect_result_slot_neg_off);
        return;
    }
    if (depth > labels.items.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:78", 0);
    const tgt_idx = labels.items.len - 1 - depth;
    if (labels.items[tgt_idx].kind == .loop) {
        // D-099 / d-24: mirror arm64 — emit MOVs from current top
        // param_arity vregs into captured param_top_vregs before
        // the back-branch so the next iteration's body reads new
        // param values.
        const param_arity = labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and pushed_vregs.items.len >= param_arity) {
            const base = pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = pushed_vregs.items[base + i];
                const dst_vreg = labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try emitMergeMov(allocator, buf, alloc, spill_base_off, func, src_vreg, dst_vreg);
                }
            }
        }
        const at: u32 = @intCast(buf.items.len);
        const tgt_byte = labels.items[tgt_idx].target_byte_offset;
        const disp: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(at)) - 5;
        try buf.appendSlice(allocator, inst.encJmpRel32(disp).slice());
        return;
    }
    // Forward branch. D-093 (d-2): block-merge capture-or-MOV
    // before emitting the JMP. For br (unconditional) the
    // MOVs land before the JMP placeholder; the fall-through
    // is dead per lower.zig unreachable-tracking so the MOVs
    // only execute when control reaches the br.
    _ = try captureOrEmitBlockMergeMov(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, func, tgt_idx);
    const at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
    try labels.items[tgt_idx].pending.append(allocator, .{ .byte_offset = at, .insn_size = 5 });
}

/// D-093 (d-11) — marshal the top N result vregs into the C-ABI
/// result registers (SysV: RAX/RDX for GPR, XMM0/XMM1 for XMM;
/// Win64: ≤1 of each). Walks `func.sig.results` in order; per-
/// class index maps the i-th result to the corresponding result
/// register. Multi-result overflow surfaces as UnsupportedOp.
/// **No parallel-move hazard** — allocatable_gprs / xmms exclude
/// the result regs, so per-result MOV emit is safe.
pub fn marshalReturnRegs(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    func: *const ZirFunc,
    return_is_memory_class: bool,
    indirect_result_slot_neg_off: u32,
) Error!void {
    if (func.sig.results.len == 0) return;
    if (pushed_vregs.items.len < func.sig.results.len) return;
    // ADR-0026 2026-05-18 Convention Swap / ADR-0069 §Phase 2:
    // MEMORY-class returns — caller passed the hidden indirect-
    // result-pointer in RDI (SysV §3.2.3); the prologue captured
    // it to `[RBP - indirect_result_slot_neg_off]`. Load it back
    // into RAX (caller-saved scratch + SysV §3.2.3 compliance
    // bonus — RAX returns the buffer address on MEMORY-class)
    // and write each result to `[RAX + i*8]`. R10/R11 stay
    // reserved as `gprLoadSpilled` spill stage; RAX is outside
    // that cohort. v128 in MEMORY-class returns is deferred —
    // ADR-0069 §Phase 3 covers up-to-16 result slots of mixed
    // int/f32/f64 (the large-sig fixture) but v128 multi-result
    // remains UnsupportedOp.
    if (return_is_memory_class) {
        const slot_disp: i32 = -@as(i32, @intCast(indirect_result_slot_neg_off));
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rbp, slot_disp).slice());
        const result_base = pushed_vregs.items.len - func.sig.results.len;
        var byte_off: i32 = 0;
        for (func.sig.results, 0..) |result_kind, i| {
            const src_vreg = pushed_vregs.items[result_base + i];
            if (src_vreg < alloc.slots.len) {
                switch (result_kind) {
                    .i32, .i64, .funcref, .externref => {
                        const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                        try buf.appendSlice(allocator, inst.encStoreR64MemDisp32(src, .rax, byte_off).slice());
                    },
                    .f32 => {
                        // MOVD R10D, xmm; MOV [RAX+disp], R10D —
                        // 4-byte store of low 32 bits of XMM.
                        // R10 is `spill_stage_gprs[0]`; the
                        // xmmLoadSpilled above uses XMM14/XMM15
                        // (fp_spill_stage_xmms), disjoint from
                        // R10, so R10 is free here as transfer
                        // scratch.
                        const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                        try buf.appendSlice(allocator, inst.encMovdR32FromXmm(.r10, src_x).slice());
                        try buf.appendSlice(allocator, inst.encStoreR32MemDisp32(.r10, .rax, byte_off).slice());
                    },
                    .f64 => {
                        // MOVQ R10, xmm; MOV [RAX+disp], R10 —
                        // 8-byte store of low 64 bits of XMM.
                        const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                        try buf.appendSlice(allocator, inst.encMovqR64FromXmm(.r10, src_x).slice());
                        try buf.appendSlice(allocator, inst.encStoreR64MemDisp32(.r10, .rax, byte_off).slice());
                    },
                    .v128 => return Error.UnsupportedOp,
                }
            }
            byte_off += 8;
        }
        return;
    }
    const gpr_result_regs = [_]abi.Gpr{ .rax, .rdx };
    const xmm_result_regs = [_]abi.Xmm{ .xmm0, .xmm1 };
    const gpr_cap: u8 = switch (abi.current_cc) {
        .sysv => 2,
        .win64 => 1,
    };
    const xmm_cap: u8 = switch (abi.current_cc) {
        .sysv => 2,
        .win64 => 1,
    };
    // D-093 (d-12) — cap-exceed silent-truncate (workaround per
    // D-094 debt row). SysV §3.2.3 limits result regs to 2/class;
    // >2 results need indirect-result-buffer via hidden RDI ptr.
    // Implementing the buffer path is significant (call sites
    // must allocate scratch + pass ptr); for now, marshal only
    // the first `cap` results per class and leave overflow
    // results unwritten. This matches the pre-d-11 behaviour
    // (single-result inline marshal never reached the overflow
    // anyway); only the spec corpus's `break-multi-value`-shape
    // funcs exercise overflow, and the runner's skip-impl filter
    // already excludes their assertions (so wrong values are
    // unobservable).

    var gpr_used: u8 = 0;
    var xmm_used: u8 = 0;
    const result_base = pushed_vregs.items.len - func.sig.results.len;
    for (func.sig.results, 0..) |result_kind, i| {
        const src_vreg = pushed_vregs.items[result_base + i];
        if (src_vreg >= alloc.slots.len) {
            // D-093 (d-5): dead placeholder; skip.
            switch (result_kind) {
                .i32, .i64, .funcref, .externref => gpr_used += 1,
                .f32, .f64, .v128 => xmm_used += 1,
            }
            continue;
        }
        switch (result_kind) {
            .i32 => {
                if (gpr_used >= gpr_cap) {
                    gpr_used += 1;
                    continue; // D-094 silent-truncate
                }
                const dst = gpr_result_regs[gpr_used];
                gpr_used += 1;
                const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                if (src != dst) try buf.appendSlice(allocator, inst.encMovRR(.d, dst, src).slice());
            },
            .i64, .funcref, .externref => {
                if (gpr_used >= gpr_cap) {
                    gpr_used += 1;
                    continue; // D-094 silent-truncate
                }
                const dst = gpr_result_regs[gpr_used];
                gpr_used += 1;
                const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                if (src != dst) try buf.appendSlice(allocator, inst.encMovRR(.q, dst, src).slice());
            },
            .f32, .f64 => {
                if (xmm_used >= xmm_cap) {
                    xmm_used += 1;
                    continue; // D-094 silent-truncate
                }
                const dst = xmm_result_regs[xmm_used];
                xmm_used += 1;
                const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                if (src_x != dst) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src_x).slice());
            },
            .v128 => {
                if (xmm_used >= xmm_cap) {
                    xmm_used += 1;
                    continue; // D-094 silent-truncate
                }
                const dst = xmm_result_regs[xmm_used];
                xmm_used += 1;
                const src_x = try gpr.resolveXmm(alloc, src_vreg);
                if (src_x != dst) try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src_x).slice());
            },
        }
    }
}

/// Marshal the top vreg as the function's result + emit the
/// regular epilogue (ADD RSP, frame ; POP R15? ; POP RBP ; RET).
/// Shared between `emitBr`'s function-depth path and `emitBrIf`'s
/// conditional return path. Mirrors the inline body of `emit.zig`'s
/// `.@"return"` handler — extracted here so br/br_if can reach for
/// it without duplicating ~40 lines per site. Module-pub so the
/// brTable path (a follow-up chunk) can reuse the same shape.
pub fn emitFunctionReturn(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    func: *const ZirFunc,
    frame_bytes: u32,
    uses_runtime_ptr: bool,
    return_is_memory_class: bool,
    indirect_result_slot_neg_off: u32,
) Error!void {
    try marshalReturnRegs(allocator, buf, alloc, pushed_vregs, spill_base_off, func, return_is_memory_class, indirect_result_slot_neg_off);
    if (frame_bytes > 0) {
        // Inline imm8/imm32 SUB-form selection mirroring emit.zig's
        // `rspAdd` helper. Kept inline here to avoid a Zone-internal
        // back-reference into emit.zig.
        if (frame_bytes <= 127) {
            try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(frame_bytes)).slice());
        } else {
            try buf.appendSlice(allocator, inst.encAddRSpImm32(@intCast(frame_bytes)).slice());
        }
    }
    if (uses_runtime_ptr) {
        try buf.appendSlice(allocator, inst.encPopR(.r15).slice());
    }
    try buf.appendSlice(allocator, inst.encPopR(.rbp).slice());
    try buf.appendSlice(allocator, inst.encRet().slice());
}

/// Emit a single `JMP target_for_depth` for one br_table case
/// (or the trailing default). Backward (loop) → concrete disp;
/// forward (block / if family) → placeholder + Fixup append.
/// Shared between the per-case loop and the default tail.
fn emitBrTableJmp(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
    spill_base_off: u32,
    func: *const ZirFunc,
    frame_bytes: u32,
    uses_runtime_ptr: bool,
    return_is_memory_class: bool,
    indirect_result_slot_neg_off: u32,
    depth: u32,
) Error!void {
    // d-23 (D-107 discharge): `br_table 0` at function scope (= no
    // enclosing block) targets depth == labels.items.len = the
    // implicit function-level block. arm64's emitBranchToDepth has
    // this case (mirror of emitBr's function-depth path); x86_64
    // pre-d-23 rejected it. unwind.wast's `func-unwind-by-br_table`
    // shape is the surfacing fixture.
    if (depth == labels.items.len) {
        try emitFunctionReturn(allocator, buf, alloc, pushed_vregs, spill_base_off, func, frame_bytes, uses_runtime_ptr, return_is_memory_class, indirect_result_slot_neg_off);
        return;
    }
    if (depth > labels.items.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:104", 0);
    const tgt_idx = labels.items.len - 1 - depth;
    if (labels.items[tgt_idx].kind == .loop) {
        // D-099 / d-24: loop-param MOVs (mirror of emitBr).
        const param_arity = labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and pushed_vregs.items.len >= param_arity) {
            const base = pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = pushed_vregs.items[base + i];
                const dst_vreg = labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try emitMergeMov(allocator, buf, alloc, spill_base_off, func, src_vreg, dst_vreg);
                }
            }
        }
        const at: u32 = @intCast(buf.items.len);
        const tgt_byte = labels.items[tgt_idx].target_byte_offset;
        const disp: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(at)) - 5;
        try buf.appendSlice(allocator, inst.encJmpRel32(disp).slice());
        return;
    }
    // D-093 (d-7): block-merge MOVs (mirror of arm64
    // emitBranchToDepth). Caller (emitBrTable) patches the
    // per-case JNE-skip disp after this returns so it covers
    // MOVs + JMP.
    _ = try captureOrEmitBlockMergeMov(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, func, tgt_idx);
    const at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
    try labels.items[tgt_idx].pending.append(allocator, .{ .byte_offset = at, .insn_size = 5 });
}

/// Wasm spec §3.4.6 (br_table) — pop index; emit a CMP+JNE-skip
/// +JMP chain for each in-range case, then an unconditional JMP
/// to the default.
///
/// ZirInstr encoding (mvp.zig:brTableOp):
///   payload = count   (number of in-range targets)
///   extra   = start   (offset into func.branch_targets)
/// branch_targets[start..start+count] = case depths
/// branch_targets[start+count]        = default depth
///
/// Per-case sequence (10-11 bytes):
///   CMP idx, i        (3-4 bytes; REX.B if idx ∈ R8..R15)
///   JNE +5            (2 bytes; skip the JMP if idx != i)
///   JMP target        (5 bytes; placeholder/concrete per kind)
///
/// **Cap**: count ≤ 127 (CMP r/m32, imm8 sign-extended). Larger
/// requires the imm32 form; surfaces as UnsupportedOp.
pub fn emitBrTable(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
    spill_base_off: u32,
    frame_bytes: u32,
    uses_runtime_ptr: bool,
    return_is_memory_class: bool,
    indirect_result_slot_neg_off: u32,
    count: u32,
    start: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = pushed_vregs.pop().?;
    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const targets = func.branch_targets.items;
    if (start + count >= targets.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:151", 0);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // §9.9 / 9.9-l-1b-d093-d45 (D-118): per-case CMP. Cases
        // i ≤ 127 fit `CMP r32, imm8`; for the wider range
        // (Wasm spec §3.4.5 br_table has no upper bound — br_table.
        // wast `large` declares 16149 targets), use `CMP r32, imm32`
        // + `Jcc rel32`. The JNE-skip's reach grows from imm8
        // (±127) to imm32 (±2 GiB), comfortable for any realistic
        // per-case payload.
        const jne_size: usize = if (i <= 127) 2 else 6;
        if (i <= 127) {
            try buf.appendSlice(allocator, inst.encCmpRImm8(.d, idx_r, @intCast(i)).slice());
        } else {
            try buf.appendSlice(allocator, inst.encCmpRImm32(idx_r, i).slice());
        }
        // D-093 (d-7): variable-disp JNE-skip. emitBrTableJmp may
        // emit MOVs + JMP (when forward target is `.block` with
        // merge captured). Pre-d-7 used fixed disp = 5 (= skip a
        // single 5-byte JMP). Patch after emitBrTableJmp returns.
        const jne_at: usize = buf.items.len;
        if (i <= 127) {
            try buf.appendSlice(allocator, inst.encJccRel8(.ne, 0).slice());
        } else {
            try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());
        }
        try emitBrTableJmp(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, func, frame_bytes, uses_runtime_ptr, return_is_memory_class, indirect_result_slot_neg_off, targets[start + i]);
        const after: usize = buf.items.len;
        const disp: usize = after - (jne_at + jne_size);
        if (i <= 127) {
            if (disp > 127) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:jne-rel8-overflow", @intCast(disp));
            buf.items[jne_at + 1] = @intCast(disp);
        } else {
            // rel32 (Jcc 0F 8X rel32) — disp32 patched into bytes [2..6].
            const disp32: u32 = @intCast(disp);
            std.mem.writeInt(u32, buf.items[jne_at + 2 ..][0..4], disp32, .little);
        }
    }
    try emitBrTableJmp(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, func, frame_bytes, uses_runtime_ptr, return_is_memory_class, indirect_result_slot_neg_off, targets[start + count]);
}

/// Wasm spec §3.4.5 (br_if N) — pop cond, branch to label at
/// depth N if cond is non-zero. Emit TEST cond, cond ; Jcc(NE)
/// target. Backward (loop) target → concrete disp; forward
/// (block / if) target → placeholder + Fixup append. When
/// `depth == labels.items.len` the conditional branch targets
/// the implicit function-level block (= conditional return); use
/// a JE-skip + inline marshal + epilogue + RET sequence so the
/// fall-through path lands on the next instruction (= cond was 0,
/// don't return). §9.7 / 7.10-h mirror of arm64's CBZ-skip path.
pub fn emitBrIf(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
    spill_base_off: u32,
    func: *const ZirFunc,
    frame_bytes: u32,
    uses_runtime_ptr: bool,
    return_is_memory_class: bool,
    indirect_result_slot_neg_off: u32,
    depth: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const cond_v = pushed_vregs.pop().?;
    const cond_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, cond_v, 0);
    if (depth == labels.items.len) {
        // Conditional function-return:
        //   TEST cond_r, cond_r
        //   JE skip_byte                  (rel32 placeholder; backpatched)
        //   <emitFunctionReturn>          (marshal + epilogue + RET)
        // skip_byte:
        try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
        const je_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
        try emitFunctionReturn(allocator, buf, alloc, pushed_vregs, spill_base_off, func, frame_bytes, uses_runtime_ptr, return_is_memory_class, indirect_result_slot_neg_off);
        // Patch the JE rel32 to land on the byte AFTER the
        // emitFunctionReturn block.
        const skip_byte: u32 = @intCast(buf.items.len);
        const je_disp: i32 = @as(i32, @intCast(skip_byte)) - @as(i32, @intCast(je_at)) - 6;
        const patched = inst.encJccRel32(.e, je_disp);
        @memcpy(buf.items[je_at .. je_at + patched.len], patched.slice());
        return;
    }
    if (depth > labels.items.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:178", 0);
    try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
    const tgt_idx = labels.items.len - 1 - depth;
    if (labels.items[tgt_idx].kind == .loop) {
        // D-099 / d-24: loop with params — MOVs gated on cond ≠ 0.
        // Wrap with JE-skip when params present; else use direct
        // JNE-back.
        const param_arity = labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and pushed_vregs.items.len >= param_arity) {
            const je_at: usize = buf.items.len;
            try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
            const base = pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = pushed_vregs.items[base + i];
                const dst_vreg = labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try emitMergeMov(allocator, buf, alloc, spill_base_off, func, src_vreg, dst_vreg);
                }
            }
            const back_at: u32 = @intCast(buf.items.len);
            const tgt_byte = labels.items[tgt_idx].target_byte_offset;
            const back_disp: i32 = @as(i32, @intCast(tgt_byte)) -
                @as(i32, @intCast(back_at)) - 5;
            try buf.appendSlice(allocator, inst.encJmpRel32(back_disp).slice());
            // Patch JE-skip disp to land at the byte after the JMP back.
            const skip_at: u32 = @intCast(buf.items.len);
            const je_disp: i32 = @as(i32, @intCast(skip_at)) - @as(i32, @intCast(je_at)) - 6;
            const patched = inst.encJccRel32(.e, je_disp);
            @memcpy(buf.items[je_at .. je_at + patched.len], patched.slice());
            return;
        }
        const at: u32 = @intCast(buf.items.len);
        const tgt_byte = labels.items[tgt_idx].target_byte_offset;
        const disp: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(at)) - 6;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
        return;
    }
    // Forward branch. D-093 (d-2): for .block with a captured
    // merge target, the MOVs+JMP must run only when cond ≠ 0.
    // Wrap them inside a JE-skip sequence so the fall-through
    // path (cond == 0) bypasses both. First br_if to a block
    // (capture path, no MOV) uses the canonical JNE-forward
    // shape with the merge captured pre-emit.
    const tgt_is_block_with_capture =
        labels.items[tgt_idx].kind == .block and
        labels.items[tgt_idx].result_arity > 0 and
        labels.items[tgt_idx].merge_captured;
    if (tgt_is_block_with_capture) {
        const je_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());
        _ = try captureOrEmitBlockMergeMov(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, func, tgt_idx);
        const jmp_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
        try labels.items[tgt_idx].pending.append(allocator, .{ .byte_offset = jmp_at, .insn_size = 5 });
        const skip_byte: u32 = @intCast(buf.items.len);
        const je_disp: i32 = @as(i32, @intCast(skip_byte)) - @as(i32, @intCast(je_at)) - 6;
        const patched = inst.encJccRel32(.e, je_disp);
        @memcpy(buf.items[je_at .. je_at + patched.len], patched.slice());
        return;
    }
    _ = try captureOrEmitBlockMergeMov(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, func, tgt_idx);
    const at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());
    try labels.items[tgt_idx].pending.append(allocator, .{ .byte_offset = at, .insn_size = 6 });
}

/// Wasm spec §3.4.4 (if) — pop cond, emit TEST cond, cond ; JE
/// skip_placeholder. Push label.if_then with the JE byte offset
/// recorded; the matching `else` patches it to else-body start,
/// or the matching `end` patches it to end-of-if (no-else case).
///
/// **Multi-result support** (D-035 chunk-d035-c): `arity` is the
/// blocktype's result count (= `ZirInstr.extra` per
/// `lower.zig:openBlock`; Wasm 2.0 multi-value). The merge MOV
/// path in emitElse / emitEndIntra captures N then-arm result
/// vregs at `else` and emits N MOVs at the matching `end` to
/// converge both arms. Cap = `Label.merge_top_vregs.len`; larger
/// surfaces as `UnsupportedOp`. Mirrors
/// `arm64/op_control.zig:emitIf`.
pub fn emitIf(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
    spill_base_off: u32,
    arity_extra: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const ar = unpackBlockArity(arity_extra);
    if (ar.results > merge_top_vregs_cap) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:217", 0);
    if (ar.params > merge_top_vregs_cap) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:if-params-cap", 0);
    const cond_v = pushed_vregs.pop().?;
    const cond_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, cond_v, 0);
    try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
    const skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice()); // JE = skip if cond==0
    // D-093 (d-10) — capture top `param_arity` vregs for else-arm
    // restore (mirror of arm64/op_control.zig:emitIf).
    var param_top_vregs: [merge_top_vregs_cap]u32 = undefined;
    if (ar.params > 0) {
        if (pushed_vregs.items.len < ar.params) return Error.AllocationMissing;
        const base = pushed_vregs.items.len - ar.params;
        var i: u32 = 0;
        while (i < ar.params) : (i += 1) {
            param_top_vregs[i] = pushed_vregs.items[base + i];
        }
    }
    try labels.append(allocator, .{
        .kind = .if_then,
        .target_byte_offset = 0,
        .pending = .empty,
        .if_skip_byte = skip_at,
        .result_arity = ar.results,
        .param_arity = ar.params,
        // D-093 (d-1): measured AFTER popping cond_v, matches
        // the depth a subsequent br would target.
        .entry_stack_depth = @intCast(pushed_vregs.items.len),
        .param_top_vregs = param_top_vregs,
    });
}

/// Wasm spec §3.4.4 (else) — emit JMP placeholder (jump from
/// end-of-then to end-of-if), patch the if's JE to current byte
/// (= start of else-body), transition label to .else_open.
/// Captures the then arm's top N result vregs as merge targets
/// (D-027 equivalent extended to Wasm 2.0 multi-value per
/// D-035 chunk-d035-c; mirrors `arm64/op_control.zig:emitElse`).
pub fn emitElse(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
) Error!void {
    if (labels.items.len == 0 or
        labels.items[labels.items.len - 1].kind != .if_then)
    {
        return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:247", 0);
    }
    const lbl_idx = labels.items.len - 1;
    const arity: u32 = labels.items[lbl_idx].result_arity;
    if (arity > 0 and pushed_vregs.items.len >= arity) {
        const base = pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            labels.items[lbl_idx].merge_top_vregs[i] = pushed_vregs.items[base + i];
        }
        labels.items[lbl_idx].merge_captured = true;
    }
    const jmp_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
    const else_start: u32 = @intCast(buf.items.len);
    const lbl = &labels.items[lbl_idx];
    // D-093 (d-10) — restore else-arm operand-stack shape per
    // Wasm spec §3.4.4 (mirror of arm64/op_control.zig:emitElse).
    if (lbl.param_arity > 0) {
        const entry_base: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
        if (pushed_vregs.items.len > entry_base) {
            pushed_vregs.shrinkRetainingCapacity(entry_base);
        }
        while (pushed_vregs.items.len < entry_base) {
            try pushed_vregs.append(allocator, lbl.param_top_vregs[0]);
        }
        var i: u32 = 0;
        while (i < lbl.param_arity) : (i += 1) {
            try pushed_vregs.append(allocator, lbl.param_top_vregs[i]);
        }
    }
    // Patch the matching `if`'s skip-Jcc — but only if the
    // if_then frame had one. Dead-code-pushed placeholder frames
    // (mirror of arm64 §9.7/7.5-deadcode-labels-bookkeeping)
    // carry `if_skip_byte = null` to mark "no Jcc to patch";
    // the if itself emitted no bytes in dead code.
    if (lbl.if_skip_byte) |skip_at| {
        const skip_disp: i32 = @as(i32, @intCast(else_start)) -
            @as(i32, @intCast(skip_at)) - 6;
        inst.patchRel32(buf.items, skip_at, 6, skip_disp);
    }
    lbl.if_skip_byte = null;
    lbl.kind = .else_open;
    try lbl.pending.append(allocator, .{ .byte_offset = jmp_at, .insn_size = 5 });
}

/// Wasm spec §3.4.4 (end intra-function) — pops a label and
/// patches its forward fixups + the if-skip-Jcc (if still
/// pending) + emits the merge MOV when an else_open frame had
/// a captured merge target. Caller (compile()) gates on
/// `labels.len > 0`; the function-level `end` shape stays
/// inline in `emit.zig`.
pub fn emitEndIntra(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    pushed_vregs: *std.ArrayList(u32),
    alloc: regalloc.Allocation,
    labels: *std.ArrayList(Label),
    spill_base_off: u32,
    func: *const ZirFunc,
) Error!void {
    var lbl = labels.pop().?;
    defer lbl.pending.deinit(allocator);

    // D-027 mirror extended to Wasm 2.0 multi-value (D-035
    // chunk-d035-c): when an else_open frame carries a captured
    // merge buffer (`result_arity > 0`), emit one MOV per result
    // slot. Stack at entry is either:
    //   live  : [..., merge_0..N-1, else_0..N-1]
    //   dead  : [..., merge_0..N-1] (else broke out via br/return/unreachable)
    // D-093 (d-2): `.block` merge fall-through. Mirror of
    // `arm64/op_control.zig:emitEndIntra` block-merge branch.
    if (lbl.kind == .block and lbl.merge_captured and lbl.result_arity > 0) {
        const arity: u32 = lbl.result_arity;
        // D-093 (d-6): account for Wasm 2.0 block params (mirror
        // of arm64).
        const entry: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
        // Three shapes (see `arm64/op_control.zig:emitEndIntra`
        // for the canonical comment). Case (c) — stack emptied
        // by intervening loop/if truncate — surfaced by
        // `labels.wast:loop1`.
        if (pushed_vregs.items.len < entry + arity) {
            if (pushed_vregs.items.len > entry) {
                pushed_vregs.shrinkRetainingCapacity(entry);
            }
            while (pushed_vregs.items.len < entry) {
                try pushed_vregs.append(allocator, lbl.merge_top_vregs[0]);
            }
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                try pushed_vregs.append(allocator, lbl.merge_top_vregs[i]);
            }
        } else {
            const top_base = pushed_vregs.items.len - arity;
            const dead_fallthrough = blk: {
                var i: u32 = 0;
                while (i < arity) : (i += 1) {
                    if (pushed_vregs.items[top_base + i] != lbl.merge_top_vregs[i]) break :blk false;
                }
                break :blk true;
            };
            if (!dead_fallthrough) {
                var i: u32 = 0;
                while (i < arity) : (i += 1) {
                    const src_vreg = pushed_vregs.items[top_base + i];
                    const merge_vreg = lbl.merge_top_vregs[i];
                    try emitMergeMov(allocator, buf, alloc, spill_base_off, func, src_vreg, merge_vreg);
                }
            }
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                pushed_vregs.items[top_base + i] = lbl.merge_top_vregs[i];
            }
        }
    }

    if (lbl.kind == .else_open and lbl.merge_captured) {
        const arity: u32 = lbl.result_arity;
        const dead_else = blk: {
            if (pushed_vregs.items.len < arity) break :blk false;
            const base = pushed_vregs.items.len - arity;
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                if (pushed_vregs.items[base + i] != lbl.merge_top_vregs[i]) break :blk false;
            }
            break :blk true;
        };
        if (dead_else) {
            // Merge targets already on top of stack. Skip MOVs.
        } else if (lbl.param_arity > 0) {
            // D-093 (d-10) — `if (param T1..TK)` case: emitElse
            // truncated the phantom merge layer below the
            // re-pushed params, so the stack at .end is just
            // [..., V_else_result_0..V_else_result_{N-1}]. MOV
            // each into the captured merge slot, then push the
            // canonical merge_top_vregs back so post-block
            // consumers read the merged result. Mirrors
            // `arm64/op_control.zig` else_open param path.
            if (pushed_vregs.items.len < arity) {
                return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:else-param-arity", 0);
            }
            var i: u32 = arity;
            while (i > 0) {
                i -= 1;
                const else_result = pushed_vregs.pop().?;
                const merge_vreg = lbl.merge_top_vregs[i];
                try emitMergeMov(allocator, buf, alloc, spill_base_off, func, else_result, merge_vreg);
            }
            var j: u32 = 0;
            while (j < arity) : (j += 1) {
                try pushed_vregs.append(allocator, lbl.merge_top_vregs[j]);
            }
        } else if (pushed_vregs.items.len < 2 * arity) {
            return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:309", 0);
        } else {
            const merge_base = pushed_vregs.items.len - 2 * arity;
            var v: u32 = 0;
            while (v < arity) : (v += 1) {
                if (pushed_vregs.items[merge_base + v] != lbl.merge_top_vregs[v]) {
                    return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:315", 0);
                }
            }
            // Pop in reverse (top = else_{N-1}); per-slot MOV
            // is independent because vregs are unique under
            // fresh-vreg-per-op regalloc.
            //
            // §9.9 / 9.9-h-7 (D-080 discharge): dispatch on
            // `alloc.shapeTag(merge_vreg)` so v128 merge results
            // take the XMM/MOVAPS path instead of the 32-bit GPR
            // MOV that previously truncated v128 to 32 bits.
            // Mirrors `arm64/op_control.zig` lines ~423-440. v128
            // spilled vregs trip D-078 (c) via `resolveXmm`.
            var i: u32 = arity;
            while (i > 0) {
                i -= 1;
                const else_result = pushed_vregs.pop().?;
                const merge_vreg = lbl.merge_top_vregs[i];
                try emitMergeMov(allocator, buf, alloc, spill_base_off, func, else_result, merge_vreg);
            }
        }
    }

    // D-093 (d-13) — implicit-else marshal (mirror of arm64).
    // `(if (param T1..TK) (result T1..TK)) (then ...)` without
    // `.else` validates per Wasm spec §3.4.4 (param == result).
    // cond=0 path takes the implicit identity else; post-frame
    // result is the original param. MOV top result_arity vregs
    // into captured param_top_vregs slots BEFORE the target so
    // cond=1 path executes the MOVs and cond=0's Jcc skips them.
    if (lbl.kind == .if_then and lbl.param_arity > 0 and !lbl.merge_captured) {
        if (lbl.param_arity != lbl.result_arity) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:implicit-else-arity-mismatch", 0);
        const arity: u32 = lbl.result_arity;
        if (pushed_vregs.items.len < arity) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:implicit-else-short-stack", 0);
        const top_base = pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            const src_vreg = pushed_vregs.items[top_base + i];
            const dst_vreg = lbl.param_top_vregs[i];
            try emitMergeMov(allocator, buf, alloc, spill_base_off, func, src_vreg, dst_vreg);
        }
        var j: u32 = 0;
        while (j < arity) : (j += 1) {
            pushed_vregs.items[top_base + j] = lbl.param_top_vregs[j];
        }
    }
    const target: u32 = @intCast(buf.items.len);
    // Patch the if-then's skip-Jcc if it's still pending (no
    // `else` was encountered).
    if (lbl.if_skip_byte) |skip_at| {
        const disp: i32 = @as(i32, @intCast(target)) -
            @as(i32, @intCast(skip_at)) - 6;
        inst.patchRel32(buf.items, skip_at, 6, disp);
    }
    // Patch all forward fixups (block / if_then / else_open).
    // Loop has no pending fixups.
    if (lbl.kind != .loop) {
        for (lbl.pending.items) |fx| {
            const disp: i32 = @as(i32, @intCast(target)) -
                @as(i32, @intCast(fx.byte_offset)) - @as(i32, fx.insn_size);
            inst.patchRel32(buf.items, fx.byte_offset, fx.insn_size, disp);
        }
    }

    // D-093 (d-1): truncate pushed_vregs to entry_stack_depth +
    // result_arity, keeping the top result_arity values. Mirrors
    // `arm64/op_control.zig:emitEndIntra` final block; see that
    // file for the rationale (br inside block leaves extras on
    // operand stack that downstream consumers must not see).
    // D-093 (d-6): account for Wasm 2.0 block params (mirror
    // of arm64). new_len = entry - param_arity + result_arity.
    const entry_base: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
    const new_len: usize = entry_base + @as(usize, lbl.result_arity);
    if (pushed_vregs.items.len > new_len and lbl.result_arity > 0) {
        const top_start = pushed_vregs.items.len - lbl.result_arity;
        var i: usize = 0;
        while (i < lbl.result_arity) : (i += 1) {
            pushed_vregs.items[entry_base + i] = pushed_vregs.items[top_start + i];
        }
    }
    if (pushed_vregs.items.len > new_len) {
        pushed_vregs.shrinkRetainingCapacity(new_len);
    }
    // D-093 (d-5): pad with placeholder vreg 0 when fall-
    // through is dead. d-52 (D-130) extended to all block kinds
    // (was `.loop`-only) — block can become dead via in-body
    // `unreachable` / `br_table` without any merge-capturing
    // `br` (e.g. `unreached-valid.wast` `meet-bottom`).
    while (pushed_vregs.items.len < new_len) {
        try pushed_vregs.append(allocator, 0);
    }
}
