//! x86_64 emit handler for `array.len` — Wasm 3.0 GC §3.3.5.6.13.
//! Mirror of the arm64 handler: pop the array GcRef (trap if null), load
//! the u32 length from the ArrayHeader at byte offset 8, push it as i32.
//!
//! Slab base chain (mirror struct_get): R15 → JitRuntime.gc_heap (*Heap)
//! → Heap.bytes `.ptr`; + ref → object base; MOV r32 length [base+8].
//! Intel SDM Vol.2 (TEST 0x85, JE 0x0F 0x84, MOV 0x8B, ADD 0x01).

const meta = @import("../../../../../instruction/wasm_3_0/array_len.zig");
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

/// Byte offset of ArrayHeader.length (after the 8-byte ObjectHeader).
const length_off: i32 = 8;
/// Slab/object-base scratch (emit stage-1 = R11; not in regalloc pool).
const slab: abi.Gpr = .r11;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ins;
    const args = try ctx.popUnary();
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    // Null-ref trap: TEST xref, xref ; JE rel32 → null_reference stub (kind 10),
    // matching the interp (Trap.NullReference) — not the generic bounds bucket.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.null_ref_fixups.append(ctx.allocator, fixup_at);

    // slab = [R15 + gc_heap_off] (*Heap), then [slab + offsetOf(Heap,bytes)]
    // (the slice `.ptr`); then slab += ref → object base.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, slab, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, slab, xref).slice());

    // MOV r32 length [base+8] into the result vreg's home (stage-0 reuse).
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR32FromMemDisp32(rd, slab, length_off).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
