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
    tgt_idx: usize,
) Error!bool {
    const arity: u32 = labels.items[tgt_idx].result_arity;
    if (arity == 0) return false;
    if (labels.items[tgt_idx].kind != .block) return false;
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
    var i: u32 = 0;
    while (i < arity) : (i += 1) {
        const src_vreg = pushed_vregs.items[base + i];
        const merge_vreg = labels.items[tgt_idx].merge_top_vregs[i];
        if (alloc.shapeTag(merge_vreg) == .v128) {
            const src_x = try gpr.resolveXmm(alloc, src_vreg);
            const merge_x = try gpr.resolveXmm(alloc, merge_vreg);
            if (merge_x != src_x) {
                try buf.appendSlice(allocator, inst.encMovapsXmmXmm(merge_x, src_x).slice());
            }
        } else {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
            const merge_r = try gpr.gprDefSpilled(alloc, merge_vreg, 1);
            if (merge_r != src_r) {
                try buf.appendSlice(allocator, inst.encMovRR(.d, merge_r, src_r).slice());
            }
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, 1);
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
    try labels.append(allocator, .{
        .kind = .loop,
        .target_byte_offset = @intCast(buf.items.len),
        .pending = .empty,
        .result_arity = ar.results,
        .param_arity = ar.params,
        .entry_stack_depth = @intCast(pushed_vregs.items.len),
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
    depth: u32,
) Error!void {
    if (depth == labels.items.len) {
        try emitFunctionReturn(allocator, buf, alloc, pushed_vregs, spill_base_off, func, frame_bytes, uses_runtime_ptr);
        return;
    }
    if (depth > labels.items.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:78", 0);
    const tgt_idx = labels.items.len - 1 - depth;
    if (labels.items[tgt_idx].kind == .loop) {
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
    _ = try captureOrEmitBlockMergeMov(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, tgt_idx);
    const at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
    try labels.items[tgt_idx].pending.append(allocator, .{ .byte_offset = at, .insn_size = 5 });
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
) Error!void {
    if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
        const top = pushed_vregs.items[pushed_vregs.items.len - 1];
        if (top >= alloc.slots.len) return Error.SlotOverflow;
        switch (func.sig.results[0]) {
            .i32, .funcref, .externref => {
                const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, top, 0);
                if (src != abi.return_gpr) {
                    try buf.appendSlice(allocator, inst.encMovRR(.d, abi.return_gpr, src).slice());
                }
            },
            .i64 => {
                const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, top, 0);
                if (src != abi.return_gpr) {
                    try buf.appendSlice(allocator, inst.encMovRR(.q, abi.return_gpr, src).slice());
                }
            },
            .f32, .f64 => {
                const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, top, 0);
                if (src_x != abi.return_xmm) {
                    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(abi.return_xmm, src_x).slice());
                }
            },
            .v128 => return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:emitFunctionReturn-v128", 0),
        }
    }
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
    depth: u32,
) Error!void {
    if (depth >= labels.items.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:104", 0);
    const tgt_idx = labels.items.len - 1 - depth;
    if (labels.items[tgt_idx].kind == .loop) {
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
    _ = try captureOrEmitBlockMergeMov(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, tgt_idx);
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
    count: u32,
    start: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    if (count > 127) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:147", 0);
    const idx_v = pushed_vregs.pop().?;
    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);
    const targets = func.branch_targets.items;
    if (start + count >= targets.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:151", 0);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try buf.appendSlice(allocator, inst.encCmpRImm8(.d, idx_r, @intCast(i)).slice());
        // D-093 (d-7): variable-disp JNE-skip. emitBrTableJmp may
        // emit MOVs + JMP (when forward target is `.block` with
        // merge captured). Pre-d-7 used fixed disp = 5 (= skip a
        // single 5-byte JMP). Patch after emitBrTableJmp returns.
        const jne_at: usize = buf.items.len;
        try buf.appendSlice(allocator, inst.encJccRel8(.ne, 0).slice());
        const jne_size: usize = 2;
        try emitBrTableJmp(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, targets[start + i]);
        const after: usize = buf.items.len;
        const disp: usize = after - (jne_at + jne_size);
        if (disp > 127) return types.rejectUnsupported("src/engine/codegen/x86_64/op_control.zig:jne-rel8-overflow", @intCast(disp));
        buf.items[jne_at + 1] = @intCast(disp);
    }
    try emitBrTableJmp(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, targets[start + count]);
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
        try emitFunctionReturn(allocator, buf, alloc, pushed_vregs, spill_base_off, func, frame_bytes, uses_runtime_ptr);
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
        _ = try captureOrEmitBlockMergeMov(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, tgt_idx);
        const jmp_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
        try labels.items[tgt_idx].pending.append(allocator, .{ .byte_offset = jmp_at, .insn_size = 5 });
        const skip_byte: u32 = @intCast(buf.items.len);
        const je_disp: i32 = @as(i32, @intCast(skip_byte)) - @as(i32, @intCast(je_at)) - 6;
        const patched = inst.encJccRel32(.e, je_disp);
        @memcpy(buf.items[je_at .. je_at + patched.len], patched.slice());
        return;
    }
    _ = try captureOrEmitBlockMergeMov(allocator, buf, alloc, pushed_vregs, labels, spill_base_off, tgt_idx);
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
                    if (alloc.shapeTag(merge_vreg) == .v128) {
                        const src_x = try gpr.resolveXmm(alloc, src_vreg);
                        const merge_x = try gpr.resolveXmm(alloc, merge_vreg);
                        if (merge_x != src_x) {
                            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(merge_x, src_x).slice());
                        }
                    } else {
                        const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                        const merge_r = try gpr.gprDefSpilled(alloc, merge_vreg, 1);
                        if (merge_r != src_r) {
                            try buf.appendSlice(allocator, inst.encMovRR(.d, merge_r, src_r).slice());
                        }
                        try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, 1);
                    }
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
                if (alloc.shapeTag(merge_vreg) == .v128) {
                    const else_xmm = try gpr.resolveXmm(alloc, else_result);
                    const merge_xmm = try gpr.resolveXmm(alloc, merge_vreg);
                    if (merge_xmm != else_xmm) {
                        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(merge_xmm, else_xmm).slice());
                    }
                } else {
                    const else_reg = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, else_result, 0);
                    const merge_reg = try gpr.gprDefSpilled(alloc, merge_vreg, 1);
                    if (merge_reg != else_reg) {
                        try buf.appendSlice(allocator, inst.encMovRR(.d, merge_reg, else_reg).slice());
                    }
                    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, 1);
                }
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
                if (alloc.shapeTag(merge_vreg) == .v128) {
                    const else_xmm = try gpr.resolveXmm(alloc, else_result);
                    const merge_xmm = try gpr.resolveXmm(alloc, merge_vreg);
                    if (merge_xmm != else_xmm) {
                        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(merge_xmm, else_xmm).slice());
                    }
                } else {
                    // D-045 chunk 13b: spill-aware merge MOV. Stage 0
                    // (R10) carries the else_reg load when spilled;
                    // stage 1 (R11) reserves the merge_vreg def slot
                    // when spilled so the two never collide.
                    const else_reg = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, else_result, 0);
                    const merge_reg = try gpr.gprDefSpilled(alloc, merge_vreg, 1);
                    if (merge_reg != else_reg) {
                        try buf.appendSlice(allocator, inst.encMovRR(.d, merge_reg, else_reg).slice());
                    }
                    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, merge_vreg, 1);
                }
            }
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
    // D-093 (d-5): pad with placeholder vreg 0 when loop fall-
    // through is dead. Restricted to `.loop` (mirror of arm64).
    if (lbl.kind == .loop) {
        while (pushed_vregs.items.len < new_len) {
            try pushed_vregs.append(allocator, 0);
        }
    }
}
