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
const gpr = @import("gpr.zig");
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
    spill_base_off: u32,
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
    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_v, 0);

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
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, val_v, 0);
            const kind: inst.SseScalarKind = if (op == .@"f64.store") .f64 else .f32;
            try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(kind, true, src_x, .rax, .rdx).slice());
        } else {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, val_v, 1);
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
            const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 0);
            const kind: inst.SseScalarKind = if (op == .@"f64.load") .f64 else .f32;
            try buf.appendSlice(allocator, inst.encMovssMovsdMemBaseIdx(kind, false, dst_x, .rax, .rdx).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
        } else {
            const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
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
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
        }
        try pushed_vregs.append(allocator, result_v);
    }
}

// ============================================================
// Bulk-memory ops (Wasm 2.0 §4.4.7 — memory.fill / memory.copy)
//
// Stack effect: pops three i32 (n: top, val|src: middle, dst: bottom).
// No result pushed. Trap on out-of-bounds.
//
// Inline byte loop. Performance is Phase 8 work; correctness first.
//
// Register convention:
//   R15 = runtime_ptr_save (callee-saved). vm_base / mem_limit are
//     reloaded from `[R15 + offset]` at point of use.
//   R10/R11 = spill_stage_gprs (private to gprLoadSpilled; clobberable
//     between two such calls because each call only stages one value
//     and we capture into a private holder before the next load).
//   RAX = vm_base scratch. RCX = dst pointer / counter scratch.
//   RDX = src pointer (memory.copy) / val (memory.fill).
//
// The bounds-check trap stub (mem_limit overflow) is reached via a
// JA Jcc patched via `bounds_fixups` exactly like emitMemOp.
// ============================================================

/// Wasm spec §4.4.7 (memory.fill) — pop n / val / dst (top→bottom);
/// set `n` bytes at `[dst, dst+n)` to `val & 0xFF`. Trap if
/// `dst+n > mem_size`.
///
/// x86_64 lowering (Intel SDM Vol 2):
///   ; capture: RDX = val (32-bit), RCX = dst (zero-ext u32 → u64),
///   ;          R10 = n (zero-ext, used as counter — repurposing the
///   ;          spill-stage reg AFTER all spill-loads complete).
///   ;
///   ; bounds check: ea = dst + n;
///   ;   MOV RAX, dst              ; RAX = dst (zero-ext)
///   ;   ADD RAX, n
///   ;   CMP RAX, [R15 + mem_limit_off]
///   ;   JA  trap_stub             ; bounds_fixups append
///   ;
///   ; pointer setup:
///   ;   MOV RAX, [R15 + vm_base_off]
///   ;   ADD RCX, RAX              ; RCX = vm_base + dst
///   ;
///   ; loop:
///   ;   TEST R10, R10
///   ;   JZ   .end
///   ;   .loop:
///   ;     MOV  byte ptr [RCX], DL
///   ;     ADD  RCX, 1
///   ;     SUB  R10, 1                     (encoded as ADD imm32 -1)
///   ;     JNZ  .loop
///   ; .end:
pub fn emitMemoryFill(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = pushed_vregs.pop().?;
    const val_v = pushed_vregs.pop().?;
    const dst_v = pushed_vregs.pop().?;

    // Step A: load each operand and capture into private holders.
    //   dst → RCX (32-bit MOV zero-extends to RCX),
    //   val → RDX (low byte goes to DL),
    //   n   → R10 (overwriting stage 0 since all spill-loads done
    //         after this point).
    const dst_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, dst_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rcx, dst_r).slice());
    const val_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, val_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rdx, val_r).slice());
    const n_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, n_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .r10, n_r).slice());

    // Step B: bounds check — RAX = dst + n; cmp RAX, mem_limit.
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rax, .rcx).slice()); // zero-extends u32
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rax, .r10).slice());
    try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
    try bounds_fixups.append(allocator, fixup_at);
    trace.writeBounds(func_idx, fixup_at);

    // Step C: convert dst to absolute pointer.
    //   MOV RAX, [R15 + vm_base_off]
    //   ADD RCX, RAX
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rcx, .rax).slice());

    // Step D: skip if n == 0.
    //   TEST R10, R10  ; sets ZF if n == 0
    //   JZ   .end      ; placeholder, patched after loop
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice()); // JE = JZ

    // Step E: loop body.
    //   .loop:
    //     MOV [RCX], DL                    (encStoreR8MemBaseIdx with idx=ZERO not avail; use disp=0 form)
    //     ADD RCX, 1
    //     ADD R10, -1                      (= SUB R10, 1)
    //     JNZ .loop
    //
    // For the byte-store at `[RCX]` (no index reg), we synthesise it
    // via the existing base+idx encoder by passing idx=RAX with
    // RAX zeroed beforehand. Cleaner: use the encoder whose only
    // form takes [base+idx]. We previously zero-extended dst via
    // `MOV RAX, [R15+vm_base_off]` + `ADD RCX, RAX`; RAX now holds
    // vm_base which is non-zero. So instead, use base=RCX, idx=ZeroIdxReg.
    // We don't have a "no-idx" byte-store helper; the cheapest fix is
    // to zero a register (e.g. RAX) here and use it as the SIB index.
    //
    // Alternative: introduce a new encoder for `MOV [base+disp8], r8`.
    // For now, zero RAX once before the loop and reuse in every
    // iteration:
    //   XOR EAX, EAX        ; RAX = 0 (zero-extends)
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());

    const loop_start: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encStoreR8MemBaseIdx(.rdx, .rcx, .rax).slice()); // [RCX + 0] = DL
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice()); // SUB R10, 1 via ADD -1; sets ZF
    {
        const after_jnz: i32 = @as(i32, @intCast(buf.items.len)) + 6; // JNZ rel32 = 6 bytes
        const disp: i32 = @as(i32, @intCast(loop_start)) - after_jnz;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
    }

    // Step F: patch the skip target.
    const end_byte: u32 = @intCast(buf.items.len);
    const skip_disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_at)) + 6);
    const skip_word: [6]u8 = inst.encJccRel32(.e, skip_disp).slice()[0..6].*;
    @memcpy(buf.items[skip_at..][0..6], &skip_word);
}

/// Wasm spec §4.4.7 (memory.copy) — pop n / src / dst (top→bottom);
/// copy `n` bytes [src,src+n) → [dst,dst+n). memmove-style overlap
/// handling (backward when dst > src). Trap if either dst+n or
/// src+n > mem_size.
///
/// x86_64 lowering: same operand-capture discipline as memory.fill,
/// then a forward / backward branch on `dst <= src`.
///
/// Register layout after capture:
///   RCX = dst (zero-ext, then absolute pointer = vm_base + dst)
///   RDX = src (zero-ext, then absolute pointer)
///   R10 = n (counter)
///
/// Bounds check uses RAX as scratch; vm_base is loaded once (kept in
/// RAX) for both `ADD RCX, RAX` and `ADD RDX, RAX` after the bounds
/// pass.  Byte-load/store via `MOVZX` + `MOV [..]` through scratch.
pub fn emitMemoryCopy(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    func_idx: u32,
) Error!void {
    if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
    const n_v = pushed_vregs.pop().?;
    const src_v = pushed_vregs.pop().?;
    const dst_v = pushed_vregs.pop().?;

    // Step A: capture operands into RCX, RDX, R10.
    const dst_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, dst_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rcx, dst_r).slice());
    const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rdx, src_r).slice());
    const n_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, n_v, 0);
    try buf.appendSlice(allocator, inst.encMovRR(.d, .r10, n_r).slice());

    // Step B1: bounds check dst + n.
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rax, .rcx).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rax, .r10).slice());
    try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
        try bounds_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // Step B2: bounds check src + n.
    try buf.appendSlice(allocator, inst.encMovRR(.d, .rax, .rdx).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rax, .r10).slice());
    try buf.appendSlice(allocator, inst.encCmpR64MemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.a, 0).slice());
        try bounds_fixups.append(allocator, fixup_at);
        trace.writeBounds(func_idx, fixup_at);
    }

    // Step C: convert dst / src to absolute pointers.
    //   MOV RAX, [R15 + vm_base_off]
    //   ADD RCX, RAX ; ADD RDX, RAX
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.vm_base_off).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .rax).slice());

    // Step D: skip if n == 0.
    try buf.appendSlice(allocator, inst.encTestRR(.q, .r10, .r10).slice());
    const skip_zero_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice());

    // Step E: direction switch — CMP RCX, RDX; JBE forward.
    //   JBE = unsigned ≤. dst <= src → forward copy is safe.
    try buf.appendSlice(allocator, inst.encCmpRR(.q, .rcx, .rdx).slice());
    const fwd_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.be, 0).slice());

    // ---- Backward path. ----
    //   ADD RCX, R10           ; dst_p += n
    //   ADD RDX, R10           ; src_p += n
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rcx, .r10).slice());
    try buf.appendSlice(allocator, inst.encAddRR(.q, .rdx, .r10).slice());
    // Need a zero scratch for byte-base-idx encoders. Reuse RAX
    // (currently holds vm_base which is no longer needed).
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
    // .bwd_loop:
    //   ADD RCX, -1
    //   ADD RDX, -1
    //   MOVZX R11d, byte [RDX + RAX]  ; R11 is spill_stage, but at
    //                                  ; this point safe (no further
    //                                  ; spill-loads in this op).
    //   MOV [RCX + RAX], R11B          ; (low byte of R11)
    //   ADD R10, -1
    //   JNZ .bwd_loop
    const bwd_loop_start: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, -1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, -1).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.r11, .rdx, .rax).slice());
    try buf.appendSlice(allocator, inst.encStoreR8MemBaseIdx(.r11, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
    {
        const after_jnz: i32 = @as(i32, @intCast(buf.items.len)) + 6;
        const disp: i32 = @as(i32, @intCast(bwd_loop_start)) - after_jnz;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
    }
    // JMP .end (placeholder, patched after fwd loop).
    const bwd_end_jmp_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // ---- Forward path. ----
    // Patch the JBE.
    const fwd_byte: u32 = @intCast(buf.items.len);
    {
        const disp: i32 = @as(i32, @intCast(fwd_byte)) - (@as(i32, @intCast(fwd_at)) + 6);
        const word: [6]u8 = inst.encJccRel32(.be, disp).slice()[0..6].*;
        @memcpy(buf.items[fwd_at..][0..6], &word);
    }
    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
    // .fwd_loop:
    //   MOVZX R11d, byte [RDX + RAX]
    //   MOV   byte [RCX + RAX], R11B
    //   ADD   RCX, 1
    //   ADD   RDX, 1
    //   ADD   R10, -1
    //   JNZ   .fwd_loop
    const fwd_loop_start: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encMovzxR32_8MemBaseIdx(.r11, .rdx, .rax).slice());
    try buf.appendSlice(allocator, inst.encStoreR8MemBaseIdx(.r11, .rcx, .rax).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rcx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.rdx, 1).slice());
    try buf.appendSlice(allocator, inst.encAddR64Imm32(.r10, -1).slice());
    {
        const after_jnz: i32 = @as(i32, @intCast(buf.items.len)) + 6;
        const disp: i32 = @as(i32, @intCast(fwd_loop_start)) - after_jnz;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
    }

    // .end: patch n==0 skip and bwd→end JMP.
    const end_byte: u32 = @intCast(buf.items.len);
    {
        const disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(skip_zero_at)) + 6);
        const word: [6]u8 = inst.encJccRel32(.e, disp).slice()[0..6].*;
        @memcpy(buf.items[skip_zero_at..][0..6], &word);
    }
    {
        const disp: i32 = @as(i32, @intCast(end_byte)) - (@as(i32, @intCast(bwd_end_jmp_at)) + 5);
        const word: [5]u8 = inst.encJmpRel32(disp).slice()[0..5].*;
        @memcpy(buf.items[bwd_end_jmp_at..][0..5], &word);
    }
}
