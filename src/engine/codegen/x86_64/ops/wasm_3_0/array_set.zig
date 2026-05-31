//! x86_64 emit handler for `array.set` — Wasm 3.0 GC §3.3.5.6.12.
//! Mirror of the arm64 handler: pop value + i32 index + array GcRef (trap
//! null OR index OOB), store the 8-byte value at `base + 12 + index*8`.
//! Pops 3 (3 → 0, no result). Register-offset store (`MOV [base + idx*8],
//! r64`); base += 12 first. Same UNSIGNED bounds check (JAE) as array_get.
//!
//! Registers: ref → stage-0 (R10), index → stage-1 (R11), object base →
//! RAX (3rd reg; caller-saved, not in pool/rt). R10 is reused for the
//! length, then for the value (loaded last, after the OOB check).

const meta = @import("../../../../../instruction/wasm_3_0/array_set.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const heap_mod = @import("../../../../../feature/gc/heap.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const header_size: i32 = 12;
const length_off: i32 = 8;
const base: abi.Gpr = .rax; // object-base scratch (3rd reg; caller-saved).
const scratch0: abi.Gpr = .r10; // stage-0, reused for length then value.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ins; // typeidx unused — uniform 8-byte slot.
    // Operand stack: [.., ref, index, value] (value on top). Pop in reverse.
    if (ctx.pushed_vregs.items.len < 3) return ctx_mod.Error.AllocationMissing;
    const value_vreg = ctx.pushed_vregs.pop().?;
    const index_vreg = ctx.pushed_vregs.pop().?;
    const ref_vreg = ctx.pushed_vregs.pop().?;

    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ref_vreg, 0);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, index_vreg, 1);
    // Null-ref trap.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.bounds_fixups.append(ctx.allocator, fixup);

    // base = slab + ref; length [base+8] → R10 (ref dead); OOB check.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base, base, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, base, xref).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR32FromMemDisp32(scratch0, base, length_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRR(.d, xidx, scratch0).slice());
    fixup = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ae, 0).slice());
    try ctx.bounds_fixups.append(ctx.allocator, fixup);

    // base += header → element[0]; load value (R10 reuse) + store.
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddR64Imm32(base, header_size).slice());
    const xval = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encStoreR64MemBaseIdxLsl3(xval, base, xidx).slice());
}
