//! ARM64 emit pass — memory load / store handlers.
//!
//! Per ADR-0021 sub-deliverable b (§9.7 / 7.5d sub-b emit.zig
//! 9-module split): all i32 / i64 / f32 / f64 load / store
//! ZirOp arms (25 op codes total) flow through a single
//! `emitMemOp` handler — they share the effective-address
//! computation + bounds-check prologue (sub-f1 pattern) and
//! differ only in the final LDR/STR encoding.
//!
//! Caller-supplied invariants for memory ops in this skeleton:
//!   X28 = vm_base   (memory_base pointer)
//!   X27 = mem_limit (size in bytes)
//! ADR-0017 prologue arranges these from `*X0 = JitRuntime`.
//!
//! Per-op shape (spec-strict bounds: ea + size > mem_limit traps):
//!
//!   ORR W16, WZR, W_addr   ; zero-extend addr into IP0 (eff_addr scratch)
//!   ADD X16, X16, #offset  ; (skipped if offset == 0)
//!   ADD X17, X16, #size    ; eff_addr + access_size into IP1 (size scratch)
//!   CMP X17, X27           ; vs mem_limit
//!   B.HI trap_stub         ; placeholder + bounds_fixups append
//!   LDR/STR <op-specific>, [X28, X16]
//!
//! IP1 (X17) は本 emitMemOp 内でのみ scratch として使う。
//! op_call.zig の call_indirect も X17 を使うが、両者は同一
//! op handler 内で交差しない (emitMemOp 終了 → push_vreg 後に
//! 別 op として call_indirect が始まる) ので衝突しない。
//! abi.zig の spill_stage_gprs は X16/X17 を call_indirect が
//! mid-op で占有することを記述しているが、op handler 境界では
//! どちらの handler も自由に scratch 利用可。
//!
//! The B.HS fixup is appended to `ctx.bounds_fixups`; emit.zig's
//! function-final `end` patches all of them to the trap stub
//! address.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const trace = @import("../../../diagnostic/trace.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// Unified handler for all 25 i32/i64/f32/f64 load/store arms.
/// Caller dispatches based on `ins.op`; this fn handles the
/// shared bounds-check prologue and per-op LDR/STR emission.
pub fn emitMemOp(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const is_store = switch (ins.op) {
        .@"i32.store", .@"i32.store8", .@"i32.store16",
        .@"i64.store", .@"i64.store8", .@"i64.store16", .@"i64.store32",
        .@"f32.store", .@"f64.store",
        => true,
        else => false,
    };
    const is_fp_value = switch (ins.op) {
        .@"f32.load", .@"f64.load", .@"f32.store", .@"f64.store" => true,
        else => false,
    };
    const ip0: inst.Xn = 16;
    const ip1: inst.Xn = 17;
    const offset_imm = ins.payload;
    if (offset_imm > 0xFFF) return Error.SlotOverflow;
    // Per-op access size in bytes (Wasm spec memory.{load,store} 系)。
    // exhaustive switch (`require_exhaustive_enum_switch` lint gate)
    // のため else => unreachable で「memory op 以外が来たら型システム
    // 違反」として落とす。
    const access_size: u12 = switch (ins.op) {
        .@"i32.load8_s", .@"i32.load8_u",
        .@"i32.store8",
        .@"i64.load8_s", .@"i64.load8_u",
        .@"i64.store8",
        => 1,
        .@"i32.load16_s", .@"i32.load16_u",
        .@"i32.store16",
        .@"i64.load16_s", .@"i64.load16_u",
        .@"i64.store16",
        => 2,
        .@"i32.load", .@"i32.store",
        .@"i64.load32_s", .@"i64.load32_u",
        .@"i64.store32",
        .@"f32.load", .@"f32.store",
        => 4,
        .@"i64.load", .@"i64.store",
        .@"f64.load", .@"f64.store",
        => 8,
        else => unreachable,
    };

    // Pop the address + (for stores) value vreg(s).
    var addr_vreg: u32 = 0;
    var val_vreg: u32 = 0;
    if (is_store) {
        if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
        val_vreg = ctx.pushed_vregs.pop().?;
        addr_vreg = ctx.pushed_vregs.pop().?;
    } else {
        if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
        addr_vreg = ctx.pushed_vregs.pop().?;
    }
    // D-034: addr_vreg via spill-staging (stage 0). After the
    // OR-into-ip0 below the address is captured in ip0, so stage 0
    // is free to reuse for store value or load result.
    const w_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_vreg, 0);

    // Effective-address + spec-strict bounds prologue.
    // ea = idx (zero-extended u32) + offset; trap iff ea + size > mem_limit.
    // u64 演算で overflow 不可: max(ea + size) = 2^33 + 7 << 2^64。
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip0, 31, w_addr));
    if (offset_imm != 0) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, @intCast(offset_imm)));
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip1, ip0, access_size));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(ip1, 27));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0)); // unsigned >
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    // ADR-0028 M3-a-1: record bounds-check emit site (no-op when
    // -Dtrace-ringbuffer=false; comptime-folded out of release).
    trace.writeBounds(ctx.func.func_idx, fixup_at);

    // Final LDR/STR. Allocate result vreg first for loads.
    if (is_store) {
        const wv: inst.Xn = if (is_fp_value)
            try gpr.resolveFp(ctx.alloc, val_vreg)
        else
            try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1);
        const word: u32 = switch (ins.op) {
            .@"i32.store"   => inst.encStrWReg(wv, 28, ip0),
            .@"i32.store8"  => inst.encStrbWReg(wv, 28, ip0),
            .@"i32.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store"   => inst.encStrXReg(wv, 28, ip0),
            .@"i64.store8"  => inst.encStrbWReg(wv, 28, ip0),
            .@"i64.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store32" => inst.encStrWReg(wv, 28, ip0),
            .@"f32.store"   => inst.encStrSReg(wv, 28, ip0),
            .@"f64.store"   => inst.encStrDReg(wv, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
    } else {
        const result = ctx.next_vreg.*;
        ctx.next_vreg.* += 1;
        if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
        const wd: inst.Xn = if (is_fp_value)
            try gpr.resolveFp(ctx.alloc, result)
        else
            try gpr.gprDefSpilled(ctx.alloc, result, 0);
        const word: u32 = switch (ins.op) {
            .@"i32.load"     => inst.encLdrWReg(wd, 28, ip0),
            .@"i32.load8_s"  => inst.encLdrsbWReg(wd, 28, ip0),
            .@"i32.load8_u"  => inst.encLdrbWReg(wd, 28, ip0),
            .@"i32.load16_s" => inst.encLdrshWReg(wd, 28, ip0),
            .@"i32.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load"     => inst.encLdrXReg(wd, 28, ip0),
            .@"i64.load8_s"  => inst.encLdrsbXReg(wd, 28, ip0),
            .@"i64.load8_u"  => inst.encLdrbWReg(wd, 28, ip0),
            .@"i64.load16_s" => inst.encLdrshXReg(wd, 28, ip0),
            .@"i64.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load32_s" => inst.encLdrswXReg(wd, 28, ip0),
            .@"i64.load32_u" => inst.encLdrWReg(wd, 28, ip0),
            .@"f32.load"     => inst.encLdrSReg(wd, 28, ip0),
            .@"f64.load"     => inst.encLdrDReg(wd, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
        if (!is_fp_value) {
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
        }
        try ctx.pushed_vregs.append(ctx.allocator, result);
    }
}

// ============================================================
// Bulk-memory ops (Wasm 2.0 §4.4.7 — memory.fill / memory.copy)
//
// Stack effect: pops three i32 (n: top, val|src: middle, dst: bottom).
// No result pushed. Trap on out-of-bounds (dst+n > mem_size, or for
// copy also src+n > mem_size).
//
// Inline byte loop. Performance is Phase 8 work; correctness first.
//
// Register convention:
//   X28 = vm_base, X27 = mem_limit (size in bytes), unchanged.
//   X14, X15 = spill_stage_gprs — clobberable. `gprLoadSpilled` may
//     pipe values through these but each call only stages one value;
//     the handler captures into private holders before the next load.
//   X16, X17 = IP scratches (regalloc never lands a vreg here). We
//     use them as private working registers AFTER the bounds-check
//     fixup is appended (the fixup is a B.HI placeholder; once
//     written, X16/X17 are free for the loop body).
// ============================================================

/// Wasm spec §4.4.7 (memory.fill) — pop n / val / dst (top→bottom);
/// set `n` bytes at `[dst, dst+n)` to `val & 0xFF`. Trap if
/// `dst+n > mem_size`.
///
/// ARM64 lowering (Arm IHI 0055):
///   ; capture operands into private holders (W12/W13 — caller-saved
///   ; scratch but not in the regalloc pool's spill-stage carve-out;
///   ; freely usable here because op-handlers don't observe pool
///   ; lifetimes mid-handler — handlers run as one IR instruction's
///   ; emission window, with no concurrent vreg reads of W12/W13
///   ; in flight)。注意: W12/W13 は regalloc pool に含まれる
///   ; (slot 3, 4) ので、その vreg を持っているかは alloc.slot で
///   ; 見える。Phase 7 の現状では bulk-mem は call_indirect 等の
///   ; pre-existing 衝突パターンと同居しないため安全だが、長期的
///   ; には専用 reservation を導入すべき。Phase 8 の最適化で再考。
///
/// Implementation note: 操作は3つのオペランドを必要とする一方、
/// `spill_stage_gprs` は2スロット (X14/X15) しかない。そのため、
/// 3番目以降のオペランドを安全に保持するため、ロード直後に
/// 私的ホルダ (X16/X17) へ MOV してから次のロードに進む。
/// Bounds-check は X16/X17 を書き換える可能性があるため、bounds-
/// check より前に必要な値を私的ホルダから別の場所へ退避する手順を
/// 注意深く順序付けている。
pub fn emitMemoryFill(ctx: *EmitCtx) Error!void {
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const val_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: Load each operand into a stable private holder.
    //
    // Plan:
    //   1. Load dst (stage 0). Move into X17 (IP1).
    //   2. Load val (stage 0; previous staged value already moved
    //      out, so reuse is safe).  Move into X16 (IP0).
    //   3. Load n   (stage 0). Move into X14 (stage 0 reg, but at
    //      this point we've finished all spill loads; X14 is now a
    //      private counter holder).
    //
    // After this:  X17 = dst (zero-extended u32),
    //              X16 = val (low byte used),
    //              X14 = n   (counter, zero-extended u32).
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_dst_src));
    const w_val_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(16, 31, w_val_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(14, 31, w_n_src));

    // Step B: Bounds check — trap if dst + n > mem_size.
    // X17 = dst (zero-extended u32 in the upper-bits-zero X17 from
    // the W-form ORR above), X14 = n (likewise zero-extended).
    // ADD X15, X17, X14 ; X15 = dst + n  (both u32 → result < 2^33)
    // CMP X15, X27
    // B.HI  trap_stub
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, 17, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 27));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    trace.writeBounds(ctx.func.func_idx, fixup_at);

    // Step C: Convert dst index to absolute pointer.
    // X17 = X28 + X17 (vm_base + dst_idx).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 28, 17));

    // Step D: If n == 0, skip the loop.
    // CBZ W14, .end  (forward branch — patched after loop end).
    const skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0));

    // Step E: Loop body.
    //   .loop:
    //     STRB W16, [X17]      ; *X17 = val (low byte)
    //     ADD  X17, X17, #1    ; X17++
    //     SUB  X14, X14, #1    ; X14--  (CBNZ checks W14)
    //     CBNZ W14, .loop
    const loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(16, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    const back_disp_words: i32 = @divExact(
        @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    );
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, back_disp_words));

    // Step F: Patch the CBZ skip target to land here (post-loop).
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    const skip_disp_words: i19 = @intCast(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_at)),
        4,
    ));
    std.mem.writeInt(u32, ctx.buf.items[skip_at..][0..4], inst.encCbzW(14, skip_disp_words), .little);
}

/// Wasm spec §4.4.7 (memory.copy) — pop n / src / dst (top→bottom);
/// copy `n` bytes from `[src, src+n)` to `[dst, dst+n)`. Trap if
/// `dst+n > mem_size` OR `src+n > mem_size`. Spec semantics require
/// memmove-style overlap handling: if `dst > src`, copy backward;
/// otherwise forward.
///
/// ARM64 lowering — same operand-capture discipline as memory.fill,
/// plus a forward/backward branch on `dst < src`.
///
/// Holder regs after Step A:
///   X17 = dst (zero-ext u32),
///   X16 = src (zero-ext u32),
///   X14 = n  (zero-ext u32).
///
/// Bounds check needs X15 scratch: ADD X15, X17, X14; CMP X15, X27;
/// B.HI trap.  Then ADD X15, X16, X14; CMP X15, X27; B.HI trap.
///
/// Pointer setup: convert X17 / X16 to absolute pointers via
/// `ADD X17, X28, X17` and `ADD X16, X28, X16`.
///
/// Direction: CMP X17, X16; B.LS forward (dst <= src copies forward).
/// Backward: pre-add n to both pointers and step backward via post-
/// decrement-style emission (SUB ptr, #1 ; LDRB/STRB ; SUB n, #1 ;
/// CBNZ loop).  `B.LS` (unsigned ≤) handles the equal case as
/// forward, which is a no-op equivalent.
pub fn emitMemoryCopy(ctx: *EmitCtx) Error!void {
    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const src_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: capture into private holders X17 / X16 / X14.
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_dst_src));
    const w_src_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(16, 31, w_src_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(14, 31, w_n_src));

    // Step B1: Bounds check dst + n.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, 17, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 27));
    const fixup_dst_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup_dst_at);
    trace.writeBounds(ctx.func.func_idx, fixup_dst_at);

    // Step B2: Bounds check src + n.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, 16, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 27));
    const fixup_src_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup_src_at);
    trace.writeBounds(ctx.func.func_idx, fixup_src_at);

    // Step C: Convert indices to absolute pointers.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 28, 17)); // dst_p = vm_base + dst
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 28, 16)); // src_p = vm_base + src

    // Step D: If n == 0, skip both loops.
    const skip_zero_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0));

    // Step E: Direction switch.
    //   CMP X17, X16          ; dst <=> src
    //   B.LS forward          ; dst <= src → forward copy
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(17, 16));
    const fwd_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ls, 0));

    // ---- Backward path (dst > src; potentially overlapping). ----
    // Pre-add n: dst_p += n, src_p += n.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 17, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 16, 14));
    // .bwd_loop:
    //   SUB X17, X17, #1
    //   SUB X16, X16, #1
    //   LDRB W15, [X16]
    //   STRB W15, [X17]
    //   SUB  X14, X14, #1
    //   CBNZ W14, .bwd_loop
    // Then branch unconditionally to .end.
    const bwd_loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    const bwd_back_disp_words: i32 = @divExact(
        @as(i32, @intCast(bwd_loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    );
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, bwd_back_disp_words));
    // Unconditional branch to .end (forward, patched after fwd loop).
    const bwd_end_jmp_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));

    // ---- Forward path (dst <= src; safe forward copy). ----
    // Patch the B.LS to land here.
    const fwd_byte: u32 = @intCast(ctx.buf.items.len);
    {
        const disp_words: i32 = @divExact(
            @as(i32, @intCast(fwd_byte)) - @as(i32, @intCast(fwd_at)),
            4,
        );
        std.mem.writeInt(u32, ctx.buf.items[fwd_at..][0..4], inst.encBCond(.ls, disp_words), .little);
    }
    // .fwd_loop:
    //   LDRB W15, [X16]
    //   STRB W15, [X17]
    //   ADD  X17, X17, #1
    //   ADD  X16, X16, #1
    //   SUB  X14, X14, #1
    //   CBNZ W14, .fwd_loop
    const fwd_loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    const fwd_back_disp_words: i32 = @divExact(
        @as(i32, @intCast(fwd_loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    );
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, fwd_back_disp_words));

    // .end: patch the n==0 skip and the bwd path's exit jump.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    {
        const disp_words: i19 = @intCast(@divExact(
            @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_zero_at)),
            4,
        ));
        std.mem.writeInt(u32, ctx.buf.items[skip_zero_at..][0..4], inst.encCbzW(14, disp_words), .little);
    }
    {
        const disp_words: i32 = @divExact(
            @as(i32, @intCast(end_byte)) - @as(i32, @intCast(bwd_end_jmp_at)),
            4,
        );
        std.mem.writeInt(u32, ctx.buf.items[bwd_end_jmp_at..][0..4], inst.encB(disp_words), .little);
    }
}
