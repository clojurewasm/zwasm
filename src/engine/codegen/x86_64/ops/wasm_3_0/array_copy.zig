//! x86_64 emit handler for `array.copy` — Wasm 3.0 GC §3.3.5.6.14.
//! Mirror of the arm64 handler: pop dst_ref + dst_off + src_ref + src_off +
//! len, null-check both refs + bounds-check both ranges + overlap-aware
//! copy inside the `jitGcArrayCopy(rt, dst_ref, dst_off, src_ref, src_off,
//! len)` trampoline (returns 1=ok / 0=trap). Emit = 6-arg marshal + CALL +
//! trap branch on a 0 result. No result push (5 → 0).
//!
//! The typeidx immediates are dropped (uniform 8-byte slots, ADR-0116 §3a)
//! → exactly 6 args, no 7th-on-stack. SysV arg regs RDI/RSI/RDX/RCX/R8/R9
//! are NOT in the regalloc allocatable pool (callee-saved only), so the
//! marshal has no parallel-move hazard.
//!
//! Lowering: MOV RDI, R15 (rt); MOV ESI = dst_ref; MOV EDX = dst_off; MOV
//! ECX = src_ref; MOV R8D = src_off; MOV R9D = len; MOVABS R10 =
//! &jitGcArrayCopy; CALL R10 → EAX = 1/0. Then TEST EAX, EAX ; JE → trap.

const meta = @import("../../../../../instruction/wasm_3_0/array_copy.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const gc_marshal = @import("gc_marshal.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const call_scratch: abi.Gpr = .r10; // emit scratch — &fn, then CALL target.

pub fn emit(ctx: *ctx_mod.EmitCtx, _: *const zir.ZirInstr) ctx_mod.Error!void {
    // Operand stack: [.., dst_ref, dst_off, src_ref, src_off, len] (len top).
    if (ctx.pushed_vregs.items.len < 5) return ctx_mod.Error.AllocationMissing;
    const len_vreg = ctx.pushed_vregs.pop().?;
    const src_off_vreg = ctx.pushed_vregs.pop().?;
    const src_ref_vreg = ctx.pushed_vregs.pop().?;
    const dst_off_vreg = ctx.pushed_vregs.pop().?;
    const dst_ref_vreg = ctx.pushed_vregs.pop().?;

    // Marshal user args 1..5 = dst_ref, dst_off, src_ref, src_off, len.
    // SysV: arg_gprs[1..6] = RSI/RDX/RCX/R8/R9 (all in regs). Win64:
    // arg_gprs[1..4] = RDX/R8/R9 (3 user GPRs) → src_off (arg 4) + len
    // (arg 5) spill to [RSP+0x20]/[RSP+0x28] (D-248). All i32 → .d.
    const xdr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_ref_vreg, 0);
    try gc_marshal.routeArg(ctx, 1, xdr, .d);
    const xdo = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, dst_off_vreg, 0);
    try gc_marshal.routeArg(ctx, 2, xdo, .d);
    const xsr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_ref_vreg, 0);
    try gc_marshal.routeArg(ctx, 3, xsr, .d);
    const xso = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_off_vreg, 0);
    try gc_marshal.routeArg(ctx, 4, xso, .d);
    const xln = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, len_vreg, 0);
    try gc_marshal.routeArg(ctx, 5, xln, .d);

    // arg 0 = rt (R15) → arg_gprs[0] (RDI on SysV, RCX on Win64).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    // MOVABS R10 = &jitGcArrayCopy; CALL R10.
    const addr: u64 = @intFromPtr(&jit_abi.jitGcArrayCopy);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(call_scratch, addr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // Trap on result == 0 (null ref / OOB): TEST EAX, EAX ; JE → trap stub.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.d, .rax, .rax).slice());
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.bounds_fixups.append(ctx.allocator, fixup);
    // array.copy is 5 → 0: no result vreg pushed.
}
