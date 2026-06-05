//! x86_64 emit handler for `struct.get` — Wasm 3.0 GC §3.3.13.6.
//! Mirror of the arm64 handler: pop a struct GcRef (trap if null), load
//! the 8-byte field slot at `slab_base + ref + header_size + fieldidx*8`,
//! push the loaded Value. Field slots are uniform 8-byte (ADR-0116 §3a)
//! so the field index alone determines the byte offset — no type-info
//! threading.
//!
//! Slab base chain: R15 (pinned rt) -> JitRuntime.gc_heap (*Heap) ->
//! Heap.bytes slice `.ptr` (the first 8 bytes at offsetOf(Heap,bytes)).
//! Re-loaded each get because the slab realloc-moves on grow. The
//! slab-base scratch is R11 (emit stage-1, never in the regalloc pool):
//! gprLoadSpilled / gprDefSpilled use stage-0 = R10, so R11 cannot
//! alias the popped ref (xref) nor the result reg.
//!
//! Lowering mirrors i31_get_s (null-trap via TEST + JE rel32 →
//! bounds_fixups generic trap stub, ADR-0123 D2). Intel SDM Vol.2
//! (TEST 0x85, JE 0x0F 0x84, MOV 0x8B, ADD 0x01).

const meta = @import("../../../../../instruction/wasm_3_0/struct_get.zig");
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

/// Slab-base scratch (emit stage-1 = R11; not in the regalloc pool).
/// Disjoint from gprLoadSpilled/gprDefSpilled stage-0 (R10), so it
/// never aliases the popped ref or the result reg.
const slab: abi.Gpr = .r11;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const fieldidx: u32 = ins.extra;
    const field_off: u32 = header_size + fieldidx * 8;

    const args = try ctx.popUnary();
    // Load the GcRef into a register (stage-0 = R10 if spilled).
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    // Null-ref trap: TEST xref, xref ; JE rel32 → generic trap stub.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.null_ref_fixups.append(ctx.allocator, fixup_at); // D-293 slice-4c null_reference (code 10)

    // slab = [R15 + gc_heap_off] (*Heap), then [slab + offsetOf(Heap,bytes)]
    // (the slice `.ptr`); then slab += ref → object base.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(slab, slab, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, slab, xref).slice());

    // Load the 8-byte field slot into the result vreg's home (the result
    // vreg already allocated by popUnary — do NOT allocate a second one).
    // D-212: an f32/f64 field is FP-class (vregClassOfOp) — load the slot
    // into a scratch GPR then MOVD/MOVQ into the XMM result home, so the
    // f32 consumer (function return / call) reads the correct XMM-home,
    // not a stale GPR. i32/i64/ref → GPR. 0x7D=f32, 0x7C=f64.
    const field_vt = ctx.func.structFieldValType(@intCast(ins.payload), fieldidx);
    switch (field_vt) {
        0x7D, 0x7C => {
            const tmp: abi.Gpr = .r10; // stage-0 scratch (dead xref slot)
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(tmp, slab, @intCast(field_off)).slice());
            const xd = try gpr.xmmDefSpilled(ctx.alloc, args.result, 0);
            if (field_vt == 0x7D)
                try ctx.buf.appendSlice(ctx.allocator, inst.encMovdXmmFromR32(xd, tmp).slice())
            else
                try ctx.buf.appendSlice(ctx.allocator, inst.encMovqXmmFromR64(xd, tmp).slice());
            try gpr.xmmStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
        else => {
            const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
            try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(rd, slab, @intCast(field_off)).slice());
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
