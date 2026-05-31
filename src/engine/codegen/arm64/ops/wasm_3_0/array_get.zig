//! arm64 emit handler for `array.get` — Wasm 3.0 GC §3.3.5.6.10.
//! Pop the i32 index + array GcRef (trap if null OR index out of bounds),
//! load the 8-byte element at `base + 12 + index*8`, push it. The element
//! offset is RUNTIME (index) and 4-mod-8 (header is 12 bytes) → a
//! REGISTER-OFFSET load (`LDR Xt, [Xn, Xm, LSL #3]`), not the immediate
//! form struct uses; the +12 header is folded into the base first.
//!
//! Bounds: a single UNSIGNED compare `index >= length` also catches a
//! negative index (negative i32 reinterpreted as u32 is huge). Both the
//! null-ref and the OOB branch route to the generic `bounds_fixups` trap
//! stub. Slab base chain mirrors struct_get/array_len. Encoders: Arm IHI
//! 0055 §C6.2.65 (CMP imm), §C6.2.66 (CMP reg), §C6.2.26 (B.cond),
//! §C6.2.131 (LDR imm), §C6.2.130 (LDR reg), §C6.2.4 (ADD).

const meta = @import("../../../../../instruction/wasm_3_0/array_get.zig");
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

const header_size: u32 = 12; // ObjectHeader (8) + length:u32 (4).
const length_off: u32 = 8;
/// IP0 (caller-saved) — slab/object-base scratch; disjoint from the
/// regalloc pool + spill-stage regs {X14,X15}.
const base: inst.Xn = 16;
/// Stage-0 (X14) reused ad-hoc for the length after the ref is consumed.
const len_scratch: inst.Xn = 14;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ins; // typeidx unused — uniform 8-byte slot (ADR-0116 §3a).
    // args.lhs = array ref; args.rhs = i32 index; args.result = element.
    const args = try ctx.popBinary();
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    // Null-ref trap: CMP Xref, #0 ; B.EQ → trap stub.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xref, 0));
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup);

    // base = slab + ref; then load length [base+8] into X14 (ref dead).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(base, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(base, base, @offsetOf(heap_mod.Heap, "bytes")));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(base, base, xref));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(len_scratch, base, @intCast(length_off)));
    // OOB trap: CMP Windex, Wlength ; B.HS (unsigned >=) → trap stub.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(xidx, len_scratch));
    fixup = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup);

    // base += header → element[0] addr; LDR element[index] (8-byte slot).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(base, base, @intCast(header_size)));
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(rd, base, xidx));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
