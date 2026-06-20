//! arm64 emit handler for `array.new_elem` — Wasm 3.0 GC §3.3.5.6.8.
//! Pop i32 offset + i32 size (size on top), allocate a `size`-element
//! array of type `ins.payload` and copy `size` ref Values from element
//! segment `ins.extra` starting at `offset` — done inside the
//! `jitGcArrayNewElem(rt, typeidx, segidx, offset, size)` trampoline
//! (returns the GcRef, or 0 on trap), so the emit is a plain 5-arg
//! marshal + CALL + trap branch on a 0 result + capture the ref. 2 → 1.
//!
//! Trivial variant of `array.new_data`: the trampoline copies each entry
//! DIRECT (it is already a u64 `Value.ref`; no LE-unpack), reusing the
//! same `elem_segments_ptr` descriptors `table.init` uses (ADR-0058
//! m-2c-init). typeidx + segidx are compile-time immediates (W1/W2 via
//! MOVZ/MOVK); offset + size are the popped operands (W3/W4). All consumed
//! before the BLR (strict `is_call`); the result ref is captured from W0
//! AFTER the call. Arg regs X0..X4 are NOT in the regalloc allocatable
//! pool, so the marshal has no parallel-move hazard.
//!
//! Lowering: MOV W3 = offset; MOV W4 = size; MOV X0, X19 (rt); MOVZ/MOVK
//! W1 = typeidx; MOVZ/MOVK W2 = segidx; MOVZ/MOVK X16 = &jitGcArrayNewElem;
//! BLR X16 → W0 = ref/0. CMP W0, #0 ; B.EQ → trap stub; else capture W0.

const meta = @import("../../../../../instruction/wasm_3_0/array_new_elem.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &jitGcArrayNewElem.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const segidx: u32 = ins.extra;
    // args.lhs = offset (deeper), args.rhs = size (top), args.result = ref.
    const args = try ctx.popBinary();
    // W3 = offset; W4 = size.
    const xoff = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    if (xoff != 3) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(3, 31, xoff));
    const xsize = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    if (xsize != 4) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(4, 31, xsize));
    // X0 = rt; W1 = typeidx; W2 = segidx.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(1, @intCast(typeidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(1, @intCast((typeidx >> 16) & 0xFFFF), 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(2, @intCast(segidx & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(2, @intCast((segidx >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcArrayNewElem; BLR X16.
    const addr: u64 = @intFromPtr(&jit_abi.jitGcArrayNewElem);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(scratch, @intCast(addr & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 16) & 0xFFFF), 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 32) & 0xFFFF), 2));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 48) & 0xFFFF), 3));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));

    // Trap on result == 0 (segment OOB): CMP W0,#0 ; B.EQ → oob_memory stub
    // (kind 6), matching interp Trap.OutOfBoundsLoad — not the generic bucket.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(0, 0));
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup);

    // Capture W0 (GcRef) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(rd, 31, 0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
