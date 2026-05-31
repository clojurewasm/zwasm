//! x86_64 emit handler for `array.get` — Wasm 3.0 GC §3.3.5.6.10.
//! Mirror of the arm64 handler: pop i32 index + array GcRef (trap null OR
//! index OOB), load the 8-byte element at `base + 12 + index*8`, push it.
//! Element offset is RUNTIME + 4-mod-8 → register-offset MOV (base+=12
//! first). A single UNSIGNED compare `index >= length` (JAE) also catches
//! a negative index. Both null + OOB → the generic `bounds_fixups` stub.
//!
//! Registers: ref → stage-0 (R10), index → stage-1 (R11). The object base
//! needs a 3rd reg while both ref and index are live → RAX (caller-saved,
//! NOT in the regalloc pool {RBX,R12,R13,R14} nor rt R15). R10 is reused
//! for the length after ref is consumed into the base. Intel SDM Vol.2
//! (TEST 0x85, MOV 0x8B, ADD 0x01/0x81, CMP 0x39, JE/JAE 0x0F 0x84/0x83).

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

const header_size: i32 = 12; // ObjectHeader (8) + length:u32 (4).
const length_off: i32 = 8;
const base: abi.Gpr = .rax; // object-base scratch (3rd reg; caller-saved).
const len_scratch: abi.Gpr = .r10; // stage-0 reused for length.

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ins; // typeidx unused — uniform 8-byte slot.
    const args = try ctx.popBinary(); // lhs=ref, rhs=index, result=element
    const xref = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xidx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    // Null-ref trap.
    try ctx.buf.appendSlice(ctx.allocator, inst.encTestRR(.q, xref, xref).slice());
    var fixup: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.e, 0).slice());
    try ctx.bounds_fixups.append(ctx.allocator, fixup);

    // base = slab + ref; length [base+8] → R10 (ref dead).
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base, base, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, base, xref).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR32FromMemDisp32(len_scratch, base, length_off).slice());
    // OOB trap: CMP index, length ; JAE (unsigned >=) → trap stub.
    try ctx.buf.appendSlice(ctx.allocator, inst.encCmpRR(.d, xidx, len_scratch).slice());
    fixup = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJccRel32(.ae, 0).slice());
    try ctx.bounds_fixups.append(ctx.allocator, fixup);

    // base += header → element[0]; MOV element[index] (8-byte slot).
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddR64Imm32(base, header_size).slice());
    const rd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromBaseIdxLsl3(rd, base, xidx).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
