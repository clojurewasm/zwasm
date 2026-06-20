//! x86_64 emit handler for `struct.get_u` — Wasm 3.0 GC §3.3.13.7.
//! Like `struct.get_s` but ZERO-extends the packed (i8/i16) field low
//! bits to i32 (MOVZX). Validator restricts to packed fields.

const meta = @import("../../../../../instruction/wasm_3_0/struct_get_u.zig");
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

const header_size: u32 = 8;
const slab: abi.Gpr = .r11;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const fieldidx: u32 = ins.extra;
    const field_off: u32 = header_size + fieldidx * 8;

    const args = try ctx.popUnary();
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    // Null-ref trap → null_reference stub (kind 10), matching interp; not generic.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.null_ref_fixups.append(ctx.allocator, fixup_at);

    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, slab, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, slab, xref).slice());

    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(rd, slab, @intCast(field_off)).slice());
    switch (ctx.func.structFieldValType(@intCast(ins.payload), fieldidx)) {
        0x78 => try ctx.buf.appendSlice(ctx.allocator, inst.encMovzxR32R8(rd, rd).slice()), // i8
        0x77 => try ctx.buf.appendSlice(ctx.allocator, inst.encMovzxR32R16(rd, rd).slice()), // i16
        else => return ctx_mod.Error.UnsupportedOp,
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
