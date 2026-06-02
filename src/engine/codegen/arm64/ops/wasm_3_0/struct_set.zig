//! arm64 emit handler for `struct.set` — Wasm 3.0 GC §3.3.5.6.4.
//! Pop a value + a struct GcRef (trap if null), store the 8-byte value
//! into the field slot at `slab_base + ref + header_size + fieldidx*8`.
//! Field slots are uniform 8-byte (ADR-0116 §3a) so the field index
//! alone determines the byte offset — no type-info threading. Fixed
//! stackEffect 2→0 (no result), so no alloc CALL and no force-spill;
//! the operands come from regular regalloc homes.
//!
//! Mirror of `struct_get.zig` but STORE not load, popping 2: the ref is
//! loaded into stage-0 (X14), null-trapped, and folded into the object
//! base (X16) — once consumed, stage-0 is REUSED to load the value, so
//! only two scratch regs are needed (X14 + X16). Encoders: Arm IHI 0055
//! §C6.2.65 (CMP imm), §C6.2.26 (B.cond), §C6.2.131 (LDR imm), §C6.2.4
//! (ADD reg), §C6.2.273 (STR imm).

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
/// IP0 (AAPCS64 §6.4 caller-saved) — slab/object-base scratch. Disjoint
/// from the regalloc pool + spill-stage regs {X14,X15}.
const slab: inst.Xn = 16;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const fieldidx: u32 = ins.extra;
    const field_off: u32 = header_size + fieldidx * 8;

    // Operand stack: [.., ref, value] (value on top). Pop value then ref.
    if (ctx.pushed_vregs.items.len < 2) return ctx_mod.Error.AllocationMissing;
    const value_vreg = ctx.pushed_vregs.pop().?;
    const ref_vreg = ctx.pushed_vregs.pop().?;

    // Load the GcRef (stage-0 = X14 if spilled); null-trap.
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ref_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xref, 0));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);

    // Object base = slab + ref (slab = [[X19,#gc_heap_off],#offsetOf(Heap,
    // bytes)]); re-loaded each set because the slab realloc-moves on grow.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(slab, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(slab, slab, @offsetOf(heap_mod.Heap, "bytes")));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(slab, slab, xref));

    // ref consumed into `slab` → stage-0 is free; load the value there and
    // store it into the field slot (field_off is 8-aligned). D-212: an
    // f32/f64 value operand is FP-class — read it from the FP register file
    // (else gprLoadSpilled reads a stale GPR home). 0x7D=f32, 0x7C=f64.
    const field_vt = ctx.func.structFieldValType(@intCast(ins.payload), fieldidx);
    switch (field_vt) {
        0x7D => {
            if (field_off > 16380) return ctx_mod.Error.SlotOverflow;
            const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrSImm(vs, slab, @intCast(field_off)));
        },
        0x7C => {
            const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrDImm(vs, slab, @intCast(field_off)));
        },
        else => {
            const xval = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(xval, slab, @intCast(field_off)));
        },
    }
}
