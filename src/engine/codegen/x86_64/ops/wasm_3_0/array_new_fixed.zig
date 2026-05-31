//! x86_64 emit handler for `array.new_fixed` — Wasm 3.0 GC §3.3.5.6.8.
//! Mirror of the arm64 handler: allocate a length-N array of type
//! `ins.payload` (typeidx) on the GC heap (N = `ins.extra`, compile-time
//! element count), store the N element operands (popped in declared order)
//! into the payload, and push the GcRef. Variadic like `struct.new`; the
//! shape differences are the 12-byte array header (vs struct's 8) and the
//! length-carrying alloc trampoline `jitGcAllocArray(rt, typeidx, N)` (N in
//! arg2 because the array size depends on the count). Allocation runs in
//! the trampoline (zero-inits the payload); the slab may realloc on grow,
//! so the slab base is RE-loaded AFTER the call.
//!
//! Element operands are force-spilled across the alloc CALL (ADR-0060
//! inclusive `is_call`, arch-independent regalloc), so each value lives in
//! its spill slot and is loaded via gprLoadSpilled (stage-0 = R10).
//!
//! Lowering: MOV EDX, N; MOV RDI, R15 (rt); MOV ESI, typeidx; MOVABS R10 =
//! &jitGcAllocArray; CALL R10 → EAX = GcRef. Then MOV R10D, EAX (zero-
//! extend ref); R11 = [[R15 + gc_heap_off] + offsetOf(Heap,bytes)] (slab
//! base); ADD R11, R10 (object base = slab + ref). For each element i: load
//! value (stage-0 = R10); MOV [R11 + (12 + i*8)], value (64-bit) — x86_64
//! disp32 is byte-granular, so the 12-byte header folds into the
//! displacement with no base bias. EAX is untouched by the element loop, so
//! the result is captured from EAX last. Element slots uniform 8-byte
//! (ADR-0116 §3a). SysV: arg0=RDI, arg1=ESI, arg2=EDX, ret=EAX; R15 (rt)
//! callee-saved survives. Intel SDM Vol.2 (MOV 0x89/0x8B, MOVABS 0xB8,
//! CALL 0xFF /2, ADD 0x01).

const meta = @import("../../../../../instruction/wasm_3_0/array_new_fixed.zig");
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

/// ArrayHeader bytes (ObjectHeader 8 + length:u32 4); uniform 8-byte
/// element slots follow at offset 12 (ADR-0116 §3a).
const header_size: i32 = 12;
/// Emit scratch (caller-saved R10) — trampoline addr, then the
/// zero-extended ref (consumed into the object base), then the
/// gprLoadSpilled stage-0 element-value reg in the store loop.
const call_scratch: abi.Gpr = .r10;
/// Object-base scratch (emit stage-1 = R11; not in the regalloc pool).
/// Disjoint from gprLoadSpilled stage-0 (R10), so the element-value load
/// never clobbers the base.
const base_reg: abi.Gpr = .r11;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const typeidx: u32 = @intCast(ins.payload);
    const n: u32 = ins.extra;
    if (ctx.pushed_vregs.items.len < n) return ctx_mod.Error.AllocationMissing;

    // Alloc: EDX = N (length), RDI = rt (R15), ESI = typeidx,
    // CALL &jitGcAllocArray → EAX = ref.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(.rdx, n).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.q, .rdi, abi.runtime_ptr_save_gpr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(.rsi, typeidx).slice());
    const addr: u64 = @intFromPtr(&jit_abi.jitGcAllocArray);
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(call_scratch, addr).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(call_scratch).slice());

    // Object base R11 = slab + ref (slab base re-loaded post-call). MOV
    // R10D, EAX zero-extends the u32 ref into R10 before the 64-bit ADD.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, call_scratch, .rax).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base_reg, abi.runtime_ptr_save_gpr, jit_abi.gc_heap_off).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovR64FromMemDisp32(base_reg, base_reg, @offsetOf(heap_mod.Heap, "bytes")).slice());
    try ctx.buf.appendSlice(ctx.allocator, inst.encAddRR(.q, base_reg, call_scratch).slice());

    // Store elements. Operand stack top = last element (N-1); pop in
    // reverse so the bottom-most operand lands in element 0 ([base+12]).
    var i: u32 = n;
    while (i > 0) {
        i -= 1;
        const evreg = ctx.pushed_vregs.pop().?;
        const valreg = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, evreg, 0);
        const elem_off: i32 = header_size + @as(i32, @intCast(i)) * 8;
        try ctx.buf.appendSlice(ctx.allocator, inst.encStoreR64MemDisp32(valreg, base_reg, elem_off).slice());
    }

    // Push ref (result) — EAX still holds it (the element loop touches only
    // R10/R11/mem). Mirror struct.new's EAX capture.
    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return ctx_mod.Error.SlotOverflow;
    const rd = try gpr.gprDefSpilled(ctx.alloc, result, 0);
    if (rd != .rax) try ctx.buf.appendSlice(ctx.allocator, inst.encMovRR(.d, rd, .rax).slice());
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result);
}
