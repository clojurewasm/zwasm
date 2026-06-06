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
const build_options = @import("build_options");

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

// ADR-0077 — op-internal scratch slot bindings used by emitMemoryInit
// (the D-133 bulk handler in this file). Regalloc guarantees these
// slots are free for vregs whose live range crosses the op's PC; the
// handler body references `sx10..sx12` instead of magic numerals so
// `check_invariant_comments.sh` no longer counts them as latent
// D-133-class overlap sites. emitMemoryInit only uses the
// {X10, X11, X12} subset of {X9..X13}; the op_scratch_reservation_table
// entry still names the full {0..4} set for forward-compatibility
// with future bulk-memory ops needing more scratch.
const sx10: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[1];
const sx11: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[2];
const sx12: inst.Xn = abi.allocatable_caller_saved_scratch_gprs[3];

/// Unified handler for all 25 i32/i64/f32/f64 load/store arms.
/// Caller dispatches based on `ins.op`; this fn handles the
/// shared bounds-check prologue and per-op LDR/STR emission.
///
/// Wasm spec §4.4.7 (memory.load/store) — i32-idx memories
/// only at this layer; i64-idx memory64 wrap-check + 64-bit
/// offset materialise lands at 10.M-4b (ADR-0111 D4).
/// `MemArgExtra.memidx == 0` invariant: multi-memory routing
/// requires the instantiate-side reject lift (10.M-5+ region);
/// until then codegen sees only memory 0. The runtime assert
/// codifies the prose-only invariant per `.claude/rules/comment_as_invariant.md`.
pub fn emitMemOp(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const memarg = zir.MemArgExtra.unpack(ins.extra);
    std.debug.assert(memarg.memidx == 0);
    // ADR-0111 D4 — 2-stage gate (comptime + runtime). When the
    // build is v2.0 the i64 arm is comptime-pruned (DCE-confirmed
    // by the v0.2 `-Dwasm=v2_0` symbol-absence gate). When v3.0,
    // the runtime check selects the i32 fast-path (byte-identical
    // to pre-10.M-4b emit, per emit_test_memory.zig assertions) or
    // the i64 wrap-check path.
    if (comptime @intFromEnum(build_options.wasm_level) >= @intFromEnum(@TypeOf(build_options.wasm_level).v3_0)) {
        if (ctx.memory0_idx_type == .i64) {
            return emitMemOpI64(ctx, ins);
        }
    }
    const is_store = switch (ins.op) {
        .@"i32.store",
        .@"i32.store8",
        .@"i32.store16",
        .@"i64.store",
        .@"i64.store8",
        .@"i64.store16",
        .@"i64.store32",
        .@"f32.store",
        .@"f64.store",
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
    // §9.7 / 7.9-d-14: full 32-bit offset support. Wasm offsets are
    // u32 (max 0xFFFFFFFF). We dispatch by magnitude:
    //   - offset == 0:                no immediate add.
    //   - 0 < offset ≤ 0xFFFFFF:      ADD imm12 (lsl 12)? + ADD imm12
    //                                  (the d-6 24-bit fast path).
    //   - offset > 0xFFFFFF:           MOVZ X17 lane0 + MOVK X17 lane1
    //                                  + ADD X16, X16, X17 (this chunk).
    // The MOVZ/MOVK pair stages the offset into ip1=X17 since ip1 is
    // not yet live (the bounds-check `ADD X17, X16, #access_size`
    // emits AFTER the offset add, reusing X17 cleanly).
    // Per-op access size in bytes (Wasm spec memory.{load,store} 系)。
    // exhaustive switch (`require_exhaustive_enum_switch` lint gate)
    // のため else => unreachable で「memory op 以外が来たら型システム
    // 違反」として落とす。
    const access_size: u12 = switch (ins.op) {
        .@"i32.load8_s",
        .@"i32.load8_u",
        .@"i32.store8",
        .@"i64.load8_s",
        .@"i64.load8_u",
        .@"i32.atomic.load8_u",
        .@"i64.atomic.load8_u",
        .@"i64.store8",
        => 1,
        .@"i32.load16_s",
        .@"i32.load16_u",
        .@"i32.store16",
        .@"i64.load16_s",
        .@"i64.load16_u",
        .@"i32.atomic.load16_u",
        .@"i64.atomic.load16_u",
        .@"i64.store16",
        => 2,
        .@"i32.load",
        .@"i32.atomic.load",
        .@"i32.store",
        .@"i64.load32_s",
        .@"i64.load32_u",
        .@"i64.atomic.load32_u",
        .@"i64.store32",
        .@"f32.load",
        .@"f32.store",
        => 4,
        .@"i64.load",
        .@"i64.atomic.load",
        .@"i64.store",
        .@"f64.load",
        .@"f64.store",
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
        if (offset_imm <= 0xFFFFFF) {
            const off_high: u12 = @intCast((offset_imm >> 12) & 0xFFF);
            const off_low: u12 = @intCast(offset_imm & 0xFFF);
            if (off_high != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12Lsl12(ip0, ip0, off_high));
            }
            if (off_low != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, off_low));
            }
        } else {
            // offset > 0xFFFFFF: stage into X17 via MOVZ + MOVK then
            // ADD X16, X16, X17. Wasm offset is u32 so lanes 2/3 are
            // always zero; emit only lanes 0 and 1.
            const lane0: u16 = @truncate(offset_imm & 0xFFFF);
            const lane1: u16 = @truncate((offset_imm >> 16) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip1, lane0));
            if (lane1 != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane1, 1));
            }
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(ip0, ip0, ip1));
        }
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip1, ip0, access_size));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(ip1, 27));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0)); // unsigned >
    try ctx.oob_fixups.append(ctx.allocator, fixup_at);
    // ADR-0028 M3-a-1: record bounds-check emit site (no-op when
    // -Dtrace-ringbuffer=false; comptime-folded out of release).
    trace.writeBounds(ctx.func.func_idx, fixup_at);

    // Final LDR/STR. Allocate result vreg first for loads.
    if (is_store) {
        // D-034 spill-aware: FP value uses fpLoadSpilled (V29/V30
        // independent of the GPR stage regs holding the address);
        // GPR value uses stage 1 (stage 0 is the address holder
        // already captured into ip0).
        const wv: inst.Xn = if (is_fp_value)
            try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1)
        else
            try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1);
        const word: u32 = switch (ins.op) {
            .@"i32.store" => inst.encStrWReg(wv, 28, ip0),
            .@"i32.store8" => inst.encStrbWReg(wv, 28, ip0),
            .@"i32.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store" => inst.encStrXReg(wv, 28, ip0),
            .@"i64.store8" => inst.encStrbWReg(wv, 28, ip0),
            .@"i64.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store32" => inst.encStrWReg(wv, 28, ip0),
            .@"f32.store" => inst.encStrSReg(wv, 28, ip0),
            .@"f64.store" => inst.encStrDReg(wv, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
    } else {
        const result = ctx.next_vreg.*;
        ctx.next_vreg.* += 1;
        if (result >= ctx.alloc.slots.len) {
            std.debug.print("arm64/op_memory: load SlotOverflow func[{d}] op={s} vreg={d} >= slots.len={d}\n", .{ ctx.func.func_idx, @tagName(ins.op), result, ctx.alloc.slots.len });
            return Error.SlotOverflow;
        }
        // D-034 spill-aware: FP result def uses fpDefSpilled (V29
        // stage if spilled); GPR result def stages through X16.
        const wd: inst.Xn = if (is_fp_value)
            try gpr.fpDefSpilled(ctx.alloc, result, 0)
        else
            try gpr.gprDefSpilled(ctx.alloc, result, 0);
        const word: u32 = switch (ins.op) {
            .@"i32.load", .@"i32.atomic.load" => inst.encLdrWReg(wd, 28, ip0),
            .@"i32.load8_s" => inst.encLdrsbWReg(wd, 28, ip0),
            .@"i32.load8_u", .@"i32.atomic.load8_u" => inst.encLdrbWReg(wd, 28, ip0),
            .@"i32.load16_s" => inst.encLdrshWReg(wd, 28, ip0),
            .@"i32.load16_u", .@"i32.atomic.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load", .@"i64.atomic.load" => inst.encLdrXReg(wd, 28, ip0),
            .@"i64.load8_s" => inst.encLdrsbXReg(wd, 28, ip0),
            .@"i64.load8_u", .@"i64.atomic.load8_u" => inst.encLdrbWReg(wd, 28, ip0),
            .@"i64.load16_s" => inst.encLdrshXReg(wd, 28, ip0),
            .@"i64.load16_u", .@"i64.atomic.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load32_s" => inst.encLdrswXReg(wd, 28, ip0),
            .@"i64.load32_u", .@"i64.atomic.load32_u" => inst.encLdrWReg(wd, 28, ip0),
            .@"f32.load" => inst.encLdrSReg(wd, 28, ip0),
            .@"f64.load" => inst.encLdrDReg(wd, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
        if (is_fp_value) {
            try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
        } else {
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
        }
        try ctx.pushed_vregs.append(ctx.allocator, result);
    }
}

/// Wasm 3.0 §5.4.7 memory64 (memory.load/store with i64 idx_type).
/// Differs from `emitMemOp`'s i32 fast path in:
///   1. Address load uses X-form `encOrrReg` (full 64-bit) instead
///      of W-form `encOrrRegW` (zero-extended u32).
///   2. Offset materialise extends to 4 lanes (MOVZ + 3 MOVK)
///      when the offset spans bits 32..63 — needed because Wasm 3.0
///      memarg offset is u64.
/// All other shapes (per-op access_size, store value pop, bounds
/// check via X27 mem_limit, final LDR/STR via [X28, X16]) are
/// identical to the i32 path — the existing encoders are already
/// X-form. mem_limit (X27) is u64; the validator caps i64 memory
/// pages at 2^32 per ADR-0111 / engine/compile.zig so `ea + access_size`
/// cannot overflow u64. Per ADR-0111 D4.
///
/// This function is NOT exposed via `pub` — only `emitMemOp`'s
/// gate calls into it.
fn emitMemOpI64(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const is_store = switch (ins.op) {
        .@"i32.store",
        .@"i32.store8",
        .@"i32.store16",
        .@"i64.store",
        .@"i64.store8",
        .@"i64.store16",
        .@"i64.store32",
        .@"f32.store",
        .@"f64.store",
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
    const access_size: u12 = switch (ins.op) {
        .@"i32.load8_s",
        .@"i32.load8_u",
        .@"i32.store8",
        .@"i64.load8_s",
        .@"i64.load8_u",
        .@"i32.atomic.load8_u",
        .@"i64.atomic.load8_u",
        .@"i64.store8",
        => 1,
        .@"i32.load16_s",
        .@"i32.load16_u",
        .@"i32.store16",
        .@"i64.load16_s",
        .@"i64.load16_u",
        .@"i32.atomic.load16_u",
        .@"i64.atomic.load16_u",
        .@"i64.store16",
        => 2,
        .@"i32.load",
        .@"i32.atomic.load",
        .@"i32.store",
        .@"i64.load32_s",
        .@"i64.load32_u",
        .@"i64.atomic.load32_u",
        .@"i64.store32",
        .@"f32.load",
        .@"f32.store",
        => 4,
        .@"i64.load",
        .@"i64.atomic.load",
        .@"i64.store",
        .@"f64.load",
        .@"f64.store",
        => 8,
        else => unreachable,
    };

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
    const w_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_vreg, 0);

    // i64 ea = idx (X-form, full 64-bit) + offset. `encOrrReg`
    // copies all 64 bits (vs `encOrrRegW` which would truncate to
    // u32).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(ip0, 31, w_addr));
    if (offset_imm != 0) {
        if (offset_imm <= 0xFFFFFF) {
            const off_high: u12 = @intCast((offset_imm >> 12) & 0xFFF);
            const off_low: u12 = @intCast(offset_imm & 0xFFF);
            if (off_high != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12Lsl12(ip0, ip0, off_high));
            }
            if (off_low != 0) {
                try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, off_low));
            }
        } else {
            const lane0: u16 = @truncate(offset_imm & 0xFFFF);
            const lane1: u16 = @truncate((offset_imm >> 16) & 0xFFFF);
            const lane2: u16 = @truncate((offset_imm >> 32) & 0xFFFF);
            const lane3: u16 = @truncate((offset_imm >> 48) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip1, lane0));
            if (lane1 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane1, 1));
            if (lane2 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane2, 2));
            if (lane3 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane3, 3));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(ip0, ip0, ip1));
        }
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip1, ip0, access_size));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(ip1, 27));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup_at);
    trace.writeBounds(ctx.func.func_idx, fixup_at);

    if (is_store) {
        const wv: inst.Xn = if (is_fp_value)
            try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1)
        else
            try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val_vreg, 1);
        const word: u32 = switch (ins.op) {
            .@"i32.store" => inst.encStrWReg(wv, 28, ip0),
            .@"i32.store8" => inst.encStrbWReg(wv, 28, ip0),
            .@"i32.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store" => inst.encStrXReg(wv, 28, ip0),
            .@"i64.store8" => inst.encStrbWReg(wv, 28, ip0),
            .@"i64.store16" => inst.encStrhWReg(wv, 28, ip0),
            .@"i64.store32" => inst.encStrWReg(wv, 28, ip0),
            .@"f32.store" => inst.encStrSReg(wv, 28, ip0),
            .@"f64.store" => inst.encStrDReg(wv, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
    } else {
        const result = ctx.next_vreg.*;
        ctx.next_vreg.* += 1;
        if (result >= ctx.alloc.slots.len) {
            std.debug.print("arm64/op_memory: i64 load SlotOverflow func[{d}] op={s} vreg={d} >= slots.len={d}\n", .{ ctx.func.func_idx, @tagName(ins.op), result, ctx.alloc.slots.len });
            return Error.SlotOverflow;
        }
        const wd: inst.Xn = if (is_fp_value)
            try gpr.fpDefSpilled(ctx.alloc, result, 0)
        else
            try gpr.gprDefSpilled(ctx.alloc, result, 0);
        const word: u32 = switch (ins.op) {
            .@"i32.load", .@"i32.atomic.load" => inst.encLdrWReg(wd, 28, ip0),
            .@"i32.load8_s" => inst.encLdrsbWReg(wd, 28, ip0),
            .@"i32.load8_u", .@"i32.atomic.load8_u" => inst.encLdrbWReg(wd, 28, ip0),
            .@"i32.load16_s" => inst.encLdrshWReg(wd, 28, ip0),
            .@"i32.load16_u", .@"i32.atomic.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load", .@"i64.atomic.load" => inst.encLdrXReg(wd, 28, ip0),
            .@"i64.load8_s" => inst.encLdrsbXReg(wd, 28, ip0),
            .@"i64.load8_u", .@"i64.atomic.load8_u" => inst.encLdrbWReg(wd, 28, ip0),
            .@"i64.load16_s" => inst.encLdrshXReg(wd, 28, ip0),
            .@"i64.load16_u", .@"i64.atomic.load16_u" => inst.encLdrhWReg(wd, 28, ip0),
            .@"i64.load32_s" => inst.encLdrswXReg(wd, 28, ip0),
            .@"i64.load32_u", .@"i64.atomic.load32_u" => inst.encLdrWReg(wd, 28, ip0),
            .@"f32.load" => inst.encLdrSReg(wd, 28, ip0),
            .@"f64.load" => inst.encLdrDReg(wd, 28, ip0),
            else => unreachable,
        };
        try gpr.writeU32(ctx.allocator, ctx.buf, word);
        if (is_fp_value) {
            try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
        } else {
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
    try ctx.oob_fixups.append(ctx.allocator, fixup_at);
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
    try ctx.oob_fixups.append(ctx.allocator, fixup_dst_at);
    trace.writeBounds(ctx.func.func_idx, fixup_dst_at);

    // Step B2: Bounds check src + n.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(15, 16, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(15, 27));
    const fixup_src_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup_src_at);
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

    // ---- Backward path (dst > src; potentially overlapping). Copy high→low,
    // 8 bytes/iteration while n >= 8 (LDR/STR X), then a ≤7-byte tail. D-285:
    // the prior byte-at-a-time loop made bulk copies slower than the
    // interpreter's vectorized copyForwards. ----
    // Pre-add n so X17 / X16 point one past the block end.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 17, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 16, 14));
    // .bwd_word: while (n >= 8) { dst-=8; src-=8; *dst = *src; n-=8; }
    const bwd_word_top: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(14, 8));
    const bwd_word_exit_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.lo, 0)); // B.lo .bwd_tail (fixup)
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(17, 17, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(16, 16, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(
        @as(i32, @intCast(bwd_word_top)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    )));
    // .bwd_tail: patch the B.lo to here; copy ≤7 remaining bytes high→low.
    const bwd_tail_top: u32 = @intCast(ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[bwd_word_exit_at..][0..4], inst.encBCond(.lo, @divExact(
        @as(i32, @intCast(bwd_tail_top)) - @as(i32, @intCast(bwd_word_exit_at)),
        4,
    )), .little);
    const bwd_tail_skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0)); // CBZ W14, .bwd_done (fixup)
    const bwd_tail_loop: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, @divExact(
        @as(i32, @intCast(bwd_tail_loop)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    )));
    // .bwd_done: unconditional branch to .end (patched after fwd path).
    const bwd_end_jmp_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    // Patch the no-tail CBZ to skip straight to .bwd_done (the B→.end).
    std.mem.writeInt(u32, ctx.buf.items[bwd_tail_skip_at..][0..4], inst.encCbzW(14, @divExact(
        @as(i32, @intCast(bwd_end_jmp_at)) - @as(i32, @intCast(bwd_tail_skip_at)),
        4,
    )), .little);

    // ---- Forward path (dst <= src; safe forward copy). Patch the B.LS. ----
    const fwd_byte: u32 = @intCast(ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[fwd_at..][0..4], inst.encBCond(.ls, @divExact(
        @as(i32, @intCast(fwd_byte)) - @as(i32, @intCast(fwd_at)),
        4,
    )), .little);
    // .fwd_word: while (n >= 8) { *dst = *src; dst+=8; src+=8; n-=8; }
    const fwd_word_top: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(14, 8));
    const fwd_word_exit_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.lo, 0)); // B.lo .fwd_tail (fixup)
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 8));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(@divExact(
        @as(i32, @intCast(fwd_word_top)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    )));
    // .fwd_tail: patch B.lo to here; copy ≤7 remaining bytes low→high.
    const fwd_tail_top: u32 = @intCast(ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[fwd_word_exit_at..][0..4], inst.encBCond(.lo, @divExact(
        @as(i32, @intCast(fwd_tail_top)) - @as(i32, @intCast(fwd_word_exit_at)),
        4,
    )), .little);
    const fwd_tail_skip_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0)); // CBZ W14, .end (fixup)
    const fwd_tail_loop: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(15, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(15, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, @divExact(
        @as(i32, @intCast(fwd_tail_loop)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    )));

    // .end: patch the n==0 skip, the bwd path's exit jump, and the fwd no-tail skip.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    std.mem.writeInt(u32, ctx.buf.items[skip_zero_at..][0..4], inst.encCbzW(14, @divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_zero_at)),
        4,
    )), .little);
    std.mem.writeInt(u32, ctx.buf.items[bwd_end_jmp_at..][0..4], inst.encB(@divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(bwd_end_jmp_at)),
        4,
    )), .little);
    std.mem.writeInt(u32, ctx.buf.items[fwd_tail_skip_at..][0..4], inst.encCbzW(14, @divExact(
        @as(i32, @intCast(end_byte)) - @as(i32, @intCast(fwd_tail_skip_at)),
        4,
    )), .little);
}

/// Wasm spec §4.5.3.10 (memory.init dataidx) — copy `n` bytes from
/// data segment `dataidx` at offset `src` into linear memory at
/// offset `dst`. Traps OutOfBoundsMemoryAccess on `src+n > seg.len`
/// or `dst+n > mem_limit`. When the segment was dropped, the spec
/// treats its length as 0 (any `n > 0` traps).
///
/// Register layout (caller-saved scratch only — no calls):
///   X17 = dst (then dst_p = vm_base + dst)
///   X16 = src (then src_p = seg.ptr + src)
///   X14 = n   (counter)
///   X11 = seg.ptr (preserved across bounds check)
///   X15 = seg.len (overridden to 0 if dropped)
///   X9, X10, X12 = ad-hoc temps
pub fn emitMemoryInit(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const dataidx: u32 = @intCast(ins.payload);
    // imm12 budget: LDR X-form scaled byte_off ≤ 32760 → idx ≤ 2047
    // (stride 16). LDRB imm12 ≤ 4095 → idx ≤ 4095. The 2047 bound
    // is the tighter one. Validator already bounds idx vs the
    // module's segment count; this guard only rejects encoding-
    // budget overflow.
    if (dataidx >= 2048) return Error.UnsupportedOp;

    if (ctx.pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = ctx.pushed_vregs.pop().?;
    const src_v = ctx.pushed_vregs.pop().?;
    const dst_v = ctx.pushed_vregs.pop().?;

    // Step A: capture operands into X17 / X16 / X14 (W-form copies
    // zero-extend to 64-bit; safe since Wasm i32 ops never set bit 32+).
    const w_dst_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_dst_src));
    const w_src_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(16, 31, w_src_src));
    const w_n_src = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, n_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(14, 31, w_n_src));

    // Step B: read seg.ptr (X11) + seg.len (X15) from data_segments_ptr.
    //   LDR  X10, [X19, #data_segments_ptr_off]    ; seg table base
    //   LDR  X11, [X10, #(idx*16)]                  ; seg.ptr
    //   LDR  X15, [X10, #(idx*16)+8]                ; seg.len
    const seg_byte_off: u15 = @intCast(@as(u32, dataidx) * 16);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.data_segments_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx11, 10, seg_byte_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(15, 10, seg_byte_off + 8));

    // Step C: dropped flag override. If dropped == 1, seg.len → 0.
    //   LDR  X10, [X19, #data_dropped_ptr_off]
    //   LDRB W12, [X10, #idx]
    //   CMP  W12, #0
    //   CSEL X15, X15, XZR, EQ      ; keep len when not dropped (W12==0)
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(sx10, abi.runtime_ptr_save_gpr, jit_abi.data_dropped_ptr_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(sx12, 10, @intCast(dataidx)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(sx12, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCselX(15, 15, 31, .eq));

    // Step D1: bounds — src + n > seg.len → trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(sx12, 16, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(sx12, 15));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.oob_fixups.append(ctx.allocator, fixup_at);
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step D2: bounds — dst + n > mem_limit (X27) → trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(sx12, 17, 14));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(sx12, 27));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
        try ctx.oob_fixups.append(ctx.allocator, fixup_at);
        trace.writeBounds(ctx.func.func_idx, fixup_at);
    }

    // Step E: if n == 0, skip the copy (CBZ on W14 — Wasm n is i32).
    const skip_zero_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbzW(14, 0));

    // Step F: compute absolute pointers.
    //   X17 = X28 + X17  ; dst_p = vm_base + dst
    //   X16 = X11 + X16  ; src_p = seg.ptr + src
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(17, 28, 17));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(16, 11, 16));

    // Step G: forward byte loop. memory.init's spec allows the source
    // (data segment) and destination (linear memory) to be disjoint
    // by construction — data segments live in module-owned host
    // storage, never overlapping linear memory — so a forward-only
    // copy is sufficient (unlike memory.copy which must handle
    // overlap).
    // .loop:
    //   LDRB W12, [X16]
    //   STRB W12, [X17]
    //   ADD  X16, X16, #1
    //   ADD  X17, X17, #1
    //   SUB  X14, X14, #1
    //   CBNZ W14, .loop
    const loop_start: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrbImm(sx12, 16, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrbImm(sx12, 17, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(16, 16, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(17, 17, 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubImm12(14, 14, 1));
    const back_disp_words: i32 = @divExact(
        @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ctx.buf.items.len)),
        4,
    );
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCbnzW(14, back_disp_words));

    // .end: patch the n==0 skip.
    const end_byte: u32 = @intCast(ctx.buf.items.len);
    {
        const disp_words: i19 = @intCast(@divExact(
            @as(i32, @intCast(end_byte)) - @as(i32, @intCast(skip_zero_at)),
            4,
        ));
        std.mem.writeInt(u32, ctx.buf.items[skip_zero_at..][0..4], inst.encCbzW(14, disp_words), .little);
    }
}
