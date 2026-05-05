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
//! Per-op shape:
//!
//!   ORR W16, WZR, W_addr   ; zero-extend addr into IP0
//!   ADD X16, X16, #offset  ; (skipped if offset == 0)
//!   CMP X16, X27           ; vs mem_limit
//!   B.HS trap_stub         ; placeholder + bounds_fixups append
//!   LDR/STR <op-specific>, [X28, X16]
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
    const offset_imm = ins.payload;
    if (offset_imm > 0xFFF) return Error.SlotOverflow;

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
    const w_addr = try gpr.resolveGpr(ctx.alloc, addr_vreg);

    // Effective-address + bounds prologue.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip0, 31, w_addr));
    if (offset_imm != 0) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, @intCast(offset_imm)));
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(ip0, 27));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);

    // Final LDR/STR. Allocate result vreg first for loads.
    if (is_store) {
        const wv: inst.Xn = if (is_fp_value)
            try gpr.resolveFp(ctx.alloc, val_vreg)
        else
            try gpr.resolveGpr(ctx.alloc, val_vreg);
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
            try gpr.resolveGpr(ctx.alloc, result);
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
        try ctx.pushed_vregs.append(ctx.allocator, result);
    }
}
