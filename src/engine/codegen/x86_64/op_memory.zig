//! x86_64 emit pass — memory load/store handlers (D-030 chunk-e).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape (`arm64/op_memory.zig`). Behaviour
//! change zero — handler bodies are unchanged from their pre-split
//! shape; only their home file moves.
//!
//! Single handler covers the i32 + f32 + f64 memory family
//! (8-byte aligned access size derived from op tag):
//!
//!   - i32.load{,8_s,8_u,16_s,16_u}, i32.store{,8,16}
//!   - f32.load, f32.store, f64.load, f64.store
//!
//! Shared eff-addr + spec-strict bounds-check prologue per Wasm
//! 1.0 spec §4.4.7 (memory.{load,store}): trap iff
//! `eff_addr + access_size > mem_limit`.
//!
//! RAX/RCX/RDX are pool-excluded scratches per `abi.zig`
//! (allocatable_caller_saved_scratch_gprs = R10+R11 only). The
//! op never coexists with i32 shift handlers within a single ZIR
//! instruction window, so RCX usage as bounds-check scratch is
//! safe (shifts also touch RCX as CL but only within their own
//! handler, never overlapping with this op).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const trace = @import("../../../diagnostic/trace.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// Wasm spec §4.4.7 (memory.load / memory.store family) — unified
/// handler for x86_64 memory ops (loads + stores + narrowed forms).
/// Mirrors `arm64/op_memory.zig:emitMemOp`'s shape: shared eff-addr
/// / bounds-check prologue, per-op final MOV/MOVZX/MOVSX encoding.
///
/// Per-op shape (load, spec-strict bounds: ea + size > mem_limit traps):
///   MOV RAX, [R15 + vm_base_off]
///   MOV EDX, idx_r              ; zero-extend idx → 64-bit RDX (= ea base)
///   ADD RDX, offset             ; (skipped if offset == 0)
///   LEA RCX, [RDX + access_size]; RCX = ea + size, RDX 無修正 (load addressing 用)
///   CMP RCX, [R15 + mem_limit_off]
///   JA  trap_stub               ; unsigned > ; bounds_fixups append
///   MOV[ZX|SX] dst, ... [RAX + RDX]
///
/// Per-op shape (store): same prologue, final form is
///   MOV [RAX + RDX], src        ; (32-bit, 16-bit, or 8-bit)
///
/// Per Wasm 1.0 spec §4.4.7: trap iff
/// `eff_addr + access_size > mem_limit` where access_size ∈
/// {1, 2, 4, 8}. u64 演算で overflow 不可 (max ≈ 2^33+7).
///
/// RAX/RCX/RDX は regalloc pool 外 (allocatable_caller_saved_
/// scratch_gprs = R10+R11 のみ; RAX/RCX/RDX は scratch 用に reserved)。
/// shifts は RCX を CL として使うが、shift handler と memory handler
/// は同一 op 内で交差しないため、RCX を bounds-check scratch として
/// 使うのは安全。
pub fn emitMemOp(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    op: zir.ZirOp,
    offset: u32,
    func_idx: u32,
) Error!void {
    const is_store = switch (op) {
        .@"i32.store", .@"i32.store8", .@"i32.store16",
        .@"i64.store", .@"i64.store8", .@"i64.store16", .@"i64.store32",
        .@"f32.store", .@"f64.store",
        => true,
        else => false,
    };
    const is_fp = switch (op) {
        .@"f32.load", .@"f64.load", .@"f32.store", .@"f64.store" => true,
        else => false,
    };

    var idx_v: u32 = 0;
    var val_v: u32 = 0;
    if (is_store) {
        if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
        val_v = pushed_vregs.pop().?;
        idx_v = pushed_vregs.pop().?;
    } else {
        if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
        idx_v = pushed_vregs.pop().?;
    }
    const idx_r = abi.slotToReg(alloc.slots[idx_v]) orelse return Error.SlotOverflow;

    // Per-op access size in bytes (Wasm spec memory.{load,store} 系)。
    // exhaustive switch (`require_exhaustive_enum_switch` lint gate);
    // dispatcher が memory op 以外を渡すことはないので else は unreachable。
    const access_size: i8 = switch (op) {
        .@"i32.load8_s", .@"i32.load8_u", .@"i32.store8",
        .@"i64.load8_s", .@"i64.load8_u", .@"i64.store8",
        => 1,
        .@"i32.load16_s", .@"i32.load16_u", .@"i32.store16",
        .@"i64.load16_s", .@"i64.load16_u", .@"i64.store16",
        => 2,
        .@"i32.load", .@"i32.store", .@"f32.load", .@"f32.store",
        .@"i64.load32_s", .@"i64.load32_u", .@"i64.store32",
        => 4,
        .@"i64.load", .@"i64.store", .@"f64.load", .@"f64.store" => 8,
        else => unreachable,
    };

    // Shared eff-addr + spec-strict bounds-check prologue.
    // ea = idx_r (zero-extended u32) + offset; trap iff ea + size > mem_limit。
    // u64 演算で overflow 不可: max(ea + size) = 2^33 + 7 << 2^64。
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rdx, idx_r).slice());
    if (offset != 0) {
        if (offset > 0x7FFFFFFF) return Error.SlotOverflow; // imm32 range
        try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, @intCast(offset)).slice());
    }
    try buf.appendSlice(allocator, inst.encLeaR64BaseDisp8(.rcx, .rdx, access_size).slice());
    try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rcx, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice()); // unsigned >
    try bounds_fixups.append(allocator, fixup_at);
    // ADR-0028 M3-a-1: record bounds-check emit site (no-op when
    // -Dtrace-ringbuffer=false; comptime-folded out of release).
    trace.writeBounds(func_idx, fixup_at);

    // Per-op final encoding.
    if (is_store) {
        if (is_fp) {
            const src_x = abi.fpSlotToReg(alloc.slots[val_v]) orelse return Error.SlotOverflow;
            const kind: inst.SseScalarKind = if (op == .@"f64.store") .f64 else .f32;
            try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(kind, true, src_x, .rax, .rdx).slice());
        } else {
            const src_r = abi.slotToReg(alloc.slots[val_v]) orelse return Error.SlotOverflow;
            const enc = switch (op) {
                .@"i32.store"    => inst.encStoreR32MemBaseIdx(src_r, .rax, .rdx),
                .@"i32.store8"   => inst.encStoreR8MemBaseIdx(src_r, .rax, .rdx),
                .@"i32.store16"  => inst.encStoreR16MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store"    => inst.encStoreR64MemBaseIdx(src_r, .rax, .rdx),
                // i64.store{8,16,32}: low N bits of the GPR; same
                // encoders as i32.store{8,16} + a 32-bit-store form
                // for the .32 variant.
                .@"i64.store8"   => inst.encStoreR8MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store16" => inst.encStoreR16MemBaseIdx(src_r, .rax, .rdx),
                .@"i64.store32"  => inst.encStoreR32MemBaseIdx(src_r, .rax, .rdx),
                else => unreachable,
            };
            try buf.appendSlice(allocator, enc.slice());
        }
    } else {
        const result_v = next_vreg.*;
        next_vreg.* += 1;
        if (result_v >= alloc.slots.len) return Error.SlotOverflow;
        if (is_fp) {
            const dst_x = abi.fpSlotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
            const kind: inst.SseScalarKind = if (op == .@"f64.load") .f64 else .f32;
            try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(kind, false, dst_x, .rax, .rdx).slice());
        } else {
            const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
            const enc = switch (op) {
                .@"i32.load"     => inst.encMovR32FromBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load8_s"  => inst.encMovsxR32_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load8_u"  => inst.encMovzxR32_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load16_s" => inst.encMovsxR32_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i32.load16_u" => inst.encMovzxR32_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load"     => inst.encMovR64FromBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load8_s"  => inst.encMovsxR64_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load8_u"  => inst.encMovzxR64_8MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load16_s" => inst.encMovsxR64_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load16_u" => inst.encMovzxR64_16MemBaseIdx(dst_r, .rax, .rdx),
                .@"i64.load32_s" => inst.encMovsxdR64_32MemBaseIdx(dst_r, .rax, .rdx),
                // i64.load32_u: MOV r32 zero-extends to r64 by AMD64
                // architectural rule (Intel SDM Vol 1 §3.4.1.1), so
                // the i32 encoder gives the right semantics for free.
                .@"i64.load32_u" => inst.encMovR32FromBaseIdx(dst_r, .rax, .rdx),
                else => unreachable,
            };
            try buf.appendSlice(allocator, enc.slice());
        }
        try pushed_vregs.append(allocator, result_v);
    }
}
