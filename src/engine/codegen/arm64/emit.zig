//! ZIR → ARM64 emit pass (§9.7 / 7.3 — skeleton).
//!
//! Walks a `ZirFunc.instrs` stream (consumed in def_pc order)
//! and emits a fixed-width AArch64 instruction stream into a
//! caller-supplied byte buffer. Slot ids from the §9.7 / 7.1
//! regalloc map to physical X-registers via §9.7 / 7.2's
//! `abi.slotToReg`.
//!
//! Phase 7.3 skeleton scope (this commit):
//! - Function prologue: save FP/LR, set up frame pointer.
//! - Function epilogue: restore FP/LR, RET.
//! - `i32.const` → `MOVZ Xd, #imm16` (lower 16 bits) +
//!   optional `MOVK` lanes for the upper 16 bits. Emits to a
//!   single result register dictated by the function's return
//!   slot.
//! - `end` of function → epilogue.
//!
//! Other op handlers land in subsequent §9.7 / 7.3 commits
//! per the row's "produce function bodies" exit; the §9.7 / 7.4
//! spec-pass gate is what closes the full op-coverage loop.
//!
//! AAPCS64 prologue / epilogue shape (per Arm IHI 0055 §6.4):
//!
//!   prologue:
//!     STP FP, LR, [SP, #-16]!     // push FP/LR pair
//!     MOV FP, SP                   // set frame pointer
//!     [optional: SUB SP, SP, #N for locals]
//!
//!   epilogue:
//!     [optional: ADD SP, SP, #N]
//!     LDP FP, LR, [SP], #16        // pop FP/LR pair
//!     RET
//!
//! For 7.3 skeleton we omit the optional stack-frame
//! adjustment (no spilled vregs in straight-line MVP code with
//! ≤17 GPRs available; spills are §9.7 / 7.3 follow-up).
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
const abi = @import("abi.zig");
const label_mod = @import("label.zig");
const regalloc = @import("../shared/regalloc.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const op_const = @import("op_const.zig");
const op_alu_int = @import("op_alu_int.zig");
const op_alu_float = @import("op_alu_float.zig");
const op_convert = @import("op_convert.zig");
const op_memory = @import("op_memory.zig");
const op_control = @import("op_control.zig");
const op_call = @import("op_call.zig");
const op_globals = @import("op_globals.zig");
const op_simd = @import("op_simd.zig");
const op_simd_int_arith = @import("op_simd_int_arith.zig");
const op_simd_int_cmp_lane = @import("op_simd_int_cmp_lane.zig");
const op_simd_float = @import("op_simd_float.zig");
const bounds_check = @import("bounds_check.zig");

const Label = label_mod.Label;
const LabelKind = label_mod.LabelKind;
const Fixup = label_mod.Fixup;
const FixupKind = label_mod.FixupKind;

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const Xn = inst.Xn;
const EmitCtx = ctx_mod.EmitCtx;

/// Re-export from `ctx.zig`. The error set lives there so
/// op-handler modules can import it without reaching back to
/// emit.zig.
pub const Error = ctx_mod.Error;

/// Re-export from `ctx.zig`. See `ctx.CallFixup`.
pub const CallFixup = ctx_mod.CallFixup;

pub const EmitOutput = struct {
    /// Encoded function body bytes (little-endian u32 stream).
    /// Caller owns; pair with `deinit` to free.
    bytes: []u8,
    /// Distinct GPR slots used (mirrors `Allocation.n_slots`).
    /// The §9.7 / 7.4 gate consults this for stack-frame sizing
    /// when the spill follow-up lands.
    n_slots: u16,
    /// `BL` fixup sites. Each is a placeholder that the caller
    /// patches once function-body addresses are known.
    /// Caller-owned; pair with `deinit` to free.
    call_fixups: []CallFixup,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
    if (out.call_fixups.len != 0) allocator.free(out.call_fixups);
}

/// §9.7 / 7.9-d-11: pre-scan the function body for the worst-case
/// outgoing-args region size (caller-side stack-arg lowering per
/// AAPCS64 §6.4.2). For each `call N` / `call_indirect type_idx`
/// instruction, count the args that overflow the X1..X7 (int) and
/// V0..V7 (fp) register pools and sum the per-slot 8-byte
/// allocations; track the max across all calls. This region sits
/// at the bottom of the caller's frame (`[SP, #0]` upward), so
/// callee can read overflows at `[X29, #16 + 8*K]`.
fn computeOutgoingMaxBytes(
    func: *const ZirFunc,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
) u32 {
    var max_bytes: u32 = 0;
    for (func.instrs.items) |ins| {
        const sig: ?zir.FuncType = switch (ins.op) {
            .call => if (ins.payload < func_sigs.len) func_sigs[ins.payload] else null,
            .call_indirect => if (ins.payload < module_types.len) module_types[ins.payload] else null,
            else => null,
        };
        const callee_sig = sig orelse continue;
        var n_int: u32 = 0;
        var n_fp: u32 = 0;
        for (callee_sig.params) |p| {
            switch (p) {
                .i32, .i64 => n_int += 1,
                .f32, .f64 => n_fp += 1,
                .v128, .funcref, .externref => {},
            }
        }
        // X0 = `*JitRuntime` per ADR-0017, so user int args use
        // X1..X7 (7 slots). FP args use V0..V7 (8 slots).
        const n_int_overflow: u32 = if (n_int > 7) n_int - 7 else 0;
        const n_fp_overflow: u32 = if (n_fp > 8) n_fp - 8 else 0;
        const bytes = (n_int_overflow + n_fp_overflow) * 8;
        if (bytes > max_bytes) max_bytes = bytes;
    }
    return max_bytes;
}

/// §9.9 / 9.9-e-1: per-function local-frame layout. Wasm locals
/// (params + declared) are split by type into two regions:
/// scalars (i32 / i64 / f32 / f64 / refs) at 8-byte stride, then
/// v128 at 16-byte stride. The split keeps the per-local offset
/// formula pure (a single offset table consulted by index) AND
/// avoids the per-slot 16-byte waste of a uniform v128-stride
/// frame. Per `private/notes/p9-9.9-e-survey.md` strategy C.
///
/// `offsets[i]` is the byte offset within the locals zone
/// (relative to `local_base_off`) for Wasm-local-index `i`.
/// `total_bytes` includes any tail padding for v128 alignment.
/// The callee zero-initialises declared locals (Wasm spec
/// §4.5.3.1) using offsets[N..total_locals].
const LocalLayout = struct {
    offsets: []u32,
    total_bytes: u32,
    v128_count: u32,

    fn deinit(self: *LocalLayout, allocator: Allocator) void {
        if (self.offsets.len != 0) allocator.free(self.offsets);
    }
};

/// Compute `LocalLayout` from `func.sig.params` + `func.locals`
/// (+ synthetic_locals via `func.totalLocalCount`). Two-pass:
/// pass 1 counts scalars vs v128; pass 2 assigns offsets in
/// declaration order — scalars consume the low region (8-byte
/// stride), v128 the high region (16-byte stride, base rounded
/// up to 16 from the scalar tail). Caller frees `offsets` via
/// `LocalLayout.deinit`.
fn computeLocalLayout(allocator: Allocator, func: *const ZirFunc) Error!LocalLayout {
    const num_params: u32 = @intCast(func.sig.params.len);
    const num_locals: u32 = func.totalLocalCount();
    const total_locals: u32 = num_params + num_locals;
    if (total_locals == 0) {
        return .{ .offsets = &.{}, .total_bytes = 0, .v128_count = 0 };
    }
    const offsets = try allocator.alloc(u32, total_locals);
    errdefer allocator.free(offsets);

    var scalar_count: u32 = 0;
    var v128_count: u32 = 0;
    var i: u32 = 0;
    while (i < total_locals) : (i += 1) {
        if (func.localValType(i) == .v128) v128_count += 1 else scalar_count += 1;
    }

    const scalar_bytes: u32 = scalar_count * 8;
    // v128 region must be 16-byte aligned within the locals zone.
    // Caller (compile()) rounds `local_base_off` up to 16 when
    // v128_count > 0 so that `local_base_off + v128_region_off`
    // is a multiple of 16 in the SP-relative absolute frame.
    const v128_region_off: u32 = if (v128_count == 0) scalar_bytes else (scalar_bytes + 15) & ~@as(u32, 15);
    const total_bytes: u32 = v128_region_off + v128_count * 16;

    var scalar_within: u32 = 0;
    var v128_within: u32 = 0;
    i = 0;
    while (i < total_locals) : (i += 1) {
        if (func.localValType(i) == .v128) {
            offsets[i] = v128_region_off + v128_within * 16;
            v128_within += 1;
        } else {
            offsets[i] = scalar_within * 8;
            scalar_within += 1;
        }
    }

    return .{ .offsets = offsets, .total_bytes = total_bytes, .v128_count = v128_count };
}

/// Emit ARM64 machine code for `func`. Requires `alloc.slots`
/// to be populated (call `regalloc.compute` first; pass the
/// `Allocation` here).
///
/// `func_sigs[k]` is the FuncType of function index `k`; consulted
/// by the `call N` handler to pick the result register class
/// (W0/X0/S0/D0). `module_types[t]` is the FuncType for type
/// index `t`; consulted by `call_indirect type_idx`. Both default
/// to empty slices for tests that don't exercise calls — the call
/// handlers fail with `AllocationMissing` if the index is out of
/// range, so callers must size the tables to the called indices.
pub fn compile(
    allocator: Allocator,
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
    num_imports: u32,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
) Error!EmitOutput {
    if (alloc.slots.len != (func.liveness orelse return Error.AllocationMissing).ranges.len) {
        return Error.AllocationMissing;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // ============================================================
    // Prologue: STP FP, LR, [SP, #-16]! ; MOV FP, SP ; SUB SP, SP, #frame
    //
    // Locals layout (per ZirFunc.locals; params unsupported in this
    // skeleton — see scope note below): each i32 local occupies an
    // 8-byte slot at [SP, #(K*8)] for stable 8-byte alignment +
    // simple imm12 LDR/STR W addressing. Frame size rounds up to
    // 16 bytes per AAPCS64 §6.4 (SP must stay 16-byte aligned).
    // ============================================================
    // Multi-arg entry (§9.7 / 7.5-multi-arg-entry / -i64-params /
    // -fp-params):
    // - AAPCS64 §6.4: int args in X0..X7; FP args in V0..V7.
    //   X0 is `*const JitRuntime` (ADR-0017), so user int args
    //   start at X1 (max 7). FP args have their own sequence
    //   starting at V0 (max 8). Mixed-type signatures interleave
    //   per declaration order but each type class indexes its own
    //   arg-reg counter.
    // - Per-class stores: i32 → STR W, i64 → STR X, f32 → STR S,
    //   f64 → STR D. v128 / refs still surface as UnsupportedOp.
    // - §9.7 / 7.9-d-7 — AAPCS64 §6.4.2 stack-arg lowering: when
    //   a class would overflow (int > X7 or fp > V7), the arg
    //   (and every subsequent arg of the SAME class) lands on
    //   the caller's stack at `[X29, #16 + 8*stack_arg_idx]`
    //   (the +16 skips the saved FP/LR pair pushed by the
    //   `STP X29,X30,[SP,#-16]!` prologue). Per AAPCS64 each
    //   class tracks its own overflow point independently;
    //   they share one NSAA stream. Loaded into X16 (GPR
    //   scratch) / V16 (FP scratch) and re-stored to the
    //   local-slot at `[SP, p_idx*8]`.
    for (func.sig.params) |p| {
        switch (p) {
            .i32, .i64, .f32, .f64, .v128 => {},
            .funcref, .externref => {
                std.debug.print("arm64/emit: param type `{s}` unsupported (func_idx={d})\n", .{ @tagName(p), func.func_idx });
                return Error.UnsupportedOp;
            },
        }
    }
    const num_params: u32 = @intCast(func.sig.params.len);
    const num_locals: u32 = func.totalLocalCount();
    // Wasm local-index space: 0..num_params-1 = params,
    // num_params..num_params+num_locals-1 = declared locals.
    // §9.9 / 9.9-e-1: per-local frame layout split by type
    // (scalars 8-byte stride, v128 16-byte stride). See
    // `computeLocalLayout` doc for the strategy.
    const total_locals: u32 = num_params + num_locals;
    var layout = try computeLocalLayout(allocator, func);
    defer layout.deinit(allocator);
    const locals_bytes: u32 = layout.total_bytes;
    // ADR-0018: extend frame by spill region. Layout:
    //   [SP + 0 .. locals_bytes-1]                   locals
    //   [SP + locals_bytes .. +spill_bytes-1]        spills
    // `spill_base_off` is the absolute SP-relative offset where
    // spill slot 0 lives; `gprLoadSpilled`/`gprStoreSpilled`
    // consume it via byte_offset = spill_base_off + slot.spill.
    const spill_bytes: u32 = alloc.spillBytes();
    // §9.7 / 7.9-d-11: outgoing args (caller-side stack args)
    // occupy the BOTTOM of the frame so the callee reads them at
    // `[X29, #16 + 8*K]` (per AAPCS64 §6.4.2 stage C.13/C.14).
    // Locals + spills shift upward by `local_base_off`.
    //   [SP + 0 .. outgoing_max-1]                     outgoing args
    //   [SP + outgoing_max .. +locals_bytes-1]         locals
    //   [SP + outgoing_max + locals_bytes .. +spill]   spills
    //
    // §9.9-e-1: when v128 locals are present, round the locals-
    // zone base up to 16 so `local_base_off + layout.offsets[v128
    // _idx]` is 16-aligned (`encStrQImm` / `encLdrQImm` reject
    // misaligned imm12). The 0-7 byte rounding waste is bounded
    // and amortised against the v128-bearing path.
    const outgoing_max_raw: u32 = computeOutgoingMaxBytes(func, func_sigs, module_types);
    const outgoing_max_bytes: u32 = if (layout.v128_count > 0) (outgoing_max_raw + 15) & ~@as(u32, 15) else outgoing_max_raw;
    const local_base_off: u32 = outgoing_max_bytes;
    const spill_base_off: u32 = local_base_off + locals_bytes;
    const frame_bytes_unaligned: u32 = outgoing_max_bytes + locals_bytes + spill_bytes;
    const frame_bytes: u32 = (frame_bytes_unaligned + 15) & ~@as(u32, 15);
    try gpr.writeU32(allocator, &buf, encStpFpLrPreIdx());
    try gpr.writeU32(allocator, &buf, encMovSpToFp());
    // ADR-0017 prologue: 5 LDRs from X0 = `*const JitRuntime`
    // into the reserved invariant regs. Per ROADMAP §2 P3 (cold-
    // start over peak throughput), 5 cycles uncached overhead is
    // acceptable for Phase 7 baseline; Phase 15 optimisation may
    // elide loads when the function provably doesn't use the
    // corresponding invariant.
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(28, 0, jit_abi.vm_base_off));
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(27, 0, jit_abi.mem_limit_off));
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(26, 0, jit_abi.funcptr_base_off));
    try gpr.writeU32(allocator, &buf, inst.encLdrImmW(25, 0, jit_abi.table_size_off));
    try gpr.writeU32(allocator, &buf, inst.encLdrImm(24, 0, jit_abi.typeidx_base_off));
    // ADR-0027 prescan: load X23 ← globals_base only when this
    // function actually consults a global. Functions without
    // global ops keep the pre-ADR-0027 prologue shape (zero
    // churn for existing tests).
    const uses_globals = blk: {
        for (func.instrs.items) |ins| {
            switch (ins.op) {
                .@"global.get", .@"global.set" => break :blk true,
                else => {},
            }
        }
        break :blk false;
    };
    if (uses_globals) {
        try gpr.writeU32(allocator, &buf, inst.encLdrImm(abi.globals_base_save_gpr, 0, jit_abi.globals_base_off));
    }
    // ADR-0017 sub-2d-ii: save runtime ptr to X19 so multi-call
    // functions can restore X0 before each BL/BLR. X19 is callee-
    // saved per AAPCS64 — preserved across calls without explicit
    // save/restore.
    try gpr.writeU32(allocator, &buf, inst.encOrrReg(abi.runtime_ptr_save_gpr, 31, 0));
    // §9.8a / 8a.2 (ADR-0034) — JIT-execution sentinel: write 1 to
    // `JitRuntime.jit_executed_flag` so post-call readers can
    // distinguish "JIT body actually ran" from "compile-passed but
    // never invoked". MOVZ X17, #1 (W17 = 1) + STR W17, [X19,
    // #flag_off]. X17 = IP1 (Arm IHI 0055 §6.4 caller-saved scratch);
    // safe to clobber since the body has not started yet. 8 bytes /
    // 2 insns; runs unconditionally per ROADMAP §A12 (no build-flag
    // gate; cost amortised below bench noise).
    try gpr.writeU32(allocator, &buf, inst.encMovzImm16(17, 1));
    try gpr.writeU32(allocator, &buf, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.jit_executed_flag_off));
    if (frame_bytes > 0) {
        // Chunk d-9: support frame_bytes up to 16 MiB-1 via the
        // two-step `SUB SP, SP, #(N>>12), lsl #12; SUB SP, SP,
        // #(N&0xFFF)` sequence. Larger needs a MOVZ/MOVK chain
        // (post-MVP). Long Go binaries with deep spill regions
        // exceed the prior 4096 cap.
        if (frame_bytes > 0xFFFFFF) return Error.SlotOverflow;
        const fb_high: u12 = @intCast((frame_bytes >> 12) & 0xFFF);
        const fb_low: u12 = @intCast(frame_bytes & 0xFFF);
        if (fb_high != 0) try gpr.writeU32(allocator, &buf, inst.encSubImm12Lsl12(31, 31, fb_high));
        if (fb_low != 0) try gpr.writeU32(allocator, &buf, inst.encSubImm12(31, 31, fb_low));
    }

    // Multi-arg entry: store params from X1..X{num_params} into
    // their stack slots [SP + 0], [SP + 8], … so subsequent
    // `local.get N` (N < num_params) reads from the same slot
    // shape as declared locals. Per AAPCS64 §6.4: i32 args are
    // passed with the upper 32 bits of the X register undefined,
    // so STR W (32-bit) is mandatory for .i32 to avoid storing
    // caller garbage in the high half. i64 args use STR X
    // (full 64-bit). AAPCS64 X0 = `*const JitRuntime` (already
    // snapshotted to X19 above), X1 = param 0, etc.
    var p_idx: u32 = 0;
    var int_arg_idx: u5 = 1; // X0 = runtime ptr; user int args from X1
    var fp_arg_idx: u5 = 0; // V0..V7 for FP args
    // §9.7 / 7.9-d-7: per-call NSAA index (Arm IHI 0055 §6.4.2
    // stage C.13/C.14). Each overflowed arg consumes one 8-byte
    // slot at [X29, #(16 + 8*stack_arg_idx)]; +16 skips the
    // saved FP/LR pair pushed by the prologue's pre-index STP.
    var stack_arg_idx: u14 = 0;
    while (p_idx < num_params) : (p_idx += 1) {
        // §9.7 / 7.9-d-11 / §9.9-e-1: param slot lives at
        // `[SP, #(local_base_off + layout.offsets[p_idx])]`. The
        // local region sits above the outgoing-args region.
        // Per-type encoding caps:
        //   STR W (.i32 / .f32): byte_offset ≤ 16380 (imm12*4)
        //   STR X (.i64 / .f64): byte_offset ≤ 32760 (imm12*8)
        //   STR Q (.v128): byte_offset ≤ 65520 (imm12*16) +
        //   16-byte alignment (`local_base_off` rounded above).
        const param_off_u: u32 = local_base_off + layout.offsets[p_idx];
        const param_ty = func.sig.params[p_idx];
        const cap: u32 = switch (param_ty) {
            .i32, .f32 => 16380,
            .i64, .f64 => 32760,
            .v128 => 65520,
            .funcref, .externref => unreachable,
        };
        if (param_off_u > cap) return Error.UnsupportedOp;
        const param_off_w: u14 = if (param_ty == .i32 or param_ty == .f32) @intCast(param_off_u) else 0;
        const param_off_x: u15 = if (param_ty == .i64 or param_ty == .f64) @intCast(param_off_u) else 0;
        const param_off_v128: u16 = if (param_ty == .v128) @intCast(param_off_u) else 0;
        switch (param_ty) {
            .i32 => {
                if (int_arg_idx > 7) {
                    const stack_off_u: u32 = 16 + @as(u32, stack_arg_idx) * 8;
                    if (stack_off_u > 32760) return Error.UnsupportedOp;
                    // i32 stack args are zero-extended to 8 bytes
                    // by the caller per AAPCS64 §6.4.2 stage C.16
                    // (8-byte slot, low 4 bytes hold the value).
                    const stack_off_w: u14 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst.encLdrImmW(16, 29, stack_off_w));
                    try gpr.writeU32(allocator, &buf, inst.encStrImmW(16, 31, param_off_w));
                    stack_arg_idx += 1;
                } else {
                    try gpr.writeU32(allocator, &buf, inst.encStrImmW(int_arg_idx, 31, param_off_w));
                    int_arg_idx += 1;
                }
            },
            .i64 => {
                if (int_arg_idx > 7) {
                    const stack_off_u: u32 = 16 + @as(u32, stack_arg_idx) * 8;
                    if (stack_off_u > 32760) return Error.UnsupportedOp;
                    const stack_off: u15 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst.encLdrImm(16, 29, stack_off));
                    try gpr.writeU32(allocator, &buf, inst.encStrImm(16, 31, param_off_x));
                    stack_arg_idx += 1;
                } else {
                    try gpr.writeU32(allocator, &buf, inst.encStrImm(int_arg_idx, 31, param_off_x));
                    int_arg_idx += 1;
                }
            },
            .f32 => {
                if (fp_arg_idx > 7) {
                    const stack_off_u: u32 = 16 + @as(u32, stack_arg_idx) * 8;
                    if (stack_off_u > 32760) return Error.UnsupportedOp;
                    // f32 stack args are zero-extended to 8 bytes
                    // by the caller; load the low 4 bytes via
                    // `LDR S16` (4-byte align — 16+8K is always
                    // 8-aligned, so 4-aligned holds).
                    const stack_off: u14 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst.encLdrSImm(16, 29, stack_off));
                    try gpr.writeU32(allocator, &buf, inst.encStrSImm(16, 31, param_off_w));
                    stack_arg_idx += 1;
                } else {
                    try gpr.writeU32(allocator, &buf, inst.encStrSImm(fp_arg_idx, 31, param_off_w));
                    fp_arg_idx += 1;
                }
            },
            .f64 => {
                if (fp_arg_idx > 7) {
                    const stack_off_u: u32 = 16 + @as(u32, stack_arg_idx) * 8;
                    if (stack_off_u > 32760) return Error.UnsupportedOp;
                    const stack_off: u15 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst.encLdrDImm(16, 29, stack_off));
                    try gpr.writeU32(allocator, &buf, inst.encStrDImm(16, 31, param_off_x));
                    stack_arg_idx += 1;
                } else {
                    try gpr.writeU32(allocator, &buf, inst.encStrDImm(fp_arg_idx, 31, param_off_x));
                    fp_arg_idx += 1;
                }
            },
            // §9.9 / 9.9-e-1: v128 param marshal per AAPCS64
            // §6.4 SIMD calling convention. v128 args arrive in
            // V0..V7; stash via `STR Q V<n>, [SP, #param_off_v128]`.
            // Overflow path per §6.4.2 stage C.4: align next stack
            // arg to 16 (consume 1 padding slot if odd), then load
            // the 16-byte v128 from `[X29, #(16 + 8*stack_arg_idx)]`
            // and re-store. Each overflow v128 consumes 2 of the
            // 8-byte stack-arg slots.
            .v128 => {
                if (fp_arg_idx > 7) {
                    if (stack_arg_idx & 1 != 0) stack_arg_idx += 1;
                    const stack_off_u: u32 = 16 + @as(u32, stack_arg_idx) * 8;
                    if (stack_off_u > 65520) return Error.UnsupportedOp;
                    const stack_off: u16 = @intCast(stack_off_u);
                    try gpr.writeU32(allocator, &buf, inst_neon.encLdrQImm(16, 29, stack_off));
                    try gpr.writeU32(allocator, &buf, inst_neon.encStrQImm(16, 31, param_off_v128));
                    stack_arg_idx += 2;
                } else {
                    try gpr.writeU32(allocator, &buf, inst_neon.encStrQImm(fp_arg_idx, 31, param_off_v128));
                    fp_arg_idx += 1;
                }
            },
            // refs were filtered above; exhaustive for zlinter.
            .funcref, .externref => unreachable,
        }
    }

    // Zero-initialise declared locals (Wasm spec §4.5.3.1: locals
    // beyond params are initialised to zero on entry). Scalar
    // slots (8 bytes) get STR XZR; v128 slots (16 bytes) get two
    // STR XZR (no SIMD-zero-immediate encoder; ZR-pair is the
    // canonical zero pattern and is bench-cost identical to
    // `MOVI V31.16B, #0; STR Q V31`).
    var loc_idx: u32 = num_params;
    while (loc_idx < total_locals) : (loc_idx += 1) {
        const loc_off_u: u32 = local_base_off + layout.offsets[loc_idx];
        const ty = func.localValType(loc_idx);
        if (ty == .v128) {
            if (loc_off_u + 8 > 32760) return Error.UnsupportedOp;
            const lo_off: u15 = @intCast(loc_off_u);
            const hi_off: u15 = @intCast(loc_off_u + 8);
            try gpr.writeU32(allocator, &buf, inst.encStrImm(31, 31, lo_off));
            try gpr.writeU32(allocator, &buf, inst.encStrImm(31, 31, hi_off));
        } else {
            if (loc_off_u > 32760) return Error.UnsupportedOp;
            const loc_off: u15 = @intCast(loc_off_u);
            try gpr.writeU32(allocator, &buf, inst.encStrImm(31, 31, loc_off));
        }
    }

    // ============================================================
    // Body: walk instrs, dispatch per op.
    //
    // For Phase 7.3 skeleton: track a "result vreg" cursor that
    // records which vreg holds the latest pushed value. The
    // function's `end` reads that vreg, ensures it ends up in X0
    // (the AAPCS64 return register), and then runs the epilogue.
    // ============================================================
    var pushed_vregs: std.ArrayList(u32) = .empty;
    defer pushed_vregs.deinit(allocator);
    var next_vreg: u32 = 0;

    // ============================================================
    // Label stack — supports `block` / `loop` + `br N` / `br_if N`.
    //
    // Each entry tracks:
    //   kind      — .block (forward branches resolve at `end`) or
    //               .loop (backward branches resolve at the loop
    //               entry).
    //   target_byte_offset — for .loop, the byte offset of the
    //               loop entry. For .block, undefined until `end`
    //               lands; pending fixups are patched at that
    //               point.
    //   pending   — fixup records (byte_offset of branch + kind)
    //               needing patch when the label resolves.
    //
    // This lives in emit.zig (not as a separate type) because the
    // patching machinery is tightly coupled to the buf layout.
    // ============================================================
    var labels: std.ArrayList(Label) = .empty;
    defer {
        for (labels.items) |*l| l.pending.deinit(allocator);
        labels.deinit(allocator);
    }

    // ============================================================
    // Memory-bounds trap fixup list (sub-f1).
    //
    // Caller-supplied invariants for memory ops in this skeleton:
    //   X28 = vm_base    (memory_base pointer)
    //   X27 = mem_limit  (size in bytes)
    // The caller arranges these before invoking the JIT body.
    // Phase-7 follow-up wires Runtime → these regs structurally
    // (D-014 `Runtime.io` injection point dissolves there).
    //
    // Each i32.load / i32.store / etc. emits:
    //   ORR W16, WZR, W_addr   ; zero-extend addr to X16
    //   ADD X16, X16, #imm     ; effective addr
    //   CMP X16, X27           ; bounds
    //   B.HS  trap_stub        ; branch on unsigned >= (placeholder + fixup)
    //   LDR/STR W_dest, [X28, X16]
    //
    // The B.HS fixup byte_offset is appended here. At function-final
    // `end`, after the regular epilogue+RET, a trap stub is emitted
    // and all bounds_fixups are patched to point at it.
    var bounds_fixups: std.ArrayList(u32) = .empty;
    defer bounds_fixups.deinit(allocator);

    // Return fixup list (§9.7 / 7.5-return-op): each `return` op
    // emits its result marshal inline and an unconditional B
    // placeholder; the byte_offset of the placeholder lives here.
    // At function-final `end`, after the marshal but before the
    // frame teardown, all return_fixups are patched to point at
    // the start of the teardown sequence (so `return` shares the
    // single epilogue path).
    var return_fixups: std.ArrayList(u32) = .empty;
    defer return_fixups.deinit(allocator);

    // Call fixup list — exposed via EmitOutput for the post-emit
    // linker / runtime to patch with concrete func-body offsets.
    // Sub-g1 skeleton: only `call` is supported; call_indirect
    // lands in sub-g2 with a different mechanism (table lookup +
    // BLR).
    var call_fixups: std.ArrayList(CallFixup) = .empty;
    errdefer call_fixups.deinit(allocator);

    // SIMD const-pool fixups (per ADR-0042). Each LDR-Q-literal
    // placeholder records (byte_offset, simd_consts index); patched
    // at function close after the const-pool is appended past the
    // trap stub.
    var simd_const_fixups: std.ArrayList(ctx_mod.SimdConstFixup) = .empty;
    defer simd_const_fixups.deinit(allocator);

    // Emit-time-derived 16-byte SIMD constants (per ADR-0051;
    // mirror of x86_64's `extra_consts`). Per-op handlers append
    // shape masks / magic constants here; at function close the
    // list is concatenated after `func.simd_consts` in the flat
    // pool so fixups address both sources via a single global
    // const_idx.
    var extra_consts: std.ArrayList([16]u8) = .empty;
    defer extra_consts.deinit(allocator);

    // Base offset into the flat const-pool that extra_consts
    // entries map to. Lower-time entries occupy
    // `[0, simd_consts_base)`; extra_consts occupy
    // `[simd_consts_base, ...)`. Immutable for the function.
    const simd_consts_base: u32 = if (func.simd_consts) |sc|
        @intCast(sc.len)
    else
        0;

    // Bundle compile()'s mutable state behind a pointer-based
    // EmitCtx so extracted op-handler modules (op_const, op_alu,
    // …) observe the same backing storage as the still-inlined
    // handlers. Op groups migrate one at a time; both views
    // coexist.
    var ctx: EmitCtx = .{
        .allocator = allocator,
        .buf = &buf,
        .func = func,
        .alloc = alloc,
        .func_sigs = func_sigs,
        .module_types = module_types,
        .pushed_vregs = &pushed_vregs,
        .next_vreg = &next_vreg,
        .labels = &labels,
        .bounds_fixups = &bounds_fixups,
        .return_fixups = &return_fixups,
        .call_fixups = &call_fixups,
        .simd_const_fixups = &simd_const_fixups,
        .extra_consts = &extra_consts,
        .simd_consts_base = simd_consts_base,
        .local_base_off = local_base_off,
        .spill_base_off = spill_base_off,
        .num_imports = num_imports,
        .globals_offsets = globals_offsets,
        .globals_valtypes = globals_valtypes,
    };

    // §9.7 / 7.5-emit-deadcode: track polymorphic-stack dead
    // regions per Wasm spec §3.3. After br / return /
    // unreachable, subsequent ops up to the next structural
    // marker (end / else) are dead — never executed at runtime
    // because the unconditional branch jumps over them. Skipping
    // them in emit avoids spurious AllocationMissing on pops
    // that the validator already deemed polymorphic-OK.
    var dead_code: bool = false;
    for (func.instrs.items, 0..) |ins, pc| {
        // §9.8a / 8a.5 — diagnostic surface: on any error return
        // from the per-op switch below, surface the failing op
        // tag + pc so the realworld_run_jit cap-removal regression
        // (D-053 + D-054) can localise to a specific opcode handler
        // instead of a generic `UnsupportedOp` at the runner.
        errdefer std.debug.print(
            "arm64/emit: failing op `{s}` at func[{d}] pc={d}\n",
            .{ @tagName(ins.op), func.func_idx, pc },
        );
        // Structural markers exit the dead region. `end` and
        // `else` always run their handlers — `end` to pop the
        // label stack / emit function epilogue; `else` to switch
        // to the else-arm of an if. Both are needed for emit's
        // own bookkeeping to stay aligned with the block nesting.
        if (ins.op == .end or ins.op == .@"else") {
            dead_code = false;
        }
        if (dead_code) {
            // Maintain labels-stack consistency for structural
            // ops in dead regions (§9.7 / 7.5-deadcode-labels-
            // bookkeeping). Without these placeholder pushes,
            // subsequent `end` / `else` cannot find their
            // matching frame and surface as
            // `emitEndIntra`/`emitElse without if_then`.
            // Placeholders carry no real CBZ / branch fixup
            // (if_skip_byte = null marks the "no CBZ to patch"
            // case so emitElse skips the patch step).
            switch (ins.op) {
                .block => try labels.append(allocator, .{
                    .kind = .block,
                    .target_byte_offset = 0,
                    .pending = .empty,
                }),
                .loop => try labels.append(allocator, .{
                    .kind = .loop,
                    .target_byte_offset = @intCast(buf.items.len),
                    .pending = .empty,
                }),
                .@"if" => try labels.append(allocator, .{
                    .kind = .if_then,
                    .target_byte_offset = 0,
                    .pending = .empty,
                    .if_skip_byte = null,
                }),
                else => {},
            }
            continue;
        }
        switch (ins.op) {
            .@"i32.const" => try op_const.emitI32Const(&ctx, &ins),
            .@"i64.const" => try op_const.emitI64Const(&ctx, &ins),
            .@"i64.add",
            .@"i64.sub",
            .@"i64.mul",
            .@"i64.and",
            .@"i64.or",
            .@"i64.xor",
            => try op_alu_int.emitI64Binary(&ctx, &ins),
            .@"i64.eq",
            .@"i64.ne",
            .@"i64.lt_s",
            .@"i64.lt_u",
            .@"i64.gt_s",
            .@"i64.gt_u",
            .@"i64.le_s",
            .@"i64.le_u",
            .@"i64.ge_s",
            .@"i64.ge_u",
            => try op_alu_int.emitI64Compare(&ctx, &ins),
            .@"i64.eqz" => try op_alu_int.emitI64Eqz(&ctx, &ins),
            // §9.9 / 9.9-m-1a (per ADR-0056): Wasm 2.0 reference-types
            // partial — null + is_null. ref.func deferred to m-1b
            // (needs JitRuntime extension for `func_entities_ptr`).
            // ref.null: push 0 (null_ref sentinel per ADR-0014 §2.1
            // / 6.K.1; Value.null_ref == 0). MOVZ Xd, #0 = 0x00000000
            // → zeroes both halves of X (W form implicitly).
            // ref.is_null: semantically identical to i64.eqz (pop
            // 64-bit, push i32=1 if zero else 0) — reuse handler.
            .@"ref.null" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const xd = try gpr.gprDefSpilled(alloc, vreg, 0);
                try gpr.writeU32(allocator, &buf, inst.encMovzImm16(xd, 0));
                try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"ref.is_null" => try op_alu_int.emitI64Eqz(&ctx, &ins),
            // §9.9 / 9.9-m-1b: ref.func idx — produce
            // `@intFromPtr(&rt.func_entities[idx])` matching
            // `Value.fromFuncRef`'s encoding (interp parity per
            // ADR-0014 §2.1). Recipe:
            //   LDR Xresult, [X19, #func_entities_ptr_off]
            //   MOVZ X16, #(byte_off & 0xFFFF)
            //   MOVK X16, #(byte_off >> 16), LSL #16   (if needed)
            //   ADD Xresult, Xresult, X16
            // where byte_off = idx * @sizeOf(FuncEntity).
            .@"ref.func" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const xresult = try gpr.gprDefSpilled(alloc, vreg, 0);
                const byte_off: u64 = @as(u64, ins.payload) * jit_abi.func_entity_size;
                // Load base pointer.
                try gpr.writeU32(allocator, &buf, inst.encLdrImm(xresult, abi.runtime_ptr_save_gpr, jit_abi.func_entities_ptr_off));
                if (byte_off != 0) {
                    // Materialise byte_off in IP0 (X16). Up to 2-instr
                    // (MOVZ low16 + optional MOVK high16, LSL #16).
                    const low16: u16 = @truncate(byte_off & 0xFFFF);
                    const high16: u16 = @truncate((byte_off >> 16) & 0xFFFF);
                    try gpr.writeU32(allocator, &buf, inst.encMovzImm16(16, low16));
                    if (high16 != 0) {
                        try gpr.writeU32(allocator, &buf, inst.encMovkImm16(16, high16, 1));
                    }
                    // ADD Xresult, Xresult, X16.
                    try gpr.writeU32(allocator, &buf, inst.encAddReg(xresult, xresult, 16));
                }
                try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i64.shl",
            .@"i64.shr_s",
            .@"i64.shr_u",
            .@"i64.rotr",
            => try op_alu_int.emitI64Shift(&ctx, &ins),
            .@"i64.rotl" => try op_alu_int.emitI64Rotl(&ctx, &ins),
            .@"i64.clz" => try op_alu_int.emitI64Clz(&ctx, &ins),
            .@"i64.ctz" => try op_alu_int.emitI64Ctz(&ctx, &ins),
            .@"i32.wrap_i64",
            .@"i64.extend_i32_u",
            => try op_convert.emitWrap32(&ctx, &ins),
            .@"i64.extend_i32_s" => try op_convert.emitExtendI32S(&ctx, &ins),
            .@"f32.convert_i32_s",
            .@"f32.convert_i32_u",
            .@"f32.convert_i64_s",
            .@"f32.convert_i64_u",
            .@"f64.convert_i32_s",
            .@"f64.convert_i32_u",
            .@"f64.convert_i64_s",
            .@"f64.convert_i64_u",
            => try op_convert.emitConvertIntToFloat(&ctx, &ins),
            .@"i32.trunc_f32_s",
            .@"i32.trunc_f32_u",
            .@"i64.trunc_f32_s",
            .@"i64.trunc_f32_u",
            => try bounds_check.emitTrappingTruncF32(&ctx, &ins),
            .@"i32.trunc_f64_s",
            .@"i32.trunc_f64_u",
            .@"i64.trunc_f64_s",
            .@"i64.trunc_f64_u",
            => try bounds_check.emitTrappingTruncF64(&ctx, &ins),
            .@"i32.trunc_sat_f32_s",
            .@"i32.trunc_sat_f32_u",
            .@"i32.trunc_sat_f64_s",
            .@"i32.trunc_sat_f64_u",
            .@"i64.trunc_sat_f32_s",
            .@"i64.trunc_sat_f32_u",
            .@"i64.trunc_sat_f64_s",
            .@"i64.trunc_sat_f64_u",
            => try op_convert.emitTruncSat(&ctx, &ins),
            .@"i32.reinterpret_f32" => try op_convert.emitReinterpretI32FromF32(&ctx, &ins),
            .@"i64.reinterpret_f64" => try op_convert.emitReinterpretI64FromF64(&ctx, &ins),
            .@"f32.reinterpret_i32" => try op_convert.emitReinterpretF32FromI32(&ctx, &ins),
            .@"f64.reinterpret_i64" => try op_convert.emitReinterpretF64FromI64(&ctx, &ins),
            .@"f32.demote_f64",
            .@"f64.promote_f32",
            => try op_convert.emitFloatDemotePromote(&ctx, &ins),
            .@"f32.const" => {
                // Stage the IEEE-754 bits via a GPR const, then
                // FMOV S, W. The intermediate W-reg is the FP
                // vreg's slot's GPR-pool counterpart (slot K → X9+K
                // for K<7, etc.) reused as scratch for the move.
                // Per the per-class slot mapping note in abi.zig
                // (allocatable_v_regs comment), GPR slot 0 maps to
                // X9 — we use that as the immediate scratch.
                //
                // D-034 spill-aware: when the vreg's GPR-class slot
                // is spilled, gprDefSpilled returns the X16 stage
                // reg; the FMOV reads from that stage. The FP-class
                // dest uses fpDefSpilled + fpStoreSpilled to flush
                // V29 to the spill slot when the FP-class slot is
                // spilled.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) {
                    std.debug.print("arm64/emit: f32.const SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, vreg, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                const vd = try gpr.fpDefSpilled(alloc, vreg, 0);
                const w_scratch = try gpr.gprDefSpilled(alloc, vreg, 0);
                try op_const.emitConstU32(allocator, &buf, w_scratch, ins.payload);
                try gpr.writeU32(allocator, &buf, inst.encFmovStoFromW(vd, w_scratch));
                try gpr.fpStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f64.const" => {
                // Similar to f32.const but for 64-bit (FMOV D, X).
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) {
                    std.debug.print("arm64/emit: f64.const SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, vreg, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                const vd = try gpr.fpDefSpilled(alloc, vreg, 0);
                const x_scratch = try gpr.gprDefSpilled(alloc, vreg, 0);
                const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
                const lane0: u16 = @truncate(value & 0xFFFF);
                const lane1: u16 = @truncate((value >> 16) & 0xFFFF);
                const lane2: u16 = @truncate((value >> 32) & 0xFFFF);
                const lane3: u16 = @truncate((value >> 48) & 0xFFFF);
                try gpr.writeU32(allocator, &buf, inst.encMovzImm16(x_scratch, lane0));
                if (lane1 != 0) try gpr.writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane1, 1));
                if (lane2 != 0) try gpr.writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane2, 2));
                if (lane3 != 0) try gpr.writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane3, 3));
                try gpr.writeU32(allocator, &buf, inst.encFmovDtoFromX(vd, x_scratch));
                try gpr.fpStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f32.add",
            .@"f32.sub",
            .@"f32.mul",
            .@"f32.div",
            .@"f64.add",
            .@"f64.sub",
            .@"f64.mul",
            .@"f64.div",
            => try op_alu_float.emitFloatBinary(&ctx, &ins),
            .@"f32.abs",
            .@"f32.neg",
            .@"f32.sqrt",
            .@"f32.ceil",
            .@"f32.floor",
            .@"f32.trunc",
            .@"f32.nearest",
            .@"f64.abs",
            .@"f64.neg",
            .@"f64.sqrt",
            .@"f64.ceil",
            .@"f64.floor",
            .@"f64.trunc",
            .@"f64.nearest",
            => try op_alu_float.emitFloatUnary(&ctx, &ins),
            .@"f32.copysign",
            .@"f64.copysign",
            => try op_alu_float.emitFloatCopysign(&ctx, &ins),
            .@"f32.min",
            .@"f32.max",
            .@"f64.min",
            .@"f64.max",
            => try op_alu_float.emitFloatMinMax(&ctx, &ins),
            .@"f32.eq",
            .@"f32.ne",
            .@"f32.lt",
            .@"f32.gt",
            .@"f32.le",
            .@"f32.ge",
            .@"f64.eq",
            .@"f64.ne",
            .@"f64.lt",
            .@"f64.gt",
            .@"f64.le",
            .@"f64.ge",
            => try op_alu_float.emitFloatCompare(&ctx, &ins),
            .@"i64.popcnt" => try op_alu_int.emitI64Popcnt(&ctx, &ins),
            .@"i32.add",
            .@"i32.sub",
            .@"i32.mul",
            .@"i32.and",
            .@"i32.or",
            .@"i32.xor",
            .@"i32.shl",
            .@"i32.shr_s",
            .@"i32.shr_u",
            => try op_alu_int.emitI32Binary(&ctx, &ins),
            .@"i32.rotr" => try op_alu_int.emitI32Rotr(&ctx, &ins),
            .@"i32.rotl" => try op_alu_int.emitI32Rotl(&ctx, &ins),
            .@"i32.eq",
            .@"i32.ne",
            .@"i32.lt_s",
            .@"i32.lt_u",
            .@"i32.gt_s",
            .@"i32.gt_u",
            .@"i32.le_s",
            .@"i32.le_u",
            .@"i32.ge_s",
            .@"i32.ge_u",
            => try op_alu_int.emitI32Compare(&ctx, &ins),
            .@"i32.eqz" => try op_alu_int.emitI32Eqz(&ctx, &ins),
            .@"i32.clz" => try op_alu_int.emitI32Clz(&ctx, &ins),
            .@"i32.ctz" => try op_alu_int.emitI32Ctz(&ctx, &ins),
            // §9.7 / 7.9 chunk c: Wasm 2.0 sign-extension ops.
            .@"i32.extend8_s" => try op_alu_int.emitI32Extend8S(&ctx, &ins),
            .@"i32.extend16_s" => try op_alu_int.emitI32Extend16S(&ctx, &ins),
            .@"i64.extend8_s" => try op_alu_int.emitI64Extend8S(&ctx, &ins),
            .@"i64.extend16_s" => try op_alu_int.emitI64Extend16S(&ctx, &ins),
            .@"i64.extend32_s" => try op_alu_int.emitI64Extend32S(&ctx, &ins),
            // §9.7 / 7.9 chunk c: integer divide / remainder.
            .@"i32.div_s",
            .@"i32.div_u",
            .@"i32.rem_s",
            .@"i32.rem_u",
            => try op_alu_int.emitI32DivRem(&ctx, &ins),
            .@"i64.div_s",
            .@"i64.div_u",
            .@"i64.rem_s",
            .@"i64.rem_u",
            => try op_alu_int.emitI64DivRem(&ctx, &ins),
            .@"local.get" => {
                // Push a fresh vreg holding the value loaded from
                // `[SP, #(local_base_off + layout.offsets[local_idx])]`.
                // Width follows declared local type (i32 → LDR W,
                // i64 → LDR X, v128 → LDR Q per §9.9-e-1).
                const local_idx = ins.payload;
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                const offset_u: u32 = local_base_off + layout.offsets[local_idx];
                const cap: u32 = switch (ty) {
                    .i32, .f32 => 16380,
                    .i64, .f64 => 32760,
                    .v128 => 65520,
                    .funcref, .externref => 16380,
                };
                if (offset_u > cap) return Error.UnsupportedOp;
                const offset_w: u14 = if (ty == .i32 or ty == .f32) @intCast(offset_u) else 0;
                const offset_x: u15 = if (ty == .i64 or ty == .f64) @intCast(offset_u) else 0;
                const offset_q: u16 = if (ty == .v128) @intCast(offset_u) else 0;
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) {
                    std.debug.print("arm64/emit: local.get SlotOverflow func[{d}] vreg={d} >= slots.len={d} local_idx={d}\n", .{ func.func_idx, vreg, alloc.slots.len, local_idx });
                    return Error.SlotOverflow;
                }
                switch (ty) {
                    .i32 => {
                        const rd = try gpr.gprDefSpilled(alloc, vreg, 0);
                        try gpr.writeU32(allocator, &buf, inst.encLdrImmW(rd, 31, offset_w));
                        try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 0);
                    },
                    .i64 => {
                        const rd = try gpr.gprDefSpilled(alloc, vreg, 0);
                        try gpr.writeU32(allocator, &buf, inst.encLdrImm(rd, 31, offset_x));
                        try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, vreg, 0);
                    },
                    .f32 => {
                        const vd = try gpr.fpDefSpilled(alloc, vreg, 0);
                        try gpr.writeU32(allocator, &buf, inst.encLdrSImm(vd, 31, offset_w));
                        try gpr.fpStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                    },
                    .f64 => {
                        const vd = try gpr.fpDefSpilled(alloc, vreg, 0);
                        try gpr.writeU32(allocator, &buf, inst.encLdrDImm(vd, 31, offset_x));
                        try gpr.fpStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                    },
                    .v128 => {
                        // Wasm spec §3.5.3 + §4.4.5.1 — local.get
                        // copies the local's stored value (16 bytes
                        // for v128). LDR Q reads the full 128-bit
                        // lane group; q* spill helpers handle V-reg
                        // vs. spill-frame placement.
                        const vd = try gpr.qDefSpilled(alloc, vreg, 0);
                        try gpr.writeU32(allocator, &buf, inst_neon.encLdrQImm(vd, 31, offset_q));
                        try gpr.qStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                    },
                    .funcref, .externref => {
                        std.debug.print("arm64/emit: local.get type `{s}` unsupported (idx={d})\n", .{ @tagName(ty), local_idx });
                        return Error.UnsupportedOp;
                    },
                }
                try pushed_vregs.append(allocator, vreg);
            },
            .@"local.set" => {
                // Pop top vreg, write to
                // `[SP, #(local_base_off + layout.offsets[local_idx])]`.
                // Width follows declared local type per §9.9-e-1.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                const offset_u: u32 = local_base_off + layout.offsets[local_idx];
                const cap: u32 = switch (ty) {
                    .i32, .f32 => 16380,
                    .i64, .f64 => 32760,
                    .v128 => 65520,
                    .funcref, .externref => 16380,
                };
                if (offset_u > cap) return Error.UnsupportedOp;
                const offset_w: u14 = if (ty == .i32 or ty == .f32) @intCast(offset_u) else 0;
                const offset_x: u15 = if (ty == .i64 or ty == .f64) @intCast(offset_u) else 0;
                const offset_q: u16 = if (ty == .v128) @intCast(offset_u) else 0;
                const src = pushed_vregs.pop().?;
                switch (ty) {
                    .i32 => {
                        const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst.encStrImmW(rs, 31, offset_w));
                    },
                    .i64 => {
                        const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst.encStrImm(rs, 31, offset_x));
                    },
                    .f32 => {
                        const vs = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst.encStrSImm(vs, 31, offset_w));
                    },
                    .f64 => {
                        const vs = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst.encStrDImm(vs, 31, offset_x));
                    },
                    .v128 => {
                        // Wasm spec §4.4.5.2 — local.set writes 16
                        // bytes for v128. STR Q via the q* helpers.
                        const vs = try gpr.qLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst_neon.encStrQImm(vs, 31, offset_q));
                    },
                    .funcref, .externref => {
                        std.debug.print("arm64/emit: local.set type `{s}` unsupported (idx={d})\n", .{ @tagName(ty), local_idx });
                        return Error.UnsupportedOp;
                    },
                }
            },
            .@"local.tee" => {
                // Write top vreg to local slot WITHOUT popping —
                // the value remains pushed.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                const offset_u: u32 = local_base_off + layout.offsets[local_idx];
                const cap: u32 = switch (ty) {
                    .i32, .f32 => 16380,
                    .i64, .f64 => 32760,
                    .v128 => 65520,
                    .funcref, .externref => 16380,
                };
                if (offset_u > cap) return Error.UnsupportedOp;
                const offset_w: u14 = if (ty == .i32 or ty == .f32) @intCast(offset_u) else 0;
                const offset_x: u15 = if (ty == .i64 or ty == .f64) @intCast(offset_u) else 0;
                const offset_q: u16 = if (ty == .v128) @intCast(offset_u) else 0;
                const src = pushed_vregs.items[pushed_vregs.items.len - 1];
                switch (ty) {
                    .i32 => {
                        const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst.encStrImmW(rs, 31, offset_w));
                    },
                    .i64 => {
                        const rs = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst.encStrImm(rs, 31, offset_x));
                    },
                    .f32 => {
                        const vs = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst.encStrSImm(vs, 31, offset_w));
                    },
                    .f64 => {
                        const vs = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst.encStrDImm(vs, 31, offset_x));
                    },
                    .v128 => {
                        // Wasm spec §4.4.5.3 — local.tee mirrors
                        // local.set's 16-byte write.
                        const vs = try gpr.qLoadSpilled(allocator, &buf, alloc, spill_base_off, src, 0);
                        try gpr.writeU32(allocator, &buf, inst_neon.encStrQImm(vs, 31, offset_q));
                    },
                    .funcref, .externref => {
                        std.debug.print("arm64/emit: local.tee type `{s}` unsupported (idx={d})\n", .{ @tagName(ty), local_idx });
                        return Error.UnsupportedOp;
                    },
                }
            },
            .@"i32.popcnt" => try op_alu_int.emitI32Popcnt(&ctx, &ins),
            .select, .select_typed => {
                // Wasm spec §4.4.4 / §3.3.2.2 (select / select_typed)
                // — pop c, val2, val1 (top of stack is c). Push val1
                // if c != 0, else val2. ARM64 lowering:
                //   CMP c_w, #0
                //   CSEL d_*, val1_*, val2_*, NE        (GPR types)
                //   FCSEL d_*, val1_*, val2_*, NE       (FP types — m-4b)
                //   v128 → op_simd.emitV128Select        (mask synth)
                //
                // Dispatch shape (§9.9 / 9.9-m-4a per ADR-0056):
                //   - v128 (shape_tag): pre-existing SIMD mask emit
                //   - i32 (extra=0x7F or .select untyped default):
                //     CSEL Wd
                //   - i64 / funcref / externref (extra=0x7E/0x70/0x6F):
                //     CSEL Xd
                //   - f32 / f64 (extra=0x7D/0x7C): UnsupportedOp
                //     pending m-4b (needs FCSEL S/D encoders)
                //   - untyped .select with non-i32 operands:
                //     UnsupportedOp pending m-4c (lower-time type
                //     inference)
                if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
                const cond_v = pushed_vregs.pop().?;
                const val2_v = pushed_vregs.pop().?;
                const val1_v = pushed_vregs.pop().?;
                const result_v = next_vreg;
                next_vreg += 1;
                if (result_v >= alloc.slots.len) {
                    std.debug.print("arm64/emit: select SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, result_v, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                // §9.9 / 9.9-d-5: dispatch on val1's shape_tag. v128
                // operands need a SIMD-aware mask synthesis (CSETM +
                // DUP V.2D + BSL); GPR / FP fall through to CSEL.
                if (alloc.shapeTag(val1_v) == .v128) {
                    try op_simd.emitV128Select(&ctx, cond_v, val1_v, val2_v, result_v);
                    try pushed_vregs.append(allocator, result_v);
                } else {
                    // §9.9 / 9.9-m-4a (GPR) + 9.9-m-4b (FP):
                    // dispatch on `ins.extra` for select_typed (0x1C).
                    // For untyped .select (0x1B), extra=0 → i32 CSEL
                    // Wd default. Lower-time type inference for
                    // untyped non-i32 select pending m-4c.
                    const TypeClass = enum { gpr32, gpr64, fp32, fp64 };
                    const tc: TypeClass = switch (ins.extra) {
                        0x7E, 0x70, 0x6F => .gpr64, // i64 / funcref / externref
                        0x7D => .fp32, // f32 (9.9-m-4b)
                        0x7C => .fp64, // f64 (9.9-m-4b)
                        else => .gpr32, // 0x7F i32 or untyped .select
                    };
                    // CMP cond, #0 emits first (stage 0 for cond). After
                    // CMP, cond is dead; stage 0 free for reuse.
                    const cond_w = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, cond_v, 0);
                    try gpr.writeU32(allocator, &buf, inst.encCmpImmW(cond_w, 0));
                    switch (tc) {
                        .gpr32, .gpr64 => {
                            const val1_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val1_v, 0);
                            const val2_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val2_v, 1);
                            const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
                            const csel_word: u32 = if (tc == .gpr64)
                                inst.encCselX(dst_r, val1_r, val2_r, .ne)
                            else
                                inst.encCselW(dst_r, val1_r, val2_r, .ne);
                            try gpr.writeU32(allocator, &buf, csel_word);
                            try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, result_v, 0);
                        },
                        .fp32, .fp64 => {
                            const val1_v_phys = try gpr.fpLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val1_v, 0);
                            const val2_v_phys = try gpr.fpLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val2_v, 1);
                            const dst_v = try gpr.fpDefSpilled(alloc, result_v, 0);
                            const fcsel_word: u32 = if (tc == .fp64)
                                inst.encFcselD(dst_v, val1_v_phys, val2_v_phys, .ne)
                            else
                                inst.encFcselS(dst_v, val1_v_phys, val2_v_phys, .ne);
                            try gpr.writeU32(allocator, &buf, fcsel_word);
                            try gpr.fpStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, result_v, 0);
                        },
                    }
                    try pushed_vregs.append(allocator, result_v);
                }
            },
            .drop => {
                // Discard the top operand. Wasm spec §4.4.4: the
                // value is consumed without storage. No machine
                // bytes emitted; we simply remove the vreg from
                // the operand-stack tracker so subsequent ops see
                // the next vreg as top-of-stack.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                _ = pushed_vregs.pop().?;
            },
            .nop => {
                // Wasm spec §4.4.6.2: do nothing. No machine
                // bytes; no stack change. Validator already
                // accepts it; emit just skips.
            },
            .@"unreachable" => {
                // Wasm spec §4.4.6.1: trap unconditionally. Emit
                // an unconditional `B 0` placeholder; record the
                // byte_offset so the function-end trap-stub patch
                // pass redirects it to the trap stub. Unlike the
                // bounds-check Bcond placeholders, this one
                // carries the unconditional-B opcode (bits 31..26
                // = 000101); the patcher distinguishes by opcode.
                const fixup_at: u32 = @intCast(buf.items.len);
                try gpr.writeU32(allocator, &buf, inst.encB(0));
                try bounds_fixups.append(allocator, fixup_at);
                dead_code = true;
            },
            .@"return" => {
                // Wasm spec §4.4.7: pop the function's results and
                // exit. We replicate the function-level `end`'s
                // result-marshal logic inline (move top vreg into
                // W0/X0/S0/D0 per result_kind), then emit an
                // unconditional B placeholder pointing at the
                // function epilogue. All `return` placeholders are
                // patched in one pass at the end-handler so they
                // share the single epilogue + RET sequence.
                if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
                    const top_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
                    const result_kind = func.sig.results[0];
                    switch (result_kind) {
                        .f32, .f64 => {
                            const src_vn = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, top_vreg, 0);
                            if (src_vn != 0) {
                                const base: u32 = if (result_kind == .f64) 0x1E604000 else 0x1E204000;
                                try gpr.writeU32(allocator, &buf, base | (@as(u32, src_vn) << 5));
                            }
                        },
                        .v128 => {
                            // §9.9-b per ADR-0046: v128 return marshal.
                            // MOV V0.16B, Vn.16B copies all 128 bits
                            // (Arm IHI 0055 §C7.2.246, alias of ORR
                            // V0.16B, Vn.16B, Vn.16B). Use resolveVn
                            // (no spill staging): fpLoadSpilled uses
                            // 8-byte stride which would truncate the
                            // upper 64 bits of a spilled v128.
                            const src_vn = try gpr.resolveFp(alloc, top_vreg);
                            if (src_vn != 0) {
                                try gpr.writeU32(allocator, &buf, inst_neon.encMovV16B(0, src_vn));
                            }
                        },
                        .i32, .i64, .funcref, .externref => {
                            const src_xn = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, top_vreg, 0);
                            if (src_xn != 0) {
                                try gpr.writeU32(allocator, &buf, encOrrZrIntoX0(src_xn));
                            }
                        },
                    }
                }
                const fixup_at: u32 = @intCast(buf.items.len);
                try gpr.writeU32(allocator, &buf, inst.encB(0));
                try return_fixups.append(allocator, fixup_at);
                dead_code = true;
            },
            .block => try op_control.emitBlock(&ctx, &ins),
            .loop => try op_control.emitLoop(&ctx, &ins),
            .br => {
                try op_control.emitBr(&ctx, &ins);
                dead_code = true;
            },
            .call_indirect => try op_call.emitCallIndirect(&ctx, &ins),
            .call => try op_call.emitCall(&ctx, &ins),
            .@"global.get" => try op_globals.emitGlobalGet(&ctx, &ins),
            .@"global.set" => try op_globals.emitGlobalSet(&ctx, &ins),
            .@"memory.size" => {
                // Wasm memory.size returns current size in 64-KiB pages.
                // X27 carries the byte limit; pages = bytes >> 16.
                // Pop nothing (Wasm signature: () → i32). Push the
                // result vreg.
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) {
                    std.debug.print("arm64/emit: memory.size SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, result, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                const wd = try gpr.gprDefSpilled(alloc, result, 0);
                try gpr.writeU32(allocator, &buf, inst.encLsrImmW(wd, 27, 16));
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, result, 0);
                try pushed_vregs.append(allocator, result);
            },
            .@"memory.grow" => {
                // Skeleton: emit `MOVN Wd, #0` = 0xFFFFFFFF = -1
                // (Wasm spec: -1 indicates grow-failed). Real grow
                // requires a Runtime callout that allocates new
                // pages + updates X27 + the underlying memory_base.
                // Phase 7 follow-up: emit BL to a runtime helper
                // pointer; Runtime.io injection (D-014) dissolves
                // alongside this step.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                _ = pushed_vregs.pop().?; // delta arg, unused in skeleton
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) {
                    std.debug.print("arm64/emit: memory.grow SlotOverflow func[{d}] vreg={d} >= slots.len={d}\n", .{ func.func_idx, result, alloc.slots.len });
                    return Error.SlotOverflow;
                }
                const wd = try gpr.gprDefSpilled(alloc, result, 0);
                try gpr.writeU32(allocator, &buf, inst.encMovnImmW(wd, 0));
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, result, 0);
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.load",
            .@"i32.load8_s",
            .@"i32.load8_u",
            .@"i32.load16_s",
            .@"i32.load16_u",
            .@"i64.load",
            .@"i64.load8_s",
            .@"i64.load8_u",
            .@"i64.load16_s",
            .@"i64.load16_u",
            .@"i64.load32_s",
            .@"i64.load32_u",
            .@"f32.load",
            .@"f64.load",
            .@"i32.store",
            .@"i32.store8",
            .@"i32.store16",
            .@"i64.store",
            .@"i64.store8",
            .@"i64.store16",
            .@"i64.store32",
            .@"f32.store",
            .@"f64.store",
            => try op_memory.emitMemOp(&ctx, &ins),
            .@"memory.fill" => try op_memory.emitMemoryFill(&ctx),
            .@"memory.copy" => try op_memory.emitMemoryCopy(&ctx),
            .br_table => try op_control.emitBrTable(&ctx, &ins),
            .@"if" => try op_control.emitIf(&ctx, &ins),
            .@"else" => try op_control.emitElse(&ctx, &ins),
            .br_if => try op_control.emitBrIf(&ctx, &ins),
            .end => {
                // Two distinct forms:
                // (A) Intra-function `end`: pops a label off the stack
                //     and patches forward fixups (block) / no-op for loop.
                // (B) Function-level `end`: marshals result, runs
                //     epilogue, returns.
                //
                // Disambiguation: if `labels` is non-empty, we're in
                // form (A). Otherwise form (B).
                if (labels.items.len > 0) {
                    try op_control.emitEndIntra(&ctx, &ins);
                    continue;
                }
                // Function-level end (labels stack is empty).
                if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
                    const top_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
                    const result_kind = func.sig.results[0];
                    switch (result_kind) {
                        .f32, .f64 => {
                            const src_vn = try gpr.fpLoadSpilled(allocator, &buf, alloc, spill_base_off, top_vreg, 0);
                            if (src_vn != 0) {
                                // FMOV S0, Sn or FMOV D0, Dn — encoded
                                // via the FP-FP move (FMOV reg-reg).
                                // Encoding: `0 0 0 11110 type 1 0000 0 10 0000 [Rn:5] [Rd:5]`
                                // type = 00 single → 0x1E204000
                                // type = 01 double → 0x1E604000
                                const base: u32 = if (result_kind == .f64) 0x1E604000 else 0x1E204000;
                                try gpr.writeU32(allocator, &buf, base | (@as(u32, src_vn) << 5));
                            }
                        },
                        .v128 => {
                            // §9.9 / 9.9-d-4 — mirror of the `.return`
                            // handler's v128 arm (added in 9.9-b but
                            // missed here): the AAPCS64 + ADR-0046
                            // v128 return convention puts the result
                            // in V0. `MOV V0.16B, Vn.16B` (alias of
                            // `ORR V0.16B, Vn.16B, Vn.16B`) copies
                            // the full 128 bits. resolveFp (no spill
                            // staging) — fpLoadSpilled uses 8-byte
                            // stride which would truncate the upper
                            // 64 bits of a spilled v128.
                            const src_vn = try gpr.resolveFp(alloc, top_vreg);
                            if (src_vn != 0) {
                                try gpr.writeU32(allocator, &buf, inst_neon.encMovV16B(0, src_vn));
                            }
                        },
                        .i32, .i64, .funcref, .externref => {
                            // GPR result: spill-aware load (sub-1c). For
                            // an in-reg vreg, returns the home reg; for
                            // a spilled vreg, emits LDR X14, [SP, #off]
                            // and returns X14. Then MOV X0, Xsrc.
                            const src_xn = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, top_vreg, 0);
                            if (src_xn != 0) {
                                try gpr.writeU32(allocator, &buf, encOrrZrIntoX0(src_xn));
                            }
                        },
                    }
                }
                // Capture the byte offset of the frame teardown.
                // `return` ops emitted earlier B-fixup placeholders
                // here (their result marshal already ran inline);
                // patch them to share this single epilogue path.
                const epilogue_byte: u32 = @intCast(buf.items.len);
                if (frame_bytes > 0) {
                    const fb_high: u12 = @intCast((frame_bytes >> 12) & 0xFFF);
                    const fb_low: u12 = @intCast(frame_bytes & 0xFFF);
                    if (fb_high != 0) try gpr.writeU32(allocator, &buf, inst.encAddImm12Lsl12(31, 31, fb_high));
                    if (fb_low != 0) try gpr.writeU32(allocator, &buf, inst.encAddImm12(31, 31, fb_low));
                }
                try gpr.writeU32(allocator, &buf, encLdpFpLrPostIdx());
                try gpr.writeU32(allocator, &buf, inst.encRet(abi.link_register));
                for (return_fixups.items) |fx_byte| {
                    const disp_words: i32 = @divExact(
                        @as(i32, @intCast(epilogue_byte)) - @as(i32, @intCast(fx_byte)),
                        4,
                    );
                    std.mem.writeInt(u32, buf.items[fx_byte..][0..4], inst.encB(disp_words), .little);
                }

                // Trap stub: emitted after the regular RET when the
                // function had any bounds-check / sig-mismatch /
                // NaN-trap / range-trap fixups. Each fixup's B.cond
                // is patched to land here.
                //
                // Per sub-7.5b-ii (ADR-0017 trap_flag amendment):
                // STR W17, [X19, #trap_flag_off] sets the runtime's
                // trap_flag = 1 (W17 holds the trap indicator).
                // Then a clean MOV X0, #0 + epilogue + RET unwinds
                // — the entry shim distinguishes trap-vs-return by
                // reading runtime.trap_flag, NOT by inspecting the
                // returned value (so a trap doesn't confuse with
                // "returned 0").
                if (bounds_fixups.items.len > 0) {
                    const trap_byte: u32 = @intCast(buf.items.len);
                    try gpr.writeU32(allocator, &buf, inst.encMovzImm16(17, 1));
                    try gpr.writeU32(allocator, &buf, inst.encStrImmW(17, abi.runtime_ptr_save_gpr, jit_abi.trap_flag_off));
                    try gpr.writeU32(allocator, &buf, inst.encMovzImm16(0, 0));
                    if (frame_bytes > 0) {
                        const fb_high: u12 = @intCast((frame_bytes >> 12) & 0xFFF);
                        const fb_low: u12 = @intCast(frame_bytes & 0xFFF);
                        if (fb_high != 0) try gpr.writeU32(allocator, &buf, inst.encAddImm12Lsl12(31, 31, fb_high));
                        if (fb_low != 0) try gpr.writeU32(allocator, &buf, inst.encAddImm12(31, 31, fb_low));
                    }
                    try gpr.writeU32(allocator, &buf, encLdpFpLrPostIdx());
                    try gpr.writeU32(allocator, &buf, inst.encRet(abi.link_register));
                    for (bounds_fixups.items) |fx_byte| {
                        const disp_words: i32 = @divExact(
                            @as(i32, @intCast(trap_byte)) - @as(i32, @intCast(fx_byte)),
                            4,
                        );
                        const orig = std.mem.readInt(u32, buf.items[fx_byte..][0..4], .little);
                        // Distinguish the placeholder shape by opcode:
                        //   bits 31..26 == 0b000101 → unconditional B
                        //                  (`unreachable` op, no condition).
                        //   bits 31..24 == 0x54     → B.cond (bounds /
                        //                  sig-mismatch / trap variants).
                        const new_word: u32 = if ((orig >> 26) == 0b000101)
                            inst.encB(disp_words)
                        else blk: {
                            const cond: inst.Cond = @enumFromInt(@as(u4, @intCast(orig & 0xF)));
                            break :blk inst.encBCond(cond, disp_words);
                        };
                        std.mem.writeInt(u32, buf.items[fx_byte..][0..4], new_word, .little);
                    }
                }
                // §9.6/9.6-f-ii + §9.9-g-19 — SIMD const-pool flush +
                // LDR-Q-literal imm19 fixups (per ADR-0042 + ADR-0051).
                // After the trap stub, if any v128.const / i8x16.shuffle
                // / emit-time-derived ops emitted LDR-Q-literal
                // placeholders, append the per-function const-pool
                // 16-byte aligned and patch each placeholder. The pool
                // is the concatenation of `func.simd_consts`
                // (lower-time) followed by `extra_consts` (emit-time);
                // const_idx is a flat index across both ranges with
                // `simd_consts_base` as the boundary.
                if (simd_const_fixups.items.len > 0) {
                    if (func.simd_consts == null and extra_consts.items.len == 0) {
                        std.debug.print("arm64/emit: simd_const_fixups present but both simd_consts and extra_consts are empty\n", .{});
                        return Error.AllocationMissing;
                    }
                    // Pad to 16-byte alignment.
                    while (buf.items.len % 16 != 0) try buf.append(allocator, 0);
                    const pool_byte: u32 = @intCast(buf.items.len);
                    if (func.simd_consts) |consts| {
                        for (consts) |c| try buf.appendSlice(allocator, &c);
                    }
                    for (extra_consts.items) |c| try buf.appendSlice(allocator, &c);
                    // Patch each LDR-Q-literal's imm19 to point at
                    // its const-pool entry (signed offset / 4 bytes).
                    for (simd_const_fixups.items) |fx| {
                        const target_byte: u32 = pool_byte + fx.const_idx * 16;
                        const disp_words: i32 = @divExact(
                            @as(i32, @intCast(target_byte)) - @as(i32, @intCast(fx.byte_offset)),
                            4,
                        );
                        const orig = std.mem.readInt(u32, buf.items[fx.byte_offset..][0..4], .little);
                        const patched = inst_neon.patchLdrLiteralQImm19(orig, @intCast(disp_words));
                        std.mem.writeInt(u32, buf.items[fx.byte_offset..][0..4], patched, .little);
                    }
                }
                break;
            },
            // §9.9 / 9.5-b-iii — SIMD-128 MVP catalogue per ADR-0041.
            // Sub-row 9.5-c covers extract/replace_lane + remaining
            // op shapes; 9.6 covers float arith + compare + shuffle
            // + conversion.
            .@"v128.load" => try op_simd.emitV128Load(&ctx, &ins),
            .@"v128.store" => try op_simd.emitV128Store(&ctx, &ins),
            // §9.9 / 9.9-d-3 — v128 mem op family (load_zero / load_splat / load_extend).
            .@"v128.load32_zero" => try op_simd.emitV128Load32Zero(&ctx, &ins),
            .@"v128.load64_zero" => try op_simd.emitV128Load64Zero(&ctx, &ins),
            .@"v128.load8_splat" => try op_simd.emitV128Load8Splat(&ctx, &ins),
            .@"v128.load16_splat" => try op_simd.emitV128Load16Splat(&ctx, &ins),
            .@"v128.load32_splat" => try op_simd.emitV128Load32Splat(&ctx, &ins),
            .@"v128.load64_splat" => try op_simd.emitV128Load64Splat(&ctx, &ins),
            .@"v128.load8x8_s" => try op_simd.emitV128Load8x8S(&ctx, &ins),
            .@"v128.load8x8_u" => try op_simd.emitV128Load8x8U(&ctx, &ins),
            .@"v128.load16x4_s" => try op_simd.emitV128Load16x4S(&ctx, &ins),
            .@"v128.load16x4_u" => try op_simd.emitV128Load16x4U(&ctx, &ins),
            .@"v128.load32x2_s" => try op_simd.emitV128Load32x2S(&ctx, &ins),
            .@"v128.load32x2_u" => try op_simd.emitV128Load32x2U(&ctx, &ins),
            // §9.9 / 9.9-d-5 — v128 lane mem family (load_lane × 4,
            // store_lane × 4) sharing v128MemPrologue + scalar
            // load/store + INS/UMOV per Wasm spec §4.4.7.4 / §4.4.7.5.
            .@"v128.load8_lane" => try op_simd.emitV128Load8Lane(&ctx, &ins),
            .@"v128.load16_lane" => try op_simd.emitV128Load16Lane(&ctx, &ins),
            .@"v128.load32_lane" => try op_simd.emitV128Load32Lane(&ctx, &ins),
            .@"v128.load64_lane" => try op_simd.emitV128Load64Lane(&ctx, &ins),
            .@"v128.store8_lane" => try op_simd.emitV128Store8Lane(&ctx, &ins),
            .@"v128.store16_lane" => try op_simd.emitV128Store16Lane(&ctx, &ins),
            .@"v128.store32_lane" => try op_simd.emitV128Store32Lane(&ctx, &ins),
            .@"v128.store64_lane" => try op_simd.emitV128Store64Lane(&ctx, &ins),
            // §9.9 / 9.9-g-4 — splat handlers for all 6 shapes.
            .@"i8x16.splat" => try op_simd_int_cmp_lane.emitI8x16Splat(&ctx, &ins),
            .@"i16x8.splat" => try op_simd_int_cmp_lane.emitI16x8Splat(&ctx, &ins),
            .@"i32x4.splat" => try op_simd_int_cmp_lane.emitI32x4Splat(&ctx, &ins),
            .@"i64x2.splat" => try op_simd_int_cmp_lane.emitI64x2Splat(&ctx, &ins),
            .@"f32x4.splat" => try op_simd_float.emitF32x4Splat(&ctx, &ins),
            .@"f64x2.splat" => try op_simd_float.emitF64x2Splat(&ctx, &ins),
            .@"i32x4.extract_lane" => try op_simd_int_cmp_lane.emitI32x4ExtractLane(&ctx, &ins),
            .@"i32x4.replace_lane" => try op_simd_int_cmp_lane.emitI32x4ReplaceLane(&ctx, &ins),
            // §9.9 / 9.9-f-1 — v128 bitwise (AND / OR / XOR / ANDNOT
            // / NOT / BITSELECT). Per Wasm spec §4.4 (bitwise SIMD)
            // + Arm IHI 0055 §C7.2.{6, 34, 39, 93, 244} (NEON
            // AND/BIC/BSL/EOR/MVN). x86_64 mirror at op_simd.zig
            // landed in §9.5/9.6.
            .@"v128.and" => try op_simd.emitV128And(&ctx, &ins),
            .@"v128.or" => try op_simd.emitV128Or(&ctx, &ins),
            .@"v128.xor" => try op_simd.emitV128Xor(&ctx, &ins),
            .@"v128.andnot" => try op_simd.emitV128Andnot(&ctx, &ins),
            .@"v128.not" => try op_simd.emitV128Not(&ctx, &ins),
            .@"v128.bitselect" => try op_simd.emitV128Bitselect(&ctx, &ins),
            // §9.9/9.5-c-iv — int-arith ADD/SUB across all 4 shapes.
            .@"i8x16.add" => try op_simd_int_arith.emitI8x16Add(&ctx, &ins),
            .@"i8x16.sub" => try op_simd_int_arith.emitI8x16Sub(&ctx, &ins),
            .@"i16x8.add" => try op_simd_int_arith.emitI16x8Add(&ctx, &ins),
            .@"i16x8.sub" => try op_simd_int_arith.emitI16x8Sub(&ctx, &ins),
            .@"i32x4.add" => try op_simd_int_arith.emitI32x4Add(&ctx, &ins),
            .@"i32x4.sub" => try op_simd_int_arith.emitI32x4Sub(&ctx, &ins),
            .@"i64x2.add" => try op_simd_int_arith.emitI64x2Add(&ctx, &ins),
            .@"i64x2.sub" => try op_simd_int_arith.emitI64x2Sub(&ctx, &ins),
            .@"i16x8.mul" => try op_simd_int_arith.emitI16x8Mul(&ctx, &ins),
            .@"i32x4.mul" => try op_simd_int_arith.emitI32x4Mul(&ctx, &ins),
            // (i64x2.mul dispatch lives below alongside the §9.5-c-vii-mul block.)
            // §9.9 / 9.9-g-10 — int min/max + avgr_u (14 ops). NEON
            // has no .2D form for these (and Wasm spec correspondingly
            // has no i64x2 min/max/avgr); i32x4.avgr_u also doesn't
            // exist in the Wasm proposal.
            .@"i8x16.min_s" => try op_simd_int_arith.emitI8x16MinS(&ctx, &ins),
            .@"i8x16.min_u" => try op_simd_int_arith.emitI8x16MinU(&ctx, &ins),
            .@"i8x16.max_s" => try op_simd_int_arith.emitI8x16MaxS(&ctx, &ins),
            .@"i8x16.max_u" => try op_simd_int_arith.emitI8x16MaxU(&ctx, &ins),
            .@"i8x16.avgr_u" => try op_simd_int_arith.emitI8x16AvgrU(&ctx, &ins),
            .@"i16x8.min_s" => try op_simd_int_arith.emitI16x8MinS(&ctx, &ins),
            .@"i16x8.min_u" => try op_simd_int_arith.emitI16x8MinU(&ctx, &ins),
            .@"i16x8.max_s" => try op_simd_int_arith.emitI16x8MaxS(&ctx, &ins),
            .@"i16x8.max_u" => try op_simd_int_arith.emitI16x8MaxU(&ctx, &ins),
            .@"i16x8.avgr_u" => try op_simd_int_arith.emitI16x8AvgrU(&ctx, &ins),
            .@"i32x4.min_s" => try op_simd_int_arith.emitI32x4MinS(&ctx, &ins),
            .@"i32x4.min_u" => try op_simd_int_arith.emitI32x4MinU(&ctx, &ins),
            .@"i32x4.max_s" => try op_simd_int_arith.emitI32x4MaxS(&ctx, &ins),
            .@"i32x4.max_u" => try op_simd_int_arith.emitI32x4MaxU(&ctx, &ins),
            // §9.9 / 9.9-g-7 + 9.9-g-8 — int shifts (12 ops).
            .@"i8x16.shl" => try op_simd_int_arith.emitI8x16Shl(&ctx, &ins),
            .@"i16x8.shl" => try op_simd_int_arith.emitI16x8Shl(&ctx, &ins),
            .@"i32x4.shl" => try op_simd_int_arith.emitI32x4Shl(&ctx, &ins),
            .@"i64x2.shl" => try op_simd_int_arith.emitI64x2Shl(&ctx, &ins),
            .@"i8x16.shr_u" => try op_simd_int_arith.emitI8x16ShrU(&ctx, &ins),
            .@"i16x8.shr_u" => try op_simd_int_arith.emitI16x8ShrU(&ctx, &ins),
            .@"i32x4.shr_u" => try op_simd_int_arith.emitI32x4ShrU(&ctx, &ins),
            .@"i64x2.shr_u" => try op_simd_int_arith.emitI64x2ShrU(&ctx, &ins),
            .@"i8x16.shr_s" => try op_simd_int_arith.emitI8x16ShrS(&ctx, &ins),
            .@"i16x8.shr_s" => try op_simd_int_arith.emitI16x8ShrS(&ctx, &ins),
            .@"i32x4.shr_s" => try op_simd_int_arith.emitI32x4ShrS(&ctx, &ins),
            .@"i64x2.shr_s" => try op_simd_int_arith.emitI64x2ShrS(&ctx, &ins),
            // §9.9 / 9.9-g-3 — v128 reductions (any_true / all_true).
            .@"v128.any_true" => try op_simd.emitV128AnyTrue(&ctx, &ins),
            .@"i8x16.all_true" => try op_simd_int_cmp_lane.emitI8x16AllTrue(&ctx, &ins),
            .@"i16x8.all_true" => try op_simd_int_cmp_lane.emitI16x8AllTrue(&ctx, &ins),
            .@"i32x4.all_true" => try op_simd_int_cmp_lane.emitI32x4AllTrue(&ctx, &ins),
            .@"i64x2.all_true" => try op_simd_int_cmp_lane.emitI64x2AllTrue(&ctx, &ins),
            // §9.9 / 9.9-g-19 — i*x*.bitmask (per ADR-0051; uses
            // emit-time-derived per-shape masks via extra_consts).
            .@"i8x16.bitmask" => try op_simd_int_cmp_lane.emitI8x16Bitmask(&ctx, &ins),
            .@"i16x8.bitmask" => try op_simd_int_cmp_lane.emitI16x8Bitmask(&ctx, &ins),
            .@"i32x4.bitmask" => try op_simd_int_cmp_lane.emitI32x4Bitmask(&ctx, &ins),
            .@"i64x2.bitmask" => try op_simd_int_cmp_lane.emitI64x2Bitmask(&ctx, &ins),
            // §9.9/9.9-f-7 — int unops (abs / neg / popcnt).
            .@"i8x16.abs" => try op_simd_int_arith.emitI8x16Abs(&ctx, &ins),
            .@"i8x16.neg" => try op_simd_int_arith.emitI8x16Neg(&ctx, &ins),
            .@"i8x16.popcnt" => try op_simd_int_arith.emitI8x16Popcnt(&ctx, &ins),
            .@"i16x8.abs" => try op_simd_int_arith.emitI16x8Abs(&ctx, &ins),
            .@"i16x8.neg" => try op_simd_int_arith.emitI16x8Neg(&ctx, &ins),
            .@"i32x4.abs" => try op_simd_int_arith.emitI32x4Abs(&ctx, &ins),
            .@"i32x4.neg" => try op_simd_int_arith.emitI32x4Neg(&ctx, &ins),
            .@"i64x2.abs" => try op_simd_int_arith.emitI64x2Abs(&ctx, &ins),
            .@"i64x2.neg" => try op_simd_int_arith.emitI64x2Neg(&ctx, &ins),
            // §9.9/9.5-c-vi — int lane access for B/H/D element forms.
            // i32x4 already wired in 9.5-c-iii above. f32x4/f64x2 +
            // i64x2.mul defer to 9.5-c-vii.
            .@"i8x16.extract_lane_s" => try op_simd_int_cmp_lane.emitI8x16ExtractLaneS(&ctx, &ins),
            .@"i8x16.extract_lane_u" => try op_simd_int_cmp_lane.emitI8x16ExtractLaneU(&ctx, &ins),
            .@"i8x16.replace_lane" => try op_simd_int_cmp_lane.emitI8x16ReplaceLane(&ctx, &ins),
            .@"i16x8.extract_lane_s" => try op_simd_int_cmp_lane.emitI16x8ExtractLaneS(&ctx, &ins),
            .@"i16x8.extract_lane_u" => try op_simd_int_cmp_lane.emitI16x8ExtractLaneU(&ctx, &ins),
            .@"i16x8.replace_lane" => try op_simd_int_cmp_lane.emitI16x8ReplaceLane(&ctx, &ins),
            .@"i64x2.extract_lane" => try op_simd_int_cmp_lane.emitI64x2ExtractLane(&ctx, &ins),
            .@"i64x2.replace_lane" => try op_simd_int_cmp_lane.emitI64x2ReplaceLane(&ctx, &ins),
            // §9.9/9.5-c-vii — f32x4 / f64x2 lane access. i64x2.mul
            // synthesis defers to 9.5-c-vii-mul (scratch-reg conv).
            .@"f32x4.extract_lane" => try op_simd_float.emitF32x4ExtractLane(&ctx, &ins),
            .@"f32x4.replace_lane" => try op_simd_float.emitF32x4ReplaceLane(&ctx, &ins),
            .@"f64x2.extract_lane" => try op_simd_float.emitF64x2ExtractLane(&ctx, &ins),
            .@"f64x2.replace_lane" => try op_simd_float.emitF64x2ReplaceLane(&ctx, &ins),
            // §9.9/9.5-c-vii-mul — i64x2.mul multi-instr synthesis.
            .@"i64x2.mul" => try op_simd_int_arith.emitI64x2Mul(&ctx, &ins),
            // §9.6/9.6-a — f32x4 / f64x2 binary FP arithmetic.
            .@"f32x4.add" => try op_simd_float.emitF32x4Add(&ctx, &ins),
            .@"f32x4.sub" => try op_simd_float.emitF32x4Sub(&ctx, &ins),
            .@"f32x4.mul" => try op_simd_float.emitF32x4Mul(&ctx, &ins),
            .@"f32x4.div" => try op_simd_float.emitF32x4Div(&ctx, &ins),
            .@"f64x2.add" => try op_simd_float.emitF64x2Add(&ctx, &ins),
            .@"f64x2.sub" => try op_simd_float.emitF64x2Sub(&ctx, &ins),
            .@"f64x2.mul" => try op_simd_float.emitF64x2Mul(&ctx, &ins),
            .@"f64x2.div" => try op_simd_float.emitF64x2Div(&ctx, &ins),
            // §9.6/9.6-b — f32x4/f64x2 unary FP arithmetic.
            .@"f32x4.abs" => try op_simd_float.emitF32x4Abs(&ctx, &ins),
            .@"f32x4.neg" => try op_simd_float.emitF32x4Neg(&ctx, &ins),
            .@"f32x4.sqrt" => try op_simd_float.emitF32x4Sqrt(&ctx, &ins),
            .@"f32x4.ceil" => try op_simd_float.emitF32x4Ceil(&ctx, &ins),
            .@"f32x4.floor" => try op_simd_float.emitF32x4Floor(&ctx, &ins),
            .@"f32x4.trunc" => try op_simd_float.emitF32x4Trunc(&ctx, &ins),
            .@"f32x4.nearest" => try op_simd_float.emitF32x4Nearest(&ctx, &ins),
            .@"f64x2.abs" => try op_simd_float.emitF64x2Abs(&ctx, &ins),
            .@"f64x2.neg" => try op_simd_float.emitF64x2Neg(&ctx, &ins),
            .@"f64x2.sqrt" => try op_simd_float.emitF64x2Sqrt(&ctx, &ins),
            .@"f64x2.ceil" => try op_simd_float.emitF64x2Ceil(&ctx, &ins),
            .@"f64x2.floor" => try op_simd_float.emitF64x2Floor(&ctx, &ins),
            .@"f64x2.trunc" => try op_simd_float.emitF64x2Trunc(&ctx, &ins),
            .@"f64x2.nearest" => try op_simd_float.emitF64x2Nearest(&ctx, &ins),
            // §9.6/9.6-c-i — f32x4/f64x2 min/max (NaN-propagating).
            .@"f32x4.min" => try op_simd_float.emitF32x4Min(&ctx, &ins),
            .@"f32x4.max" => try op_simd_float.emitF32x4Max(&ctx, &ins),
            .@"f64x2.min" => try op_simd_float.emitF64x2Min(&ctx, &ins),
            .@"f64x2.max" => try op_simd_float.emitF64x2Max(&ctx, &ins),
            // §9.6/9.6-c-ii — f32x4/f64x2 pmin/pmax synthesis (FCMGT + BSL).
            .@"f32x4.pmin" => try op_simd_float.emitF32x4Pmin(&ctx, &ins),
            .@"f32x4.pmax" => try op_simd_float.emitF32x4Pmax(&ctx, &ins),
            .@"f64x2.pmin" => try op_simd_float.emitF64x2Pmin(&ctx, &ins),
            .@"f64x2.pmax" => try op_simd_float.emitF64x2Pmax(&ctx, &ins),
            // §9.6/9.6-d — int per-lane compares (CMEQ/CMGT/CMGE/CMHI/CMHS family).
            .@"i8x16.eq" => try op_simd_int_cmp_lane.emitI8x16Eq(&ctx, &ins),
            .@"i8x16.ne" => try op_simd_int_cmp_lane.emitI8x16Ne(&ctx, &ins),
            .@"i8x16.lt_s" => try op_simd_int_cmp_lane.emitI8x16LtS(&ctx, &ins),
            .@"i8x16.lt_u" => try op_simd_int_cmp_lane.emitI8x16LtU(&ctx, &ins),
            .@"i8x16.gt_s" => try op_simd_int_cmp_lane.emitI8x16GtS(&ctx, &ins),
            .@"i8x16.gt_u" => try op_simd_int_cmp_lane.emitI8x16GtU(&ctx, &ins),
            .@"i8x16.le_s" => try op_simd_int_cmp_lane.emitI8x16LeS(&ctx, &ins),
            .@"i8x16.le_u" => try op_simd_int_cmp_lane.emitI8x16LeU(&ctx, &ins),
            .@"i8x16.ge_s" => try op_simd_int_cmp_lane.emitI8x16GeS(&ctx, &ins),
            .@"i8x16.ge_u" => try op_simd_int_cmp_lane.emitI8x16GeU(&ctx, &ins),
            .@"i16x8.eq" => try op_simd_int_cmp_lane.emitI16x8Eq(&ctx, &ins),
            .@"i16x8.ne" => try op_simd_int_cmp_lane.emitI16x8Ne(&ctx, &ins),
            .@"i16x8.lt_s" => try op_simd_int_cmp_lane.emitI16x8LtS(&ctx, &ins),
            .@"i16x8.lt_u" => try op_simd_int_cmp_lane.emitI16x8LtU(&ctx, &ins),
            .@"i16x8.gt_s" => try op_simd_int_cmp_lane.emitI16x8GtS(&ctx, &ins),
            .@"i16x8.gt_u" => try op_simd_int_cmp_lane.emitI16x8GtU(&ctx, &ins),
            .@"i16x8.le_s" => try op_simd_int_cmp_lane.emitI16x8LeS(&ctx, &ins),
            .@"i16x8.le_u" => try op_simd_int_cmp_lane.emitI16x8LeU(&ctx, &ins),
            .@"i16x8.ge_s" => try op_simd_int_cmp_lane.emitI16x8GeS(&ctx, &ins),
            .@"i16x8.ge_u" => try op_simd_int_cmp_lane.emitI16x8GeU(&ctx, &ins),
            .@"i32x4.eq" => try op_simd_int_cmp_lane.emitI32x4Eq(&ctx, &ins),
            .@"i32x4.ne" => try op_simd_int_cmp_lane.emitI32x4Ne(&ctx, &ins),
            .@"i32x4.lt_s" => try op_simd_int_cmp_lane.emitI32x4LtS(&ctx, &ins),
            .@"i32x4.lt_u" => try op_simd_int_cmp_lane.emitI32x4LtU(&ctx, &ins),
            .@"i32x4.gt_s" => try op_simd_int_cmp_lane.emitI32x4GtS(&ctx, &ins),
            .@"i32x4.gt_u" => try op_simd_int_cmp_lane.emitI32x4GtU(&ctx, &ins),
            .@"i32x4.le_s" => try op_simd_int_cmp_lane.emitI32x4LeS(&ctx, &ins),
            .@"i32x4.le_u" => try op_simd_int_cmp_lane.emitI32x4LeU(&ctx, &ins),
            .@"i32x4.ge_s" => try op_simd_int_cmp_lane.emitI32x4GeS(&ctx, &ins),
            .@"i32x4.ge_u" => try op_simd_int_cmp_lane.emitI32x4GeU(&ctx, &ins),
            .@"i64x2.eq" => try op_simd_int_cmp_lane.emitI64x2Eq(&ctx, &ins),
            .@"i64x2.ne" => try op_simd_int_cmp_lane.emitI64x2Ne(&ctx, &ins),
            .@"i64x2.lt_s" => try op_simd_int_cmp_lane.emitI64x2LtS(&ctx, &ins),
            .@"i64x2.gt_s" => try op_simd_int_cmp_lane.emitI64x2GtS(&ctx, &ins),
            .@"i64x2.le_s" => try op_simd_int_cmp_lane.emitI64x2LeS(&ctx, &ins),
            .@"i64x2.ge_s" => try op_simd_int_cmp_lane.emitI64x2GeS(&ctx, &ins),
            // §9.6/9.6-e — FP per-lane compares (FCMEQ/FCMGT/FCMGE).
            .@"f32x4.eq" => try op_simd_float.emitF32x4Eq(&ctx, &ins),
            .@"f32x4.ne" => try op_simd_float.emitF32x4Ne(&ctx, &ins),
            .@"f32x4.lt" => try op_simd_float.emitF32x4Lt(&ctx, &ins),
            .@"f32x4.gt" => try op_simd_float.emitF32x4Gt(&ctx, &ins),
            .@"f32x4.le" => try op_simd_float.emitF32x4Le(&ctx, &ins),
            .@"f32x4.ge" => try op_simd_float.emitF32x4Ge(&ctx, &ins),
            .@"f64x2.eq" => try op_simd_float.emitF64x2Eq(&ctx, &ins),
            .@"f64x2.ne" => try op_simd_float.emitF64x2Ne(&ctx, &ins),
            .@"f64x2.lt" => try op_simd_float.emitF64x2Lt(&ctx, &ins),
            .@"f64x2.gt" => try op_simd_float.emitF64x2Gt(&ctx, &ins),
            .@"f64x2.le" => try op_simd_float.emitF64x2Le(&ctx, &ins),
            .@"f64x2.ge" => try op_simd_float.emitF64x2Ge(&ctx, &ins),
            // §9.6/9.6-f-i — i8x16.swizzle via NEON TBL (1-register form).
            .@"i8x16.swizzle" => try op_simd_int_cmp_lane.emitI8x16Swizzle(&ctx, &ins),
            // §9.6/9.6-g-i — extend low/high (SXTL/SXTL2/UXTL/UXTL2).
            .@"i16x8.extend_low_i8x16_s" => try op_simd_int_cmp_lane.emitI16x8ExtendLowI8x16S(&ctx, &ins),
            .@"i16x8.extend_high_i8x16_s" => try op_simd_int_cmp_lane.emitI16x8ExtendHighI8x16S(&ctx, &ins),
            .@"i16x8.extend_low_i8x16_u" => try op_simd_int_cmp_lane.emitI16x8ExtendLowI8x16U(&ctx, &ins),
            .@"i16x8.extend_high_i8x16_u" => try op_simd_int_cmp_lane.emitI16x8ExtendHighI8x16U(&ctx, &ins),
            .@"i32x4.extend_low_i16x8_s" => try op_simd_int_cmp_lane.emitI32x4ExtendLowI16x8S(&ctx, &ins),
            .@"i32x4.extend_high_i16x8_s" => try op_simd_int_cmp_lane.emitI32x4ExtendHighI16x8S(&ctx, &ins),
            .@"i32x4.extend_low_i16x8_u" => try op_simd_int_cmp_lane.emitI32x4ExtendLowI16x8U(&ctx, &ins),
            .@"i32x4.extend_high_i16x8_u" => try op_simd_int_cmp_lane.emitI32x4ExtendHighI16x8U(&ctx, &ins),
            .@"i64x2.extend_low_i32x4_s" => try op_simd_int_cmp_lane.emitI64x2ExtendLowI32x4S(&ctx, &ins),
            .@"i64x2.extend_high_i32x4_s" => try op_simd_int_cmp_lane.emitI64x2ExtendHighI32x4S(&ctx, &ins),
            .@"i64x2.extend_low_i32x4_u" => try op_simd_int_cmp_lane.emitI64x2ExtendLowI32x4U(&ctx, &ins),
            .@"i64x2.extend_high_i32x4_u" => try op_simd_int_cmp_lane.emitI64x2ExtendHighI32x4U(&ctx, &ins),
            // §9.6/9.6-g-ii — saturating narrow (SQXTN/SQXTUN family).
            .@"i8x16.narrow_i16x8_s" => try op_simd_int_cmp_lane.emitI8x16NarrowI16x8S(&ctx, &ins),
            .@"i8x16.narrow_i16x8_u" => try op_simd_int_cmp_lane.emitI8x16NarrowI16x8U(&ctx, &ins),
            .@"i16x8.narrow_i32x4_s" => try op_simd_int_cmp_lane.emitI16x8NarrowI32x4S(&ctx, &ins),
            .@"i16x8.narrow_i32x4_u" => try op_simd_int_cmp_lane.emitI16x8NarrowI32x4U(&ctx, &ins),
            // §9.6/9.6-g-iii — i→f FP convert (SCVTF/UCVTF family).
            .@"f32x4.convert_i32x4_s" => try op_simd_float.emitF32x4ConvertI32x4S(&ctx, &ins),
            .@"f32x4.convert_i32x4_u" => try op_simd_float.emitF32x4ConvertI32x4U(&ctx, &ins),
            .@"f64x2.convert_low_i32x4_s" => try op_simd_float.emitF64x2ConvertLowI32x4S(&ctx, &ins),
            .@"f64x2.convert_low_i32x4_u" => try op_simd_float.emitF64x2ConvertLowI32x4U(&ctx, &ins),
            // §9.6/9.6-g-iv — FP promote/demote (FCVTL/FCVTN).
            .@"f64x2.promote_low_f32x4" => try op_simd_float.emitF64x2PromoteLowF32x4(&ctx, &ins),
            .@"f32x4.demote_f64x2_zero" => try op_simd_float.emitF32x4DemoteF64x2Zero(&ctx, &ins),
            // §9.6/9.6-g-v — trunc_sat (FCVTZS/U + SQXTN/UQXTN family).
            .@"i32x4.trunc_sat_f32x4_s" => try op_simd_float.emitI32x4TruncSatF32x4S(&ctx, &ins),
            .@"i32x4.trunc_sat_f32x4_u" => try op_simd_float.emitI32x4TruncSatF32x4U(&ctx, &ins),
            .@"i32x4.trunc_sat_f64x2_s_zero" => try op_simd_float.emitI32x4TruncSatF64x2SZero(&ctx, &ins),
            .@"i32x4.trunc_sat_f64x2_u_zero" => try op_simd_float.emitI32x4TruncSatF64x2UZero(&ctx, &ins),
            // §9.6/9.6-f-ii — v128.const + i8x16.shuffle (per ADR-0042
            // const-pool with PC-relative LDR-Q-literal + fixup pass).
            .@"v128.const" => try op_simd.emitV128Const(&ctx, &ins),
            .@"i8x16.shuffle" => try op_simd_int_cmp_lane.emitI8x16Shuffle(&ctx, &ins),

            else => {
                // §9.7 / 7.5-diag-op: surface the unhandled op
                // tag to stderr so the spec-jit-compile-runner's
                // /tmp/<host>.log captures which Wasm op the
                // emit pass doesn't know yet. Without this, every
                // missing-op fixture reports the opaque
                // `UnsupportedOp` and triaging requires hand
                // bisecting the body.
                std.debug.print(
                    "arm64/emit: unsupported op `{s}` (func_idx={d})\n",
                    .{ @tagName(ins.op), func.func_idx },
                );
                return Error.UnsupportedOp;
            },
        }
    }

    return .{
        .bytes = try buf.toOwnedSlice(allocator),
        .n_slots = alloc.n_slots,
        .call_fixups = try call_fixups.toOwnedSlice(allocator),
    };
}

// ============================================================
// AAPCS64 prologue / epilogue micro-encodings
//
// These are the four fixed encodings every leaf function body
// uses. Inlined here rather than added to inst.zig because
// they're convention-shaped (always the same operands) — adding
// a dedicated enc* in inst.zig would invite false flexibility.
// ============================================================

/// `STP X29, X30, [SP, #-16]!` — pre-index push of FP/LR pair.
/// Encoding (STP 64-bit pre-indexed):
///   `1010 1001 10 [imm7:7] [Rt2:5] [Rn:5] [Rt:5]`
/// imm7 = -16/8 = -2 (signed) = 7'b1111110 = 0x7E.
/// Rn = 31 (SP), Rt = 29 (FP), Rt2 = 30 (LR).
fn encStpFpLrPreIdx() u32 {
    // 0xA9BF7BFD = STP X29, X30, [SP, #-16]!
    return 0xA9BF7BFD;
}

/// Look up the declared Wasm value-type at a local index (params
/// followed by declared locals; per D-033 fix). Caller has already
/// validated `local_idx < total_locals`.
fn localValType(func: *const ZirFunc, num_params: u32, local_idx: u32) zir.ValType {
    _ = num_params;
    return func.localValType(local_idx);
}

/// `LDP X29, X30, [SP], #16` — post-index pop of FP/LR pair.
/// Encoding (LDP 64-bit post-indexed):
///   `1010 1000 11 [imm7:7] [Rt2:5] [Rn:5] [Rt:5]`
/// imm7 = +16/8 = 2.
fn encLdpFpLrPostIdx() u32 {
    // 0xA8C17BFD = LDP X29, X30, [SP], #16
    return 0xA8C17BFD;
}

/// `MOV X29, SP` — encoded as `ADD X29, SP, #0` (the canonical
/// MOV between SP-form and a register).
/// Encoding (ADD 64-bit imm, sh=0): `1 00 10001 00 0 0000 0000 0000 [Rn:5] [Rd:5]`
/// Rn = 31 (SP), Rd = 29 (FP).
fn encMovSpToFp() u32 {
    // 0x910003FD = mov x29, sp
    return 0x910003FD;
}

/// `MOV X0, Xsrc` — encoded as `ORR X0, XZR, Xsrc` (the
/// canonical 64-bit register-to-register MOV).
/// Encoding: `1 01 01010 00 0 [Rm:5] 000000 11111 [Rd:5]`
/// = 0xAA0003E0 | (Rm << 16).
fn encOrrZrIntoX0(rm: Xn) u32 {
    return 0xAA0003E0 | (@as(u32, rm) << 16);
}
