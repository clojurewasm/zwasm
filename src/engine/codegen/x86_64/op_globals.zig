//! x86_64 emit pass — global.get / global.set handlers (D-030 chunk-h).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape (`arm64/op_globals.zig`). Behaviour
//! change zero — handler bodies are unchanged from their pre-split
//! shape; only their home file moves.
//!
//! Per ADR-0027 + ADR-0026 reload pattern: `globals_base` is not
//! held in a callee-saved slot; it reloads from `[R15 + offset]`
//! at point of use. The cost (1 extra MOV vs ARM64's reserved-reg
//! read) is accepted per ADR-0026 §"Decision".
//!
//! **Scope**: i32 globals only. i64 / f32 / f64 / refs surface as
//! UnsupportedOp at the dispatcher (ZIR doesn't yet emit typed
//! global ops for non-i32). RAX is the GPR scratch (not in the
//! regalloc pool; cannot collide with any live vreg).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// Wasm spec §4.4.5 (global.get N) — push the value of global N
/// onto the operand stack. i32 lowering:
///
///   MOV RAX, [R15 + globals_base_off]  ; reload globals_base ptr
///   MOV R<dst>, [RAX + N*8]            ; load i32 (low 4 bytes of slot)
///
/// idx range: u32 from ZirInstr.payload; byte_offset = idx * 8
/// must fit i32 (≈ 268M globals max), well beyond Wasm spec.
pub fn emitI32GlobalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    idx: u32,
) Error!void {
    if (idx > 0x0FFF_FFFF) return Error.SlotOverflow; // sane Wasm-module ceiling
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
    const byte_off: i32 = @intCast(idx * 8);

    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.globals_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(dst_r, .rax, byte_off).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.4.5 (global.set N) — pop a vreg and store its low
/// 32 bits to `[globals_base + N*8]`. Upper 4 bytes of the slot
/// left untouched (i32-typed globals; slot zero-init at module
/// load).
pub fn emitI32GlobalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    idx: u32,
) Error!void {
    if (idx > 0x0FFF_FFFF) return Error.SlotOverflow;
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const byte_off: i32 = @intCast(idx * 8);

    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.globals_base_off).slice());
    try buf.appendSlice(allocator, inst.encStoreR32MemDisp32(src_r, .rax, byte_off).slice());
}
