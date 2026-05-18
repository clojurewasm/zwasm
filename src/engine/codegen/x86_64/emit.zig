//! x86_64 emit pass — skeleton (§9.7 / 7.7).
//!
//! Mirrors the role of `arm64/emit.zig`'s `compile()` entry but
//! covers the minimal `(i32.const N) end` cycle to prove the
//! ZIR → x86_64 byte-stream pipeline end-to-end. Subsequent
//! chunks layer on op coverage (i32 ALU, memory, control flow,
//! calls, FP) and the reserved_invariant_gprs reservation
//! decision (deferred from §9.7 / 7.6 chunk c).
//!
//! Skeleton scope (this commit):
//! - Function prologue: PUSH RBP ; MOV RBP, RSP (no SUB RSP yet
//!   — locals + spills land with the regalloc port).
//! - `i32.const N` → MOV r32(slot 0), #N (zero-extended to 64 by
//!   the W-form of MOV-imm).
//! - Function-level `end` → MOV EAX, r32(top vreg) ; POP RBP ;
//!   RET. EAX is RAX low 32 bits — Wasm i32 return per SysV
//!   x86_64 §3.2.4.
//!
//! What's INTENTIONALLY NOT in this skeleton:
//! - Multi-call X0-style runtime_ptr restore: arm64's ADR-0017
//!   sub-2d-ii doesn't apply here yet because there are no
//!   calls. The reserved_invariant_gprs decision (load-once at
//!   prologue vs reload-from-runtime-ptr at point of use) lands
//!   when the first call / memory op handler arrives.
//! - Frame extension for locals / spills (no LOCAL ops in the
//!   skeleton — `func.locals.len > 0` → `UnsupportedOp`).
//! - Call fixups (no `call` ops — `EmitOutput.call_fixups` is
//!   declared but always empty in this chunk).
//! - Bounds-check trap stub (no memory ops yet).
//! - Label / control flow stack (no `block` / `loop` / `br`
//!   / `if` ops).
//!
//! The shape mirrors arm64/emit.zig (compile() returns
//! EmitOutput; `func.liveness` must agree with `alloc.slots`)
//! so the §9.7 / 7.11 three-way differential can compare ARM64
//! and x86_64 outputs at the same byte-stream layer.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const usage = @import("usage.zig");
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");
const label_mod = @import("label.zig");
const op_alu_int = @import("op_alu_int.zig");
const op_alu_float = @import("op_alu_float.zig");
const op_convert = @import("op_convert.zig");
const op_memory = @import("op_memory.zig");
const op_control = @import("op_control.zig");
const op_call = @import("op_call.zig");
const op_globals = @import("op_globals.zig");
const op_table = @import("op_table.zig");
const op_simd = @import("op_simd.zig");
const op_simd_int_arith = @import("op_simd_int_arith.zig");
const op_simd_int_cmp_lane = @import("op_simd_int_cmp_lane.zig");
const op_simd_float = @import("op_simd_float.zig");
const gpr = @import("gpr.zig");
const rbp_disp = @import("rbp_disp.zig");

// rbp/rsp form-selectors live in rbp_disp.zig per D-052
// progression (extract when emit.zig approached the 2000-LOC
// hard cap). Call-site shape is unchanged.
const rbpStoreR32 = rbp_disp.rbpStoreR32;
const rbpLoadR32 = rbp_disp.rbpLoadR32;
const rbpStoreR64 = rbp_disp.rbpStoreR64;
const rbpLoadR64 = rbp_disp.rbpLoadR64;
const rbpStoreXmmF32 = rbp_disp.rbpStoreXmmF32;
const rbpLoadXmmF32 = rbp_disp.rbpLoadXmmF32;
const rbpStoreXmmF64 = rbp_disp.rbpStoreXmmF64;
const rbpLoadXmmF64 = rbp_disp.rbpLoadXmmF64;
const rbpStoreXmmV128 = rbp_disp.rbpStoreXmmV128;
const rbpLoadXmmV128 = rbp_disp.rbpLoadXmmV128;
const rspSub = rbp_disp.rspSub;
const rspAdd = rbp_disp.rspAdd;

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;

// Re-exports from `types.zig` (D-030 chunk-a) — external callers
// (`src/zwasm.zig`, `src/diagnostic/trace.zig`, the linker) and
// the inner emit-pass code keep referencing these via the original
// `x86_64/emit.zig` paths.
pub const Error = types.Error;
pub const CallFixup = types.CallFixup;
pub const EmitOutput = types.EmitOutput;
pub const deinit = types.deinit;

// Internal types from `label.zig` (D-030 chunk-a). Aliased so the
// dispatch loop body keeps reading like the pre-split code.
const LabelKind = label_mod.LabelKind;
const Fixup = label_mod.Fixup;
const Label = label_mod.Label;

/// §9.7 / 7.10-f mirror of `arm64/emit.zig:computeOutgoingMaxBytes`.
/// Pre-scan the function body for the worst-case outgoing-args
/// region size at the bottom of the caller's frame (`[RSP, #0]`
/// upward). For each `call N` / `call_indirect type_idx`, count
/// the args that overflow the per-Cc register pools and sum the
/// per-slot 8-byte allocations; track the max across all calls.
///
/// **SysV** (System V x86_64 §3.2.3): int args use arg_gprs[1..6]
/// (5 user slots; arg_gprs[0] = RDI = runtime_ptr per ADR-0026).
/// FP args use arg_xmms[0..7] (8 user slots, independent counter).
/// Per-call overflow = `(max(0, n_int - 5) + max(0, n_fp - 8)) * 8`.
///
/// **Win64** (Microsoft x64): int and FP share slots arg_gprs[1..3]
/// (3 user slots; arg_gprs[0] = RCX = runtime_ptr). Total user
/// args > 3 ⇒ overflow. The shared shadow-space-prefixed region
/// places overflow at `[RSP + 32 + 8*K]`, so the outgoing region
/// must include the 32-byte shadow when any call exists. Per-call
/// outgoing = `32 + max(0, n_int + n_fp - 3) * 8`.
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
        var n_v128: u32 = 0;
        for (callee_sig.params) |p| {
            switch (p) {
                .i32, .i64, .funcref, .externref => n_int += 1,
                .f32, .f64 => n_fp += 1,
                // §9.9 / 9.9-i-1: Win64 v128 is a hidden-pointer
                // arg — consumes one int-arg-reg slot for the
                // pointer; on SysV it's an XMM-reg / stack-eightbyte
                // arg (already excluded from n_int / n_fp here).
                .v128 => n_v128 += 1,
            }
        }
        // §9.9 / 9.9-h-7 SysV: v128 fp-class consumes 2 eightbytes
        // on stack per overflowed arg (SSE class). §9.9 / 9.9-i-1
        // Win64: v128 = hidden ptr in int-arg slot + 16-byte scratch
        // in caller's outgoing region (Microsoft x64 §Param passing).
        const bytes: u32 = switch (abi.current_cc) {
            .sysv => blk: {
                // ADR-0026 2026-05-18 Convention Swap: MEMORY-class
                // callee receives &buffer in RDI (slot 0) + rt in
                // RSI (slot 1), shrinking the user int-reg pool to
                // 4 slots (RDX/RCX/R8/R9). Non-MEMORY callee
                // retains 5 user int regs (RSI..R9).
                const callee_is_memory_class = callee_sig.results.len > 2;
                const n_user_int_regs: u32 = if (callee_is_memory_class) 4 else 5;
                const n_int_overflow: u32 = if (n_int > n_user_int_regs) n_int - n_user_int_regs else 0;
                const n_fp_total = n_fp + 2 * n_v128;
                const n_fp_overflow: u32 = if (n_fp_total > 8) n_fp_total - 8 else 0;
                const overflow_bytes: u32 = (n_int_overflow + n_fp_overflow) * 8;
                // MEMORY-class return reserves an N×8 B buffer slot
                // at the top of THIS call's outgoing-args footprint.
                // The caller LEAs RDI = &buffer immediately before
                // CALL (Convention Swap above); the callee captures
                // RDI into its own frame slot. Mirrors arm64's
                // `indirect_result_slot_bytes` accounting. Win64
                // MEMORY-class deferred to §9.13-0.
                const return_buf_bytes: u32 = if (callee_is_memory_class)
                    @as(u32, @intCast(callee_sig.results.len)) * 8
                else
                    0;
                break :blk overflow_bytes + return_buf_bytes;
            },
            .win64 => blk: {
                const n_int_w = n_int + n_v128;
                const n_total = n_int_w + n_fp;
                const n_overflow: u32 = if (n_total > 3) n_total - 3 else 0;
                const shadow_and_overflow = abi.current.shadow_space_bytes + n_overflow * 8;
                const scratch_base = (shadow_and_overflow + 15) & ~@as(u32, 15);
                break :blk scratch_base + n_v128 * 16;
            },
        };
        if (bytes > max_bytes) max_bytes = bytes;
    }
    return max_bytes;
}

// `win64V128ScratchBase` helper lives in `op_call.zig` (used by
// the caller-side marshal). See §9.9 / 9.9-i-1.

/// Emit x86_64 machine code for `func`. Requires `alloc.slots`
/// to be populated (call `regalloc.compute` first; pass the
/// `Allocation` here). `func_sigs` and `module_types` are
/// declared for shape-parity with arm64 but unused in this
/// skeleton (no `call` / `call_indirect` handlers yet).
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
    // §9.7 / 7.8-x86-params: lift the params=0 reject. Mirrors
    // arm64/emit.zig:134 ("Multi-arg entry"). For now i32-only
    // params are supported; i64/f32/f64 surface UnsupportedOp
    // until the type-aware local + FP-marshal chunks land.
    // SysV reserves RDI for the runtime ptr (ADR-0026), so user
    // int args start at RSI (max 5). Win64 reserves RCX → user
    // int args start at RDX (max 3). The total runs through the
    // arch-specific `abi.current.arg_gprs` array, indexed past
    // the runtime-ptr save reg.
    const num_params: u32 = @intCast(func.sig.params.len);
    for (func.sig.params) |p| {
        switch (p) {
            // §9.9 / 9.9-i-1: v128 is supported under both ABIs.
            // SysV uses direct XMM0..XMM7 + stack-overflow (16-byte
            // aligned eightbyte pair). Win64 uses hidden-pointer
            // marshal per Microsoft x64 ABI §"Parameter passing"
            // (`__m128` passed via pointer in int-arg reg slot;
            // ADR-0055).
            // D-093 (d-33): reftype params share the i64 gpr-class
            // 8-byte slot per ADR-0061.
            .i32, .i64, .f32, .f64, .v128, .funcref, .externref => {},
        }
    }
    const num_locals: u32 = func.totalLocalCount();
    const total_locals: u32 = num_params + num_locals;
    // §9.7 / 7.10-g: localDisp now returns i32 + auto-helpers
    // pick disp8 / disp32 form per offset, so total_locals is no
    // longer capped at 15. Practical cap = i32 disp range / 8 =
    // ~268M slots — far past any realistic Wasm function.

    // Prescan: does this function need the runtime-ptr save?
    // Helper in `usage.zig`. Per ADR-0026 + §9.9 / 9.9-m-5
    // (D-087/088/089 cohort) — see helper doc for the full
    // op set.
    const uses_runtime_ptr = usage.usesRuntimePtr(func);

    // Frame-bytes formula depends on prologue shape (SysV §3.2.2
    // 16-byte stack alignment; CALL pushes ret addr → entry RSP
    // ≡ 8 mod 16; PUSH RBP → 0 mod 16; PUSH R15 → 8 mod 16):
    //   - 1-PUSH:  frame ≡ 0 mod 16  (current shape; rounds up locals_bytes to 16)
    //   - 2-PUSH:  frame ≡ 8 mod 16  (per ADR-0026 prologue)
    //
    // D-045 chunk 13b: extend frame by spill region. Layout
    // (frame grows DOWN from RBP):
    //   [RBP - 8]                     R15 save (if uses_runtime_ptr)
    //   [RBP - 8*(K+1)]               local K  (without R15)
    //   [RBP - 8 - 8*(K+1)]           local K  (with R15)
    //   [RBP - spill_base_off - off]  spill slot at offset `off`
    // `spill_base_off` = locals_bytes + (uses_runtime_ptr ? 8 : 0) + 8
    // (the +8 puts spill slot 0 in the next 8-byte cell below
    // the deepest local). `gpr.zig`'s `rbpDispNegI8` consumes it
    // as `disp = -(spill_base_off + spill_off)`.
    // §9.9 / 9.9-e-2: per-function frame layout (group-by-type).
    // Mirror of arm64/emit.zig's LocalLayout: scalars at 8-byte
    // stride, v128 at 16-byte stride. `base_off_for_locals` is
    // -8 if uses_runtime_ptr (R15 save occupies [RBP-8]) else 0;
    // disps[i] is the most-negative byte of v128 slot `i` (since
    // MOVUPS [RBP+disp] writes UPWARD from disp).
    const base_off_for_locals: i32 = if (uses_runtime_ptr) -8 else 0;
    var layout = try computeLocalLayout(allocator, func, base_off_for_locals);
    defer layout.deinit(allocator);
    const locals_bytes: u32 = layout.total_bytes;
    const spill_bytes: u32 = alloc.spillBytes();
    const r15_save_bytes: u32 = if (uses_runtime_ptr) 8 else 0;
    // ADR-0026 2026-05-18 amend (Convention Swap) / ADR-0069 §Phase 2:
    // MEMORY-class returns (struct > 16 B per SysV §3.2.3; v2
    // trigger = `sig.results.len > 2`) follow the standard SysV
    // §3.2.3 hidden-arg shape — RDI = &result_buffer, RSI = rt
    // (= the function's natural arg0 shifted one int-slot deeper).
    // Aligns with Zig's auto-generated `callconv(.c)` lowering for
    // struct returns > 16 B so entry.zig helpers don't need inline-
    // asm thunks. The prologue captures RDI into an 8-byte frame
    // slot positioned BELOW the spill region; the epilogue
    // (`marshalReturnRegs`) loads it into RAX and writes each
    // result to `[RAX + i*8]`. Win64 MEMORY-class deferred to
    // §9.13-0.
    const return_is_memory_class: bool = func.sig.results.len > 2 and abi.current_cc == .sysv;
    const indirect_result_slot_bytes: u32 = if (return_is_memory_class) 8 else 0;
    const spill_base_off: u32 = locals_bytes + r15_save_bytes + 8;
    // Buffer-ptr capture slot lives BELOW the spill region (deeper
    // into the frame, larger RBP-negative offset). Slot anchored at
    // `[RBP - (spill_base_off + spill_bytes)]`; the +8 below
    // gives the slot its own 8-byte cell.
    const indirect_result_slot_neg_off: u32 = spill_base_off + spill_bytes;
    // §9.7 / 7.10-f: outgoing-args region pre-allocated at the
    // BOTTOM of the frame (`[RSP, #0]` upward). For SysV this is
    // pure overflow bytes; for Win64 it includes the 32-byte
    // shadow space when any call exists. When `outgoing_max_bytes`
    // > 0 the per-call `emitShadowAlloc` / `Free` become no-ops
    // (the shadow is already part of the prologue's SUB RSP).
    const outgoing_max_bytes: u32 = computeOutgoingMaxBytes(func, func_sigs, module_types);
    // §9.7/9.7-as / D-054: include r15_save_bytes so local 0 at
    // [RBP-16] (when uses_runtime_ptr=true) lives INSIDE the frame.
    // The prologue does PUSH R15 before MOV RBP,RSP so R15 actually
    // saves at [RBP+0], NOT [RBP-8] — but localDisp's comment +
    // formula assume the slot at [RBP-8] is reserved for R15 (it
    // is, just above the locals). Without this +r15_save_bytes,
    // SysV (no shadow space) under-allocates and the next CALL's
    // pushed return address lands on local 0 at [RBP-16]. Win64's
    // 32-byte shadow_space inflates the frame enough that it hid
    // this bug until OrbStack runs (= Linux x86_64 SysV).
    const frame_unaligned: u32 = outgoing_max_bytes + locals_bytes + spill_bytes + indirect_result_slot_bytes + r15_save_bytes;
    const frame_bytes: u32 = if (uses_runtime_ptr)
        ((frame_unaligned + 7) & ~@as(u32, 15)) + 8
    else
        (frame_unaligned + 15) & ~@as(u32, 15);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Prologue:
    //   PUSH RBP
    //   PUSH R15           (only if uses_runtime_ptr; saves callee-saved R15)
    //   MOV RBP, RSP       (frame pointer captured AFTER any extra push)
    //   MOV R15, RDI       (only if uses_runtime_ptr; capture runtime_ptr arg)
    //   SUB RSP, frame_bytes
    //
    // Local layout (Wasm ZirFunc.locals): local K at
    //   [RBP - 8*(K+1)]               when !uses_runtime_ptr
    //   [RBP - 8 - 8*(K+1)]           when  uses_runtime_ptr (R15 occupies [RBP-8])
    try buf.appendSlice(allocator, inst.encPushR(.rbp).slice());
    if (uses_runtime_ptr) {
        try buf.appendSlice(allocator, inst.encPushR(.r15).slice());
    }
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rbp, .rsp).slice());
    if (uses_runtime_ptr) {
        // MOV R15, <runtime_ptr_arg_gpr> — entry shim's runtime_ptr
        // snapshot. Cc-pivot per ADR-0026: SysV passes *const
        // JitRuntime in RDI for non-MEMORY-class returns; for
        // MEMORY-class returns (ADR-0026 2026-05-18 Convention Swap)
        // SysV §3.2.3 inserts the hidden &buffer ptr into RDI and
        // shifts rt to RSI. Win64 passes in RCX (MEMORY-class Win64
        // deferred). Both encodings are 3 bytes (REX.W+B + opcode +
        // modrm) so the prologue's frame-bytes formula stays Cc-agnostic.
        const rt_src_gpr: abi.Gpr = if (return_is_memory_class) .rsi else abi.current.entry_arg0_gpr;
        try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.runtime_ptr_save_gpr, rt_src_gpr).slice());
    }
    // §9.8a / 8a.2 (ADR-0034) — JIT-execution sentinel: ARM64
    // has the inject landed at d6e29ac; x86_64 inject is deferred
    // (D-055) pending x86_64 prologue.zig helper extract (D-052)
    // because the existing test landscape uses
    // `expectEqualSlices(&full_byte_array, out.bytes)` rather than
    // a body_start_offset()-relative pattern. Inserting 7 sentinel
    // bytes per func without a helper layer would require updating
    // 50+ test sites manually, exceeding chunk-bundle threshold.
    // The encoder helper `inst.encMovMemDisp32Imm32` lands now
    // (reusable for future Phase 8 / 15 work) so the wire-up
    // becomes a 5-line patch once the helper migration completes.
    if (frame_bytes > 0) {
        // §9.7 / 7.10-g: pick imm8 / imm32 form per range.
        // imm8 form is 4 bytes; imm32 is 7 bytes.
        try buf.appendSlice(allocator, rspSub(frame_bytes).slice());
    }
    // ADR-0026 2026-05-18 amend (Convention Swap) / ADR-0069 §Phase 2:
    // MEMORY-class returns — capture the caller-supplied SysV
    // hidden indirect-result-pointer (RDI per §3.2.3) into the
    // frame slot just below the spill region. Emitted AFTER
    // `SUB RSP, frame_bytes` so the slot offset is RBP-relative
    // and stable through the body. RDI's user value (= the
    // shifted runtime_ptr) was already stashed into R15 above;
    // this STR captures RDI itself for the epilogue's MEMORY-class
    // write path. Param shuffle below uses RDX/RCX/R8/R9 +
    // XMM0..XMM7 when self is MEMORY-class (slots 2-5 instead
    // of 1-5). The body's `gprLoadSpilled` staging through
    // R10/R11 is unaffected.
    if (return_is_memory_class) {
        const disp: i32 = -@as(i32, @intCast(indirect_result_slot_neg_off));
        try buf.appendSlice(allocator, inst.encStoreR64MemRBPDisp32(disp, .rdi).slice());
    }

    // §9.7 / 7.8-x86-params: marshal i32 params from arg regs to
    // local slots. Per ADR-0026 Cc-pivot:
    //   SysV: arg_gprs = {RDI, RSI, RDX, RCX, R8, R9}; RDI = runtime
    //         ptr, user int args from RSI (max 5)
    //   Win64: arg_gprs = {RCX, RDX, R8, R9}; RCX = runtime ptr,
    //         user int args from RDX (max 3)
    // The base index into arg_gprs is set so index 0 of the user
    // params lands on the first non-runtime-ptr arg reg.
    {
        var p_idx: u32 = 0;
        // Cc-aware arg-reg index counters. SysV (§3.2.3) tracks
        // int and FP args independently — `int_arg_idx` starts
        // at 1 (skip runtime_ptr in RDI = arg_gprs[0]); FP args
        // use a separate `fp_arg_idx` from XMM0. Win64 (Microsoft
        // ABI) shares slot positions: arg N occupies either
        // arg_gprs[N] OR arg_xmms[N], so `fp_arg_idx` mirrors
        // the int-side slot counter and both advance per arg.
        // Win64 args at slot >= 4 land on the stack at
        // [RBP + 16 + 8*slot] (Microsoft x64 ABI §"Argument
        // Passing"); the prologue copies them via RAX scratch
        // into the local frame slot.
        // ADR-0026 2026-05-18 Convention Swap: when SELF returns
        // MEMORY-class, SysV §3.2.3 places &buffer in RDI (slot 0)
        // and shifts rt to RSI (slot 1); user int args begin at
        // RDX (slot 2). For non-MEMORY-class, slot 0 = RDI = rt;
        // user int args begin at RSI (slot 1).
        var int_arg_idx: usize = if (return_is_memory_class) 2 else 1;
        var fp_arg_idx: usize = if (abi.current_cc == .win64) 1 else 0;
        // §9.7 / 7.10-j: per-overflow NSAA index for SysV. Mirror of
        // the caller-side counter in op_call.marshalCallArgs (chunk
        // 7.10-f). Both classes share the NSAA stream in declaration
        // order — increment per overflowed arg regardless of class.
        var nsaa_idx: u32 = 0;
        while (p_idx < num_params) : (p_idx += 1) {
            // §9.7 / 7.10-g + §9.9-e-2: per-local disp from layout.
            // Auto-helpers pick disp8 / disp32 form per offset range.
            const off: i32 = layout.disps[p_idx];
            const ptype = func.sig.params[p_idx];
            switch (ptype) {
                .i32, .i64, .f32, .f64, .v128, .funcref, .externref => {},
            }
            // Win64 stack-arg fallback for slot >= 4. The shared
            // slot is `int_arg_idx` (== `fp_arg_idx` under Win64).
            // Read from the shadow-space-relative location and
            // write to local slot.
            //   [RBP + 16 + r15_save_off + 8*slot]
            // where +16 = saved RBP (8) + return addr (8); the
            // +r15_save_off (8 bytes) covers our PUSH R15 prologue
            // shifting RBP one cell deeper than the std ABI shape.
            // Without it, [RBP + 48] (the standard "first overflow
            // at slot 4") reads the saved-RBP slot instead of
            // caller-written arg bytes when uses_runtime_ptr fires.
            if (abi.current_cc == .win64 and int_arg_idx >= abi.current.arg_gprs.len) {
                const r15_save_off: i32 = if (uses_runtime_ptr) 8 else 0;
                const stack_disp: i32 = 16 + r15_save_off + @as(i32, @intCast(int_arg_idx * 8));
                switch (ptype) {
                    .i32 => {
                        try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, rbpStoreR32(off, .rax).slice());
                    },
                    // D-093 (d-33): reftype shares i64 8-byte gpr slot.
                    .i64, .f32, .f64, .funcref, .externref => {
                        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, rbpStoreR64(off, .rax).slice());
                    },
                    .v128 => {
                        // §9.9 / 9.9-i-1 Win64 v128 hidden-pointer
                        // marshal — stack-overflow slot. Per Microsoft
                        // x64 ABI §"Parameter passing" the caller wrote
                        // an 8-byte pointer at the int-arg stack slot;
                        // the pointed-to memory holds the 16-byte v128
                        // value (16-byte aligned per ABI). Load pointer
                        // → RAX, then MOVUPS xmm_tmp ← [RAX] and store
                        // to local slot.
                        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, inst.encMovupsXmmMemBaseDisp32(false, .xmm0, .rax, 0).slice());
                        try buf.appendSlice(allocator, rbpStoreXmmV128(off, .xmm0).slice());
                    },
                }
                int_arg_idx += 1;
                fp_arg_idx += 1;
                continue;
            }
            // SysV per-overflow stack-arg read (§9.7 / 7.10-j;
            // mirror of op_call.marshalCallArgs's NSAA write path).
            // `[RBP + 16 + r15_save_off + 8 * nsaa_idx]` matches the
            // caller's `[RSP + 8 * nsaa_idx]` write after RET addr +
            // saved RBP (+ saved R15) push. Win64 already handled
            // above; this branch is structurally SysV-only.
            const sysv_int_overflow = (ptype == .i32 or ptype == .i64 or ptype == .funcref or ptype == .externref) and int_arg_idx >= abi.current.arg_gprs.len;
            const sysv_fp_overflow = (ptype == .f32 or ptype == .f64) and fp_arg_idx >= abi.current.arg_xmms.len;
            if (sysv_int_overflow or sysv_fp_overflow) {
                const r15_save_off: i32 = if (uses_runtime_ptr) 8 else 0;
                const stack_disp: i32 = 16 + r15_save_off + @as(i32, @intCast(nsaa_idx * 8));
                switch (ptype) {
                    .i32 => {
                        try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, rbpStoreR32(off, .rax).slice());
                    },
                    // D-093 (d-33): reftype shares i64 8-byte gpr slot.
                    .i64, .f32, .f64, .funcref, .externref => {
                        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rbp, stack_disp).slice());
                        try buf.appendSlice(allocator, rbpStoreR64(off, .rax).slice());
                    },
                    .v128 => unreachable, // Win64 v128 hidden-ptr handled above
                }
                nsaa_idx += 1;
                if (sysv_int_overflow) int_arg_idx += 1 else fp_arg_idx += 1;
                continue;
            }
            switch (ptype) {
                .i32 => {
                    try buf.appendSlice(allocator, rbpStoreR32(off, abi.current.arg_gprs[int_arg_idx]).slice());
                    int_arg_idx += 1;
                    if (abi.current_cc == .win64) fp_arg_idx += 1;
                },
                // D-093 (d-33): reftype shares i64 8-byte gpr slot.
                .i64, .funcref, .externref => {
                    try buf.appendSlice(allocator, rbpStoreR64(off, abi.current.arg_gprs[int_arg_idx]).slice());
                    int_arg_idx += 1;
                    if (abi.current_cc == .win64) fp_arg_idx += 1;
                },
                .f32 => {
                    try buf.appendSlice(allocator, rbpStoreXmmF32(off, abi.current.arg_xmms[fp_arg_idx]).slice());
                    fp_arg_idx += 1;
                    if (abi.current_cc == .win64) int_arg_idx += 1;
                },
                .f64 => {
                    try buf.appendSlice(allocator, rbpStoreXmmF64(off, abi.current.arg_xmms[fp_arg_idx]).slice());
                    fp_arg_idx += 1;
                    if (abi.current_cc == .win64) int_arg_idx += 1;
                },
                .v128 => {
                    if (abi.current_cc == .win64) {
                        // §9.9 / 9.9-i-1 Win64 v128 hidden-pointer
                        // marshal — register slot. Per Microsoft x64
                        // ABI §"Parameter passing" the caller wrote
                        // the v128 into a 16-byte aligned scratch buf
                        // in its outgoing-args region and passed the
                        // address in the int-arg-reg slot (RDX/R8/R9).
                        // Load via MOVUPS xmm_tmp ← [ptr_reg] and
                        // store to local slot.
                        const ptr_reg = abi.current.arg_gprs[int_arg_idx];
                        try buf.appendSlice(allocator, inst.encMovupsXmmMemBaseDisp32(false, .xmm0, ptr_reg, 0).slice());
                        try buf.appendSlice(allocator, rbpStoreXmmV128(off, .xmm0).slice());
                        int_arg_idx += 1;
                        fp_arg_idx += 1;
                    } else {
                        // §9.9 / 9.9-e-2 + §9.9 / 9.9-i-1 SysV co-discharge:
                        // SysV v128 in XMM0..XMM7 direct (AMD64 ABI §3.2.3
                        // SSE class); stack-overflow at `fp_arg_idx >= 8`
                        // reads 16 consecutive aligned bytes from the
                        // NSAA stream (SSE class → 2 eightbytes on stack).
                        if (fp_arg_idx >= abi.current.arg_xmms.len) {
                            // SysV NSAA v128 alignment: each v128 takes
                            // 2 eightbyte slots, 16-byte aligned. Round
                            // nsaa_idx up to even before consuming.
                            if ((nsaa_idx & 1) != 0) nsaa_idx += 1;
                            const r15_save_off: i32 = if (uses_runtime_ptr) 8 else 0;
                            const stack_disp: i32 = 16 + r15_save_off + @as(i32, @intCast(nsaa_idx * 8));
                            try buf.appendSlice(allocator, inst.encMovupsXmmMemBaseDisp32(false, .xmm0, .rbp, stack_disp).slice());
                            try buf.appendSlice(allocator, rbpStoreXmmV128(off, .xmm0).slice());
                            nsaa_idx += 2;
                            fp_arg_idx += 1;
                        } else {
                            try buf.appendSlice(allocator, rbpStoreXmmV128(off, abi.current.arg_xmms[fp_arg_idx]).slice());
                            fp_arg_idx += 1;
                        }
                    }
                },
            }
        }
    }

    // Wasm spec §4.5.3.1 — locals beyond params are initialised to
    // zero on entry. Mirror of arm64/emit.zig:263-267 (STR XZR per
    // slot). x86_64: `XOR EAX, EAX` zeros RAX (32-bit XOR zero-
    // extends to 64); then `MOV [RBP+disp], RAX` writes 8 bytes per
    // local slot. RAX is the return reg, overwritten at function-
    // end, so its temporary use here is invariant-clean.
    if (num_locals > 0) {
        try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice());
        var loc_idx: u32 = num_params;
        while (loc_idx < total_locals) : (loc_idx += 1) {
            const loc_disp = layout.disps[loc_idx];
            const ty = func.localValType(loc_idx);
            if (ty == .v128) {
                // §9.9-e-2: zero-init v128 declared local — write
                // 16 bytes via two STR XZR (RAX, already zeroed
                // above). MOVUPS-with-zero would need a const
                // pool constant; the two MOVs are bench-cost
                // identical and avoid a pool insertion.
                try buf.appendSlice(allocator, rbpStoreR64(loc_disp, .rax).slice());
                try buf.appendSlice(allocator, rbpStoreR64(loc_disp + 8, .rax).slice());
            } else {
                try buf.appendSlice(allocator, rbpStoreR64(loc_disp, .rax).slice());
            }
        }
    }

    // ============================================================
    // Body: walk instrs, dispatch per op.
    //
    // For 7.7 skeleton: track a "result vreg" cursor that records
    // which vreg holds the latest pushed value. `end` reads that
    // vreg, ensures it ends up in EAX (the SysV x86_64 i32 return
    // register), and then runs the epilogue.
    // ============================================================
    var pushed_vregs: std.ArrayList(u32) = .empty;
    defer pushed_vregs.deinit(allocator);
    var next_vreg: u32 = 0;

    // Control-stack: Wasm structured-control labels (block /
    // loop). Forward fixups (br to block) land in `pending`;
    // backward jumps (br to loop) resolve immediately at the
    // `br` site since the target was captured on push.
    var labels: std.ArrayList(Label) = .empty;
    defer {
        for (labels.items) |*l| l.pending.deinit(allocator);
        labels.deinit(allocator);
    }

    // Bounds-check trap fixups: each memory op emits a
    // JAE rel32 placeholder that branches to the trap stub
    // emitted at function-final `end`. Each Fixup records the
    // Jcc instruction's byte_offset; the function-level end
    // patches them all to the trap stub address.
    var bounds_fixups: std.ArrayList(u32) = .empty;
    defer bounds_fixups.deinit(allocator);
    // §9.7 / 7.8-x86-unreachable: distinct list because JMP rel32
    // placeholders are 5 bytes (0xE9 + 4-byte disp32) while the
    // bounds-check Jcc rel32 placeholders are 6 bytes (0x0F 0x8x +
    // 4-byte disp32). Both target the same trap stub but the
    // disp formula differs by 1 byte. Patched at function-end
    // trap-stub block alongside bounds_fixups.
    var unreach_fixups: std.ArrayList(u32) = .empty;
    defer unreach_fixups.deinit(allocator);

    // Direct-call placeholders awaiting linker patch.
    var call_fixups: std.ArrayList(CallFixup) = .empty;
    errdefer call_fixups.deinit(allocator);

    // §9.7/9.7-al — SIMD const-pool fixups (per ADR-0042). Each
    // entry records a MOVUPS-RIP-rel placeholder's disp32 byte
    // offset and post-instruction byte plus the `func.simd_consts`
    // index. The post-emit pass appends the per-function const
    // pool past the trap stub (16-byte aligned) and patches each
    // disp32 to the PC-relative offset of the target const.
    var simd_const_fixups: std.ArrayList(types.SimdConstFixup) = .empty;
    defer simd_const_fixups.deinit(allocator);

    // §9.7/9.7-am — emit-time-derived const-pool entries (per-op
    // shared 16-byte constants like INT32_MAX_f64-broadcast for
    // trunc_sat). These extend `func.simd_consts` (which carries
    // only per-instance `v128.const` / shuffle-mask literals from
    // the lower pass). At post-emit pool placement the two lists
    // are concatenated; const_idx in fixups maps uniformly into
    // the concat'd pool.
    var extra_consts: std.ArrayList([16]u8) = .empty;
    defer extra_consts.deinit(allocator);

    // §9.7 / 7.8-x86-mem-grow-size: dead_code tracking. After
    // `unreachable` / `return` mid-function, subsequent ops are
    // unreachable per Wasm spec §3.3 polymorphic-stack rules; the
    // validator already accepts them but this emitter would
    // attempt to lower them and trip UnsupportedOp on rare ops
    // like memory.grow inside dead code (e.g. unreachable.wast's
    // `as-memory.grow-size`). Mirror of arm64 7.5-emit-deadcode.
    var dead_code: bool = false;
    for (func.instrs.items) |ins| {
        // `end` / `else` always exit the dead region — emit's own
        // bookkeeping (label-stack pop / arm switch) must run.
        // Mirror of arm64/emit.zig:381-414.
        if (ins.op == .end or ins.op == .@"else") {
            dead_code = false;
        }
        if (dead_code) {
            // Maintain label-stack consistency for structural ops
            // inside the dead region: push placeholder labels for
            // block / loop / if so the matching end / else find a
            // frame. Without this, unreachable.wast's `as-if-cond`
            // (where `(unreachable)` is the if-cond) surfaces
            // `emitElse without if_then` once the inner else fires.
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
            .@"i32.const" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const dst = try gpr.gprDefSpilled(alloc, vreg, 0);
                try buf.appendSlice(allocator, inst.encMovImm32W(dst, ins.payload).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i64.const" => {
                // Wasm spec §4.4.1.1 (i64.const) — push a 64-bit
                // immediate. Encoded as MOVABS r64, imm64
                // (REX.W + 0xB8+rd + 8-byte imm = 10 bytes).
                // Mirrors arm64 emitI64Const which uses 4×16-bit
                // MOVZ/MOVK chunks; x86_64's MOVABS-form is a
                // single instruction, simpler to emit.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const dst = try gpr.gprDefSpilled(alloc, vreg, 0);
                const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
                try buf.appendSlice(allocator, inst.encMovImm64Q(dst, value).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i32.add",
            .@"i32.sub",
            .@"i32.mul",
            .@"i32.and",
            .@"i32.or",
            .@"i32.xor",
            => try op_alu_int.emitI32Binary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
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
            => try op_alu_int.emitI32Compare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.eqz" => try op_alu_int.emitI32Eqz(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32.shl",
            .@"i32.shr_s",
            .@"i32.shr_u",
            .@"i32.rotl",
            .@"i32.rotr",
            => try op_alu_int.emitI32Shift(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.clz",
            .@"i32.ctz",
            .@"i32.popcnt",
            => try op_alu_int.emitI32Bitcount(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.add",
            .@"i64.sub",
            .@"i64.mul",
            .@"i64.and",
            .@"i64.or",
            .@"i64.xor",
            => try op_alu_int.emitI64Binary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
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
            => try op_alu_int.emitI64Compare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.eqz" => try op_alu_int.emitI64Eqz(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.9 / 9.9-m-1a (per ADR-0056): Wasm 2.0 reference-types
            // partial — null + is_null. ref.func deferred to m-1b
            // (needs JitRuntime extension). ref.null = push 0
            // (XOR r,r zeroes the 64-bit reg via implicit upper-32
            // clear on 32-bit ops). ref.is_null = reuse i64.eqz.
            .@"ref.null" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const dst_r = try gpr.gprDefSpilled(alloc, vreg, 0);
                try buf.appendSlice(allocator, inst.encXorRR(.d, dst_r, dst_r).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"ref.is_null" => try op_alu_int.emitI64Eqz(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.9 / 9.9-m-1b: ref.func idx — load
            // func_entities_ptr from JitRuntime, add idx * size.
            // Recipe:
            //   MOV r_dst, [r15 + func_entities_ptr_off]
            //   ADD r_dst, imm32 (= idx * sizeOf(FuncEntity))
            .@"ref.func" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const dst_r = try gpr.gprDefSpilled(alloc, vreg, 0);
                try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(dst_r, abi.runtime_ptr_save_gpr, jit_abi.func_entities_ptr_off).slice());
                const byte_off: u64 = @as(u64, ins.payload) * jit_abi.func_entity_size;
                if (byte_off != 0) {
                    // ADD r64, imm32 (7 bytes). For byte_off > i32 max
                    // (extremely unlikely with FuncEntity_size=16 →
                    // 134M+ entries needed), would need MOV scratch +
                    // ADD — not handled (UnsupportedOp would surface
                    // via validator's funcidx bounds anyway).
                    if (byte_off > 0x7FFFFFFF) return Error.UnsupportedOp;
                    try buf.appendSlice(allocator, inst.encAddR64Imm32(dst_r, @intCast(byte_off)).slice());
                }
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, vreg, 0);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i64.shl",
            .@"i64.shr_s",
            .@"i64.shr_u",
            .@"i64.rotl",
            .@"i64.rotr",
            => try op_alu_int.emitI64Shift(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.clz",
            .@"i64.ctz",
            .@"i64.popcnt",
            => try op_alu_int.emitI64Bitcount(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.wrap_i64",
            .@"i64.extend_i32_u",
            .@"i64.extend_i32_s",
            => try op_alu_int.emitConvertWidth(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            // §9.7 / 7.9 chunk c: Wasm 2.0 sign-extension ops.
            .@"i32.extend8_s",
            .@"i32.extend16_s",
            .@"i64.extend8_s",
            .@"i64.extend16_s",
            .@"i64.extend32_s",
            => try op_alu_int.emitSignExtend(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            // §9.7 / 7.9 chunk c: integer divide / remainder.
            .@"i32.div_s",
            .@"i32.div_u",
            .@"i32.rem_s",
            .@"i32.rem_u",
            => try op_alu_int.emitI32DivRem(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.op),
            .@"i64.div_s",
            .@"i64.div_u",
            .@"i64.rem_s",
            .@"i64.rem_u",
            => try op_alu_int.emitI64DivRem(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.op),
            .call => try op_call.emitCall(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &call_fixups, spill_base_off, outgoing_max_bytes, func_sigs, num_imports, ins.payload),
            .call_indirect => try op_call.emitCallIndirect(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, outgoing_max_bytes, module_types, ins.payload, ins.extra),
            .@"f32.const",
            .@"f64.const",
            => try op_alu_float.emitFpConst(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op, ins.payload, ins.extra),
            .@"f32.add",
            .@"f32.sub",
            .@"f32.mul",
            .@"f32.div",
            .@"f64.add",
            .@"f64.sub",
            .@"f64.mul",
            .@"f64.div",
            => try op_alu_float.emitFpBinary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
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
            => try op_alu_float.emitFpCompare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
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
            => try op_alu_float.emitFpUnary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f32.copysign",
            .@"f64.copysign",
            => try op_alu_float.emitFpCopysign(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f32.min",
            .@"f32.max",
            .@"f64.min",
            .@"f64.max",
            => try op_alu_float.emitFpMinMax(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f64.promote_f32",
            .@"f32.demote_f64",
            .@"i32.reinterpret_f32",
            .@"i64.reinterpret_f64",
            .@"f32.reinterpret_i32",
            .@"f64.reinterpret_i64",
            .@"f32.convert_i32_s",
            .@"f32.convert_i64_s",
            .@"f64.convert_i32_s",
            .@"f64.convert_i64_s",
            .@"f32.convert_i32_u",
            .@"f64.convert_i32_u",
            => try op_convert.emitFpConvertSimple(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"f32.convert_i64_u",
            .@"f64.convert_i64_u",
            => try op_convert.emitFpConvertI64Unsigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.trunc_sat_f32_s",
            .@"i32.trunc_sat_f64_s",
            .@"i64.trunc_sat_f32_s",
            .@"i64.trunc_sat_f64_s",
            => try op_convert.emitFpTruncSatSigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.trunc_sat_f32_u",
            .@"i32.trunc_sat_f64_u",
            => try op_convert.emitFpTruncSatU32(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i64.trunc_sat_f32_u",
            .@"i64.trunc_sat_f64_u",
            => try op_convert.emitFpTruncSatU64(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.op),
            .@"i32.trunc_f32_s",
            .@"i32.trunc_f64_s",
            .@"i64.trunc_f32_s",
            .@"i64.trunc_f64_s",
            => try op_convert.emitFpTruncTrapSigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.op),
            .@"i32.trunc_f32_u",
            .@"i32.trunc_f64_u",
            .@"i64.trunc_f32_u",
            .@"i64.trunc_f64_u",
            => try op_convert.emitFpTruncTrapUnsigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.op),
            .@"local.get" => try emitLocalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, func, num_params, total_locals, layout.disps, ins.payload),
            .@"local.set" => try emitLocalSet(allocator, &buf, alloc, &pushed_vregs, spill_base_off, func, num_params, total_locals, layout.disps, ins.payload),
            .@"local.tee" => try emitLocalTee(allocator, &buf, alloc, &pushed_vregs, spill_base_off, func, num_params, total_locals, layout.disps, ins.payload),
            .@"i32.load",
            .@"i32.load8_s",
            .@"i32.load8_u",
            .@"i32.load16_s",
            .@"i32.load16_u",
            .@"i32.store",
            .@"i32.store8",
            .@"i32.store16",
            .@"i64.load",
            .@"i64.load8_s",
            .@"i64.load8_u",
            .@"i64.load16_s",
            .@"i64.load16_u",
            .@"i64.load32_s",
            .@"i64.load32_u",
            .@"i64.store",
            .@"i64.store8",
            .@"i64.store16",
            .@"i64.store32",
            .@"f32.load",
            .@"f64.load",
            .@"f32.store",
            .@"f64.store",
            => try op_memory.emitMemOp(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.op, ins.payload, func.func_idx),
            .@"memory.fill" => try op_memory.emitMemoryFill(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, func.func_idx),
            // §9.9 / 9.9-m-3a: data.drop / elem.drop — write 1 to
            // the dropped-flag byte. No operands; no result. The
            // validator already bounds-checks idx.
            //   MOV r10, [r15 + ptr_off]      ; load base
            //   MOV BYTE [r10 + idx], 1
            .@"data.drop" => {
                try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r10, abi.runtime_ptr_save_gpr, jit_abi.data_dropped_ptr_off).slice());
                try buf.appendSlice(allocator, inst.encStoreImm8MemBaseDisp32(.r10, @intCast(ins.payload), 1).slice());
            },
            .@"elem.drop" => {
                try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.r10, abi.runtime_ptr_save_gpr, jit_abi.elem_dropped_ptr_off).slice());
                try buf.appendSlice(allocator, inst.encStoreImm8MemBaseDisp32(.r10, @intCast(ins.payload), 1).slice());
            },
            .@"memory.copy" => try op_memory.emitMemoryCopy(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, func.func_idx),
            .@"memory.init" => try op_memory.emitMemoryInit(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, func.func_idx, ins.payload),
            .@"global.get" => try op_globals.emitGlobalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload, globals_offsets, globals_valtypes),
            .@"global.set" => try op_globals.emitGlobalSet(allocator, &buf, alloc, &pushed_vregs, spill_base_off, ins.payload, globals_offsets, globals_valtypes),
            // §9.9 / 9.9-m-2a (per ADR-0058): table.get / table.set
            // / table.size — bounds-checked load/store against the
            // per-table TableSlice descriptor in JitRuntime.
            .@"table.get" => try op_table.emitTableGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, func.func_idx, ins.payload),
            .@"table.set" => try op_table.emitTableSet(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, func.func_idx, ins.payload),
            .@"table.size" => try op_table.emitTableSize(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            .@"table.grow" => try op_table.emitTableGrow(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, outgoing_max_bytes, ins.payload),
            // §9.9 / 9.9-m-2b (per ADR-0058): table.fill — inline
            // loop. Mirror of arm64 path.
            .@"table.fill" => try op_table.emitTableFill(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, func.func_idx, ins.payload),
            // §9.9 / 9.9-m-2c (per ADR-0058): table.copy — element-
            // typed memmove with same-table backward arm.
            .@"table.copy" => try op_table.emitTableCopy(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, func.func_idx, ins.payload, ins.extra),
            // §9.9 / 9.9-m-2c-init (per ADR-0058 amendment):
            // table.init — copy elem segment to table; honours
            // elem_dropped flag.
            .@"table.init" => try op_table.emitTableInit(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, func.func_idx, ins.payload, ins.extra),
            // §9.7 / 9.7-a + 9.7-b: SIMD-128 packed integer add/sub
            // family (8 ops). Wires the FP-class regalloc +
            // shape-tag pipeline on x86_64 per ADR-0041; spilled
            // v128 vregs surface UnsupportedOp until 9.7-c MOVDQU
            // helpers land.
            .@"i8x16.add" => try op_simd_int_arith.emitI8x16Add(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.sub" => try op_simd_int_arith.emitI8x16Sub(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.add" => try op_simd_int_arith.emitI16x8Add(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.sub" => try op_simd_int_arith.emitI16x8Sub(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.add" => try op_simd_int_arith.emitI32x4Add(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.sub" => try op_simd_int_arith.emitI32x4Sub(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.add" => try op_simd_int_arith.emitI64x2Add(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.sub" => try op_simd_int_arith.emitI64x2Sub(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-c: native multiply. PMULLW (SSE2) for
            // i16x8.mul; PMULLD (SSE4.1) for i32x4.mul.
            .@"i16x8.mul" => try op_simd_int_arith.emitI16x8Mul(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.mul" => try op_simd_int_arith.emitI32x4Mul(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-d: i64x2.mul synthesis (no native SSE4.1 form;
            // PMULUDQ + shift/add idiom uses XMM14/15 as scratch).
            .@"i64x2.mul" => try op_simd_int_arith.emitI64x2Mul(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-e: lane access foundation (i32x4 only — other
            // shapes follow in 9.7-f). Splat broadcasts a scalar i32
            // across 4 lanes; extract_lane pulls one lane back to
            // scalar via PEXTRD (SSE4.1).
            .@"i32x4.splat" => try op_simd_int_cmp_lane.emitI32x4Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.extract_lane" => try op_simd_int_cmp_lane.emitI32x4ExtractLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            // §9.7 / 9.7-aw: i64x2.extract_lane via PEXTRQ (SSE4.1
            // REX.W=1 variant of PEXTRD). Mirror of i32x4.extract_
            // lane handler with u1 lane (i64x2 has 2 lanes).
            .@"i64x2.extract_lane" => try op_simd_int_cmp_lane.emitI64x2ExtractLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            // §9.7 / 9.7-f: replace_lane for the wide-int v128 shapes.
            // PINSRD (32-bit) / PINSRQ (64-bit, REX.W mandatory) plus a
            // MOVAPS preamble when dst doesn't alias the input vec.
            .@"i32x4.replace_lane" => try op_simd_int_cmp_lane.emitI32x4ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            .@"i64x2.replace_lane" => try op_simd_int_cmp_lane.emitI64x2ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            // §9.7 / 9.7-g: narrow-int lane access (i8x16 / i16x8).
            // PEXTRB / PEXTRW + optional MOVSX for signed extract.
            // PINSRB / PINSRW + MOVAPS preamble for replace.
            .@"i8x16.extract_lane_s" => try op_simd_int_cmp_lane.emitI8x16ExtractLaneS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            .@"i8x16.extract_lane_u" => try op_simd_int_cmp_lane.emitI8x16ExtractLaneU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            .@"i16x8.extract_lane_s" => try op_simd_int_cmp_lane.emitI16x8ExtractLaneS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            .@"i16x8.extract_lane_u" => try op_simd_int_cmp_lane.emitI16x8ExtractLaneU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            .@"i8x16.replace_lane" => try op_simd_int_cmp_lane.emitI8x16ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            .@"i16x8.replace_lane" => try op_simd_int_cmp_lane.emitI16x8ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, ins.payload),
            // §9.7 / 9.7-h: integer splat siblings (i32x4 already
            // landed in 9.7-e). i8x16 via PSHUFB-broadcast; i16x8
            // via PSHUFLW + PSHUFD; i64x2 via PUNPCKLQDQ.
            .@"i8x16.splat" => try op_simd_int_cmp_lane.emitI8x16Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.splat" => try op_simd_int_cmp_lane.emitI16x8Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.splat" => try op_simd_int_cmp_lane.emitI64x2Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-i: f32x4 lane access trio. XMM-source
            // semantics — splat / extract reuse encPshufd; replace
            // uses the new INSERTPS encoder (SSE4.1 3A 21 /r ib).
            .@"f32x4.splat" => try op_simd_float.emitF32x4Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.extract_lane" => try op_simd_float.emitF32x4ExtractLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.payload),
            .@"f32x4.replace_lane" => try op_simd_float.emitF32x4ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.payload),
            // §9.7 / 9.7-j: f64x2 lane access trio. splat + extract_lane
            // reuse encPshufd (imm 0x44 / 0xEE for low/high qword).
            // replace_lane uses MOVAPS preamble + MOVSD (lane=0) /
            // MOVLHPS (lane=1).
            .@"f64x2.splat" => try op_simd_float.emitF64x2Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.extract_lane" => try op_simd_float.emitF64x2ExtractLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.payload),
            .@"f64x2.replace_lane" => try op_simd_float.emitF64x2ReplaceLane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.payload),
            // §9.7 / 9.7-k: int compare eq/ne family. PCMPEQ B/W/D
            // (SSE2) + PCMPEQQ (SSE4.1); ne paths apply NOT via
            // PXOR with an all-ones mask (PCMPEQB scratch, scratch).
            .@"i8x16.eq" => try op_simd_int_cmp_lane.emitI8x16Eq(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.eq" => try op_simd_int_cmp_lane.emitI16x8Eq(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.eq" => try op_simd_int_cmp_lane.emitI32x4Eq(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.eq" => try op_simd_int_cmp_lane.emitI64x2Eq(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.ne" => try op_simd_int_cmp_lane.emitI8x16Ne(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.ne" => try op_simd_int_cmp_lane.emitI16x8Ne(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.ne" => try op_simd_int_cmp_lane.emitI32x4Ne(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.ne" => try op_simd_int_cmp_lane.emitI64x2Ne(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-l: signed lt/gt/le/ge for 8/16/32-bit shapes
            // (12 ops). PCMPGT_<shape> direct for gt; operand swap for
            // lt; PXOR-with-all-ones NOT for le/ge. i64x2 signed
            // compares defer to 9.7-m (PCMPGTQ is SSE4.2 — needs ADR).
            .@"i8x16.gt_s" => try op_simd_int_cmp_lane.emitI8x16GtS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i8x16.lt_s" => try op_simd_int_cmp_lane.emitI8x16LtS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i8x16.le_s" => try op_simd_int_cmp_lane.emitI8x16LeS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i8x16.ge_s" => try op_simd_int_cmp_lane.emitI8x16GeS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.gt_s" => try op_simd_int_cmp_lane.emitI16x8GtS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.lt_s" => try op_simd_int_cmp_lane.emitI16x8LtS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.le_s" => try op_simd_int_cmp_lane.emitI16x8LeS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.ge_s" => try op_simd_int_cmp_lane.emitI16x8GeS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.gt_s" => try op_simd_int_cmp_lane.emitI32x4GtS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.lt_s" => try op_simd_int_cmp_lane.emitI32x4LtS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.le_s" => try op_simd_int_cmp_lane.emitI32x4LeS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.ge_s" => try op_simd_int_cmp_lane.emitI32x4GeS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-m: i64x2 signed compare lt_s/gt_s/le_s/ge_s
            // (4 ops). PCMPGTQ (SSE4.2 0F 38 37) threaded through
            // 9.7-l's emitV128IntCmpSigned helper. Per ADR-0041 §5
            // amend at 9.7-m — x86_64 baseline raised SSE4.1 →
            // SSE4.2 (Steam Apr 2026 98.18% adoption).
            .@"i64x2.gt_s" => try op_simd_int_cmp_lane.emitI64x2GtS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.lt_s" => try op_simd_int_cmp_lane.emitI64x2LtS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.le_s" => try op_simd_int_cmp_lane.emitI64x2LeS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.ge_s" => try op_simd_int_cmp_lane.emitI64x2GeS(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-n: unsigned compares lt_u/gt_u/le_u/ge_u for
            // 8/16/32-bit shapes (12 ops). PMINU/PMAXU + PCMPEQ
            // (cranelift `lower.isle:2016-2080`): gt/lt = NOT eq(min/max,
            // rhs); ge/le = eq(lhs, max/min). PMAXUB/PMINUB SSE2;
            // PMAXU{W,D} / PMINU{W,D} SSE4.1. i64x2 unsigned not in
            // Wasm SIMD spec.
            .@"i8x16.gt_u" => try op_simd_int_cmp_lane.emitI8x16GtU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i8x16.lt_u" => try op_simd_int_cmp_lane.emitI8x16LtU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i8x16.le_u" => try op_simd_int_cmp_lane.emitI8x16LeU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i8x16.ge_u" => try op_simd_int_cmp_lane.emitI8x16GeU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.gt_u" => try op_simd_int_cmp_lane.emitI16x8GtU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.lt_u" => try op_simd_int_cmp_lane.emitI16x8LtU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.le_u" => try op_simd_int_cmp_lane.emitI16x8LeU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.ge_u" => try op_simd_int_cmp_lane.emitI16x8GeU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.gt_u" => try op_simd_int_cmp_lane.emitI32x4GtU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.lt_u" => try op_simd_int_cmp_lane.emitI32x4LtU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.le_u" => try op_simd_int_cmp_lane.emitI32x4LeU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.ge_u" => try op_simd_int_cmp_lane.emitI32x4GeU(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-o: FP compare eq/ne/lt/gt/le/ge for f32x4 +
            // f64x2 (12 ops). CMPPS (SSE 0F C2 /r ib) + CMPPD (SSE2
            // 66 0F C2 /r ib) with imm8 predicate per Intel SDM Vol
            // 2A "CMPPS" Table 3-7. eq/ne/lt/le direct with imm
            // 0/4/1/2; gt/ge swap operands + imm 1/2 per cranelift
            // `lower.isle:2169-2172`.
            .@"f32x4.eq" => try op_simd_float.emitF32x4Eq(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.ne" => try op_simd_float.emitF32x4Ne(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.lt" => try op_simd_float.emitF32x4Lt(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.gt" => try op_simd_float.emitF32x4Gt(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.le" => try op_simd_float.emitF32x4Le(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.ge" => try op_simd_float.emitF32x4Ge(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.eq" => try op_simd_float.emitF64x2Eq(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.ne" => try op_simd_float.emitF64x2Ne(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.lt" => try op_simd_float.emitF64x2Lt(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.gt" => try op_simd_float.emitF64x2Gt(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.le" => try op_simd_float.emitF64x2Le(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.ge" => try op_simd_float.emitF64x2Ge(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-p: FP arithmetic add/sub/mul/div + sqrt
            // for f32x4 + f64x2 (10 ops). ADDPS/SUBPS/MULPS/DIVPS/
            // SQRTPS (SSE 0F 58/5C/59/5E/51) + PD variants (SSE2 66
            // prefix). Binary ops reuse 9.7-b's emitV128IntBinop;
            // sqrt uses new emitV128FpUnop. min/max defer to 9.7-q
            // (NaN-correction synthesis ~7 instr per cranelift
            // `lower.isle` F32X4/F64X2 fmin/fmax).
            .@"f32x4.add" => try op_simd_float.emitF32x4Add(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.sub" => try op_simd_float.emitF32x4Sub(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.mul" => try op_simd_float.emitF32x4Mul(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.div" => try op_simd_float.emitF32x4Div(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f32x4.sqrt" => try op_simd_float.emitF32x4Sqrt(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.add" => try op_simd_float.emitF64x2Add(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.sub" => try op_simd_float.emitF64x2Sub(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.mul" => try op_simd_float.emitF64x2Mul(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.div" => try op_simd_float.emitF64x2Div(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"f64x2.sqrt" => try op_simd_float.emitF64x2Sqrt(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-q: f32x4 + f64x2 min/max NaN-correction
            // synthesis (4 ops). MINPS/MAXPS / MINPD/MAXPD wrapped
            // with cranelift's 10-instr (fmin) / 13-instr (fmax)
            // recipe per `lower.isle:2783-2939` — produces canonical
            // IEEE-754-2019 minimum/maximum (NaN-propagating, signed-
            // zero-aware) where naive MIN/MAX would return src2 on
            // unordered inputs (off-spec). XMM14 + XMM15 used as
            // scratch.
            .@"f32x4.min" => try op_simd_float.emitF32x4Min(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.max" => try op_simd_float.emitF32x4Max(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.min" => try op_simd_float.emitF64x2Min(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.max" => try op_simd_float.emitF64x2Max(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-r: v128 bitwise ops + v128.any_true (7 ops).
            // PAND/POR/PXOR/PANDN (SSE2) for and/or/xor/andnot;
            // 3-instr synthesis for not (PCMPEQB ones,ones + PXOR);
            // 5-instr PAND/PANDN/POR chain for bitselect; PTEST +
            // SETNE + MOVZX for any_true (SSE4.1 PTEST).
            .@"v128.not" => try op_simd.emitV128Not(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"v128.and" => try op_simd.emitV128And(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"v128.or" => try op_simd.emitV128Or(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"v128.xor" => try op_simd.emitV128Xor(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"v128.andnot" => try op_simd.emitV128Andnot(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"v128.bitselect" => try op_simd.emitV128Bitselect(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"v128.any_true" => try op_simd.emitV128AnyTrue(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-s: per-shape all_true + bitmask reductions
            // (8 ops). all_true via SSE4.1 PXOR + PCMPEQ_<lane> +
            // PTEST + SETZ + MOVZX (5 instr per cranelift
            // `lower.isle:4936`). bitmask via PMOVMSKB / MOVMSKPS /
            // MOVMSKPD direct for i8/i32/i64; i16x8 needs PACKSSWB
            // + PMOVMSKB + SHR 8 (cranelift `lower.isle:4977`).
            .@"i8x16.all_true" => try op_simd_int_cmp_lane.emitI8x16AllTrue(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.all_true" => try op_simd_int_cmp_lane.emitI16x8AllTrue(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.all_true" => try op_simd_int_cmp_lane.emitI32x4AllTrue(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.all_true" => try op_simd_int_cmp_lane.emitI64x2AllTrue(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.bitmask" => try op_simd_int_cmp_lane.emitI8x16Bitmask(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.bitmask" => try op_simd_int_cmp_lane.emitI16x8Bitmask(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.bitmask" => try op_simd_int_cmp_lane.emitI32x4Bitmask(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.bitmask" => try op_simd_int_cmp_lane.emitI64x2Bitmask(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-t: i*x* packed shifts shl/shr_s/shr_u for
            // i16x8 + i32x4 + i64x2 (8 ops; i8x16 + i64x2.shr_s
            // synthesis defer to 9.7-u). 5-instr emit per shift:
            // AND mask (lane_width - 1), MOVD count→xmm, MOVAPS
            // dst,vec (skip-elide), <shift> dst,scratch.
            .@"i16x8.shl" => try op_simd_int_arith.emitI16x8Shl(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.shr_s" => try op_simd_int_arith.emitI16x8ShrS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.shr_u" => try op_simd_int_arith.emitI16x8ShrU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.shl" => try op_simd_int_arith.emitI32x4Shl(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.shr_s" => try op_simd_int_arith.emitI32x4ShrS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.shr_u" => try op_simd_int_arith.emitI32x4ShrU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.shl" => try op_simd_int_arith.emitI64x2Shl(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i64x2.shr_u" => try op_simd_int_arith.emitI64x2ShrU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-u: i64x2.shr_s synthesis (no native PSRAQ
            // in SSE; runtime-mask sign-bit fixup recipe per
            // cranelift `lower.isle:943-951` — 9 instr, no
            // const-pool needed since the sign-bit mask is
            // PCMPEQB+PSLLQ-imm-synthesised inline). i8x16 shifts
            // defer to 9.7-v (count-dependent broadcast mask
            // synthesis or const-pool dependency per ADR-0042).
            .@"i64x2.shr_s" => try op_simd_int_arith.emitI64x2ShrS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-v: i8x16.shl + i8x16.shr_u via inline-mask
            // synthesis (no const-pool dep). 9-/10-instr recipes
            // using PSLLW/PSRLW + PCMPEQB-derived all-ones + PSHUFB
            // broadcast of byte-0 of the shifted-mask word.
            // i8x16.shr_s defers to 9.7-w (byte→word extension via
            // PUNPCKLBW + PSRAW + PACKSSWB — structurally different).
            .@"i8x16.shl" => try op_simd_int_arith.emitI8x16Shl(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.shr_u" => try op_simd_int_arith.emitI8x16ShrU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-w: i8x16.shr_s via cranelift sign-extension
            // synthesis (`lower.isle:846+`). 11-instr: PCMPGTB sign-
            // mask + PUNPCKL/HBW byte→word extension + PSRAW per
            // half + PACKSSWB pack.
            .@"i8x16.shr_s" => try op_simd_int_arith.emitI8x16ShrS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-x: i*x*.extend_{low,high}_*_{s,u} (12 ops).
            // Low half: 1-instr SSE4.1 PMOVSX*/PMOVZX* direct.
            // High half: PSHUFD imm=0xEE swaps upper qword to lower
            // position + PMOVSX/ZX. 2 instr per high-extend.
            .@"i16x8.extend_low_i8x16_s" => try op_simd_int_cmp_lane.emitI16x8ExtendLowI8x16S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.extend_low_i8x16_u" => try op_simd_int_cmp_lane.emitI16x8ExtendLowI8x16U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.extend_high_i8x16_s" => try op_simd_int_cmp_lane.emitI16x8ExtendHighI8x16S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.extend_high_i8x16_u" => try op_simd_int_cmp_lane.emitI16x8ExtendHighI8x16U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.extend_low_i16x8_s" => try op_simd_int_cmp_lane.emitI32x4ExtendLowI16x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.extend_low_i16x8_u" => try op_simd_int_cmp_lane.emitI32x4ExtendLowI16x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.extend_high_i16x8_s" => try op_simd_int_cmp_lane.emitI32x4ExtendHighI16x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.extend_high_i16x8_u" => try op_simd_int_cmp_lane.emitI32x4ExtendHighI16x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.extend_low_i32x4_s" => try op_simd_int_cmp_lane.emitI64x2ExtendLowI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.extend_low_i32x4_u" => try op_simd_int_cmp_lane.emitI64x2ExtendLowI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.extend_high_i32x4_s" => try op_simd_int_cmp_lane.emitI64x2ExtendHighI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.extend_high_i32x4_u" => try op_simd_int_cmp_lane.emitI64x2ExtendHighI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-y: i*x*.narrow_*_{s,u} (4 ops). PACKSSWB
            // (SSE2) + PACKUSWB (SSE2) for i8x16; PACKSSDW (SSE2)
            // + PACKUSDW (SSE4.1) for i16x8. All single-instr via
            // emitV128IntBinop.
            .@"i8x16.narrow_i16x8_s" => try op_simd_int_cmp_lane.emitI8x16NarrowI16x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.narrow_i16x8_u" => try op_simd_int_cmp_lane.emitI8x16NarrowI16x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.narrow_i32x4_s" => try op_simd_int_cmp_lane.emitI16x8NarrowI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.narrow_i32x4_u" => try op_simd_int_cmp_lane.emitI16x8NarrowI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-z: i*x*.abs (4 ops). PABSB/W/D (SSSE3
            // 0F 38 1C/1D/1E) for 8/16/32-bit lanes — single-instr
            // unary via emitV128FpUnop. i64x2.abs synthesises via
            // 5-instr sign-mask + PXOR + PSUBQ recipe (no PABSQ
            // in SSE; SSE4.2 PCMPGTQ available per ADR-0041).
            .@"i8x16.abs" => try op_simd_int_arith.emitI8x16Abs(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.abs" => try op_simd_int_arith.emitI16x8Abs(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.abs" => try op_simd_int_arith.emitI32x4Abs(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.abs" => try op_simd_int_arith.emitI64x2Abs(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-aa: i*x*.neg (4 ops). 3-instr recipe via
            // emitV128IntNeg helper: PXOR XMM14,XMM14 + PSUB_<shape>
            // XMM14, src + MOVAPS dst, XMM14. Aliasing-safe.
            .@"i8x16.neg" => try op_simd_int_arith.emitI8x16Neg(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.neg" => try op_simd_int_arith.emitI16x8Neg(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.neg" => try op_simd_int_arith.emitI32x4Neg(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.neg" => try op_simd_int_arith.emitI64x2Neg(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-ab: FP convert signed + promote/demote
            // (4 ops). Single-instr unary CVT* via emitV128FpUnop.
            // u-variants and trunc-sat defer (cranelift uses
            // const-pool float magic numbers; ADR-0042 pending).
            .@"f32x4.convert_i32x4_s" => try op_simd_float.emitF32x4ConvertI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.convert_low_i32x4_s" => try op_simd_float.emitF64x2ConvertLowI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.promote_low_f32x4" => try op_simd_float.emitF64x2PromoteLowF32x4(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.demote_f64x2_zero" => try op_simd_float.emitF32x4DemoteF64x2Zero(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-ae: 2 inline-synth FP convert / trunc-sat
            // ops. The 4 const-pool-dependent variants
            // (f64x2.convert_low_i32x4_u, i32x4.trunc_sat_f32x4_u,
            // i32x4.trunc_sat_f64x2_{s,u}_zero) defer to 9.7-ag
            // pending ADR-0042 const-pool plumbing.
            .@"f32x4.convert_i32x4_u" => try op_simd_float.emitF32x4ConvertI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.trunc_sat_f32x4_s" => try op_simd_float.emitI32x4TruncSatF32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-at: i32x4.trunc_sat_f32x4_u closes the
            // last of the 4 deferred 9.7-ae u-variants. The
            // "3-scratch" framing turned out to be a non-issue:
            // dst (regalloc'd from XMM8..XMM13) + XMM14 + XMM15
            // gives 3 distinct physical xmms within the existing
            // fp_spill_stage_xmms reservation. No ABI change.
            .@"i32x4.trunc_sat_f32x4_u" => try op_simd_float.emitI32x4TruncSatF32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-au: int min/max + saturating arith +
            // avgr_u (22 ops). All single-instruction native
            // SSE2/SSE4.1 ops; each wrapper dispatches via
            // emitV128IntBinop with the matching encoder. No new
            // helpers; cranelift maps 1-to-1 (`inst.isle:2470-2486`).
            .@"i8x16.min_s" => try op_simd_int_arith.emitI8x16MinS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.min_u" => try op_simd_int_arith.emitI8x16MinU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.max_s" => try op_simd_int_arith.emitI8x16MaxS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.max_u" => try op_simd_int_arith.emitI8x16MaxU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.min_s" => try op_simd_int_arith.emitI16x8MinS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.min_u" => try op_simd_int_arith.emitI16x8MinU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.max_s" => try op_simd_int_arith.emitI16x8MaxS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.max_u" => try op_simd_int_arith.emitI16x8MaxU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.min_s" => try op_simd_int_arith.emitI32x4MinS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.min_u" => try op_simd_int_arith.emitI32x4MinU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.max_s" => try op_simd_int_arith.emitI32x4MaxS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.max_u" => try op_simd_int_arith.emitI32x4MaxU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.add_sat_s" => try op_simd_int_arith.emitI8x16AddSatS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.add_sat_u" => try op_simd_int_arith.emitI8x16AddSatU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.sub_sat_s" => try op_simd_int_arith.emitI8x16SubSatS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.sub_sat_u" => try op_simd_int_arith.emitI8x16SubSatU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.add_sat_s" => try op_simd_int_arith.emitI16x8AddSatS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.add_sat_u" => try op_simd_int_arith.emitI16x8AddSatU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.sub_sat_s" => try op_simd_int_arith.emitI16x8SubSatS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.sub_sat_u" => try op_simd_int_arith.emitI16x8SubSatU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i8x16.avgr_u" => try op_simd_int_arith.emitI8x16AvgrU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i16x8.avgr_u" => try op_simd_int_arith.emitI16x8AvgrU(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-av: f32x4/f64x2 .pmin/pmax (4 ops). Direct
            // dispatch to MINPS/MAXPS/MINPD/MAXPD with operands
            // swapped (dst=c2, src=c1) to align Wasm pseudo-min/max
            // semantics with x86's "return src on equal/NaN/zero".
            // Cranelift maps the same way (`lower.isle:1542-1545`).
            .@"f32x4.pmin" => try op_simd_float.emitF32x4Pmin(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.pmax" => try op_simd_float.emitF32x4Pmax(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.pmin" => try op_simd_float.emitF64x2Pmin(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.pmax" => try op_simd_float.emitF64x2Pmax(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-ax: v128.load + v128.store foundation
            // memory ops. Mirror scalar emitMemOp shape with
            // access_size=16 + MOVUPS final encoding. RAX/RCX/RDX
            // scratches reused (pool-excluded). bounds_fixups +
            // spill_base_off + ins.payload threading mirrors i32.load.
            .@"v128.load" => try op_simd.emitV128Load(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.store" => try op_simd.emitV128Store(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            // §9.7 / 9.7-ay: v128.load{8,16,32,64}_splat (4 ops).
            // All reuse v128MemPrologue with appropriate access_size
            // + a per-lane-width broadcast tail. 8/16-bit go through
            // GPR (MOVZX + MOVD); 32/64-bit use MOVSS/MOVSD direct
            // load + PSHUFD broadcast.
            .@"v128.load8_splat" => try op_simd.emitV128Load8Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load16_splat" => try op_simd.emitV128Load16Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load32_splat" => try op_simd.emitV128Load32Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load64_splat" => try op_simd.emitV128Load64Splat(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            // §9.7 / 9.7-az: v128.load{32,64}_zero (2 ops). Single-
            // instruction MOVSS/MOVSD memory load — the scalar form
            // already zero-extends the upper bits per Intel SDM.
            .@"v128.load32_zero" => try op_simd.emitV128Load32Zero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load64_zero" => try op_simd.emitV128Load64Zero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            // §9.7 / 9.7-ba: v128.load_lane / store_lane × 4 sizes
            // (8 ops). payload = memarg.offset; extra = lane byte.
            // Uses GPR roundtrip (MOVZX/MOV + PINSR/PEXTR reg-form);
            // store_lane PUSH/POPs RCX around the prologue's RCX-
            // clobbering LEA.
            .@"v128.load8_lane" => try op_simd.emitV128Load8Lane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, ins.extra, func.func_idx),
            .@"v128.load16_lane" => try op_simd.emitV128Load16Lane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, ins.extra, func.func_idx),
            .@"v128.load32_lane" => try op_simd.emitV128Load32Lane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, ins.extra, func.func_idx),
            .@"v128.load64_lane" => try op_simd.emitV128Load64Lane(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, ins.extra, func.func_idx),
            .@"v128.store8_lane" => try op_simd.emitV128Store8Lane(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, ins.payload, ins.extra, func.func_idx),
            .@"v128.store16_lane" => try op_simd.emitV128Store16Lane(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, ins.payload, ins.extra, func.func_idx),
            .@"v128.store32_lane" => try op_simd.emitV128Store32Lane(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, ins.payload, ins.extra, func.func_idx),
            .@"v128.store64_lane" => try op_simd.emitV128Store64Lane(allocator, &buf, alloc, &pushed_vregs, &bounds_fixups, spill_base_off, ins.payload, ins.extra, func.func_idx),
            // §9.7 / 9.7-bb: v128.load{8x8,16x4,32x2}_{s,u} (6 ops).
            // MOVSD load + PMOVSX/ZX{BW,WD,DQ} extend. No new
            // encoders. Closes the §9.7 v128 op surface.
            .@"v128.load8x8_s" => try op_simd.emitV128Load8x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load8x8_u" => try op_simd.emitV128Load8x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load16x4_s" => try op_simd.emitV128Load16x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load16x4_u" => try op_simd.emitV128Load16x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load32x2_s" => try op_simd.emitV128Load32x2S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            .@"v128.load32x2_u" => try op_simd.emitV128Load32x2U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, spill_base_off, ins.payload, func.func_idx),
            // §9.7 / 9.7-af: native single-instr multiply-and-add
            // pair. PMULHRSW (SSSE3) implements Q15 multiply-round-
            // saturate exactly per Wasm spec; PMADDWD (SSE2)
            // implements pairwise dot product with wrapping i32
            // accumulation matching the Wasm spec.
            .@"i16x8.q15mulr_sat_s" => try op_simd_int_arith.emitI16x8Q15mulrSatS(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            .@"i32x4.dot_i16x8_s" => try op_simd_int_arith.emitI32x4DotI16x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off),
            // §9.7 / 9.7-ag: i16x8.extmul × 4. Cranelift recipe
            // `lower.isle:1197-1285` — PMOVSX/ZX BW each operand
            // (extend i8→i16) + PMULLW. High variants prefix
            // PSHUFD imm=0xEE to swap upper 64 bits down before
            // extending. No new encoders.
            .@"i16x8.extmul_low_i8x16_s" => try op_simd_int_cmp_lane.emitI16x8ExtmulLowI8x16S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.extmul_high_i8x16_s" => try op_simd_int_cmp_lane.emitI16x8ExtmulHighI8x16S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.extmul_low_i8x16_u" => try op_simd_int_cmp_lane.emitI16x8ExtmulLowI8x16U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.extmul_high_i8x16_u" => try op_simd_int_cmp_lane.emitI16x8ExtmulHighI8x16U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-ah: i32x4.extmul × 4 (i16x8 → i32x4).
            // Same recipe as 9.7-ag with PMOVSXWD/PMOVZXWD +
            // PMULLD substituted; helpers reused unchanged.
            .@"i32x4.extmul_low_i16x8_s" => try op_simd_int_cmp_lane.emitI32x4ExtmulLowI16x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.extmul_high_i16x8_s" => try op_simd_int_cmp_lane.emitI32x4ExtmulHighI16x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.extmul_low_i16x8_u" => try op_simd_int_cmp_lane.emitI32x4ExtmulLowI16x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32x4.extmul_high_i16x8_u" => try op_simd_int_cmp_lane.emitI32x4ExtmulHighI16x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-ai: i64x2.extmul × 4 (i32x4 → i64x2).
            // Different shape: PMULDQ/PMULUDQ already widen
            // i32→i64, so PSHUFD imm=0x{50,FA} is the only
            // positioning needed (no PMOVSX/ZX prefix).
            .@"i64x2.extmul_low_i32x4_s" => try op_simd_int_cmp_lane.emitI64x2ExtmulLowI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.extmul_high_i32x4_s" => try op_simd_int_cmp_lane.emitI64x2ExtmulHighI32x4S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.extmul_low_i32x4_u" => try op_simd_int_cmp_lane.emitI64x2ExtmulLowI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i64x2.extmul_high_i32x4_u" => try op_simd_int_cmp_lane.emitI64x2ExtmulHighI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-aj: i16x8.extadd_pairwise_i8x16 × 2.
            // PCMPEQB + PABSB synthesises a 0x01-per-byte vector;
            // PMADDUBSW (SSSE3) reduces to pairwise add. No
            // const-pool dep.
            .@"i16x8.extadd_pairwise_i8x16_s" => try op_simd_int_cmp_lane.emitI16x8ExtaddPairwiseI8x16S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i16x8.extadd_pairwise_i8x16_u" => try op_simd_int_cmp_lane.emitI16x8ExtaddPairwiseI8x16U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-ak: i32x4.extadd_pairwise_i16x8_s.
            // Inline-synth 0x00010001-per-dword mask + PMADDWD.
            // The _u variant is deferred (PMADDWD reads i16 as
            // signed; u16 inputs need pre-correction via ADR-0042
            // const-pool sign-flip + post-add fixup).
            .@"i32x4.extadd_pairwise_i16x8_s" => try op_simd_int_cmp_lane.emitI32x4ExtaddPairwiseI16x8S(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7/9.7-aq — i32x4.extadd_pairwise_i16x8_u via
            // sign-flip XOR + PMADDWD-with-+1 + bias-correction-add.
            // 11-instr inline-synth (no const-pool dep) — closes
            // the extadd_pairwise family.
            .@"i32x4.extadd_pairwise_i16x8_u" => try op_simd_int_cmp_lane.emitI32x4ExtaddPairwiseI16x8U(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7/9.7-ar — i8x16.shuffle via PSHUFB-pair + POR.
            // The handler reads the original Wasm mask from
            // func.simd_consts[ins.payload], derives a-mask /
            // b-mask, and appends both to extra_consts.
            .@"i8x16.shuffle" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_int_cmp_lane.emitI8x16Shuffle(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &simd_const_fixups, &extra_consts, simd_consts_base, func.simd_consts, ins.payload);
            },
            // §9.7/9.7-al — v128.const via ADR-0042 const-pool
            // (mirror of ARM64 §9.6/9.6-f-ii). Lower pass stored
            // const_idx in ins.payload pointing into
            // func.simd_consts.
            .@"v128.const" => try op_simd.emitV128Const(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &simd_const_fixups, ins.payload, spill_base_off),
            // §9.7/9.7-am — i32x4.trunc_sat_f64x2_s_zero. Recipe
            // needs a shared INT32_MAX_f64-broadcast const; placed
            // into per-emit-pass extra_consts.
            .@"i32x4.trunc_sat_f64x2_s_zero" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_float.emitI32x4TruncSatF64x2SZero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // §9.7/9.7-an — i8x16.popcnt via SSSE3 PSHUFB-LUT
            // (1 op, 2 const-pool entries shared via extra_consts).
            .@"i8x16.popcnt" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_int_arith.emitI8x16Popcnt(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // §9.7/9.7-ao — f64x2.convert_low_i32x4_u via IEEE-754
            // mantissa-overlay trick (5 instr + 2 const-pool entries).
            .@"f64x2.convert_low_i32x4_u" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_float.emitF64x2ConvertLowI32x4U(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // §9.7/9.7-ap — i32x4.trunc_sat_f64x2_u_zero via the
            // ROUNDPD + ADDPD-magic + SHUFPS-extract recipe per
            // cranelift `lower.isle:5061-5093`.
            .@"i32x4.trunc_sat_f64x2_u_zero" => {
                const simd_consts_base: u32 = if (func.simd_consts) |sc| @intCast(sc.len) else 0;
                try op_simd_float.emitI32x4TruncSatF64x2UZero(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &simd_const_fixups, &extra_consts, simd_consts_base);
            },
            // §9.7 / 9.7-ac: i8x16.swizzle (1 op). 10-instr inline
            // recipe synthesises 0x0F broadcast + PCMPGTB-detect of
            // idx>15 + POR-correct + PSHUFB. No const-pool dep.
            .@"i8x16.swizzle" => try op_simd_int_cmp_lane.emitI8x16Swizzle(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            // §9.7 / 9.7-ad: FP unop family (12 ops). abs / neg
            // via inline sign-mask synthesis (PCMPEQB ones +
            // PSLL{D,Q}-imm 31/63); ceil/floor/trunc/nearest via
            // SSE4.1 ROUNDPS/ROUNDPD imm with precision-exception
            // suppression (bit 3 set).
            .@"f32x4.abs" => try op_simd_float.emitF32x4Abs(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.abs" => try op_simd_float.emitF64x2Abs(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.neg" => try op_simd_float.emitF32x4Neg(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.neg" => try op_simd_float.emitF64x2Neg(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.ceil" => try op_simd_float.emitF32x4Ceil(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.floor" => try op_simd_float.emitF32x4Floor(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.trunc" => try op_simd_float.emitF32x4Trunc(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f32x4.nearest" => try op_simd_float.emitF32x4Nearest(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.ceil" => try op_simd_float.emitF64x2Ceil(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.floor" => try op_simd_float.emitF64x2Floor(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.trunc" => try op_simd_float.emitF64x2Trunc(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"f64x2.nearest" => try op_simd_float.emitF64x2Nearest(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"memory.size" => {
                // Wasm spec §4.4.7 — return current memory size in
                // 64-KiB pages. mem_limit (bytes) lives at
                // [R15 + jit_abi.mem_limit_off]; pages = bytes >> 16.
                // Push fresh i32 vreg.
                const result_v = next_vreg;
                next_vreg += 1;
                if (result_v >= alloc.slots.len) return Error.SlotOverflow;
                const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
                try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(dst_r, abi.runtime_ptr_save_gpr, jit_abi.mem_limit_off).slice());
                try buf.appendSlice(allocator, inst.encShrRImm8(.q, dst_r, 16).slice());
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, result_v, 0);
                try pushed_vregs.append(allocator, result_v);
            },
            .@"memory.grow" => try op_call.emitMemoryGrow(allocator, &buf, alloc, &pushed_vregs, &next_vreg, spill_base_off, outgoing_max_bytes),
            .select, .select_typed => {
                // Wasm spec §4.4.4 / §3.3.2.2 — pop c, val2, val1;
                // push val1 if c != 0 else val2. x86_64: TEST c,c
                // → q-form MOV+CMOVNE. Dispatch (§9.9-m-4a / ADR-0056):
                // v128 via op_simd; i32 / i64 / funcref / externref
                // share q-form (REX.W harmless for i32 zero-ext IR);
                // f32/f64 → UnsupportedOp (m-4b XMM dispatch).
                if (pushed_vregs.items.len < 3) return Error.AllocationMissing;
                const cond_v = pushed_vregs.pop().?;
                const val2_v = pushed_vregs.pop().?;
                const val1_v = pushed_vregs.pop().?;
                const result_v = next_vreg;
                next_vreg += 1;
                if (result_v >= alloc.slots.len) return Error.SlotOverflow;
                if (alloc.shapeTag(val1_v) == .v128) {
                    // D-083 part 2: v128 select → mask-based emit
                    // (mirror of arm64/emit.zig dispatch).
                    try op_simd.emitV128Select(allocator, &buf, alloc, spill_base_off, cond_v, val1_v, val2_v, result_v);
                    try pushed_vregs.append(allocator, result_v);
                    continue;
                }
                // §9.9 / 9.9-m-4b: f32 / f64 select via op_alu_float.
                // emitFpSelect (MOVD/Q-to-GPR + CMOVNE + MOVD/Q-back
                // shuttle; x86 has no FP CMOV).
                if (ins.extra == 0x7D or ins.extra == 0x7C) {
                    try op_alu_float.emitFpSelect(allocator, &buf, alloc, spill_base_off, &pushed_vregs, ins.extra == 0x7C, cond_v, val1_v, val2_v, result_v);
                    continue;
                }
                // GPR path (i32 / i64 / funcref / externref).
                //
                // D-097 d-18: select with two non-distinct register
                // slots needs alias-aware cmov direction. The
                // regalloc's LIFO free-pool reuses slots, so
                // `result_v` can land on EITHER `val1_v`'s slot or
                // `val2_v`'s slot depending on the expire order at
                // select's def PC. Pre-d-18 always emitted
                // `MOV dst, val2 ; CMOVNE dst, val1` — safe when
                // dst aliases val2 (MOV is a self-MOV) but broken
                // when dst aliases val1 (MOV clobbers val1 before
                // CMOVNE reads it). The d-18 fix picks the cmov
                // direction so the MOV is always a self-MOV (or
                // skipped entirely) when an alias exists:
                //   - dst == val1: CMOVE dst, val2 if cond=0
                //   - dst == val2: CMOVNE dst, val1 if cond≠0
                //   - otherwise: MOV dst, val1; CMOVE dst, val2.
                //
                // CMOV's read-modify-write shape means the "dst
                // already holds X" branch must precede the cmov
                // whose condition keeps that X. CMOVE = move on
                // ZF=1 (= cond was 0 = pick val2); CMOVNE = move
                // on ZF=0 (= cond ≠ 0 = pick val1). Wasm spec
                // §4.4.4: result = (cond ≠ 0) ? val1 : val2.
                const cond_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, cond_v, 0);
                try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
                const val2_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, val2_v, 1);
                const val1_r = try gpr.gprLoadSpilled(allocator, &buf, alloc, spill_base_off, val1_v, 0);
                const dst_r = try gpr.gprDefSpilled(alloc, result_v, 0);
                if (dst_r == val2_r) {
                    // dst already holds val2 (alias). CMOVNE swaps
                    // to val1 on cond ≠ 0.
                    try buf.appendSlice(allocator, inst.encCmovccRR(.q, .ne, dst_r, val1_r).slice());
                } else {
                    // dst == val1 or independent: MOV dst, val1
                    // (skipped if aliased) + CMOVE swaps to val2 on
                    // cond = 0.
                    if (dst_r != val1_r) {
                        try buf.appendSlice(allocator, inst.encMovRR(.q, dst_r, val1_r).slice());
                    }
                    try buf.appendSlice(allocator, inst.encCmovccRR(.q, .e, dst_r, val2_r).slice());
                }
                try gpr.gprStoreSpilled(allocator, &buf, alloc, spill_base_off, result_v, 0);
                try pushed_vregs.append(allocator, result_v);
            },
            .@"unreachable" => {
                // Wasm spec §4.4.6.1 — trap unconditionally.
                // Emit JMP rel32 placeholder; record fixup so the
                // function-end trap-stub block patches the disp32
                // to land in the trap stub (which sets trap_flag,
                // clears EAX, runs epilogue, RETs). Mirrors arm64
                // `unreachable` semantics but uses JMP rel32 (5
                // bytes) instead of B (4 bytes); the fixup list
                // is separate to carry the 5-byte disp formula.
                const fixup_at: u32 = @intCast(buf.items.len);
                try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
                try unreach_fixups.append(allocator, fixup_at);
                dead_code = true;
            },
            .nop => {
                // Wasm spec §4.4.6.2 (nop) — do nothing. No machine
                // bytes; no stack change. Mirrors arm64/emit.zig.
            },
            .drop => {
                // Wasm spec §4.4.4 (drop) — pop top operand without
                // storage. No machine bytes; only the operand-stack
                // tracker advances. Mirrors arm64/emit.zig.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                _ = pushed_vregs.pop().?;
            },
            .@"return" => {
                // Wasm spec §4.4.7 (return) — pop the function's
                // result(s) and exit. We inline the same marshal +
                // epilogue + RET sequence as the function-level
                // `end` form below; multiple physical RETs are
                // harmless on x86_64 (no jump table needed, unlike
                // ARM64 where return_fixups consolidate to a single
                // epilogue). Subsequent ops in the same body may
                // emit dead bytes that are unreachable at runtime.
                // D-093 (d-11): multi-result return marshal via the
                // shared op_control helper (mirrors arm64's
                // `marshalFunctionReturn`).
                try op_control.marshalReturnRegs(allocator, &buf, alloc, &pushed_vregs, spill_base_off, func, return_is_memory_class, indirect_result_slot_neg_off);
                if (frame_bytes > 0) {
                    try buf.appendSlice(allocator, rspAdd(frame_bytes).slice());
                }
                if (uses_runtime_ptr) {
                    try buf.appendSlice(allocator, inst.encPopR(.r15).slice());
                }
                try buf.appendSlice(allocator, inst.encPopR(.rbp).slice());
                try buf.appendSlice(allocator, inst.encRet().slice());
                dead_code = true;
            },
            .block => try op_control.emitBlock(allocator, &labels, &pushed_vregs, ins.extra),
            .loop => try op_control.emitLoop(allocator, &buf, &labels, &pushed_vregs, ins.extra),
            .br => {
                try op_control.emitBr(allocator, &buf, alloc, &pushed_vregs, &labels, spill_base_off, func, frame_bytes, uses_runtime_ptr, return_is_memory_class, indirect_result_slot_neg_off, ins.payload);
                // br is an unconditional control transfer; subsequent
                // ops in the same body are unreachable until the
                // matching `end` re-enters live emission.
                dead_code = true;
            },
            .br_if => try op_control.emitBrIf(allocator, &buf, alloc, &pushed_vregs, &labels, spill_base_off, func, frame_bytes, uses_runtime_ptr, return_is_memory_class, indirect_result_slot_neg_off, ins.payload),
            .br_table => try op_control.emitBrTable(allocator, &buf, func, alloc, &pushed_vregs, &labels, spill_base_off, frame_bytes, uses_runtime_ptr, return_is_memory_class, indirect_result_slot_neg_off, ins.payload, ins.extra),
            .@"if" => try op_control.emitIf(allocator, &buf, alloc, &pushed_vregs, &labels, spill_base_off, ins.extra),
            .@"else" => try op_control.emitElse(allocator, &buf, &pushed_vregs, &labels),
            .end => {
                // Two distinct forms (mirrors arm64/emit.zig):
                // (A) Intra-function `end`: pops a label, patches
                //     forward fixups (block) / no-op for loop.
                // (B) Function-level `end`: marshals result, runs
                //     epilogue, returns. Disambiguation: empty
                //     label stack → form (B).
                if (labels.items.len > 0) {
                    try op_control.emitEndIntra(allocator, &buf, &pushed_vregs, alloc, &labels, spill_base_off, func);
                    continue;
                }
                // D-093 (d-5): function-level end may inherit a
                // placeholder vreg from a dead-fall-through loop
                // (`loop.wast:cont-inner` shape). The marshal is
                // unreachable at runtime; skip when top_vreg has
                // no slot entry.
                // D-093 (d-11): multi-result return marshal via the
                // shared op_control helper. Same shape as the
                // `.return` op path above.
                try op_control.marshalReturnRegs(allocator, &buf, alloc, &pushed_vregs, spill_base_off, func, return_is_memory_class, indirect_result_slot_neg_off);
                // Epilogue: ADD RSP, frame ; POP R15? ; POP RBP ; RET.
                if (frame_bytes > 0) {
                    try buf.appendSlice(allocator, rspAdd(frame_bytes).slice());
                }
                if (uses_runtime_ptr) {
                    try buf.appendSlice(allocator, inst.encPopR(.r15).slice());
                }
                try buf.appendSlice(allocator, inst.encPopR(.rbp).slice());
                try buf.appendSlice(allocator, inst.encRet().slice());

                // Trap stub: emitted after the regular RET when
                // the function had any bounds-check fixups. Sets
                // JitRuntime.trap_flag = 1, clears EAX (return
                // value cleared so traps don't masquerade as
                // valid returns), runs the same epilogue, RETs.
                // Each pending bounds_fixup gets its disp32
                // patched to the trap stub address.
                if (bounds_fixups.items.len > 0 or unreach_fixups.items.len > 0) {
                    const trap_byte: u32 = @intCast(buf.items.len);
                    try buf.appendSlice(allocator, inst.encStoreImm32MemDisp32(abi.runtime_ptr_save_gpr, jit_abi.trap_flag_off, 1).slice());
                    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice()); // XOR EAX, EAX (return = 0)
                    if (frame_bytes > 0) {
                        try buf.appendSlice(allocator, rspAdd(frame_bytes).slice());
                    }
                    if (uses_runtime_ptr) {
                        try buf.appendSlice(allocator, inst.encPopR(.r15).slice());
                    }
                    try buf.appendSlice(allocator, inst.encPopR(.rbp).slice());
                    try buf.appendSlice(allocator, inst.encRet().slice());
                    for (bounds_fixups.items) |fx_byte| {
                        const disp: i32 = @as(i32, @intCast(trap_byte)) -
                            @as(i32, @intCast(fx_byte)) - 6;
                        inst.patchRel32(buf.items, fx_byte, 6, disp);
                    }
                    // unreachable fixups: 5-byte JMP rel32 (0xE9 +
                    // disp32). disp = trap_byte - (fx_byte + 5).
                    for (unreach_fixups.items) |fx_byte| {
                        const disp: i32 = @as(i32, @intCast(trap_byte)) -
                            @as(i32, @intCast(fx_byte)) - 5;
                        inst.patchRel32(buf.items, fx_byte, 5, disp);
                    }
                }
                // §9.7/9.7-al — SIMD const-pool append + patch
                // (per ADR-0042). After the trap stub, if any
                // v128.const / future shuffle ops emitted MOVUPS-
                // RIP-rel placeholders, append the per-function
                // const-pool 16-byte aligned and patch each
                // placeholder's disp32 to the RIP-relative offset.
                if (simd_const_fixups.items.len > 0) {
                    while (buf.items.len % 16 != 0) try buf.append(allocator, 0);
                    const pool_byte: u32 = @intCast(buf.items.len);
                    if (func.simd_consts) |sc| {
                        for (sc) |c| try buf.appendSlice(allocator, &c);
                    }
                    for (extra_consts.items) |c| try buf.appendSlice(allocator, &c);
                    for (simd_const_fixups.items) |fx| {
                        const target_byte: u32 = pool_byte + fx.const_idx * 16;
                        const disp32: i32 = @as(i32, @intCast(target_byte)) -
                            @as(i32, @intCast(fx.post_insn_byte));
                        inst.patchRipRelDisp32(buf.items, fx.disp32_byte_offset, disp32);
                    }
                }
                break;
            },
            else => {
                std.debug.print("x86_64/emit: UnsupportedOp[body-op-{s}] (func_idx={d})\n", .{ @tagName(ins.op), func.func_idx });
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

/// Compute the i8 displacement for local index `idx`. Layout:
///   local 0 at [RBP - 8],  local K at [RBP - 8*(K+1)]
///       when !uses_runtime_ptr (1-PUSH prologue).
///   local 0 at [RBP - 16], local K at [RBP - 8 - 8*(K+1)]
///       when  uses_runtime_ptr (R15 occupies [RBP-8]).
/// Surfaces `UnsupportedOp` for indices the i8 disp cannot
/// reach (15 locals max either way; coincidentally same cap).
/// Returns the declared Wasm type of local index `idx`. Params
/// occupy idx 0..num_params-1; declared locals follow. Mirror
/// of arm64/emit.zig:localValType.
fn localValType(func: *const ZirFunc, num_params: u32, local_idx: u32) zir.ValType {
    _ = num_params;
    return func.localValType(local_idx);
}

/// §9.7 / 7.10-g: localDisp returns i32 (was i8). The i8 form
/// previously capped total_locals at 15 (deepest local at
/// `[RBP - 136]` overflows i8). i32 widening uses the disp32
/// form encoders for slots beyond i8 range; smaller slots stay
/// on the disp8 form via `rbpStoreR{32,64}` / `rbpLoadR{32,64}`
/// auto-helpers that pick form per offset.
///
/// §9.9 / 9.9-e-2: layout-aware overload via `localDispLayout`.
/// The pure-formula form below remains for non-v128 callers
/// (e.g. test fixtures + scalar emit_test_local sites that
/// hard-code the `(idx+1)*8` shape). v128-aware emit paths must
/// route through `localDispLayout(layout, idx, ...)` so the
/// per-type stride is honoured.
pub fn localDisp(idx: u32, total_locals: u32, uses_runtime_ptr: bool) Error!i32 {
    if (idx >= total_locals) {
        std.debug.print("x86_64/emit: UnsupportedOp[localDisp-idx>=total_locals] (idx={d}, total={d})\n", .{ idx, total_locals });
        return Error.UnsupportedOp;
    }
    const base_off: i32 = if (uses_runtime_ptr) -8 else 0;
    return base_off - @as(i32, @intCast((idx + 1) * 8));
}

/// §9.9 / 9.9-e-2: per-function local-frame layout. Mirror of
/// `arm64/emit.zig:LocalLayout` (group-by-type strategy C):
/// scalars at 8-byte stride in the low part of the locals zone,
/// v128 at 16-byte stride in the high part. RBP-relative
/// negative-disp coordinate space (frame grows DOWN from RBP).
///
/// `disps[i]` is the RBP-relative negative byte offset for Wasm-
/// local-index `i` (i.e. the value passed to `MOV [RBP+disp]`).
/// `total_bytes` is the locals-zone size in bytes (used by frame
/// sizing). The v128-region disp is the most-negative end of
/// each v128 slot, 16-byte aligned by construction (the scalar
/// region's tail rounds up to 16 before v128 slots start).
const LocalLayout = struct {
    disps: []i32,
    total_bytes: u32,
    v128_count: u32,

    fn deinit(self: *LocalLayout, allocator: Allocator) void {
        if (self.disps.len != 0) allocator.free(self.disps);
    }
};

/// Compute `LocalLayout` per `func.sig.params` + `func.locals` (+
/// synthetic) in declaration order. Two passes: count scalars vs
/// v128, then assign disps. Caller passes the `base_off_for_locals`
/// (= -8 if uses_runtime_ptr else 0) so the helper produces the
/// final RBP-relative disps directly.
fn computeLocalLayout(allocator: Allocator, func: *const ZirFunc, base_off_for_locals: i32) Error!LocalLayout {
    const num_params: u32 = @intCast(func.sig.params.len);
    const num_locals: u32 = func.totalLocalCount();
    const total_locals: u32 = num_params + num_locals;
    if (total_locals == 0) {
        return .{ .disps = &.{}, .total_bytes = 0, .v128_count = 0 };
    }
    const disps = try allocator.alloc(i32, total_locals);
    errdefer allocator.free(disps);

    var scalar_count: u32 = 0;
    var v128_count: u32 = 0;
    var i: u32 = 0;
    while (i < total_locals) : (i += 1) {
        if (func.localValType(i) == .v128) v128_count += 1 else scalar_count += 1;
    }

    const scalar_bytes: u32 = scalar_count * 8;
    // Scalars sit at the low (closer to RBP) end. v128 region
    // starts at -(scalar_bytes + 16-aligned padding). Since the
    // base RBP-relative origin (`base_off_for_locals`) is either
    // 0 or -8 (uses_runtime_ptr), the v128 region's most-positive
    // disp is `base_off_for_locals - aligned(scalar_bytes, 16)`.
    const v128_region_off: u32 = if (v128_count == 0) scalar_bytes else (scalar_bytes + 15) & ~@as(u32, 15);
    const total_bytes: u32 = v128_region_off + v128_count * 16;

    var scalar_within: u32 = 0;
    var v128_within: u32 = 0;
    i = 0;
    while (i < total_locals) : (i += 1) {
        if (func.localValType(i) == .v128) {
            // Each v128 occupies 16 bytes; disps point to the
            // LOW byte (= the most-negative disp, since
            // `MOVUPS [RBP+disp]` writes 16 bytes upward from
            // there).
            disps[i] = base_off_for_locals - @as(i32, @intCast(v128_region_off + (v128_within + 1) * 16));
            v128_within += 1;
        } else {
            disps[i] = base_off_for_locals - @as(i32, @intCast((scalar_within + 1) * 8));
            scalar_within += 1;
        }
    }

    return .{ .disps = disps, .total_bytes = total_bytes, .v128_count = v128_count };
}

// rbp/rsp form-selectors moved to rbp_disp.zig (D-052 progression);
// aliased at the top of this file so call-sites stay the same.

/// `local.get K` — push a fresh vreg holding the value loaded
/// from [RBP + localDisp(K)].
fn emitLocalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    func: *const ZirFunc,
    num_params: u32,
    total_locals: u32,
    disps: []const i32,
    idx: u32,
) Error!void {
    if (idx >= total_locals) return Error.UnsupportedOp;
    const disp = disps[idx];
    const vreg = next_vreg.*;
    next_vreg.* += 1;
    if (vreg >= alloc.slots.len) return Error.SlotOverflow;
    switch (localValType(func, num_params, idx)) {
        .i32 => {
            const dst_r = try gpr.gprDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadR32(dst_r, disp).slice());
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        // D-093 (d-33): reftype shares i64 8-byte gpr slot.
        .i64, .funcref, .externref => {
            const dst_r = try gpr.gprDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadR64(dst_r, disp).slice());
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .f32 => {
            const dst_x = try gpr.xmmDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadXmmF32(dst_x, disp).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .f64 => {
            const dst_x = try gpr.xmmDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadXmmF64(dst_x, disp).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
        .v128 => {
            // §9.9-e-2: Wasm spec §3.5.3 + §4.4.5.1 — local.get
            // copies the local's stored value (16 bytes for v128).
            // MOVUPS xmm, [RBP+disp] reads the full 128-bit lane
            // group; xmm spill helpers handle XMM-vs-spill-frame
            // placement.
            const dst_x = try gpr.xmmDefSpilled(alloc, vreg, 0);
            try buf.appendSlice(allocator, rbpLoadXmmV128(dst_x, disp).slice());
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, vreg, 0);
        },
    }
    try pushed_vregs.append(allocator, vreg);
}

/// `local.set K` — pop the top vreg and store its low 32 bits
/// into [RBP + disp].
fn emitLocalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    func: *const ZirFunc,
    num_params: u32,
    total_locals: u32,
    disps: []const i32,
    idx: u32,
) Error!void {
    if (idx >= total_locals) return Error.UnsupportedOp;
    const disp = disps[idx];
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    switch (localValType(func, num_params, idx)) {
        .i32 => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreR32(disp, src_r).slice());
        },
        // D-093 (d-33): reftype shares i64 8-byte gpr slot.
        .i64, .funcref, .externref => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreR64(disp, src_r).slice());
        },
        .f32 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmF32(disp, src_x).slice());
        },
        .f64 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmF64(disp, src_x).slice());
        },
        .v128 => {
            // §9.9-e-2: Wasm spec §4.4.5.2 — local.set writes 16
            // bytes via MOVUPS [RBP+disp], xmm.
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmV128(disp, src_x).slice());
        },
    }
}

/// `local.tee K` — store the top vreg's value into [RBP + disp]
/// WITHOUT popping.
fn emitLocalTee(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    func: *const ZirFunc,
    num_params: u32,
    total_locals: u32,
    disps: []const i32,
    idx: u32,
) Error!void {
    if (idx >= total_locals) return Error.UnsupportedOp;
    const disp = disps[idx];
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.items[pushed_vregs.items.len - 1];
    switch (localValType(func, num_params, idx)) {
        .i32 => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreR32(disp, src_r).slice());
        },
        // D-093 (d-33): reftype shares i64 8-byte gpr slot.
        .i64, .funcref, .externref => {
            const src_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreR64(disp, src_r).slice());
        },
        .f32 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmF32(disp, src_x).slice());
        },
        .f64 => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmF64(disp, src_x).slice());
        },
        .v128 => {
            // §9.9-e-2: Wasm spec §4.4.5.3 — local.tee mirrors
            // local.set's 16-byte write.
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            try buf.appendSlice(allocator, rbpStoreXmmV128(disp, src_x).slice());
        },
    }
}
