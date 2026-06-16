//! arm64 emit handler for `br_on_cast` / `br_on_cast_fail` — Wasm 3.0 GC
//! §3.3.5.5 / §4.4.5. PEEK the top reftype operand (it STAYS on the stack:
//! the branch carries the narrowed ref to the label, and the fall-through
//! keeps it), test whether it is an instance of the target heap-type `ht2`
//! via the `jitGcRefTest(rt, ref, ht2|nullbit)` trampoline, then conditionally
//! branch to the label at `payload` depth — `br_on_cast` branches on match,
//! `br_on_cast_fail` on NON-match (the bool is inverted first).
//!
//! The branch body is the shared `op_control.branchOnReg` (extracted from
//! `emitBrIf`, Cycle A `7a44f910`). It reads the condition reg FIRST in each
//! of its 5 cases, so W0 (the cast bool; ∉ regalloc pool) survives the merge
//! MOVs. The ref stays as `pushed_vregs` top → branchOnReg's
//! captureOrEmitBlockMergeMov carries it to the label result (= the narrowed
//! ref, br_on_cast's label block-type result).
//!
//! D-453 ZirInstr: `payload = labelidx | (ht2_encoded << 32)`, `extra =
//! flags`. `ht2 = payload >> 32` (the full TARGET heap-type — idx ≥ 64
//! representable), `ht2_nullable = flags bit1 = (extra&0x02)!=0`. Null folds
//! inside the trampoline (arg2 bit 0x4000_0000). ht1 (the source type) is
//! validator-only and dropped at lower time. The label depth handed to the
//! shared `branchOnReg` is the low 32 bits of `payload` (a masked copy).
//!
//! `br_on_cast` and `br_on_cast_fail` share this `emit` (the sense is read
//! from `ins.op`); `br_on_cast_fail.zig` re-exports it (mirror ref_test_null).

const meta = @import("../../../../../instruction/wasm_3_0/br_on_cast.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const op_control = @import("../../op_control.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &jitGcRefTest.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    if (ctx.pushed_vregs.items.len < 1) return ctx_mod.Error.AllocationMissing;
    const is_fail = ins.op == .br_on_cast_fail;
    const ht2: u32 = @truncate(ins.payload >> 32);
    const ht2_nullable = (ins.extra & 0x02) != 0;
    const arg2: u32 = ht2 | (if (ht2_nullable) @as(u32, 0x4000_0000) else 0);

    // PEEK the ref (do NOT pop — it stays as the block-result top vreg that
    // branchOnReg's merge carries to the label, and that fall-through keeps).
    const src = ctx.pushed_vregs.items[ctx.pushed_vregs.items.len - 1];
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src, 0);
    // X1 = ref (64-bit reftype value); X0 = rt; W2 = ht2|nullbit.
    if (xsrc != 1) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, xsrc));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(2, @intCast(arg2 & 0xFFFF)));
    if (arg2 >> 16 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(2, @intCast((arg2 >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcRefTest; BLR X16 → W0 = 0/1.
    const addr: u64 = @intFromPtr(&jit_abi.jitGcRefTest);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(scratch, @intCast(addr & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 16) & 0xFFFF), 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 32) & 0xFFFF), 2));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 48) & 0xFFFF), 3));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));

    // br_on_cast_fail: invert W0 = (W0 == 0) ? 1 : 0 so branchOnReg (which
    // branches when the cond reg is non-zero) takes the branch on NON-match.
    if (is_fail) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(0, 0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(0, .eq));
    }

    // Conditional branch on the cast bool in W0 (= register 0). The shared
    // branchOnReg reads `ins.payload` as the label depth; D-453 packs ht2
    // into payload bits 32+, so hand it a copy masked to the low 32 (labelidx).
    var br_ins = ins.*;
    br_ins.payload = @as(u32, @truncate(ins.payload));
    try op_control.branchOnReg(ctx, &br_ins, 0);
}
