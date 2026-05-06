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
