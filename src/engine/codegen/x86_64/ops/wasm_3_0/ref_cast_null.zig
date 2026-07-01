//! x86_64 emit handler for `ref.cast_null` — Wasm 3.0 GC §3.3.5.4 (nullable
//! target). Mirror of the arm64 handler: NULL passes through unchanged (no
//! trap); a non-null value traps on type-mismatch, else passes through. 1→1.
//!
//! The null-passes semantics needs an INLINE null-skip branch: `TEST
//! ref,ref ; JZ .done` jumps over the cast check so a null operand is NOT
//! trapped. On the non-null path it reuses the `jitGcRefCast(rt, ref,
//! ht)` trampoline (ref / 0=trap-on-mismatch) and captures the matched ref
//! from RAX AFTER the CALL (a register-allocated result would be clobbered
//! by the CALL). The `JZ` rel32 is patched in-place once `.done`'s offset is
//! known (a local forward branch; the trap `JE` still routes through
//! `bounds_fixups`).
//!
//! Lowering: MOV rd, ref ; TEST ref,ref ; JZ .done ; { MOV RSI,ref ; MOV
//! RDI,R15 ; MOV EDX=ht ; MOVABS R10=&jitGcRefCast ; CALL R10 ; TEST
//! RAX,RAX ; JE → trap ; MOV rd, RAX } ; .done: store rd→slot.

const meta = @import("../../../../../instruction/wasm_3_0/ref_cast_null.zig");
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
    // D-453: full encoded u32 (concrete-tag bit 31 | idx bits 0..29, or a
    // bare wire byte) — must NOT mask to one byte or a concrete idx ≥ 64 is
    // lost. Null passes via the inline JZ branch, so no null flag is ORed.
    const ht: u32 = @truncate(ins.payload);
    const args = try ctx.popUnary();
    const xsrc = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    // rd = operand (the result for the NULL path; no CALL runs there).
    if (rd != xsrc) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, rd, xsrc).slice());
    // TEST ref,ref ; JZ .done — null passes through unchanged.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xsrc, xsrc).slice());
    const jz_at: usize = ctx.buf.items.len;
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice()); // placeholder rel32

    // Non-null path: jitGcRefCast(rt, ref, ht) → RAX (ref / 0=trap-on-mismatch).
    if (xsrc != abi.current.arg_gprs[1]) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[1], xsrc).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, abi.current.arg_gprs[0], abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(abi.current.arg_gprs[2], ht).slice());
    const addr: u64 = @intFromPtr(&jit_abi.jitGcRefCast);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(call_scratch, addr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, .rax, .rax).slice());
    const fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.cast_fail_fixups.append(ctx.allocator, fixup); // D-293 slice-4d cast_failure (code 11)
    // Match: rd = the returned ref (RAX; rd may have been CALL-clobbered).
    if (rd != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, rd, .rax).slice());

    // .done — patch the JZ forward rel32 (disp = done - (jz_at + 6)).
    const done_at: usize = ctx.buf.items.len;
    const disp: i32 = @intCast(@as(i64, @intCast(done_at)) - @as(i64, @intCast(jz_at + 6)));
    inst.patchRel32(ctx.buf.items, jz_at, 6, disp);

    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
