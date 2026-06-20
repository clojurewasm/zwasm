//! arm64 emit handler for `array.len` — Wasm 3.0 GC §3.3.5.6.13.
//! Pop the array GcRef (trap if null), load the u32 length from the
//! ArrayHeader at byte offset 8 (ObjectHeader is 8 bytes; length follows),
//! push it as i32. No typeidx — the length lives in the object header.
//!
//! Slab base chain (mirror struct_get): X19 (pinned rt) → JitRuntime
//! .gc_heap (*Heap) → Heap.bytes `.ptr`; + ref → object base; LDR W
//! length [base, #8] (W-form: length is u32; offset 8 is 4-aligned).
//! Encoders: Arm IHI 0055 §C6.2.65 (CMP imm), §C6.2.26 (B.cond),
//! §C6.2.131 (LDR imm), §C6.2.4 (ADD reg).

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
const length_off: u32 = 8;
/// IP0 (AAPCS64 §6.4 caller-saved) — slab/object-base scratch. Disjoint
/// from the regalloc pool + spill-stage regs {X14,X15}.
const slab: inst.Xn = 16;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ins;
    // args.src = array ref; args.result = pushed length (i32).
    const args = try ctx.popUnary();
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    // Null-ref trap: CMP Xref, #0 ; B.EQ → null_reference stub (kind 10),
    // matching the interp (Trap.NullReference) — not the generic bounds bucket.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xref, 0));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, fixup_at);

    // slab = [[X19,#gc_heap_off], #offsetOf(Heap,bytes)]; + ref → base.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(slab, slab, @offsetOf(heap_mod.Heap, "bytes")));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(slab, slab, xref));

    // LDR W length [base, #8] into the result vreg's home (stage-0 reuse).
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(rd, slab, @intCast(length_off)));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
