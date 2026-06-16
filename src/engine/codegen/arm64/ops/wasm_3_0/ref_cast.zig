//! arm64 emit handler for `ref.cast` — Wasm 3.0 GC §3.3.5.4 (non-null
//! target). Pop one reftype operand (the full 64-bit reftype value); trap
//! if null OR if its runtime type is not a subtype of the heap-type
//! immediate; else push the value back UNCHANGED. Done inside the
//! `jitGcRefCast(rt, ref, ht)` trampoline (returns the ref, or 0 on trap),
//! so the emit is a 3-arg marshal + CALL + trap branch on a 0 result +
//! capture the (64-bit) ref. 1 → 1.
//!
//! ht is a compile-time immediate (`ins.payload` byte). The ref is the
//! popped operand (X1, 64-bit). Arg regs X0..X2 ∉ regalloc pool → no
//! parallel-move. `0` is an unambiguous trap sentinel: a successful
//! non-null cast returns a non-zero ref, so `CMP X0,#0` (64-bit, since a
//! funcref ptr fills all 64 bits) + B.EQ → trap stub is exact.
//!
//! Lowering: MOV X1, ref ; MOV X0, X19 (rt) ; MOVZ W2 = ht ; MOVZ/MOVK
//! X16 = &jitGcRefCast ; BLR X16 → X0 = ref/0 ; CMP X0,#0 ; B.EQ → trap ;
//! else capture X0.

const meta = @import("../../../../../instruction/wasm_3_0/ref_cast.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &jitGcRefCast.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    // D-453: ht is the full encoded u32 (bit31 concrete-tag | idx, or bare byte).
    const ht: u32 = @truncate(ins.payload);
    // args.src = ref (operand), args.result = ref (unchanged on success).
    const args = try ctx.popUnary();
    // X1 = ref (64-bit reftype value).
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    if (xsrc != 1) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, xsrc));
    // X0 = rt; W2 = ht (full 32-bit: MOVZ low half + MOVK high half).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(2, @intCast(ht & 0xFFFF)));
    if (ht >> 16 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(2, @intCast((ht >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcRefCast; BLR X16.
    const addr: u64 = @intFromPtr(&jit_abi.jitGcRefCast);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(scratch, @intCast(addr & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 16) & 0xFFFF), 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 32) & 0xFFFF), 2));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 48) & 0xFFFF), 3));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));

    // Trap on result == 0 (null / type mismatch): CMP X0,#0 ; B.EQ.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(0, 0));
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.cast_fail_fixups.append(ctx.allocator, fixup); // D-293 slice-4d cast_failure (code 11)

    // Capture X0 (the cast ref, full 64-bit) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(rd, 31, 0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
