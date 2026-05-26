//! ARM64 tail-call emit helpers (ADR-0112 D2 + D3).
//!
//! Separate from `op_call.zig` per ADR-0112 D2: regular `call`
//! returns to the caller (LR-restored on RET); tail-call
//! consumes the caller's frame and BR-jumps without LR
//! preserving caller's LR for the callee's eventual RET (which
//! returns to caller's caller). Mixing the two shapes in one
//! file would invite single_slot_dual_meaning drift across
//! Phase 11+ work.
//!
//! Per ADR-0112 D3 the full tail-call emit sequence is:
//!
//!   (1) marshal args → X1..X7 / V0..V7   (caller frame still live)
//!   (2) load callee_rt → X0              (from caller's literal pool)
//!   (3) load callee_entry → X16
//!   (4) frame_teardown.emit(…)           (caller's frame disappears)
//!   (5) BR X16                           (no LR; callee RETs to caller's caller)
//!
//! This file currently lands step (5) — `emitTailJump` — as the
//! observable foundation. Subsequent chunks layer on:
//!   10.TC-3e: callee target load + frame_teardown integration
//!             + per-op-file wire-up into collected_arm64_ops.
//!   10.TC-3f: cross_module_tail_call.zig (ADR-0112 D4).
//!
//! INVARIANT (ADR-0112 D7): the segment from frame_teardown
//! start through the BR X16 contains NO allocator calls, NO
//! host-call dispatches, NO signal-check branches. This file
//! is the natural home for that invariant's audit.
//!
//! Spec: Wasm Core 3.0 §3.3.8.18-20 (tail-call proposal).
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const gpr = @import("gpr.zig");
const abi = @import("abi.zig");
const ctx_mod = @import("ctx.zig");
const op_call = @import("op_call.zig");
const frame_teardown = @import("../shared/frame_teardown.zig");
const canonical_type = @import("../shared/canonical_type.zig");
const zir = @import("../../../ir/zir.zig");

/// X16 — the AAPCS64 intra-procedure-call scratch (IP0) per
/// Arm IHI 0055 §6.4. ADR-0066 § (bridge thunk) already uses
/// X16 as the callee-target-load register; tail-call reuses
/// the same convention so the regalloc layer's pinned-cohort
/// stays a single set.
pub const tail_target_gpr: inst.Xn = 16;

/// Emit step (2) of the ADR-0112 D3 tail-call sequence for
/// the SAME-MODULE case: restore X0 = runtime_ptr so the
/// callee's prologue (which does `MOV X19, X0` per ADR-0017
/// sub-2d-ii) sees the correct runtime pointer. For
/// same-module tail-call, caller_rt == callee_rt and X19 is
/// already correct, so we simply `MOV X0, X19` (encoded as
/// `ORR X0, XZR, X19` per the canonical AAPCS64 idiom).
///
/// Cross-module tail-call (ADR-0112 D4 / 10.TC-3f follow-on)
/// loads callee_rt from the caller's literal pool instead;
/// that path lives in `cross_module_tail_call.zig`.
pub fn emitLoadCalleeRtSameModule(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
) !void {
    // ORR X0, XZR, X19  ≡  MOV X0, X19 (the canonical move
    // between two GPRs in the AAPCS64 encoding — XZR is reg 31).
    try gpr.writeU32(allocator, buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
}

/// Emit step (5) of the ADR-0112 D3 tail-call sequence: the
/// `BR X16` unconditional branch to the callee entry. Caller
/// MUST have already loaded the callee target into X16 and
/// emitted `frame_teardown.emit(...)` immediately above this
/// (the safepoint-free invariant per ADR-0112 D7).
///
/// `target` is parameterised (default `tail_target_gpr` = 16)
/// so future tests can verify the encoder against alternate
/// targets without polluting the call sites.
pub fn emitTailJump(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    target: inst.Xn,
) !void {
    try gpr.writeU32(allocator, buf, inst.encBr(target));
}

/// Same-module direct tail-call alternative to the BR X16 path:
/// emit a `B 0` placeholder + register a `CallFixup{is_tail=true}`
/// so the post-emit linker patches the imm26 to a PC-relative B
/// (0x14...) targeting the callee body. Refinement of ADR-0112
/// D4 (not deviation): D4 prescribes BR X16 for the cross-module
/// case where the callee target isn't reachable by imm26; for
/// same-module direct the linker has the offset and a single B
/// (one instr) is structurally equivalent to load-then-BR-X16.
///
/// Caller MUST have:
///   (1) marshalled args into X1..X7 / V0..V7,
///   (2) emitted `emitLoadCalleeRtSameModule` (X0 ← X19),
///   (3) emitted `frame_teardown.emit(...)` (caller's frame gone).
/// This helper emits step (5) of the D3 sequence; step (3) is
/// elided because the linker materialises the target directly
/// into the B instruction's imm26.
pub fn emitDirectTailJump(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    call_fixups: *std.ArrayList(ctx_mod.CallFixup),
    target_func_idx: u32,
) !void {
    const fixup_at: u32 = @intCast(buf.items.len);
    try gpr.writeU32(allocator, buf, inst.encB(0));
    try call_fixups.append(allocator, ctx_mod.CallFixup{
        .byte_offset = fixup_at,
        .target_func_idx = target_func_idx,
        .is_tail = true,
    });
}

/// Wasm spec 3.0 §3.3.8.18 (tail-call proposal) — `return_call N`.
/// Orchestrates the ADR-0112 D3 sequence for the same-module
/// direct case:
///   (1) marshal args via `op_call.marshalCallArgs` (X1..X7 + V0..V7),
///   (2) restore X0 = X19 via `emitLoadCalleeRtSameModule`,
///   (3) `frame_teardown.emit(frame_bytes)` (caller's frame gone),
///   (4) `emitDirectTailJump(target_func_idx)` (B + CallFixup).
///
/// Step (3) of D3 (load callee_entry → X16) is elided here because
/// the linker materialises the callee body offset directly into the
/// B instruction's imm26 — saving one instruction over the BR X16
/// path. Cross-module / indirect / ref tail-calls (which can't
/// reach via imm26) take the BR X16 path through follow-on chunks.
///
/// Import-as-callee is rejected (UnsupportedOp) for now: a host
/// import call doesn't follow v2's prologue convention and can't
/// be tail-called via this same-module path. Per ADR-0112 D4 the
/// cross-module bridge-tail-call shape is a separate chunk
/// (10.TC-3f) and the import-tail-call subset would route through
/// there or its own thunk.
pub fn emitDirectReturnCall(
    ctx: *ctx_mod.EmitCtx,
    ins: *const zir.ZirInstr,
) ctx_mod.Error!void {
    if (ins.payload >= ctx.func_sigs.len) return ctx_mod.Error.AllocationMissing;
    if (ins.payload < ctx.num_imports) return ctx_mod.Error.UnsupportedOp;
    const callee_sig: zir.FuncType = ctx.func_sigs[ins.payload];

    try op_call.marshalCallArgs(ctx, callee_sig);
    try emitLoadCalleeRtSameModule(ctx.allocator, ctx.buf);
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{ .frame_bytes = ctx.frame_bytes });
    try emitDirectTailJump(ctx.allocator, ctx.buf, ctx.call_fixups, @intCast(ins.payload));
}

/// Wasm spec 3.0 §3.3.8.19 (tail-call proposal) —
/// `return_call_indirect type_idx tableidx`. Mirror of
/// `op_call.emitCallIndirect` minus the captureCallResult tail,
/// with frame_teardown inserted between funcptr load and BR X16.
///
/// Restrictions in this initial wiring:
///   - `table_idx == 0` only (single-table fast path; multi-table
///     follow-on chunk). `ins.extra > 0` → `UnsupportedOp`.
///   - `results.len <= 2` (no MEMORY-class return-buffer dance;
///     the tail-called frame inherits the caller's X8 if any).
///
/// Sequence:
///   (1) pop idx vreg, marshal args (caller's frame still live
///       for outgoing-args stack region),
///   (2) bounds check (CMP W17, W25 ; B.HS cind_bounds_fixup) —
///       trap stub does full epilogue+RET, caller's frame OK,
///   (3) sig check (LDR W16, [X24, X17, LSL #2] ; CMP imm ;
///       B.NE cind_sig_fixup),
///   (4) funcptr load (LDR X16, [X26, X17, LSL #3]),
///   (5) MOV X0, X19 (emitLoadCalleeRtSameModule),
///   (6) frame_teardown.emit (caller's frame gone),
///   (7) BR X16 (emitTailJump).
///
/// NOT-a-safepoint invariant (ADR-0112 D7): the bounds+sig
/// branches both target the trap stub (which does its own
/// epilogue); the path from teardown to BR X16 has no allocator
/// / host-call / signal-check branch.
pub fn emitIndirectReturnCall(
    ctx: *ctx_mod.EmitCtx,
    ins: *const zir.ZirInstr,
) ctx_mod.Error!void {
    if (ins.payload >= ctx.module_types.len) return ctx_mod.Error.AllocationMissing;
    const callee_sig: zir.FuncType = ctx.module_types[ins.payload];
    const table_idx: u32 = ins.extra;
    if (table_idx != 0) return ctx_mod.Error.UnsupportedOp;
    if (callee_sig.results.len > 2) return ctx_mod.Error.UnsupportedOp;

    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const idx_vreg = ctx.pushed_vregs.pop().?;

    std.debug.print("[D-185] emitIndirectReturnCall entry buf.len={d} (%4={d}) sizeof(ZirInstr)={d} alignof(ZirInstr)={d}\n", .{ ctx.buf.items.len, ctx.buf.items.len % 4, @sizeOf(zir.ZirInstr), @alignOf(zir.ZirInstr) });

    try op_call.marshalCallArgs(ctx, callee_sig);
    std.debug.print("[D-185] post-marshal buf.len={d} (%4={d}) idx_vreg={d}\n", .{ ctx.buf.items.len, ctx.buf.items.len % 4, idx_vreg });

    const w_idx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    std.debug.print("[D-185] post-gprLoadSpilled buf.len={d} (%4={d}) w_idx={d}\n", .{ ctx.buf.items.len, ctx.buf.items.len % 4, w_idx });
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_idx));

    const expected_typeidx: u32 = canonical_type.canonicalTypeidx(ctx.module_types, @intCast(ins.payload));
    if (expected_typeidx >= 4096) return ctx_mod.Error.UnsupportedOp;

    // Bounds: CMP W17, W25 ; B.HS trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(17, 25));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        // D-185 probe: byte alignment of cind_bounds fixup site.
        // Both hosts MUST see fixup_at % 4 == 0 (arm64 instruction
        // boundary). Divergence localises the panic source.
        std.debug.print("[D-185] cind_bounds fixup_at={d} (%4={d})\n", .{ fixup_at, fixup_at % 4 });
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.cind_bounds_fixups.append(ctx.allocator, fixup_at);
    }

    // Sig: LDR W16, [X24, X17, LSL #2] ; CMP W16, #expected ; B.NE trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrWRegLsl2(16, 24, 17));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(16, @intCast(expected_typeidx)));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        std.debug.print("[D-185] cind_sig fixup_at={d} (%4={d})\n", .{ fixup_at, fixup_at % 4 });
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0));
        try ctx.cind_sig_fixups.append(ctx.allocator, fixup_at);
    }

    // Funcptr load: LDR X16, [X26, X17, LSL #3]. X16 = tail-target
    // (per `tail_target_gpr`) — matches the BR X16 in step (7).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(tail_target_gpr, 26, 17));
    std.debug.print("[D-185] post-funcptr buf.len={d} (%4={d})\n", .{ ctx.buf.items.len, ctx.buf.items.len % 4 });

    try emitLoadCalleeRtSameModule(ctx.allocator, ctx.buf);
    std.debug.print("[D-185] post-loadCalleeRt buf.len={d} (%4={d}) ctx.frame_bytes={d}\n", .{ ctx.buf.items.len, ctx.buf.items.len % 4, ctx.frame_bytes });
    try frame_teardown.emit(ctx.allocator, ctx.buf, .{ .frame_bytes = ctx.frame_bytes });
    std.debug.print("[D-185] post-frame_teardown buf.len={d} (%4={d})\n", .{ ctx.buf.items.len, ctx.buf.items.len % 4 });
    try emitTailJump(ctx.allocator, ctx.buf, tail_target_gpr);
    std.debug.print("[D-185] post-tailJump buf.len={d} (%4={d})\n", .{ ctx.buf.items.len, ctx.buf.items.len % 4 });
}

// ---------------------------------------------------------------------
// Unit tests — byte-level snapshots for the BR encoder. These run on
// every host since the arm64 encoders are pure comptime helpers.
// ---------------------------------------------------------------------

const testing = std.testing;

test "op_tail_call arm64: emitTailJump X16 → 0xD61F0200 (canonical AAPCS64 tail-jump)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, tail_target_gpr);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 0xD61F0200), word);
}

test "op_tail_call arm64: emitTailJump X17 — alternate IP1 target (Arm IHI 0055 §6.4)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitTailJump(testing.allocator, &buf, 17);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encBr(17), word);
}

test "op_tail_call arm64: tail_target_gpr matches ADR-0066 thunk convention (X16 = IP0)" {
    try testing.expectEqual(@as(inst.Xn, 16), tail_target_gpr);
}

test "op_tail_call arm64: emitLoadCalleeRtSameModule emits MOV X0, X19 (ORR X0, XZR, X19)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try emitLoadCalleeRtSameModule(testing.allocator, &buf);
    try testing.expectEqual(@as(usize, 4), buf.items.len);
    const word = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(inst.encOrrReg(0, 31, 19), word);
}

test "op_tail_call arm64: emitLoadCalleeRtSameModule uses abi.runtime_ptr_save_gpr (X19) as source" {
    try testing.expectEqual(@as(inst.Xn, 19), abi.runtime_ptr_save_gpr);
}

test "op_tail_call arm64: emitDirectTailJump appends B 0 placeholder + is_tail=true CallFixup" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var fixups: std.ArrayList(ctx_mod.CallFixup) = .empty;
    defer fixups.deinit(testing.allocator);

    // Pre-pad the buffer so the fixup's byte_offset is non-zero
    // (better regression value than the trivial start-of-function
    // case).
    try gpr.writeU32(testing.allocator, &buf, inst.encOrrReg(0, 31, 19)); // 4-byte prelude

    try emitDirectTailJump(testing.allocator, &buf, &fixups, 7);

    // Buffer grew by exactly one 4-byte placeholder.
    try testing.expectEqual(@as(usize, 8), buf.items.len);
    const placeholder = std.mem.readInt(u32, buf.items[4..8], .little);
    try testing.expectEqual(inst.encB(0), placeholder);

    // Fixup records the right offset + target + is_tail flag.
    try testing.expectEqual(@as(usize, 1), fixups.items.len);
    try testing.expectEqual(@as(u32, 4), fixups.items[0].byte_offset);
    try testing.expectEqual(@as(u32, 7), fixups.items[0].target_func_idx);
    try testing.expectEqual(true, fixups.items[0].is_tail);
}

test "op_tail_call arm64: emitDirectTailJump byte_offset tracks pre-existing buf length" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var fixups: std.ArrayList(ctx_mod.CallFixup) = .empty;
    defer fixups.deinit(testing.allocator);

    // Three preludes — verify the fixup tracks current cursor.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try gpr.writeU32(testing.allocator, &buf, inst.encOrrReg(0, 31, 19));
    }

    try emitDirectTailJump(testing.allocator, &buf, &fixups, 0);

    try testing.expectEqual(@as(u32, 12), fixups.items[0].byte_offset);
}
