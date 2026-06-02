//! x86_64 emit handler for `struct.get_s` — Wasm 3.0 GC §3.3.13.7.
//! Mirror of the arm64 handler: pop a struct GcRef (trap if null), load
//! the 8-byte packed (i8/i16) field slot, then SIGN-extend its low bits
//! to i32 (MOVSX) and push. Validator restricts get_s to packed fields,
//! so the field valtype is 0x78/0x77 (mirror array.get_s's MOVSX tail).

const meta = @import("../../../../../instruction/wasm_3_0/struct_get_s.zig");
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
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);

    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, slab, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, slab, xref).slice());

    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(rd, slab, @intCast(field_off)).slice());
    switch (ctx.func.structFieldValType(@intCast(ins.payload), fieldidx)) {
        0x78 => try ctx.buf.appendSlice(ctx.allocator, inst.encMovsxR32R8(rd, rd).slice()), // i8
        0x77 => try ctx.buf.appendSlice(ctx.allocator, inst.encMovsxR32R16(rd, rd).slice()), // i16
        else => return ctx_mod.Error.UnsupportedOp,
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
