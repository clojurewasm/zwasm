//! arm64 emit handler for `array.init_data` — Wasm 3.0 GC §3.3.5.6.16.
//! Pop the array GcRef + i32 dst_off + i32 src_off + i32 len (len on top),
//! null-check + bounds-check + copy `len` natural-width elements from data
//! segment $segidx into the existing array at dst_off. The checks + copy run
//! inside the `jitGcArrayInitData(rt, segidx, ref, dst_off, src_off, len)`
//! trampoline (returns 1=ok / 0=trap), so the per-arch emit is a plain 6-arg
//! marshal + CALL + a trap branch on a 0 result. No result push (4 → 0).
//!
//! All four operands are consumed into arg registers BEFORE the BLR (strict
//! `is_call`; only vregs SPANNING it spill). Arg regs X0..X5 ∉ regalloc pool,
//! so marshalling each operand cannot clobber another's source — no parallel-
//! move hazard. The `typeidx` immediate is NOT marshalled: it won't fit the
//! 6-arg budget alongside the 4 operands + segidx, so the trampoline reads it
//! back from the array's ObjectHeader (see jitGcArrayInitData).
//!
//! Lowering: MOV X0, X19 (rt); MOVZ/MOVK W1 = segidx; MOV W2 = ref; MOV W3 =
//! dst_off; MOV W4 = src_off; MOV W5 = len; MOVZ/MOVK X16 = &jitGcArrayInitData;
//! BLR X16 → W0 = 1/0. Then CMP W0, #0 ; B.EQ → trap stub (null/OOB). Encoders:
//! Arm IHI 0055 §C6.2.34 (BLR), §C6.2.179 (MOVZ/MOVK), §C6.2.207 (ORR/MOV reg),
//! §C6.2.65 (CMP imm), §C6.2.27 (B.cond).

const meta = @import("../../../../../instruction/wasm_3_0/array_init_data.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &jitGcArrayInitData.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const segidx: u32 = ins.extra;
    // Operand stack: [.., ref, dst_off, src_off, len] (len on top). Pop reverse.
    if (ctx.pushed_vregs.items.len < 4) return ctx_mod.Error.AllocationMissing;
    const len_vreg = ctx.pushed_vregs.pop().?;
    const src_off_vreg = ctx.pushed_vregs.pop().?;
    const dst_off_vreg = ctx.pushed_vregs.pop().?;
    const ref_vreg = ctx.pushed_vregs.pop().?;

    // Marshal each operand into its arg reg (W2=ref, W3=dst_off, W4=src_off,
    // W5=len) — all i32, so the 32-bit ORR form throughout.
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ref_vreg, 0);
    // D-470 — inline null-ref check (→ null_reference, kind 10, matching interp)
    // BEFORE the call; the residual result==0 is then only the segment/array OOB.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(xref, 0));
    const null_fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, null_fixup);
    if (xref != 2) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(2, 31, xref));
    const xdst = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_off_vreg, 0);
    if (xdst != 3) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(3, 31, xdst));
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_off_vreg, 0);
    if (xsrc != 4) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(4, 31, xsrc));
    const xlen = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, len_vreg, 0);
    if (xlen != 5) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(5, 31, xlen));

    // X0 = rt; W1 = segidx.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(segidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(1, @intCast((segidx >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcArrayInitData; BLR X16.
    const addr: u64 = @intFromPtr(&jit_abi.jitGcArrayInitData);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(scratch, @intCast(addr & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 16) & 0xFFFF), 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 32) & 0xFFFF), 2));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 48) & 0xFFFF), 3));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));

    // Trap on result == 0 (segment/array OOB; null caught inline above):
    // CMP W0, #0 ; B.EQ → oob_memory stub (kind 6), matching interp.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(0, 0));
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup);
    // array.init_data is 4 → 0: no result vreg pushed.
}
