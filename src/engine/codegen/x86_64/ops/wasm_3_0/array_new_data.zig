//! x86_64 emit handler for `array.new_data` — Wasm 3.0 GC §3.3.5.6.7.
//! Mirror of the arm64 handler: pop i32 offset + i32 size, alloc a
//! `size`-element array and copy its payload from data segment `ins.extra`
//! at byte `offset` inside the `jitGcArrayNewData(rt, typeidx, segidx,
//! offset, size)` trampoline (returns the GcRef, or 0 on trap). Emit =
//! 5-arg marshal + CALL + trap branch on a 0 result + capture the ref.
//! 2 → 1.
//!
//! typeidx + segidx are immediates (ESI/EDX); offset + size are the popped
//! operands (ECX/R8D). SysV arg regs ∉ regalloc pool → no parallel-move.
//! Trampoline reuses memory.init's data_segments_ptr plumbing.
//!
//! Lowering: MOV ECX = offset; MOV R8D = size; MOV RDI, R15 (rt); MOV ESI =
//! typeidx; MOV EDX = segidx; MOVABS R10 = &jitGcArrayNewData; CALL R10 →
//! EAX = ref/0. TEST EAX, EAX ; JE → trap stub; else capture EAX.

const meta = @import("../../../../../instruction/wasm_3_0/array_new_data.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const call_scratch: abi.Gpr = .r10; // emit scratch — &fn, then CALL target.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const segidx: u32 = ins.extra;
    const args = try ctx.popBinary(); // lhs=offset, rhs=size, result=ref
    // ECX = offset; R8D = size.
    const xoff = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    if (xoff != .rcx) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, .rcx, xoff).slice());
    const xsize = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    if (xsize != .r8) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, .r8, xsize).slice());
    // RDI = rt (R15); ESI = typeidx; EDX = segidx.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, .rdi, abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(.rsi, typeidx).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(.rdx, segidx).slice());
    // MOVABS R10 = &jitGcArrayNewData; CALL R10.
    const addr: u64 = @intFromPtr(&jit_abi.jitGcArrayNewData);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(call_scratch, addr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // Trap on result == 0: TEST EAX, EAX ; JE → trap stub.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.d, .rax, .rax).slice());
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.bounds_fixups.append(ctx.allocator, fixup);

    // Capture EAX (GcRef) → result vreg.
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    if (rd != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, rd, .rax).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
