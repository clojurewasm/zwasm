//! arm64 emit handler for `array.get` — Wasm 3.0 GC §3.3.5.6.10.
//! Pop the i32 index + array GcRef (trap if null OR index out of bounds),
//! load the 8-byte element at `base + 12 + index*8`, push it. The element
//! offset is RUNTIME (index) and 4-mod-8 (header is 12 bytes) → a
//! REGISTER-OFFSET load (`LDR Xt, [Xn, Xm, LSL #3]`), not the immediate
//! form struct uses; the +12 header is folded into the base first.
//!
//! Bounds: a single UNSIGNED compare `index >= length` also catches a
//! negative index (negative i32 reinterpreted as u32 is huge). The null-ref
//! branch routes to `null_ref_fixups` (code 10) and the OOB branch to
//! `oob_fixups` (code 6) per D-293 slice-4c (NOT the generic bounds_fixups).
//! Slab base chain mirrors struct_get/array_len. Encoders: Arm IHI
//! 0055 §C6.2.65 (CMP imm), §C6.2.66 (CMP reg), §C6.2.26 (B.cond),
//! §C6.2.131 (LDR imm), §C6.2.130 (LDR reg), §C6.2.4 (ADD).

const meta = @import("../../../../../instruction/wasm_3_0/array_get.zig");
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
/// IP0 (caller-saved) — slab/object-base scratch; disjoint from the
/// regalloc pool + spill-stage regs {X14,X15}.
const base: inst.Xn = 16;
/// Stage-0 (X14) reused ad-hoc for the length after the ref is consumed.
const len_scratch: inst.Xn = 14;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    // D-212 — element valtype selects the result register class. f32/f64
    // elements are FP-class (vregClassOfOp); the GPR-only load left the
    // value in a GPR while the f32 consumer reads the FP home → stale.
    const elem_vt = ctx.func.arrayElemValType(@intCast(ins.payload));
    // args.lhs = array ref; args.rhs = i32 index; args.result = element.
    const args = try ctx.popBinary();
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    // Null-ref trap: CMP Xref, #0 ; B.EQ → trap stub.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xref, 0));
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, fixup); // D-293 slice-4c null_reference (code 10)

    // base = slab + ref; then load length [base+8] into X14 (ref dead).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(base, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(base, base, @offsetOf(heap_mod.Heap, "bytes")));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(base, base, xref));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(len_scratch, base, @intCast(length_off)));
    // OOB trap: CMP Windex, Wlength ; B.HS (unsigned >=) → trap stub.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(xidx, len_scratch));
    fixup = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup); // D-293 slice-4c array index OOB → oob_memory (code 6)

    // base += header → element[0] addr; LDR element[index] (8-byte slot).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(base, base, @intCast(header_size)));
    switch (elem_vt) {
        0x7D, 0x7C => {
            // FP element. The FP register-offset load doesn't apply LSL #3,
            // so load the 8-byte slot into a scratch GPR (X14, dead after
            // the bounds check) then FMOV into the FP result home.
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(len_scratch, base, xidx));
            const vd = try gpr.fpDefSpilled(ctx.alloc, args.result, 0);
            if (elem_vt == 0x7D)
                try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovStoFromW(vd, len_scratch))
            else
                try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovDtoFromX(vd, len_scratch));
            try gpr.fpStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
        0x7B => {
            // v128 (D-460): 16-byte element. Scale index by 16 (idx<<4) into
            // X14 (len, dead after the bounds check), then LDR Q [base, X14].
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLslImmX(len_scratch, xidx, 4));
            const vd = try gpr.qDefSpilled(ctx.alloc, args.result, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encLdrQReg(vd, base, len_scratch));
            try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
        else => {
            const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(rd, base, xidx));
            try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
