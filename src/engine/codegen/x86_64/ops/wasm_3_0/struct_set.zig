//! x86_64 emit handler for `struct.set` — Wasm 3.0 GC §3.3.5.6.4.
//! Mirror of the arm64 handler: pop a value + a struct GcRef (trap if
//! null), store the 8-byte value into the field slot at `slab_base +
//! ref + header_size + fieldidx*8`. Field slots uniform 8-byte
//! (ADR-0116 §3a). Fixed stackEffect 2→0 (no result); no alloc CALL,
//! no force-spill.
//!
//! Mirror of `struct_get.zig` (x86_64) but STORE not load, popping 2:
//! the ref loads into stage-0 (R10), is null-trapped, then folded into
//! the object base (R11). Once consumed, stage-0 is REUSED to load the
//! value, so only R10 + R11 are needed. Intel SDM Vol.2 (TEST 0x85,
//! JE 0x0F 0x84, MOV 0x8B, ADD 0x01, MOV-store 0x89).

const meta = @import("../../../../../instruction/wasm_3_0/struct_set.zig");
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

/// ObjectHeader bytes; uniform 8-byte field slots follow (ADR-0116 §3a).
const header_size: u32 = 8;
/// Slab/object-base scratch (emit stage-1 = R11; not in the regalloc
/// pool). Disjoint from gprLoadSpilled stage-0 (R10).
const slab: abi.Gpr = .r11;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const fieldidx: u32 = ins.extra;
    const field_off: u32 = header_size + fieldidx * 8;

    // Operand stack: [.., ref, value] (value on top). Pop value then ref.
    if (ctx.pushed_vregs.items.len < 2) return ctx_mod.Error.AllocationMissing;
    const value_vreg = ctx.pushed_vregs.pop().?;
    const ref_vreg = ctx.pushed_vregs.pop().?;

    // Load the GcRef (stage-0 = R10 if spilled); null-trap.
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ref_vreg, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);

    // Object base R11 = slab + ref (slab re-loaded each set; realloc-moves).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, slab, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, slab, xref).slice());

    // ref consumed into `slab` → stage-0 free; load value there and store.
    // D-212: an f32/f64 value operand is XMM-class — read it from the XMM
    // file then MOVD/MOVQ into a scratch GPR for the store. 0x7D=f32, 0x7C=f64.
    const field_vt = ctx.func.structFieldValType(@intCast(ins.payload), fieldidx);
    switch (field_vt) {
        0x7D, 0x7C => {
            const xv = try gpr.xmmLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            const tmp: abi.Gpr = .r10; // stage-0 scratch
            if (field_vt == 0x7D)
                try ctx.buf.appendSlice(ctx.allocator, inst.encMovdR32FromXmm(tmp, xv).slice())
            else
                try ctx.buf.appendSlice(ctx.allocator, inst.encMovqR64FromXmm(tmp, xv).slice());
            try ctx.buf.appendSlice(ctx.allocator, inst.encStoreR64MemDisp32(tmp, slab, @intCast(field_off)).slice());
        },
        else => {
            const xval = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            try ctx.buf.appendSlice(ctx.allocator, inst.encStoreR64MemDisp32(xval, slab, @intCast(field_off)).slice());
        },
    }
}
