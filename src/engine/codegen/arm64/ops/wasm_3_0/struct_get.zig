//! arm64 emit handler for `struct.get` — Wasm 3.0 GC §3.3.13.6.
//! Pop a struct GcRef (trap if null), load the 8-byte field slot at
//! `slab_base + ref + header_size + fieldidx*8`, push the loaded
//! Value. Field slots are uniform 8-byte (ADR-0116 §3a) so the field
//! index alone determines the byte offset — no type-info threading.
//!
//! Slab base chain: X19 (pinned rt) -> JitRuntime.gc_heap (*Heap) ->
//! Heap.bytes slice `.ptr` (the first 8 bytes at offsetOf(Heap,bytes)).
//! Re-loaded each get because the slab realloc-moves on grow.
//!
//! Lowering mirrors i31_get_s (null-trap via CMP + B.EQ → bounds_fixups
//! generic trap stub, ADR-0123 D2) + struct_new_default (X19/jit_abi
//! addressing + result-vreg capture). Encoders: Arm IHI 0055 §C6.2.65
//! (CMP imm = SUBS), §C6.2.26 (B.cond), §C6.2.131 (LDR imm), §C6.2.4
//! (ADD reg).

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

/// IP0 (AAPCS64 §6.4 caller-saved) — slab-base scratch. Disjoint from
/// the regalloc pool + spill-stage regs, so safe to clobber mid-op.
const slab: inst.Xn = 16;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const fieldidx: u32 = ins.extra;
    const field_off: u32 = header_size + fieldidx * 8;

    const args = try ctx.popUnary();
    // Load the GcRef into a register (stage reg 0 = X14 if spilled).
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    // Null-ref trap: CMP Xref, #0 ; B.EQ → generic trap stub.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xref, 0));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, fixup_at); // D-293 slice-4c null_reference (code 10)

    // slab = [X19, #gc_heap_off] (*Heap), then [slab, #offsetOf(Heap,bytes)]
    // (the slice `.ptr`). Both offsets are 8-aligned.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(slab, slab, @offsetOf(heap_mod.Heap, "bytes")));
    // addr = slab + ref.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(slab, slab, xref));

    // Load the 8-byte field slot into the result vreg's home (the result
    // vreg already allocated by popUnary — mirror i31_get_s, do NOT
    // allocate a second one). field_off is 8-aligned (header_size=8 + idx*8).
    // D-212: an f32/f64 field is FP-class (vregClassOfOp) — load via the FP
    // register file (LDR S/D) so the f32-return / call consumer reads the
    // correct V-home, not a stale one. i32/i64/ref → GPR (LDR X).
    const field_vt = ctx.func.structFieldValType(@intCast(ins.payload), fieldidx);
    switch (field_vt) {
        0x7D => { // f32
            if (field_off > 16380) return ctx_mod.Error.SlotOverflow;
            const vd = try gpr.fpDefSpilled(ctx.alloc, args.result, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrSImm(vd, slab, @intCast(field_off)));
            try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
        0x7C => { // f64
            const vd = try gpr.fpDefSpilled(ctx.alloc, args.result, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrDImm(vd, slab, @intCast(field_off)));
            try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
        else => {
            const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(rd, slab, @intCast(field_off)));
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
