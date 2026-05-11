//! x86_64 emit pass — global.get / global.set handlers.
//!
//! Per ADR-0027 (scalar) + ADR-0052 (v128): each defined global's
//! byte offset is looked up from the per-module
//! `globals_offsets[idx]` table; the matching valtype in
//! `globals_valtypes[idx]` selects the emit path. Scalar globals
//! (i32/i64/f32/f64/refs) use 8-byte slots; v128 globals use
//! 16-byte slots aligned to 16 bytes, addressed via MOVUPS.
//!
//! Per ADR-0026 reload pattern: `globals_base` is not held in a
//! callee-saved slot; it reloads from `[R15 + offset]` at point
//! of use. RAX is the GPR scratch (not in the regalloc pool).
//!
//! **Scope**: i32 + v128. i64 / f32 / f64 / refs surface as
//! UnsupportedOp at the dispatcher (ZIR doesn't yet emit typed
//! global ops for non-i32 scalars).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

fn lookupGlobalShape(
    idx: u32,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
) struct { byte_off: u32, vt: zir.ValType } {
    if (idx < globals_offsets.len) {
        return .{ .byte_off = globals_offsets[idx], .vt = globals_valtypes[idx] };
    }
    return .{ .byte_off = idx * 8, .vt = .i32 };
}

/// Wasm spec §4.4.5 (global.get N). Dispatch on valtype.
pub fn emitGlobalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    idx: u32,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
) Error!void {
    const shape = lookupGlobalShape(idx, globals_offsets, globals_valtypes);
    switch (shape.vt) {
        .i32 => try emitI32GlobalGet(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, idx, shape.byte_off),
        .v128 => try emitV128GlobalGet(allocator, buf, alloc, pushed_vregs, next_vreg, idx, shape.byte_off),
        .i64, .f32, .f64, .funcref, .externref => return Error.UnsupportedOp,
    }
}

pub fn emitGlobalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    idx: u32,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
) Error!void {
    const shape = lookupGlobalShape(idx, globals_offsets, globals_valtypes);
    switch (shape.vt) {
        .i32 => try emitI32GlobalSet(allocator, buf, alloc, pushed_vregs, spill_base_off, idx, shape.byte_off),
        .v128 => try emitV128GlobalSet(allocator, buf, alloc, pushed_vregs, idx, shape.byte_off),
        .i64, .f32, .f64, .funcref, .externref => return Error.UnsupportedOp,
    }
}

/// i32 lowering:
///   MOV RAX, [R15 + globals_base_off]   ; reload globals_base ptr
///   MOV R<dst>, [RAX + byte_off]        ; load i32 (low 4 bytes)
fn emitI32GlobalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    idx: u32,
    byte_off: u32,
) Error!void {
    if (idx > 0x0FFF_FFFF) return Error.SlotOverflow;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
    const disp: i32 = @intCast(byte_off);

    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.globals_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(dst_r, .rax, disp).slice());
    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

fn emitI32GlobalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    idx: u32,
    byte_off: u32,
) Error!void {
    if (idx > 0x0FFF_FFFF) return Error.SlotOverflow;
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const disp: i32 = @intCast(byte_off);

    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.globals_base_off).slice());
    try buf.appendSlice(allocator, inst.encStoreR32MemDisp32(src_r, .rax, disp).slice());
}

/// v128 lowering (ADR-0052 §3):
///   MOV RAX, [R15 + globals_base_off]   ; reload globals_base ptr
///   MOVUPS XMM<dst>, [RAX + byte_off]   ; 16-byte load
fn emitV128GlobalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    idx: u32,
    byte_off: u32,
) Error!void {
    if (idx > 0x0FFF_FFFF) return Error.SlotOverflow;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const dst_xmm = try gpr.resolveXmm(alloc, result_v);
    const disp: i32 = @intCast(byte_off);

    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.globals_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovupsXmmMemBaseDisp32(false, dst_xmm, .rax, disp).slice());
    try pushed_vregs.append(allocator, result_v);
}

/// v128 lowering:
///   MOV RAX, [R15 + globals_base_off]
///   MOVUPS [RAX + byte_off], XMM<src>
fn emitV128GlobalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    idx: u32,
    byte_off: u32,
) Error!void {
    if (idx > 0x0FFF_FFFF) return Error.SlotOverflow;
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const src_xmm = try gpr.resolveXmm(alloc, src_v);
    const disp: i32 = @intCast(byte_off);

    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.globals_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovupsXmmMemBaseDisp32(true, src_xmm, .rax, disp).slice());
}
