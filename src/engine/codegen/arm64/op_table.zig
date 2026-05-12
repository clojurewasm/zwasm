//! ARM64 emit pass — `table.get` / `table.set` / `table.size`
//! handlers (§9.9 / 9.9-m-2a per ADR-0058).
//!
//! Each declared table has a `TableSlice` descriptor in the JIT
//! runtime's `tables_ptr` array (stride 16 bytes per ADR-0058);
//! the JIT body loads `refs` + `len` from the indexed descriptor
//! then performs a bounds-checked load/store against
//! `refs[idx]` (8-byte ref slot).
//!
//! Per-op shape (Wasm spec §4.4.10–12):
//!
//!   table.get x:
//!     LDR  X10, [X19, #tables_ptr_off]        ; tables_ptr
//!     LDR  X11, [X10, #(tableidx*16)]         ; refs ptr
//!     LDR  W12, [X10, #(tableidx*16)+8]       ; len
//!     ORR  W17, WZR, W_idx                    ; zero-ext idx into ip1
//!     CMP  W17, W12                           ; idx vs len
//!     B.HS trap_stub                          ; bounds_fixups
//!     LDR  Xresult, [X11, X17, LSL #3]        ; refs[idx]
//!     (store back to spill slot if needed)
//!
//!   table.set x:
//!     (same prologue + bounds check)
//!     STR  Xval, [X11, X17, LSL #3]
//!
//!   table.size x:
//!     LDR  X10, [X19, #tables_ptr_off]
//!     LDR  W_result, [X10, #(tableidx*16)+8]  ; push len as i32
//!
//! X10 / X11 / X12 / X17 are caller-saved scratch within this
//! handler (X10/X11/X12 follow op_memory's scratch convention;
//! X17 is the bounds-check scratch already used by op_memory and
//! op_call's emit paths but the handler boundaries don't overlap).
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const trace = @import("../../../diagnostic/trace.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// Wasm spec §4.4.10 (table.get) — pop i32 idx, push tables[x][idx]
/// as a reference Value (8-byte). Traps `OutOfBoundsTableAccess` on
/// idx >= table.len via the shared `bounds_fixups` channel.
///
/// Operand capture happens BEFORE the X10/X11/X12 LDR sequence
/// because the regalloc may have parked the operand vreg in
/// X9..X13 — clobbering it without snapshotting first would lose
/// the operand's value (silent miscompile mirror of the m-5 trap-
/// stub R15 prescan bug).
pub fn emitTableGet(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx = ins.payload;
    // imm12 budget for X-form LDR: byte_off scaled by 8 → max
    // tableidx for the X-form refs load = 32760/16 = 2047. For
    // the W-form len load (scaled by 4), max byte_off = 16380 →
    // tableidx ≤ (16380-8)/16 = 1023. The W-form path is tighter.
    if (tableidx >= 1024) return Error.UnsupportedOp;
    const tbl_off: u15 = @intCast(@as(u32, tableidx) * 16);

    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot idx into W17 (intra-procedure scratch, never
    // in the regalloc pool — survives the X10/X11/X12 clobbering
    // below).
    const w_idx_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_idx_src));

    // Step B: read TableSlice[tableidx]. Safe to clobber X10/X11/X12.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(10, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(11, 10, tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(12, 10, @intCast(@as(u32, tbl_off) + 8)));

    // Step C: CMP W17, W12 ; B.HS trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(17, 12));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step D: allocate the result vreg and load.
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const xd = try gpr.gprDefSpilled(ctx.alloc, result, 0);

    // LDR Xd, [X11, X17, LSL #3]
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(xd, 11, 17));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

/// Wasm spec §4.4.11 (table.set) — pop reftype value then i32 idx,
/// write `tables[x][idx] = val`. Traps `OutOfBoundsTableAccess` on
/// idx >= table.len.
pub fn emitTableSet(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx = ins.payload;
    if (tableidx >= 1024) return Error.UnsupportedOp;
    const tbl_off: u15 = @intCast(@as(u32, tableidx) * 16);

    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const val_v = ctx.pushed_vregs.pop().?;
    const idx_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot operands into intra-procedure scratch BEFORE
    // touching X10/X11/X12 (regalloc may park operand vregs in
    // X9..X13). idx → W17; val → X16 (full 64-bit ref).
    const w_idx_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_idx_src));
    const x_val_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(16, 31, x_val_src));

    // Step B: read TableSlice[tableidx].
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(10, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(11, 10, tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(12, 10, @intCast(@as(u32, tbl_off) + 8)));

    // Step C: CMP W17, W12 ; B.HS trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(17, 12));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step D: STR X16 (val), [X11 + X17 * 8] — write refs[idx].
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(16, 11, 17));
}

/// Wasm spec §4.4.12 (table.size) — push current `tables[x].len`
/// as i32. No trap conditions; the validator already rejected
/// out-of-range tableidx.
pub fn emitTableSize(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx = ins.payload;
    if (tableidx >= 1024) return Error.UnsupportedOp;
    const len_off: u14 = @intCast(@as(u32, tableidx) * 16 + 8);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(10, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));

    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const wd = try gpr.gprDefSpilled(ctx.alloc, result, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(wd, 10, len_off));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}

/// Wasm spec §4.4.14 (table.fill x) — pop n (i32), val (reftype),
/// dst (i32); write `n` copies of `val` into `tables[x][dst..dst+n]`.
/// Traps `OutOfBoundsTableAccess` if `dst+n > tables[x].len`.
///
/// Operand-capture discipline (per ADR-0058 §"Operand-capture"):
/// snapshot all three operands into intra-procedure scratch
/// (W17 = dst, X16 = val, W14 = n) BEFORE touching X10/X11/X12 for
/// the TableSlice prologue load. Skipping this surfaces as silent
/// miscompile (m-2a class bug).
pub fn emitTableFill(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tableidx = ins.payload;
    if (tableidx >= 1024) return Error.UnsupportedOp;
    const tbl_off: u15 = @intCast(@as(u32, tableidx) * 16);

    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const val_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot operands into private holders.
    //   W17 ← dst (zero-ext from i32 home)
    //   X16 ← val (full 64-bit ref)
    //   W14 ← n   (zero-ext from i32 home, used as loop counter)
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_dst_src));
    const x_val_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(16, 31, x_val_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(14, 31, w_n_src));

    // Step B: read TableSlice[tableidx]. Safe to clobber X10..X12.
    //   X10 = tables_ptr; X11 = refs; W12 = len.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(10, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(11, 10, tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(12, 10, @intCast(@as(u32, tbl_off) + 8)));

    // Step C: bounds check — trap if dst + n > len.
    //   X13 = X17 + X14  (both upper-bits zero → result fits in u33)
    //   CMP X13, X12
    //   B.HI trap
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(13, 17, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(13, 12));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step D: if n == 0, skip the loop entirely.
    const skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0));

    // Step E: forward loop. Each iteration:
    //   STR X16, [X11, X17, LSL #3]   ; refs[dst] = val
    //   ADD W17, W17, #1               ; dst++
    //   SUB W14, W14, #1               ; n--
    //   CBNZ W14, .loop
    const loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(16, 11, 17));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    const back_disp_words: i32 = @divExact(
        @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    );
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, back_disp_words));

    // Step F: patch the n==0 skip target.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    const skip_disp_words: i19 = @intCast(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_at)),
        4,
    ));
    std.mem.writeInt(u32, ctx.buf.items[skip_at..][0..4], inst.encCbzW(14, skip_disp_words), .little);
}

/// Wasm spec §4.4.15 (table.copy x y) — pop n / src / dst; copy n
/// reftype values from tables[y][src..src+n] into
/// tables[x][dst..dst+n]. Traps `OutOfBoundsTableAccess` if either
/// `dst+n > tables[x].len` or `src+n > tables[y].len`. memmove
/// semantics on overlap (only matters when x == y).
///
/// Encoding: ins.payload = dst-tableidx (x); ins.extra = src-tableidx (y).
///
/// Holder regs after Step A:
///   W17 = dst_idx, W16 = src_idx, W14 = n (counter).
///
/// Scratch reused across the handler:
///   X10 = tables_ptr (transient)
///   X11 = dst_refs  (long-lived for the copy loop)
///   X12 = src_refs  (long-lived; loaded after dst bounds check)
///   W13 = dst_len / src_len (transient, reused per bounds check)
///   X15 = ref scratch (per-iter LDR target → STR source)
pub fn emitTableCopy(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const dst_tbl = ins.payload;
    const src_tbl = ins.extra;
    if (dst_tbl >= 1024 or src_tbl >= 1024) return Error.UnsupportedOp;
    const dst_tbl_off: u15 = @intCast(@as(u32, dst_tbl) * 16);
    const src_tbl_off: u15 = @intCast(@as(u32, src_tbl) * 16);
    const same_table = (dst_tbl == src_tbl);

    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const src_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: snapshot operands into private holders.
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_dst_src));
    const w_src_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(16, 31, w_src_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(14, 31, w_n_src));

    // Step B: load tables_ptr → X10.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(10, abi.runtime_ptr_save_gpr, jit_abi.tables_ptr_off));

    // Step C1: bounds check dst_idx + n vs tables[x].len.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(11, 10, dst_tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(13, 10, @intCast(@as(u32, dst_tbl_off) + 8)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, 17, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 13));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step C2: bounds check src_idx + n vs tables[y].len.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(12, 10, src_tbl_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(13, 10, @intCast(@as(u32, src_tbl_off) + 8)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, 16, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 13));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step D: if n == 0, skip the loop entirely.
    const skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0));

    if (same_table) {
        // Step E (same-table): direction switch.
        //   CMP W17, W16 ; B.LS .fwd  (dst <= src → forward safe)
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(17, 16));
        const fwd_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ls, 0));

        // .bwd: pre-advance both indices by n (W17 += W14; W16 += W14),
        // then loop with pre-decrement of indices.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 17, 14));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 16, 14));
        const bwd_loop_start: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(17, 17, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(16, 16, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 12, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 11, 17));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
        {
            const back: i32 = @divExact(
                @as(i32, @intCast(bwd_loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
                4,
            );
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, back));
        }
        const bwd_end_jmp_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));

        // .fwd: patch the B.LS to land here.
        const fwd_byte: u32 = @intCast(ctx.buf.items.len);
        {
            const disp: i32 = @divExact(
                @as(i32, @intCast(fwd_byte)) - @as(i32, @intCast(fwd_at)),
                4,
            );
            std.mem.writeInt(u32, ctx.buf.items[fwd_at..][0..4], inst.encBCond(.ls, disp), .little);
        }
        const fwd_loop_start: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 12, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 11, 17));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
        {
            const back: i32 = @divExact(
                @as(i32, @intCast(fwd_loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
                4,
            );
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, back));
        }

        // Patch the bwd→end jump.
        const end_byte: u32 = @intCast(ctx.buf.items.len);
        {
            const disp: i32 = @divExact(
                @as(i32, @intCast(end_byte)) - @as(i32, @intCast(bwd_end_jmp_at)),
                4,
            );
            std.mem.writeInt(u32, ctx.buf.items[bwd_end_jmp_at..][0..4], inst.encB(disp), .little);
        }
    } else {
        // Different tables: no overlap possible; forward only.
        const fwd_loop_start: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(15, 12, 16));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(15, 11, 17));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
        {
            const back: i32 = @divExact(
                @as(i32, @intCast(fwd_loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
                4,
            );
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, back));
        }
    }

    // Patch the n==0 skip.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    const skip_disp: i19 = @intCast(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_at)),
        4,
    ));
    std.mem.writeInt(u32, ctx.buf.items[skip_at..][0..4], inst.encCbzW(14, skip_disp), .little);
}
