//! arm64 emit handler for `array.copy` — Wasm 3.0 GC §3.3.5.6.14.
//! Pop dst GcRef + dst i32 offset + src GcRef + src i32 offset + i32 len
//! (len on top), trap if either ref null OR either range OOB, else copy
//! `len` element slots src→dst (memmove-overlap semantics). The whole
//! null-check + bounds-check + overlap-aware copy runs inside the
//! `jitGcArrayCopy(rt, dst_ref, dst_off, src_ref, src_off, len)` trampoline
//! (returns 1=ok / 0=trap), so the emit is a plain 6-arg marshal + CALL +
//! trap branch on a 0 result. No result push (5 → 0).
//!
//! The two typeidx immediates (`ins.payload` = dst, `ins.extra` = src) are
//! NOT marshalled: element slots are the uniform 8 bytes (ADR-0116 §3a), so
//! the trampoline needs no typeidx (it reads each array's length from the
//! heap ArrayHeader). Dropping them keeps the call at 6 args — no 7th-arg
//! stack pass, no offset-packing. All operands consumed into arg regs
//! before the BLR (strict `is_call`); arg regs X0..X5 are NOT in the
//! regalloc allocatable pool (scratch starts at X9), so the marshal has no
//! parallel-move hazard.
//!
//! Lowering: MOV X0, X19 (rt); MOV W1 = dst_ref; MOV W2 = dst_off; MOV W3 =
//! src_ref; MOV W4 = src_off; MOV W5 = len; MOVZ/MOVK X16 = &jitGcArrayCopy;
//! BLR X16 → W0 = 1/0. Then CMP W0, #0 ; B.EQ → trap stub.

const meta = @import("../../../../../instruction/wasm_3_0/array_copy.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &jitGcArrayCopy.

pub fn emit(ctx: *ctx_mod.EmitCtx, _: *const zir.ZirInstr) ctx_mod.Error!void {
    // Operand stack: [.., dst_ref, dst_off, src_ref, src_off, len] (len top).
    if (ctx.pushed_vregs.items.len < 5) return ctx_mod.Error.AllocationMissing;
    const len_vreg = ctx.pushed_vregs.pop().?;
    const src_off_vreg = ctx.pushed_vregs.pop().?;
    const src_ref_vreg = ctx.pushed_vregs.pop().?;
    const dst_off_vreg = ctx.pushed_vregs.pop().?;
    const dst_ref_vreg = ctx.pushed_vregs.pop().?;

    // Marshal into W1=dst_ref, W2=dst_off, W3=src_ref, W4=src_off, W5=len.
    const xdr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_ref_vreg, 0);
    if (xdr != 1) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(1, 31, xdr));
    const xdo = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_off_vreg, 0);
    if (xdo != 2) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(2, 31, xdo));
    const xsr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_ref_vreg, 0);
    if (xsr != 3) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(3, 31, xsr));
    const xso = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_off_vreg, 0);
    if (xso != 4) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(4, 31, xso));
    const xln = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, len_vreg, 0);
    if (xln != 5) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(5, 31, xln));

    // X0 = rt.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    // MOVZ/MOVK X16 = &jitGcArrayCopy; BLR X16.
    // ADR-0203 D1 — helper via the rt slot ([X19+off]), not a baked imm64 (D-516 PIC).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(scratch, abi.runtime_ptr_save_gpr, jit_abi.gc_array_copy_fn_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));

    // W0: 1=ok, 0=OOB, 2=ARRAY_NULL_SENTINEL (D-293 array_oob). CMP #2 → null_reference (10);
    // CMP #0 → oob_memory (6); else (1) proceed. Matches array.get/set + interp.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(0, jit_abi.ARRAY_NULL_SENTINEL));
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, fixup);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(0, 0));
    fixup = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup);
    // array.copy is 5 → 0: no result vreg pushed.
}
