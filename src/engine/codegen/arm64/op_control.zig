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
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const label_mod = @import("label.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;
const Label = label_mod.Label;
const Allocator = std.mem.Allocator;

/// `block` — push a forward-resolving label frame.
pub fn emitBlock(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try ctx.labels.append(ctx.allocator, .{
        .kind = .block,
        .target_byte_offset = 0, // unknown until matching `end`
        .pending = .empty,
    });
}

/// `loop` — push a backward-resolving label frame; capture the
/// current buf offset as the loop entry.
pub fn emitLoop(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try ctx.labels.append(ctx.allocator, .{
        .kind = .loop,
        .target_byte_offset = @intCast(ctx.buf.items.len),
        .pending = .empty,
    });
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
        // Marshal the top-of-stack value as the function's
        // result (if the signature has one) and emit a B-fixup
        // pointing at the function epilogue.
        if (ctx.pushed_vregs.items.len > 0 and ctx.func.sig.results.len > 0) {
            const top_vreg = ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
            const result_kind = ctx.func.sig.results[0];
            switch (result_kind) {
                .f32, .f64 => {
                    const src_vn = try gpr.resolveFp(ctx.alloc, top_vreg);
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
                        // ORR Xd, XZR, Xs — alias for MOV X0, Xs.
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
    if (ins.payload > ctx.labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = ctx.labels.items.len - 1 - ins.payload;
    const tgt = &ctx.labels.items[tgt_idx];
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    if (tgt.kind == .loop) {
        const disp_words: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(disp_words, 4)));
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
        try tgt.pending.append(ctx.allocator, .{ .byte_offset = fixup_at, .kind = .b_uncond });
    }
}

/// `br_if N` — pop cond; branch to label at depth N if non-zero.
/// When N equals the number of explicit labels, the conditional
/// branch targets the implicit function-level block (= conditional
/// `return`); CBZ skip + marshal + B epilogue placeholder.
pub fn emitBrIf(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const cond = ctx.pushed_vregs.pop().?;
    const wn = try gpr.resolveGpr(ctx.alloc, cond);
    if (ins.payload == ctx.labels.items.len) {
        // Conditional return: CBZ cond, skip ; marshal ; B
        // epilogue ; skip:
        const cbz_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
        if (ctx.pushed_vregs.items.len > 0 and ctx.func.sig.results.len > 0) {
            const top_vreg = ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
            const result_kind = ctx.func.sig.results[0];
            switch (result_kind) {
                .f32, .f64 => {
                    const src_vn = try gpr.resolveFp(ctx.alloc, top_vreg);
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
    const tgt = &ctx.labels.items[tgt_idx];
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    if (tgt.kind == .loop) {
        const disp_words: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(wn, @divExact(disp_words, 4)));
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(wn, 0));
        try tgt.pending.append(ctx.allocator, .{ .byte_offset = fixup_at, .kind = .cbnz_w });
    }
}

/// Emit a `B target_for_depth` for a single br_table case (or
/// the default tail). Backward (loop) → direct disp; forward →
/// placeholder + Fixup append. Shared between the per-case loop
/// body and the trailing default branch.
fn emitBranchToDepth(
    a: Allocator,
    b: *std.ArrayList(u8),
    labs: []Label,
    depth: u32,
) Error!void {
    if (depth >= labs.len) return Error.UnsupportedOp;
    const tgt_idx = labs.len - 1 - depth;
    const tgt = &labs[tgt_idx];
    const fixup_at: u32 = @intCast(b.items.len);
    if (tgt.kind == .loop) {
        const disp_words: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
            @as(i32, @intCast(fixup_at));
        try gpr.writeU32(a, b, inst.encB(@divExact(disp_words, 4)));
    } else {
        try gpr.writeU32(a, b, inst.encB(0));
        try tgt.pending.append(a, .{ .byte_offset = fixup_at, .kind = .b_uncond });
    }
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
    const wn = try gpr.resolveGpr(ctx.alloc, idx_vreg);
    const count = ins.payload;
    const start = ins.extra;
    if (count >= (@as(u32, 1) << 12)) return Error.SlotOverflow;
    const targets = ctx.func.branch_targets.items;
    if (start + count >= targets.len) return Error.UnsupportedOp;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(wn, @intCast(i)));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 2));
        try emitBranchToDepth(ctx.allocator, ctx.buf, ctx.labels.items, targets[start + i]);
    }
    try emitBranchToDepth(ctx.allocator, ctx.buf, ctx.labels.items, targets[start + count]);
}

/// `if` — pop cond; emit `CBZ Wn, 0` placeholder that skips the
/// then-body when cond=0; push Label.if_then with the skip byte
/// recorded. The skip resolves at matching `else` (to else-body
/// start) or `end` (to end-of-if).
pub fn emitIf(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const cond = ctx.pushed_vregs.pop().?;
    const wn = try gpr.resolveGpr(ctx.alloc, cond);
    const skip_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(wn, 0));
    try ctx.labels.append(ctx.allocator, .{
        .kind = .if_then,
        .target_byte_offset = 0,
        .pending = .empty,
        .if_skip_byte = skip_byte,
    });
}

/// `else` — emit B-uncond placeholder (jumps from end-of-then
/// to end-of-if), patch the if's CBZ to current byte (= start
/// of else-body), transition label to .else_open. Captures the
/// then arm's top vreg as the merge target per D-027 fix.
pub fn emitElse(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    if (ctx.labels.items.len == 0 or
        ctx.labels.items[ctx.labels.items.len - 1].kind != .if_then)
    {
        return Error.UnsupportedOp;
    }
    const lbl_idx = ctx.labels.items.len - 1;
    if (ctx.pushed_vregs.items.len > 0) {
        ctx.labels.items[lbl_idx].merge_top_vreg = ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
    }
    const b_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    const else_start: u32 = @intCast(ctx.buf.items.len);
    const lbl = &ctx.labels.items[lbl_idx];
    const skip_byte = lbl.if_skip_byte.?;
    const skip_disp: i32 = @as(i32, @intCast(else_start)) -
        @as(i32, @intCast(skip_byte));
    const orig_cbz = std.mem.readInt(u32, ctx.buf.items[skip_byte..][0..4], .little);
    const cbz_rt: inst.Xn = @intCast(orig_cbz & 0x1F);
    const new_cbz = inst.encCbzW(cbz_rt, @divExact(skip_disp, 4));
    std.mem.writeInt(u32, ctx.buf.items[skip_byte..][0..4], new_cbz, .little);
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

    // D-027 fix (sub-7.5c-vi): if this is an else_open label
    // with a captured merge target, the else arm's result is on
    // top of pushed_vregs; emit MOV merge_reg ← else_result_reg
    // BEFORE the join label so both arms converge. Then drop
    // the else arm's result vreg (its value now lives in the
    // merge target's reg).
    if (lbl.kind == .else_open and lbl.merge_top_vreg != null) {
        if (ctx.pushed_vregs.items.len < 2) return Error.UnsupportedOp;
        const else_result = ctx.pushed_vregs.pop().?;
        const merge_vreg = lbl.merge_top_vreg.?;
        if (ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1] != merge_vreg) {
            return Error.UnsupportedOp;
        }
        const merge_reg = try gpr.resolveGpr(ctx.alloc, merge_vreg);
        const else_reg = try gpr.resolveGpr(ctx.alloc, else_result);
        if (merge_reg != else_reg) {
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(merge_reg, 31, else_reg));
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
}
