//! ARM64 emit pass — control-flow handlers.
//!
//! Per ADR-0021 sub-deliverable b (§9.7 / 7.5d sub-b emit.zig
//! 9-module split): Wasm structured-control ops that push /
//! pop the per-function label stack and patch forward fixups.
//!
//! Handlers in this module:
//!   - block / loop — push a Label frame; loop captures the
//!     current buf offset for backward branches.
//!   - br / br_if — branch to label N (depth-indexed). Backward
//!     (loop) targets resolve immediately to a concrete disp;
//!     forward (block / if family) targets append a Fixup that
//!     `emitEndIntra` patches at the matching end.
//!   - br_table — linear CMP+B.NE+B chain over the in-range
//!     case targets, with an unconditional B to the default at
//!     the tail. Each case branch goes through the same
//!     forward-vs-backward dispatch as a single br.
//!   - if — pop cond, emit CBZ skip placeholder, push
//!     Label.if_then with the skip byte recorded. The skip
//!     resolves at the matching `else` (to else-body start) or
//!     `end` (to end-of-if).
//!   - else — emit B-uncond placeholder (jumps to end-of-if),
//!     patch the if's CBZ to the current byte (= else-body
//!     start), transition the label to .else_open. Captures
//!     the then arm's result vreg as the merge target per
//!     D-027 fix.
//!   - emitEndIntra — intra-function `end`: pops a label,
//!     patches its forward fixups, runs the D-027 merge MOV
//!     when an else_open frame had a captured merge target.
//!     Function-level `end` (epilogue + RET + trap stub) stays
//!     in emit.zig orchestrator.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const label_mod = @import("label.zig");
const regalloc = @import("../shared/regalloc.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;
const Label = label_mod.Label;
const Allocator = std.mem.Allocator;

/// Mirror of `Label.merge_top_vregs.len` — comptime-knowable cap
/// on Wasm 2.0 multi-value if/else result arity. Wasm spec
/// imposes no tight limit but production guests typically use
/// ≤ 4. 8 is generous and keeps the Label struct compact.
const merge_top_vregs_cap: u8 = 8;

/// D-097 / d-17 (ADR-0060 follow-up): unified merge-MOV dispatcher.
///
/// Copies `src_vreg`'s value into `merge_vreg`'s storage. Picks the
/// right register-class path:
///   - `.v128` (per `alloc.shapeTag`)  → q-form (16-byte) MOV
///   - `.fpr`  (per `regalloc.vregClassByDef`) → FMOV D (8-byte)
///   - `.gpr`  (default)                → 32-bit ORR (legacy)
///
/// Pre-d-17 only dispatched on `.v128` — FP scalar fell through
/// to GPR MOV which silently corrupted f32/f64 if-frame merges
/// because the GPR view of an FP slot is a different physical
/// register on both arm64 (X_n vs V_n) and x86_64 (RBX vs XMM8
/// etc.). compose_no_call.wat on x86_64 + the 8 x86_64-specific
/// `if.wast` residuals all traced back to this single gap.
///
/// `stage_src` / `stage_dst` index the per-class spill stage
/// register pool so concurrent loads + defs of the same class
/// never alias (R10/R11 on x86_64, X14/X15 on arm64; V29/V30
/// for FP / v128 stage on arm64; XMM14/XMM15 on x86_64).
fn emitMergeMov(
    ctx: *EmitCtx,
    src_vreg: u32,
    merge_vreg: u32,
    stage_src: u8,
    stage_dst: u8,
) Error!void {
    if (ctx.alloc.shapeTag(merge_vreg) == .v128) {
        const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, stage_src);
        const merge_v = try gpr.qDefSpilled(ctx.alloc, merge_vreg, stage_dst);
        if (merge_v != src_v) {
            try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(merge_v, src_v));
        }
        try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, merge_vreg, stage_dst);
        return;
    }
    if (regalloc.vregClassByDef(ctx.func, merge_vreg) == .fpr) {
        const src_v = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, stage_src);
        const merge_v = try gpr.fpDefSpilled(ctx.alloc, merge_vreg, stage_dst);
        if (merge_v != src_v) {
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovDReg(merge_v, src_v));
        }
        try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, merge_vreg, stage_dst);
        return;
    }
    const src_r = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, stage_src);
    const merge_r = try gpr.gprDefSpilled(ctx.alloc, merge_vreg, stage_dst);
    if (merge_r != src_r) {
        // X-form (64-bit) ORR — preserves all 64 bits. W-form would
        // truncate upper 32 bits on i64 vregs; for i32 the upper
        // bits are don't-care per AAPCS64, so X-form is safe for
        // both. (Pre-d-17 the else_open merge path used W-form
        // throughout — load-bearing for i32 corpus but quietly
        // wrong for i64. The implicit-else path d-13 had to
        // re-derive the same fix locally; the unified merge
        // helper now applies it everywhere.)
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(merge_r, 31, src_r));
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, merge_vreg, stage_dst);
}

/// Block-merge mechanism for forward `br` / `br_if` to a
/// `block (result T..)` target. Mirrors the if/else
/// `merge_top_vregs` mechanism (D-027 + D-035 chunk-d035-c)
/// extended to `.block` per D-093 (d-2).
///
/// On the FIRST forward branch to a block label with
/// `result_arity > 0`, captures the top `arity` vregs as the
/// canonical merge target. No MOV is emitted: the captured
/// vregs ARE the merge target (the operand stack is already
/// in the right slots).
///
/// On SUBSEQUENT forward branches, emits `arity` MOVs from
/// the current top `arity` vregs into the captured merge
/// target's physical registers, so all paths through the
/// block end on the same regs. Post-block consumers then
/// read from `merge_top_vregs`.
///
/// Returns `true` when MOVs were emitted (caller is a second-
/// or-later br/br_if and must structure its branch
/// accordingly — br_if wraps MOVs+B inside a CBZ skip so
/// the fall-through path doesn't run them).
///
/// No-op when the target is not `.block` or `result_arity ==
/// 0` (legacy single-arm shapes).
fn captureOrEmitBlockMergeMov(ctx: *EmitCtx, tgt_idx: usize) Error!bool {
    const arity: u32 = ctx.labels.items[tgt_idx].result_arity;
    if (arity == 0) return false;
    // D-096 / d-17: br inside if-arm targets the if-frame. The br
    // skips past .end so the .end merge MOV never runs; the br
    // must carry the value into the if-frame's result slot itself.
    // Same shape as block-target br: capture top vregs on first br,
    // MOV from current top on subsequent brs (after .else has
    // captured merge_top_vregs).
    const kind = ctx.labels.items[tgt_idx].kind;
    if (kind != .block and kind != .if_then and kind != .else_open) return false;
    if (ctx.pushed_vregs.items.len < arity) return Error.AllocationMissing;

    if (!ctx.labels.items[tgt_idx].merge_captured) {
        const base = ctx.pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            ctx.labels.items[tgt_idx].merge_top_vregs[i] = ctx.pushed_vregs.items[base + i];
        }
        ctx.labels.items[tgt_idx].merge_captured = true;
        return false;
    }

    const base = ctx.pushed_vregs.items.len - arity;
    var i: u32 = 0;
    while (i < arity) : (i += 1) {
        const src_vreg = ctx.pushed_vregs.items[base + i];
        const merge_vreg = ctx.labels.items[tgt_idx].merge_top_vregs[i];
        try emitMergeMov(ctx, src_vreg, merge_vreg, 1, 0);
    }
    return true;
}

/// Unpack `(param_arity, result_arity)` from a block-open
/// ZirInstr's `extra` field. Per lower.zig's `readBlockArity`
/// the packing is `(params << 8) | results`, both u8.
fn unpackBlockArity(extra: u32) struct { params: u8, results: u8 } {
    return .{
        .params = @intCast((extra >> 8) & 0xFF),
        .results = @intCast(extra & 0xFF),
    };
}

/// `block` — push a forward-resolving label frame.
pub fn emitBlock(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const ar = unpackBlockArity(ins.extra);
    if (ar.results > merge_top_vregs_cap) return Error.UnsupportedOp;
    try ctx.labels.append(ctx.allocator, .{
        .kind = .block,
        .target_byte_offset = 0, // unknown until matching `end`
        .pending = .empty,
        .result_arity = ar.results,
        .param_arity = ar.params,
        .entry_stack_depth = @intCast(ctx.pushed_vregs.items.len),
    });
}

/// `loop` — push a backward-resolving label frame; capture the
/// current buf offset as the loop entry.
pub fn emitLoop(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const ar = unpackBlockArity(ins.extra);
    if (ar.results > merge_top_vregs_cap) return Error.UnsupportedOp;
    if (ar.params > merge_top_vregs_cap) return Error.UnsupportedOp;
    // D-099 / d-24: capture the loop's entry param vregs. At a
    // backward `br $l` (or `br_if $l`), top `param_arity` vregs
    // are the NEW values for the next iteration; emit needs to
    // MOV those into the captured param vreg slots BEFORE the
    // back-branch so the loop body's first ops (which read the
    // param vreg slots) see the next-iter values.
    var param_top: [merge_top_vregs_cap]u32 = undefined;
    if (ar.params > 0 and ctx.pushed_vregs.items.len >= ar.params) {
        const base = ctx.pushed_vregs.items.len - ar.params;
        var i: u32 = 0;
        while (i < ar.params) : (i += 1) {
            param_top[i] = ctx.pushed_vregs.items[base + i];
        }
    }
    try ctx.labels.append(ctx.allocator, .{
        .kind = .loop,
        .target_byte_offset = @intCast(ctx.buf.items.len),
        .pending = .empty,
        .result_arity = ar.results,
        .param_arity = ar.params,
        .entry_stack_depth = @intCast(ctx.pushed_vregs.items.len),
        .param_top_vregs = param_top,
    });
}

/// D-093 (d-11) — marshal function results into AAPCS64 result
/// registers (X0..X7 / V0..V7) before a function-level
/// br / br_if / end. Walks `func.sig.results` in order; per-
/// class index maps the i-th result to Xi/Vi (independent
/// GPR / FP counters). Top N vregs on pushed_vregs are the
/// results (deepest = result[0], top = result[N-1]). Stack
/// overflow (>8 results per class) → UnsupportedOp.
///
/// **No parallel-move hazard**: allocatable pool excludes
/// X0..X7 and V0..V7 by ADR-0017's reservation, so MOV-in-
/// order is correct.
pub fn marshalFunctionReturn(ctx: *EmitCtx) Error!void {
    if (ctx.func.sig.results.len == 0) return;
    if (ctx.pushed_vregs.items.len < ctx.func.sig.results.len) return;
    var n_gpr_cap: u8 = 0;
    var n_fp_cap: u8 = 0;
    for (ctx.func.sig.results) |rt| switch (rt) {
        .i32, .i64, .funcref, .externref => n_gpr_cap += 1,
        .f32, .f64, .v128 => n_fp_cap += 1,
    };
    if (n_gpr_cap > 8 or n_fp_cap > 8) return Error.UnsupportedOp;

    var n_gpr: u8 = 0;
    var n_fp: u8 = 0;
    const result_base = ctx.pushed_vregs.items.len - ctx.func.sig.results.len;
    for (ctx.func.sig.results, 0..) |result_kind, i| {
        const src_vreg = ctx.pushed_vregs.items[result_base + i];
        if (src_vreg >= ctx.alloc.slots.len) {
            // D-093 (d-5): dead-fall-through placeholder; skip.
            switch (result_kind) {
                .i32, .i64, .funcref, .externref => n_gpr += 1,
                .f32, .f64, .v128 => n_fp += 1,
            }
            continue;
        }
        switch (result_kind) {
            .f32, .f64 => {
                const dst: inst.Vn = @intCast(n_fp);
                n_fp += 1;
                const src_vn = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (src_vn != dst) {
                    const base: u32 = if (result_kind == .f64) 0x1E604000 else 0x1E204000;
                    try gpr.writeU32(ctx.allocator, ctx.buf, base | (@as(u32, src_vn) << 5) | @as(u32, dst));
                }
            },
            .v128 => {
                const dst: inst_neon.Vn = @intCast(n_fp);
                n_fp += 1;
                const src_vn = try gpr.resolveFp(ctx.alloc, src_vreg);
                if (src_vn != dst) {
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(dst, src_vn));
                }
            },
            .i32, .i64, .funcref, .externref => {
                const dst: inst.Xn = @intCast(n_gpr);
                n_gpr += 1;
                const src_xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (src_xn != dst) {
                    try gpr.writeU32(ctx.allocator, ctx.buf, 0xAA0003E0 | (@as(u32, src_xn) << 16) | @as(u32, dst));
                }
            },
        }
    }
}

/// `br N` — unconditional branch to label at depth N (0 =
/// innermost). Backward (loop) targets resolve to a concrete
/// disp now; forward targets emit a placeholder + append a
/// Fixup for the matching end to patch. When `N` equals the
/// number of explicit labels, the branch targets the implicit
/// function-level block (= `return`); marshal the function's
/// result and append to `return_fixups` so the final `end`
/// patches it to the regular epilogue.
pub fn emitBr(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ins.payload == ctx.labels.items.len) {
        // br <function-depth>: equivalent to `return`.
        // Marshal top N result vregs into AAPCS64 result regs, emit
        // a B-fixup pointing at the function epilogue.
        try marshalFunctionReturn(ctx);
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try ctx.return_fixups.append(ctx.allocator, fixup_at);
        return;
    }
    if (ins.payload > ctx.labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = ctx.labels.items.len - 1 - ins.payload;
    if (ctx.labels.items[tgt_idx].kind == .loop) {
        // D-099 / d-24: Wasm 2.0 multi-value loop with params. The
        // loop's label-type is its param type (not result); a
        // backward br supplies the NEXT iteration's param values
        // on top of stack. Emit MOVs from top `param_arity` vregs
        // into the captured `param_top_vregs` (the loop body's
        // initial param vreg slots) so the next iter's body reads
        // the new values. Pre-d-24 this was a no-op (loops
        // without params worked; multi-param loops like fac-ssa
        // returned wrong values).
        const param_arity = ctx.labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and ctx.pushed_vregs.items.len >= param_arity) {
            const base = ctx.pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = ctx.pushed_vregs.items[base + i];
                const dst_vreg = ctx.labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try emitMergeMov(ctx, src_vreg, dst_vreg, 1, 0);
                }
            }
        }
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        const tgt_byte = ctx.labels.items[tgt_idx].target_byte_offset;
        const disp_words: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(disp_words, 4)));
        return;
    }
    // Forward branch (block / if_then with br inside / else_open).
    // D-093 (d-2): for `.block` with result_arity > 0, the FIRST
    // br captures top arity vregs as merge target (no MOV); a
    // SUBSEQUENT br emits MOVs from current top → merge regs so
    // both paths converge on the same physical regs.
    _ = try captureOrEmitBlockMergeMov(ctx, tgt_idx);
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = fixup_at, .kind = .b_uncond });
}

/// `br_if N` — pop cond; branch to label at depth N if non-zero.
/// When N equals the number of explicit labels, the conditional
/// branch targets the implicit function-level block (= conditional
/// `return`); CBZ skip + marshal + B epilogue placeholder.
pub fn emitBrIf(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const cond = ctx.pushed_vregs.pop().?;
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, cond, 0);
    if (ins.payload == ctx.labels.items.len) {
        // Conditional return: CBZ cond, skip ; marshal ; B
        // epilogue ; skip:
        const cbz_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
        try marshalFunctionReturn(ctx);
        const b_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try ctx.return_fixups.append(ctx.allocator, b_at);
        // Patch the CBZ to skip past the B (i.e. land at the
        // current buf end — the next instruction).
        const skip_byte: u32 = @intCast(ctx.buf.items.len);
        const cbz_disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(skip_byte)) - @as(i32, @intCast(cbz_at)), 4));
        std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbzW(wn, cbz_disp_words), .little);
        return;
    }
    if (ins.payload > ctx.labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = ctx.labels.items.len - 1 - ins.payload;
    if (ctx.labels.items[tgt_idx].kind == .loop) {
        // D-099 / d-24: loop with params — MOVs must run only when
        // cond ≠ 0 (= when the back-branch is taken). Without
        // params, fall through to the simpler CBNZ-direct shape
        // since no MOVs are needed.
        const param_arity = ctx.labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and ctx.pushed_vregs.items.len >= param_arity) {
            const cbz_at: u32 = @intCast(ctx.buf.items.len);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
            const base = ctx.pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = ctx.pushed_vregs.items[base + i];
                const dst_vreg = ctx.labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try emitMergeMov(ctx, src_vreg, dst_vreg, 1, 0);
                }
            }
            const b_at: u32 = @intCast(ctx.buf.items.len);
            const tgt_byte = ctx.labels.items[tgt_idx].target_byte_offset;
            const disp_words: i32 = @as(i32, @intCast(tgt_byte)) -
                @as(i32, @intCast(b_at));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(disp_words, 4)));
            // Patch CBZ to skip past the MOVs + B.
            const skip_byte: u32 = @intCast(ctx.buf.items.len);
            const cbz_disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(skip_byte)) - @as(i32, @intCast(cbz_at)), 4));
            std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbzW(wn, cbz_disp_words), .little);
            return;
        }
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        const tgt_byte = ctx.labels.items[tgt_idx].target_byte_offset;
        const disp_words: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(wn, @divExact(disp_words, 4)));
        return;
    }
    // Forward branch. D-093 (d-2): for `.block` with merge already
    // captured, MOVs must run only when cond ≠ 0. Wrap the MOVs +
    // B inside a CBZ-skip sequence so the fall-through path
    // (cond == 0) bypasses both. First br_if to a block (capture
    // path, no MOV) still uses the canonical CBNZ-forward shape.
    const tgt_is_block_with_capture =
        ctx.labels.items[tgt_idx].kind == .block and
        ctx.labels.items[tgt_idx].result_arity > 0 and
        ctx.labels.items[tgt_idx].merge_captured;
    if (tgt_is_block_with_capture) {
        const cbz_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
        _ = try captureOrEmitBlockMergeMov(ctx, tgt_idx);
        const b_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = b_at, .kind = .b_uncond });
        const skip_byte: u32 = @intCast(ctx.buf.items.len);
        const cbz_disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(skip_byte)) - @as(i32, @intCast(cbz_at)), 4));
        std.mem.writeInt(u32, ctx.buf.items[cbz_at..][0..4], inst.encCbzW(wn, cbz_disp_words), .little);
        return;
    }
    // First br_if to a .block: capture merge target (no MOV).
    // Other forward kinds (if_then with br inside, else_open):
    // unchanged — no merge mechanism applies.
    _ = try captureOrEmitBlockMergeMov(ctx, tgt_idx);
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(wn, 0));
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = fixup_at, .kind = .cbnz_w });
}

/// Emit a `B target_for_depth` for a single br_table case (or
/// the default tail). Backward (loop) → direct disp; forward →
/// placeholder + Fixup append. When `depth == labs.len` the
/// branch targets the implicit function-level block (= return);
/// marshal the function's result and append to return_fixups.
fn emitBranchToDepth(ctx: *EmitCtx, depth: u32) Error!void {
    if (depth == ctx.labels.items.len) {
        // br_table case targeting function-depth: same shape as
        // emitBr's return path.
        if (ctx.pushed_vregs.items.len > 0 and ctx.func.sig.results.len > 0) {
            const top_vreg = ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
            const result_kind = ctx.func.sig.results[0];
            switch (result_kind) {
                .f32, .f64 => {
                    const src_vn = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, top_vreg, 0);
                    if (src_vn != 0) {
                        const base: u32 = if (result_kind == .f64) 0x1E604000 else 0x1E204000;
                        try gpr.writeU32(ctx.allocator, ctx.buf, base | (@as(u32, src_vn) << 5));
                    }
                },
                .i32, .i64, .v128, .funcref, .externref => {
                    const src_xn = try gpr.gprLoadSpilled(
                        ctx.allocator,
                        ctx.buf,
                        ctx.alloc,
                        ctx.spill_base_off,
                        top_vreg,
                        0,
                    );
                    if (src_xn != 0) {
                        const orr_word: u32 = 0xAA0003E0 | (@as(u32, src_xn) << 16);
                        try gpr.writeU32(ctx.allocator, ctx.buf, orr_word);
                    }
                },
            }
        }
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try ctx.return_fixups.append(ctx.allocator, fixup_at);
        return;
    }
    if (depth > ctx.labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = ctx.labels.items.len - 1 - depth;
    if (ctx.labels.items[tgt_idx].kind == .loop) {
        // D-099 / d-24: mirror emitBr's loop-param MOV path.
        const param_arity = ctx.labels.items[tgt_idx].param_arity;
        if (param_arity > 0 and ctx.pushed_vregs.items.len >= param_arity) {
            const base = ctx.pushed_vregs.items.len - param_arity;
            var i: u32 = 0;
            while (i < param_arity) : (i += 1) {
                const src_vreg = ctx.pushed_vregs.items[base + i];
                const dst_vreg = ctx.labels.items[tgt_idx].param_top_vregs[i];
                if (src_vreg != dst_vreg) {
                    try emitMergeMov(ctx, src_vreg, dst_vreg, 1, 0);
                }
            }
        }
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        const tgt_byte = ctx.labels.items[tgt_idx].target_byte_offset;
        const disp_words: i32 = @as(i32, @intCast(tgt_byte)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(disp_words, 4)));
        return;
    }
    // D-093 (d-7): forward branch — same block-merge mechanism
    // as emitBr / emitBrIf. First br to a `.block` target with
    // `result_arity > 0` captures merge_top_vregs; subsequent
    // brs emit MOVs from current top → merge regs before the B
    // fixup. br_table dispatches multiple cases through this
    // helper; per-case CMP+B.NE-skip in emitBrTable is patched
    // with variable disp to cover the MOVs + B span.
    _ = try captureOrEmitBlockMergeMov(ctx, tgt_idx);
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    try ctx.labels.items[tgt_idx].pending.append(ctx.allocator, .{ .byte_offset = fixup_at, .kind = .b_uncond });
}

/// `br_table` — pop index; emit a CMP+B.NE+B chain for each
/// in-range case, then an unconditional B to the default.
///
/// ZirInstr encoding (mvp.zig:brTableOp):
///   payload = count   (number of in-range targets)
///   extra   = start   (offset into func.branch_targets)
/// branch_targets[start..start+count] = case depths
/// branch_targets[start+count]        = default depth
pub fn emitBrTable(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_vreg = ctx.pushed_vregs.pop().?;
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    const count = ins.payload;
    const start = ins.extra;
    if (count >= (@as(u32, 1) << 12)) return Error.SlotOverflow;
    const targets = ctx.func.branch_targets.items;
    if (start + count >= targets.len) return Error.UnsupportedOp;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(wn, @intCast(i)));
        // D-093 (d-7): emitBranchToDepth may now emit MOVs +
        // B (when forward target is `.block` with merge
        // already captured). Patch B.NE-skip's disp after the
        // case body lands so it covers the actual span. Pre-d-7
        // used a fixed disp of 2 words (= skip a single 4-byte
        // B). Variable disp keeps the skip correct when MOVs
        // are emitted between B.NE and the per-case B.
        const bne_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0));
        try emitBranchToDepth(ctx, targets[start + i]);
        const after: u32 = @intCast(ctx.buf.items.len);
        const disp_words: i19 = @intCast(@divExact(@as(i32, @intCast(after)) - @as(i32, @intCast(bne_at)), 4));
        std.mem.writeInt(u32, ctx.buf.items[bne_at..][0..4], inst.encBCond(.ne, disp_words), .little);
    }
    try emitBranchToDepth(ctx, targets[start + count]);
}

/// `if` — pop cond; emit `CBZ Wn, 0` placeholder that skips the
/// then-body when cond=0; push Label.if_then with the skip byte
/// recorded. The skip resolves at matching `else` (to else-body
/// start) or `end` (to end-of-if).
///
/// **Multi-result support** (D-035 chunk-d035-c): `ins.extra`
/// carries the blocktype result arity per `lower.zig:openBlock`
/// (Wasm 2.0 multi-value). The merge MOV path in emitElse /
/// emitEndIntra captures N then-arm result vregs at `else` and
/// emits N MOVs at the matching `end` to converge both arms.
/// Cap = `Label.merge_top_vregs.len`; larger surfaces as
/// `UnsupportedOp`.
pub fn emitIf(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const ar = unpackBlockArity(ins.extra);
    if (ar.results > merge_top_vregs_cap) return Error.UnsupportedOp;
    if (ar.params > merge_top_vregs_cap) return Error.UnsupportedOp;
    const cond = ctx.pushed_vregs.pop().?;
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, cond, 0);
    const skip_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
    // D-093 (d-10) — capture top `param_arity` vregs so emitElse
    // can re-push them onto the operand stack at else-arm entry
    // (Wasm spec §3.4.4 specifies the else-arm starts with the
    // same shape as the then-arm did at if-entry).
    var param_top_vregs: [merge_top_vregs_cap]u32 = undefined;
    if (ar.params > 0) {
        if (ctx.pushed_vregs.items.len < ar.params) return Error.AllocationMissing;
        const base = ctx.pushed_vregs.items.len - ar.params;
        var i: u32 = 0;
        while (i < ar.params) : (i += 1) {
            param_top_vregs[i] = ctx.pushed_vregs.items[base + i];
        }
    }
    try ctx.labels.append(ctx.allocator, .{
        .kind = .if_then,
        .target_byte_offset = 0,
        .pending = .empty,
        .if_skip_byte = skip_byte,
        .result_arity = ar.results,
        .param_arity = ar.params,
        // D-093 (d-1): entry_stack_depth measured AFTER popping
        // the if's condition vreg (matches the depth a
        // subsequent br would target).
        .entry_stack_depth = @intCast(ctx.pushed_vregs.items.len),
        .param_top_vregs = param_top_vregs,
    });
}

/// `else` — emit B-uncond placeholder (jumps from end-of-then
/// to end-of-if), patch the if's CBZ to current byte (= start
/// of else-body), transition label to .else_open. Captures the
/// then arm's top N result vregs as merge targets (D-027 fix
/// extended to Wasm 2.0 multi-value per D-035 chunk-d035-c).
pub fn emitElse(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    if (ctx.labels.items.len == 0 or
        ctx.labels.items[ctx.labels.items.len - 1].kind != .if_then)
    {
        std.debug.print("arm64/op_control: emitElse without matching if_then frame (labels.len={d}, func_idx={d})\n", .{ ctx.labels.items.len, ctx.func.func_idx });
        return Error.UnsupportedOp;
    }
    const lbl_idx = ctx.labels.items.len - 1;
    const arity: u32 = ctx.labels.items[lbl_idx].result_arity;
    if (arity > 0 and ctx.pushed_vregs.items.len >= arity) {
        const base = ctx.pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            ctx.labels.items[lbl_idx].merge_top_vregs[i] = ctx.pushed_vregs.items[base + i];
        }
        ctx.labels.items[lbl_idx].merge_captured = true;
    }
    const b_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    const else_start: u32 = @intCast(ctx.buf.items.len);
    const lbl = &ctx.labels.items[lbl_idx];
    // D-093 (d-10) — restore else-arm operand-stack shape. Wasm
    // spec §3.4.4: the else-arm starts with the if-frame's param
    // types pushed back onto the stack (same view the then-arm
    // had at entry). Truncate to `entry_stack_depth - param_arity`
    // (= state BEFORE params were placed), then push the captured
    // `param_top_vregs` back.
    if (lbl.param_arity > 0) {
        const entry_base: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
        if (ctx.pushed_vregs.items.len > entry_base) {
            ctx.pushed_vregs.shrinkRetainingCapacity(entry_base);
        }
        while (ctx.pushed_vregs.items.len < entry_base) {
            // Defensive — should not fire (validator guarantees
            // the operand-stack depth at .else matches the
            // entry-base + result_arity shape); padding here
            // preserves the entry-base invariant if a future
            // validator change drifts.
            try ctx.pushed_vregs.append(ctx.allocator, lbl.param_top_vregs[0]);
        }
        var i: u32 = 0;
        while (i < lbl.param_arity) : (i += 1) {
            try ctx.pushed_vregs.append(ctx.allocator, lbl.param_top_vregs[i]);
        }
    }
    // Patch the matching `if`'s CBZ skip — but only if the
    // if_then frame had one. Dead-code-pushed placeholder
    // frames (§9.7 / 7.5-deadcode-labels-bookkeeping) carry
    // `if_skip_byte = null` to mark "no CBZ to patch"; in
    // that case the if itself never emitted bytes, so the
    // skip-patch step is a no-op.
    if (lbl.if_skip_byte) |skip_byte| {
        const skip_disp: i32 = @as(i32, @intCast(else_start)) -
            @as(i32, @intCast(skip_byte));
        const orig_cbz = std.mem.readInt(u32, ctx.buf.items[skip_byte..][0..4], .little);
        const cbz_rt: inst.Xn = @intCast(orig_cbz & 0x1F);
        const new_cbz = inst.encCbzW(cbz_rt, @divExact(skip_disp, 4));
        std.mem.writeInt(u32, ctx.buf.items[skip_byte..][0..4], new_cbz, .little);
    }
    lbl.if_skip_byte = null;
    lbl.kind = .else_open;
    try lbl.pending.append(ctx.allocator, .{ .byte_offset = b_byte, .kind = .b_uncond });
}

/// Intra-function `end`: pops a label, patches its forward
/// fixups, runs the D-027 merge MOV when an else_open frame had
/// a captured merge target. Caller (emit.zig) gates on
/// `ctx.labels.items.len > 0`; the function-level `end` shape
/// (epilogue + RET + trap stub) stays inline in compile().
pub fn emitEndIntra(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    var lbl = ctx.labels.pop().?;
    defer lbl.pending.deinit(ctx.allocator);

    // D-027 fix (sub-7.5c-vi) extended to Wasm 2.0 multi-value
    // (D-035 chunk-d035-c): when an else_open frame carries a
    // captured merge buffer (`result_arity > 0`), emit one MOV
    // per result slot before the join label so both arms
    // converge on the same physical regs. Stack at entry is
    // either:
    //   live  : [..., merge_0, ..., merge_{N-1}, else_0, ..., else_{N-1}]
    //   dead  : [..., merge_0, ..., merge_{N-1}]
    //           (else arm broke out via br / return / unreachable)
    // D-093 (d-2): `.block` merge fall-through. When at least one
    // forward br/br_if captured a merge target during the block
    // body, the fall-through `end` must MOV the current top arity
    // vregs into the captured merge regs (live fall-through case);
    // or skip MOVs when the top vregs already ARE the merge target
    // (dead fall-through — every path exited via br). After this
    // step the canonical block result on the operand stack is the
    // merge_top_vregs (not the fall-through top), so post-block
    // consumers read from a stable vreg regardless of which path
    // ran at runtime.
    if (lbl.kind == .block and lbl.merge_captured and lbl.result_arity > 0) {
        const arity: u32 = lbl.result_arity;
        // D-093 (d-6): block-with-params consumed `param_arity`
        // entry-time values; canonical post-block stack base
        // is `entry - param_arity`.
        const entry: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
        // Three shapes at block-end fall-through:
        //   (a) Live fall-through  — pushed_vregs.len >= entry +
        //       arity and top arity differ from merge_top_vregs.
        //       Emit MOVs from top → merge regs.
        //   (b) Dead fall-through  — pushed_vregs.len >= entry +
        //       arity and top arity == merge_top_vregs (the br
        //       that captured the merge target left them on top).
        //       Skip MOVs.
        //   (c) Dead fall-through with operand-stack emptied —
        //       pushed_vregs.len < entry + arity. An intervening
        //       end (loop / if) truncated below the block's
        //       fall-through height. The br that captured the
        //       merge already populated merge_top_vregs's slots
        //       at runtime (via fresh emit of source-vreg-into-
        //       merge-slot or by the first-br capture being its
        //       own merge); no MOV emit needed. Grow
        //       pushed_vregs to [...entry, merge_top_vregs] so
        //       post-block consumers see the canonical result.
        //       Surfaced by `labels.wast:loop1` (br $exit inside
        //       if-then inside loop inside block; loop's truncate
        //       emptied the stack at loop-end, leaving block-end
        //       with 0 entries but arity=1).
        if (ctx.pushed_vregs.items.len < entry + arity) {
            if (ctx.pushed_vregs.items.len > entry) {
                ctx.pushed_vregs.shrinkRetainingCapacity(entry);
            }
            // Pad up to entry with merge_top_vregs[0] as filler
            // when the stack is shorter than entry (a deeper-
            // than-expected truncate happened upstream; preserves
            // entry-base invariant for the post-block consumer).
            while (ctx.pushed_vregs.items.len < entry) {
                try ctx.pushed_vregs.append(ctx.allocator, lbl.merge_top_vregs[0]);
            }
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                try ctx.pushed_vregs.append(ctx.allocator, lbl.merge_top_vregs[i]);
            }
        } else {
            const top_base = ctx.pushed_vregs.items.len - arity;
            const dead_fallthrough = blk: {
                var i: u32 = 0;
                while (i < arity) : (i += 1) {
                    if (ctx.pushed_vregs.items[top_base + i] != lbl.merge_top_vregs[i]) break :blk false;
                }
                break :blk true;
            };
            if (!dead_fallthrough) {
                var i: u32 = 0;
                while (i < arity) : (i += 1) {
                    const src_vreg = ctx.pushed_vregs.items[top_base + i];
                    const merge_vreg = lbl.merge_top_vregs[i];
                    try emitMergeMov(ctx, src_vreg, merge_vreg, 1, 0);
                }
            }
            // Overwrite top arity slots with merge_top_vregs so the
            // downstream truncate (and consumers reading via
            // pushed_vregs) see the canonical merge result.
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                ctx.pushed_vregs.items[top_base + i] = lbl.merge_top_vregs[i];
            }
        }
    }

    if (lbl.kind == .else_open and lbl.merge_captured) {
        const arity: u32 = lbl.result_arity;
        const dead_else = blk: {
            if (ctx.pushed_vregs.items.len < arity) break :blk false;
            const base = ctx.pushed_vregs.items.len - arity;
            var i: u32 = 0;
            while (i < arity) : (i += 1) {
                if (ctx.pushed_vregs.items[base + i] != lbl.merge_top_vregs[i]) {
                    break :blk false;
                }
            }
            break :blk true;
        };
        if (dead_else) {
            // Merge targets already on top of stack from the
            // then arm. Skip MOVs; B fixups patched below.
        } else if (lbl.param_arity > 0) {
            // D-093 (d-10) — `if (param T1..TK)` case: emitElse
            // truncated the phantom V_then_result below the
            // re-pushed params, so at .end the stack is just
            // [..., V_else_result_0 .. V_else_result_{N-1}].
            // MOV else-results into the captured merge slots
            // (= V_then_result vregs); the truncate at line 730+
            // collapses pushed_vregs to `entry_base + arity` and
            // back-fills the canonical merge_top_vregs into the
            // top slots. Mirrors the param=0 path's MOV+swap
            // shape, just without the "verify merge_base" check
            // (no phantom layer to verify against).
            if (ctx.pushed_vregs.items.len < arity) {
                std.debug.print("arm64/op_control: emitEndIntra (param else_open) needs >={d} pushed_vregs, got {d} (func_idx={d})\n", .{ arity, ctx.pushed_vregs.items.len, ctx.func.func_idx });
                return Error.UnsupportedOp;
            }
            var i: u32 = arity;
            while (i > 0) {
                i -= 1;
                const else_result = ctx.pushed_vregs.pop().?;
                const merge_vreg = lbl.merge_top_vregs[i];
                try emitMergeMov(ctx, else_result, merge_vreg, 1, 0);
            }
            // Push back canonical merge_top_vregs so the post-block
            // consumer reads the merged result.
            var j: u32 = 0;
            while (j < arity) : (j += 1) {
                try ctx.pushed_vregs.append(ctx.allocator, lbl.merge_top_vregs[j]);
            }
        } else if (ctx.pushed_vregs.items.len < 2 * arity) {
            std.debug.print("arm64/op_control: emitEndIntra (else_open merge) needs >={d} pushed_vregs, got {d} (func_idx={d})\n", .{ 2 * arity, ctx.pushed_vregs.items.len, ctx.func.func_idx });
            return Error.UnsupportedOp;
        } else {
            // Verify the slot below the else-results is the
            // captured merge buffer. Mismatch surfaces as
            // UnsupportedOp (matches single-result behaviour).
            const merge_base = ctx.pushed_vregs.items.len - 2 * arity;
            var v: u32 = 0;
            while (v < arity) : (v += 1) {
                if (ctx.pushed_vregs.items[merge_base + v] != lbl.merge_top_vregs[v]) {
                    std.debug.print("arm64/op_control: emitEndIntra merge mismatch at slot {d} — top vreg={d}, merge={d} (func_idx={d})\n", .{ v, ctx.pushed_vregs.items[merge_base + v], lbl.merge_top_vregs[v], ctx.func.func_idx });
                    return Error.UnsupportedOp;
                }
            }
            // D-038 discharge: spill-aware merge MOV. Convention:
            //   stage 0 = merge dest (def-then-store)
            //   stage 1 = else-arm operand load
            // For the unspilled common case both calls return home
            // regs and the store helper is a no-op. Pop in reverse
            // (top = else_{N-1}); MOVs are independent so order
            // doesn't matter for correctness, but reverse-pop
            // matches the natural top-of-stack consumption.
            //
            // §9.9 / 9.9-f-3: per-slot type dispatch — when the
            // merge target is v128 (per `alloc.shapeTag`), use the
            // q* helpers + `encMovV16B` so the full 128 bits move.
            // Pre-9.9-f-3 behaviour was 32-bit ORR W which silently
            // truncated v128 merges; surfaced via simd_const.386's
            // `as-block-retval` / `as-if-then-retval` exports.
            var i: u32 = arity;
            while (i > 0) {
                i -= 1;
                const else_result = ctx.pushed_vregs.pop().?;
                const merge_vreg = lbl.merge_top_vregs[i];
                try emitMergeMov(ctx, else_result, merge_vreg, 1, 0);
            }
        }
    }
    // D-093 (d-13) — implicit-else marshal. `(if (param T1..TK)
    // (result T1..TK)) (then ...)` without an `.else` validates
    // per Wasm spec §3.4.4 (params == results required). The
    // cond=0 path takes an implicit identity else; the
    // post-frame result is the original param. To honour this
    // at runtime: MOV the then-body's top `result_arity` vregs
    // into the captured `param_top_vregs` slots BEFORE the
    // target_byte. cond=1 path falls through the MOVs (writing
    // V_param.slot with the new value); cond=0 path's CBZ
    // jumps to `target_byte` AFTER the MOVs (V_param.slot still
    // has its def value).
    if (lbl.kind == .if_then and lbl.param_arity > 0 and !lbl.merge_captured) {
        if (lbl.param_arity != lbl.result_arity) return Error.UnsupportedOp;
        const arity: u32 = lbl.result_arity;
        if (ctx.pushed_vregs.items.len < arity) return Error.UnsupportedOp;
        const top_base = ctx.pushed_vregs.items.len - arity;
        var i: u32 = 0;
        while (i < arity) : (i += 1) {
            const src_vreg = ctx.pushed_vregs.items[top_base + i];
            const dst_vreg = lbl.param_top_vregs[i];
            try emitMergeMov(ctx, src_vreg, dst_vreg, 1, 0);
        }
        // Replace top arity vregs with param_top_vregs so post-if
        // consumers read the canonical merged slot.
        var j: u32 = 0;
        while (j < arity) : (j += 1) {
            ctx.pushed_vregs.items[top_base + j] = lbl.param_top_vregs[j];
        }
    }
    const target_byte: u32 = @intCast(ctx.buf.items.len);
    // Patch the if-then's skip-CBZ if it's still pending (no
    // `else` was encountered).
    if (lbl.if_skip_byte) |skip_byte| {
        const disp: i32 = @as(i32, @intCast(target_byte)) -
            @as(i32, @intCast(skip_byte));
        const orig = std.mem.readInt(u32, ctx.buf.items[skip_byte..][0..4], .little);
        const rt: inst.Xn = @intCast(orig & 0x1F);
        const new_cbz = inst.encCbzW(rt, @divExact(disp, 4));
        std.mem.writeInt(u32, ctx.buf.items[skip_byte..][0..4], new_cbz, .little);
    }
    // Patch all forward br fixups that targeted this label
    // (block, if_then with br inside, else_open including the
    // else-end B). Loop labels have no pending fixups.
    if (lbl.kind == .block or lbl.kind == .if_then or lbl.kind == .else_open) {
        for (lbl.pending.items) |fx| {
            const disp_words: i32 = @as(i32, @intCast(target_byte)) -
                @as(i32, @intCast(fx.byte_offset));
            const new_word: u32 = switch (fx.kind) {
                .b_uncond => inst.encB(@divExact(disp_words, 4)),
                .cbnz_w => blk: {
                    const orig = std.mem.readInt(u32, ctx.buf.items[fx.byte_offset..][0..4], .little);
                    const rt: inst.Xn = @intCast(orig & 0x1F);
                    break :blk inst.encCbnzW(rt, @divExact(disp_words, 4));
                },
            };
            std.mem.writeInt(u32, ctx.buf.items[fx.byte_offset..][0..4], new_word, .little);
        }
    }

    // D-093 (d-1): truncate pushed_vregs to entry_stack_depth +
    // result_arity, keeping the top result_arity values. When a
    // br inside the block left extra vregs on the operand stack
    // (e.g. `block (result i32) (i32.const 4) (i32.const 8)
    // (br 0)`: stack = [pre, V_four, V_eight] but block result
    // is just V_eight), the extras must be discarded so the
    // post-block consumer reads the correct vregs. For the
    // simple fall-through case (no br) the stack already has
    // exactly `entry + result_arity` entries; the truncation is
    // a no-op. For if/else with merge MOVs (else_open branch
    // above), the merge already aligned pushed_vregs to the
    // canonical merge target vregs, so this final truncation
    // collapses the redundant else-arm slots into a single
    // result slot.
    // D-093 (d-6): account for Wasm 2.0 block params. The
    // block's body consumed `param_arity` values from the
    // entry-time operand stack (they were on top at block-open),
    // so the post-block height is
    // `entry_stack_depth - param_arity + result_arity`. Pre-d-6
    // the truncate used `entry + result`, which over-counted
    // when the block had params (block:param tests).
    const entry_base: usize = @as(usize, lbl.entry_stack_depth) -| @as(usize, lbl.param_arity);
    const new_len: usize = entry_base + @as(usize, lbl.result_arity);
    if (ctx.pushed_vregs.items.len > new_len and lbl.result_arity > 0) {
        const top_start = ctx.pushed_vregs.items.len - lbl.result_arity;
        var i: usize = 0;
        while (i < lbl.result_arity) : (i += 1) {
            ctx.pushed_vregs.items[entry_base + i] = ctx.pushed_vregs.items[top_start + i];
        }
    }
    if (ctx.pushed_vregs.items.len > new_len) {
        ctx.pushed_vregs.shrinkRetainingCapacity(new_len);
    }
    // D-093 (d-5): `.loop` fall-through dead — pad with
    // placeholder vreg 0 so the downstream post-loop pop
    // doesn't underflow. Restricted to `.loop` because
    // block/if dead-fall-through is already handled by the
    // merge-MOV mechanism (d-2 / d-4 cases) or by the natural
    // operand-stack invariant (live fall-through always
    // produces exactly `new_len` entries).
    if (lbl.kind == .loop) {
        while (ctx.pushed_vregs.items.len < new_len) {
            try ctx.pushed_vregs.append(ctx.allocator, 0);
        }
    }
}
