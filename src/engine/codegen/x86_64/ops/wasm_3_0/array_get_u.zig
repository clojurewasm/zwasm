//! x86_64 emit handler for `array.get_u` — Wasm 3.0 GC §3.3.5.6.11.
//! Unsigned twin of `array.get_s`: pop i32 index + array GcRef
//! (trap null OR OOB), load the 8-byte element slot at `base + 12 +
//! index*8`, then ZERO-extend its packed low bits to i32 (MOVZX) and
//! push. Identical to `array.get_s` apart from the final MOVZX (vs
//! MOVSX). The validator restricts `array.get_u` to packed (i8 / i16)
//! arrays; the compile pipeline stamps the element valtype byte (0x78
//! i8 / 0x77 i16) into `ZirInstr.extra`. Intel SDM Vol.2 (MOV 0x8B,
//! MOVZX 0x0FB6 / 0x0FB7).

const meta = @import("../../../../../instruction/wasm_3_0/array_get_u.zig");
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
const base: abi.Gpr = .rax;
const len_scratch: abi.Gpr = .r10;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const args = try ctx.popBinary(); // lhs=ref, rhs=index, result=element
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    // Null-ref trap → null_reference (code 10), mirroring array.get/set.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.null_ref_fixups.append(ctx.allocator, fixup); // D-293 array_oob: null → null_reference (code 10)

    // base = slab + ref; length [base+8] → R10 (ref dead).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base, base, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, base, xref).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR32FromMemDisp32(len_scratch, base, length_off).slice());
    // OOB trap: CMP index, length ; JAE (unsigned >=) → oob_memory (code 6), mirroring array.get/set.
    try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRR(.d, xidx, len_scratch).slice());
    fixup = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ae, 0).slice());
    try ctx.oob_fixups.append(ctx.allocator, fixup); // D-293 array_oob: index OOB → oob_memory (code 6)

    // base += header → element[0]; MOV element[index] (8-byte slot).
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddR64Imm32(base, header_size).slice());
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromBaseIdxLsl3(rd, base, xidx).slice());
    // Zero-extend the packed low bits to i32 (extra = element valtype byte).
    switch (ins.extra) {
        0x78 => try ctx.buf.appendSlice(ctx.allocator, inst.encMovzxR32R8(rd, rd).slice()), // i8
        0x77 => try ctx.buf.appendSlice(ctx.allocator, inst.encMovzxR32R16(rd, rd).slice()), // i16
        else => unreachable, // validator restricts get_u to packed i8/i16
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
