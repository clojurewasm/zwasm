//! arm64 emit handler for `struct.get_s` — Wasm 3.0 GC §3.3.13.7.
//! Pop a struct GcRef (trap if null), load the 8-byte packed (i8/i16)
//! field slot, then SIGN-extend its packed low bits to i32 and push.
//! Front half mirrors `struct.get`; the validator restricts get_s to
//! packed (i8/i16) fields, so the field valtype byte (structFieldValType)
//! is always 0x78/0x77 here (mirror array.get_s's SXTB/SXTH tail).

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
const slab: inst.Xn = 16;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const fieldidx: u32 = ins.extra;
    const field_off: u32 = header_size + fieldidx * 8;

    const args = try ctx.popUnary();
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xref, 0));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(slab, slab, @offsetOf(heap_mod.Heap, "bytes")));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(slab, slab, xref));

    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(rd, slab, @intCast(field_off)));
    switch (ctx.func.structFieldValType(@intCast(ins.payload), fieldidx)) {
        0x78 => try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxtbW(rd, rd)), // i8
        0x77 => try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxthW(rd, rd)), // i16
        else => return ctx_mod.Error.UnsupportedOp, // validator restricts to packed
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
