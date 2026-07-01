//! arm64 emit handler for `array.get_s` — Wasm 3.0 GC §3.3.5.6.11.
//! Pop the i32 index + array GcRef (trap if null OR index out of bounds),
//! load the 8-byte element slot at `base + 12 + index*8`, then SIGN-extend
//! its packed low bits to i32 and push. Identical front half to `array.get`;
//! the only addition is the final SXTB / SXTH. The validator
//! restricts `array.get_s` to packed (i8 / i16) element arrays, and the
//! compile pipeline stamps the element valtype byte (0x78 i8 / 0x77 i16)
//! into `ZirInstr.extra` so this emit picks the width without re-deriving
//! the type section (mirror struct.new's field-count stamp). Encoders: Arm
//! IHI 0055 §C6.2.131 (LDR reg), §C6.2.4 (ADD), §C6.2.220 (SBFM/SXTB,SXTH).

const meta = @import("../../../../../instruction/wasm_3_0/array_get_s.zig");
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
const base: inst.Xn = 16; // IP0 (caller-saved) — slab/object base.
const len_scratch: inst.Xn = 14; // stage-0 — length.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    // args.lhs = array ref; args.rhs = i32 index; args.result = element.
    const args = try ctx.popBinary();
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    // Null-ref trap: CMP Xref, #0 ; B.EQ → null_reference (code 10), mirroring array.get/set.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xref, 0));
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.null_ref_fixups.append(ctx.allocator, fixup); // D-293 array_oob: null → null_reference (code 10)

    // base = slab + ref; length [base+8] into X14 (ref dead).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(base, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(base, base, @offsetOf(heap_mod.Heap, "bytes")));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(base, base, xref));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImmW(len_scratch, base, @intCast(length_off)));
    // OOB trap: CMP Windex, Wlength ; B.HS (unsigned >=) → oob_memory (code 6), mirroring array.get/set.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(xidx, len_scratch));
    fixup = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
    try ctx.oob_fixups.append(ctx.allocator, fixup); // D-293 array_oob: index OOB → oob_memory (code 6)

    // base += header → element[0] addr; LDR element[index] (8-byte slot).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(base, base, @intCast(header_size)));
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(rd, base, xidx));
    // Sign-extend the packed low bits to i32 (extra = element valtype byte).
    switch (ins.extra) {
        0x78 => try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxtbW(rd, rd)), // i8
        0x77 => try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxthW(rd, rd)), // i16
        else => unreachable, // validator restricts get_s to packed i8/i16
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
