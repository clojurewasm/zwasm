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
            .i32, .i64, .f32, .f64 => {},
            .v128, .funcref, .externref => {
                std.debug.print("arm64/emit: param type `{s}` unsupported (func_idx={d})\n", .{ @tagName(p), func.func_idx });
                return Error.UnsupportedOp;
            },
        }
    }
    const num_params: u32 = @intCast(func.sig.params.len);
    const num_locals: u32 = func.totalLocalCount();
    // Wasm local-index space: 0..num_params-1 = params,
    // num_params..num_params+num_locals-1 = declared locals.
    // Both share the same per-slot 8-byte stack region; frame
    // size accounts for both.
    const total_locals: u32 = num_params + num_locals;
    const locals_bytes: u32 = total_locals * 8;
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
    const outgoing_max_bytes: u32 = computeOutgoingMaxBytes(func, func_sigs, module_types);
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
        // §9.7 / 7.9-d-11: param slot lives at `[SP, #(local_base_off
        // + p_idx*8)]` — the local region sits above the outgoing-
        // args region. Width-checked per encoding (W-form u14,
        // X/D-form u15).
        const param_off_u: u32 = local_base_off + p_idx * 8;
        if (param_off_u > 16380) return Error.UnsupportedOp;
        const param_off_w: u14 = @intCast(param_off_u);
        const param_off_x: u15 = @intCast(param_off_u);
        switch (func.sig.params[p_idx]) {
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
            // SIMD / refs were already filtered above; the
            // exhaustive switch here is for zlinter satisfaction.
            .v128, .funcref, .externref => unreachable,
        }
    }

    // Zero-initialise declared locals (Wasm spec §4.5.3.1: locals
    // beyond params are initialised to zero on entry). Each slot is
    // 8 bytes; STR XZR covers all i32/i64/f32/f64 widths since the
    // upper bits of narrower local-loads are masked by the LDR W /
    // LDR S forms.
    var loc_idx: u32 = num_params;
    while (loc_idx < total_locals) : (loc_idx += 1) {
        const loc_off_u: u32 = local_base_off + loc_idx * 8;
        if (loc_off_u > 32760) return Error.UnsupportedOp;
        const loc_off: u15 = @intCast(loc_off_u);
        try gpr.writeU32(allocator, &buf, inst.encStrImm(31, 31, loc_off));
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
        .local_base_off = local_base_off,
        .spill_base_off = spill_base_off,
        .num_imports = num_imports,
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
        _ = pc;
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
                // [SP, #(local_idx * 8)]. Width follows declared
                // local type (i32 → LDR W, i64 → LDR X) per D-033.
                const local_idx = ins.payload;
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                // §9.7 / 7.9-d-11: local slot at `[SP, #(local_base_off
                // + local_idx*8)]` (above the outgoing-args region).
                const offset_u: u32 = local_base_off + local_idx * 8;
                if (offset_u > 16380) return Error.UnsupportedOp;
                const offset_w: u14 = @intCast(offset_u);
                const offset_x: u15 = @intCast(offset_u);
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
                    .v128, .funcref, .externref => {
                        std.debug.print("arm64/emit: local.get type `{s}` unsupported (idx={d})\n", .{ @tagName(ty), local_idx });
                        return Error.UnsupportedOp;
                    },
                }
                try pushed_vregs.append(allocator, vreg);
            },
            .@"local.set" => {
                // Pop top vreg, write to [SP, #(local_idx * 8)].
                // Width follows declared local type per D-033.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                const offset_u: u32 = local_base_off + local_idx * 8;
                if (offset_u > 16380) return Error.UnsupportedOp;
                const offset_w: u14 = @intCast(offset_u);
                const offset_x: u15 = @intCast(offset_u);
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
                    .v128, .funcref, .externref => {
                        std.debug.print("arm64/emit: local.set type `{s}` unsupported (idx={d})\n", .{ @tagName(ty), local_idx });
                        return Error.UnsupportedOp;
                    },
                }
            },
            .@"local.tee" => {
                // Write top vreg to [SP, #(local_idx * 8)] WITHOUT
                // popping — the value remains pushed.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= total_locals) return Error.UnsupportedOp;
                const ty = localValType(func, num_params, local_idx);
                const offset_u: u32 = local_base_off + local_idx * 8;
                if (offset_u > 16380) return Error.UnsupportedOp;
                const offset_w: u14 = @intCast(offset_u);
                const offset_x: u15 = @intCast(offset_u);
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
                    .v128, .funcref, .externref => {
                        std.debug.print("arm64/emit: local.tee type `{s}` unsupported (idx={d})\n", .{ @tagName(ty), local_idx });
                        return Error.UnsupportedOp;
                    },
                }
            },
            .@"i32.popcnt" => try op_alu_int.emitI32Popcnt(&ctx, &ins),
            .select, .select_typed => {
                // Wasm spec §4.4.4: pop c, val2, val1 (top of
                // stack is c). Push val1 if c != 0, else val2.
                // ARM64 lowering: CMP c_w, #0 ; CSEL d_w,
                // val1_w, val2_w, NE.
                //
                // Type assumption: val1 / val2 width is i32
                // (CSEL Wd, 32-bit select). The validator
                // already enforces both operands share a single
                // type; supporting i64 needs CSEL Xd via
                // type-aware dispatch (debt: D-034 / 7.5-select-
                // i64-fp variant). FP / refs surface as a
                // separate variant lifted later.
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
                // D-034 spill-aware: 3 source operands but only 2
                // stage regs. CMP is encoded first using stage 0 for
                // cond; after CMP the cond value is dead, so stage 0
                // is reused for val1 (and result).
                const cond_w = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, cond_v, 0);
                try gpr.writeU32(allocator, &buf, inst.encCmpImmW(cond_w, 0));
                const val1_w = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val1_v, 0);
                const val2_w = try gpr.gprLoadSpilled(allocator, &buf, alloc, ctx.spill_base_off, val2_v, 1);
                const dst_w = try gpr.gprDefSpilled(alloc, result_v, 0);
                try gpr.writeU32(allocator, &buf, inst.encCselW(dst_w, val1_w, val2_w, .ne));
                try gpr.gprStoreSpilled(allocator, &buf, alloc, ctx.spill_base_off, result_v, 0);
                try pushed_vregs.append(allocator, result_v);
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
                        .i32, .i64, .v128, .funcref, .externref => {
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
            .@"global.get" => try op_globals.emitI32GlobalGet(&ctx, &ins),
            .@"global.set" => try op_globals.emitI32GlobalSet(&ctx, &ins),
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
                    const is_fp = switch (result_kind) {
                        .f32, .f64 => true,
                        .i32, .i64, .v128, .funcref, .externref => false,
                    };
                    if (is_fp) {
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
                    } else {
                        // GPR result: spill-aware load (sub-1c). For
                        // an in-reg vreg, returns the home reg; for
                        // a spilled vreg, emits LDR X14, [SP, #off]
                        // and returns X14. Then MOV X0, Xsrc.
                        const src_xn = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, top_vreg, 0);
                        if (src_xn != 0) {
                            try gpr.writeU32(allocator, &buf, encOrrZrIntoX0(src_xn));
                        }
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
                break;
            },
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
