//! arm64 emit handler for `array.set` — Wasm 3.0 GC §3.3.5.6.12.
//! Pop the value + i32 index + array GcRef (trap if null OR index OOB),
//! store the 8-byte value at `base + 12 + index*8`. Mirror of array_get
//! but STORE not load, popping 3 (3 → 0, no result). The ref loads into
//! stage-0 (X14) → consumed into the object base; X14 is then REUSED for
//! the length, then for the value (loaded last, after the OOB check).
//! Register-offset store `STR Xt, [Xn, Xm, LSL #3]` (element offset is
//! runtime + 4-mod-8). Same UNSIGNED bounds check as array_get.

const meta = @import("../../../../../instruction/wasm_3_0/array_set.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const inst_fp = @import("../../inst_fp.zig");
const inst_neon = @import("../../inst_neon.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const heap_mod = @import("../../../../../feature/gc/heap.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

const header_size: u32 = 12; // ObjectHeader (8) + length:u32 (4).
const length_off: u32 = 8;
const base: inst.Xn = 16; // IP0 — slab/object-base scratch.
const scratch0: inst.Xn = 14; // stage-0, reused for length then value.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const elem_vt = ctx.func.arrayElemValType(@intCast(ins.payload)); // D-212
    // Operand stack: [.., ref, index, value] (value on top). Pop in reverse.
    if (ctx.pushed_vregs.items.len < 3) return ctx_mod.Error.AllocationMissing;
    const value_vreg = ctx.pushed_vregs.pop().?;
    const index_vreg = ctx.pushed_vregs.pop().?;
    const ref_vreg = ctx.pushed_vregs.pop().?;

    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, ref_vreg, 0);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, index_vreg, 1);
    // Null-ref trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xref, 0));
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, fixup); // D-293 slice-4c null_reference (code 10)

    // base = slab + ref; length [base+8] into X14 (ref dead).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(base, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(base, base, @offsetOf(heap_mod.Heap, "bytes")));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(base, base, xref));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(scratch0, base, @intCast(length_off)));
    // OOB trap: CMP Windex, Wlength ; B.HS → trap stub.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(xidx, scratch0));
    fixup = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup); // D-293 slice-4c array index OOB → oob_memory (code 6)

    // base += header → element[0] addr; load value (X14 reuse) + STR.
    // D-212: an f32/f64 value operand is FP-class — read it from the FP
    // register file then FMOV into the scratch GPR (the register-offset
    // store has no FP form). 0x7D=f32 (low 32), 0x7C=f64.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(base, base, @intCast(header_size)));
    switch (elem_vt) {
        0x7D, 0x7C => {
            const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            if (elem_vt == 0x7D)
                try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovWFromS(scratch0, vs))
            else
                try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovXFromD(scratch0, vs));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(scratch0, base, xidx));
        },
        0x7B => {
            // v128 (D-460): qLoad the value into a Q-reg, scale the index by
            // 16 (idx<<4) into X14 (length, dead now), STR Q [base, X14].
            const vs = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLslImmX(scratch0, xidx, 4));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encStrQReg(vs, base, scratch0));
        },
        else => {
            const xval = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrXRegLsl3(xval, base, xidx));
        },
    }
}
