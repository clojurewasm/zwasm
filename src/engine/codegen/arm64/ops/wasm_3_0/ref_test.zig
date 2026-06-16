//! arm64 emit handler for `ref.test` / `ref.test_null` — Wasm 3.0 GC
//! §3.3.5.3. Pop one reftype operand (the full 64-bit reftype value:
//! GcRef offset / i31-tagged / funcref ptr / 0=null), push i32 (1 if the
//! value is an instance of the heap-type immediate, else 0). Done inside
//! the `jitGcRefTest(rt, ref, ht_nullbit)` trampoline, so the emit is a
//! plain 3-arg marshal + CALL + capture W0. 1 → 1. No trap.
//!
//! `ref.test` and `ref.test_null` share this handler: the null-handling
//! bit is folded into arg2 (`ht | (nullbit << 30)`), so a null ref yields
//! 0 for `ref.test` and 1 for `ref.test_null` INSIDE the trampoline —
//! emit stays straight-line. The nullbit is read from `ins.op`.
//!
//! ht (heap-type byte) is a compile-time immediate in `ins.payload`
//! (lower.zig stores one byte). The ref is the popped operand (X1, 64-bit
//! — reftypes occupy the full 8-byte slot). Arg regs X0..X2 are NOT in the
//! regalloc allocatable pool, so the marshal has no parallel-move hazard.
//!
//! Lowering: MOV X1, ref ; MOV X0, X19 (rt) ; MOVZ W2 = ht|nullbit ;
//! MOVZ/MOVK X16 = &jitGcRefTest ; BLR X16 → W0 = 0/1 ; capture W0.

const meta = @import("../../../../../instruction/wasm_3_0/ref_test.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const scratch: inst.Xn = 16; // IP0 — &jitGcRefTest.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const null_bit: u32 = if (ins.op == .@"ref.test_null") 0x4000_0000 else 0;
    // D-453 trampoline ABI: ht is the full encoded u32 (concrete-tag = bit
    // 31, idx = bits 0..29 for a tagged concrete index, else a bare wire
    // byte). The null flag is bit 30 — just below the concrete-tag, above
    // any in-range typeidx — so it never collides with the index bits.
    const arg2: u32 = @as(u32, @truncate(ins.payload)) | null_bit;
    // args.src = ref (the operand), args.result = i32.
    const args = try ctx.popUnary();
    // X1 = ref (64-bit reftype value).
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    if (xsrc != 1) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(1, 31, xsrc));
    // X0 = rt; W2 = ht|nullbit (full 32-bit: MOVZ low half + MOVK high half).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(2, @intCast(arg2 & 0xFFFF)));
    if (arg2 >> 16 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(2, @intCast((arg2 >> 16) & 0xFFFF), 1));
    // MOVZ/MOVK X16 = &jitGcRefTest; BLR X16.
    const addr: u64 = @intFromPtr(&jit_abi.jitGcRefTest);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(scratch, @intCast(addr & 0xFFFF)));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 16) & 0xFFFF), 1));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 32) & 0xFFFF), 2));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, @intCast((addr >> 48) & 0xFFFF), 3));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));

    // Capture W0 (i32 0/1) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(rd, 31, 0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
