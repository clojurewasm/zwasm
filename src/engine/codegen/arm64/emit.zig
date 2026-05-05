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
    n_slots: u8,
    /// `BL` fixup sites. Each is a placeholder that the caller
    /// patches once function-body addresses are known.
    /// Caller-owned; pair with `deinit` to free.
    call_fixups: []CallFixup,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
    if (out.call_fixups.len != 0) allocator.free(out.call_fixups);
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
    if (func.sig.params.len > 0) return Error.UnsupportedOp;
    const num_locals: u32 = @intCast(func.locals.len);
    const locals_bytes: u32 = num_locals * 8;
    // ADR-0018: extend frame by spill region. Layout:
    //   [SP + 0 .. locals_bytes-1]                   locals
    //   [SP + locals_bytes .. +spill_bytes-1]        spills
    // `spill_base_off` is the absolute SP-relative offset where
    // spill slot 0 lives; `gprLoadSpilled`/`gprStoreSpilled`
    // consume it via byte_offset = spill_base_off + slot.spill.
    const spill_bytes: u32 = alloc.spillBytes();
    const spill_base_off: u32 = locals_bytes;
    const frame_bytes_unaligned: u32 = locals_bytes + spill_bytes;
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
    // ADR-0017 sub-2d-ii: save runtime ptr to X19 so multi-call
    // functions can restore X0 before each BL/BLR. X19 is callee-
    // saved per AAPCS64 — preserved across calls without explicit
    // save/restore.
    try gpr.writeU32(allocator, &buf, inst.encOrrReg(abi.runtime_ptr_save_gpr, 31, 0));
    if (frame_bytes > 0) {
        if (frame_bytes >= (@as(u32, 1) << 12)) return Error.SlotOverflow;
        try gpr.writeU32(allocator, &buf, inst.encSubImm12(31, 31, @intCast(frame_bytes)));
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
        .call_fixups = &call_fixups,
        .spill_base_off = spill_base_off,
    };

    for (func.instrs.items, 0..) |ins, pc| {
        _ = pc;
        switch (ins.op) {
            .@"i32.const" => try op_const.emitI32Const(&ctx, &ins),
            .@"i64.const" => try op_const.emitI64Const(&ctx, &ins),
            .@"i64.add", .@"i64.sub", .@"i64.mul", .@"i64.and", .@"i64.or", .@"i64.xor",
            => try op_alu_int.emitI64Binary(&ctx, &ins),
            .@"i64.eq", .@"i64.ne", .@"i64.lt_s", .@"i64.lt_u", .@"i64.gt_s", .@"i64.gt_u",
            .@"i64.le_s", .@"i64.le_u", .@"i64.ge_s", .@"i64.ge_u",
            => try op_alu_int.emitI64Compare(&ctx, &ins),
            .@"i64.eqz" => try op_alu_int.emitI64Eqz(&ctx, &ins),
            .@"i64.shl", .@"i64.shr_s", .@"i64.shr_u", .@"i64.rotr",
            => try op_alu_int.emitI64Shift(&ctx, &ins),
            .@"i64.rotl" => try op_alu_int.emitI64Rotl(&ctx, &ins),
            .@"i64.clz" => try op_alu_int.emitI64Clz(&ctx, &ins),
            .@"i64.ctz" => try op_alu_int.emitI64Ctz(&ctx, &ins),
            .@"i32.wrap_i64", .@"i64.extend_i32_u",
            => try op_convert.emitWrap32(&ctx, &ins),
            .@"i64.extend_i32_s" => try op_convert.emitExtendI32S(&ctx, &ins),
            .@"f32.convert_i32_s", .@"f32.convert_i32_u",
            .@"f32.convert_i64_s", .@"f32.convert_i64_u",
            .@"f64.convert_i32_s", .@"f64.convert_i32_u",
            .@"f64.convert_i64_s", .@"f64.convert_i64_u",
            => try op_convert.emitConvertIntToFloat(&ctx, &ins),
            .@"i32.trunc_f32_s", .@"i32.trunc_f32_u",
            .@"i64.trunc_f32_s", .@"i64.trunc_f32_u",
            => try bounds_check.emitTrappingTruncF32(&ctx, &ins),
            .@"i32.trunc_f64_s", .@"i32.trunc_f64_u",
            .@"i64.trunc_f64_s", .@"i64.trunc_f64_u",
            => try bounds_check.emitTrappingTruncF64(&ctx, &ins),
            .@"i32.trunc_sat_f32_s", .@"i32.trunc_sat_f32_u",
            .@"i32.trunc_sat_f64_s", .@"i32.trunc_sat_f64_u",
            .@"i64.trunc_sat_f32_s", .@"i64.trunc_sat_f32_u",
            .@"i64.trunc_sat_f64_s", .@"i64.trunc_sat_f64_u",
            => try op_convert.emitTruncSat(&ctx, &ins),
            .@"i32.reinterpret_f32" => try op_convert.emitReinterpretI32FromF32(&ctx, &ins),
            .@"i64.reinterpret_f64" => try op_convert.emitReinterpretI64FromF64(&ctx, &ins),
            .@"f32.reinterpret_i32" => try op_convert.emitReinterpretF32FromI32(&ctx, &ins),
            .@"f64.reinterpret_i64" => try op_convert.emitReinterpretF64FromI64(&ctx, &ins),
            .@"f32.demote_f64", .@"f64.promote_f32",
            => try op_convert.emitFloatDemotePromote(&ctx, &ins),
            .@"f32.const" => {
                // Stage the IEEE-754 bits via a GPR const, then
                // FMOV S, W. The intermediate W-reg is the FP
                // vreg's slot's GPR-pool counterpart (slot K → X9+K
                // for K<7, etc.) reused as scratch for the move.
                // Per the per-class slot mapping note in abi.zig
                // (allocatable_v_regs comment), GPR slot 0 maps to
                // X9 — we use that as the immediate scratch.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const vd = try gpr.resolveFp(alloc, vreg);
                const w_scratch = try gpr.resolveGpr(alloc, vreg);
                try op_const.emitConstU32(allocator, &buf, w_scratch, ins.payload);
                try gpr.writeU32(allocator, &buf, inst.encFmovStoFromW(vd, w_scratch));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f64.const" => {
                // Similar to f32.const but for 64-bit (FMOV D, X).
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const vd = try gpr.resolveFp(alloc, vreg);
                const x_scratch = try gpr.resolveGpr(alloc, vreg);
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
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f32.add", .@"f32.sub", .@"f32.mul", .@"f32.div",
            .@"f64.add", .@"f64.sub", .@"f64.mul", .@"f64.div",
            => try op_alu_float.emitFloatBinary(&ctx, &ins),
            .@"f32.abs", .@"f32.neg", .@"f32.sqrt", .@"f32.ceil",
            .@"f32.floor", .@"f32.trunc", .@"f32.nearest",
            .@"f64.abs", .@"f64.neg", .@"f64.sqrt", .@"f64.ceil",
            .@"f64.floor", .@"f64.trunc", .@"f64.nearest",
            => try op_alu_float.emitFloatUnary(&ctx, &ins),
            .@"f32.copysign", .@"f64.copysign",
            => try op_alu_float.emitFloatCopysign(&ctx, &ins),
            .@"f32.min", .@"f32.max", .@"f64.min", .@"f64.max",
            => try op_alu_float.emitFloatMinMax(&ctx, &ins),
            .@"f32.eq", .@"f32.ne", .@"f32.lt", .@"f32.gt", .@"f32.le", .@"f32.ge",
            .@"f64.eq", .@"f64.ne", .@"f64.lt", .@"f64.gt", .@"f64.le", .@"f64.ge",
            => try op_alu_float.emitFloatCompare(&ctx, &ins),
            .@"i64.popcnt" => try op_alu_int.emitI64Popcnt(&ctx, &ins),
            .@"i32.add", .@"i32.sub", .@"i32.mul", .@"i32.and", .@"i32.or", .@"i32.xor",
            .@"i32.shl", .@"i32.shr_s", .@"i32.shr_u",
            => try op_alu_int.emitI32Binary(&ctx, &ins),
            .@"i32.rotr" => try op_alu_int.emitI32Rotr(&ctx, &ins),
            .@"i32.rotl" => try op_alu_int.emitI32Rotl(&ctx, &ins),
            .@"i32.eq", .@"i32.ne", .@"i32.lt_s", .@"i32.lt_u", .@"i32.gt_s", .@"i32.gt_u",
            .@"i32.le_s", .@"i32.le_u", .@"i32.ge_s", .@"i32.ge_u",
            => try op_alu_int.emitI32Compare(&ctx, &ins),
            .@"i32.eqz" => try op_alu_int.emitI32Eqz(&ctx, &ins),
            .@"i32.clz" => try op_alu_int.emitI32Clz(&ctx, &ins),
            .@"i32.ctz" => try op_alu_int.emitI32Ctz(&ctx, &ins),
            .@"local.get" => {
                // Push a fresh vreg holding the value loaded from
                // [SP, #(local_idx * 8)].
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const wd = try gpr.resolveGpr(alloc, vreg);
                try gpr.writeU32(allocator, &buf, inst.encLdrImmW(wd, 31, offset));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"local.set" => {
                // Pop top vreg, write to [SP, #(local_idx * 8)].
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const src = pushed_vregs.pop().?;
                const ws = try gpr.resolveGpr(alloc, src);
                try gpr.writeU32(allocator, &buf, inst.encStrImmW(ws, 31, offset));
            },
            .@"local.tee" => {
                // Write top vreg to [SP, #(local_idx * 8)] WITHOUT
                // popping — the value remains pushed.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const src = pushed_vregs.items[pushed_vregs.items.len - 1];
                const ws = try gpr.resolveGpr(alloc, src);
                try gpr.writeU32(allocator, &buf, inst.encStrImmW(ws, 31, offset));
            },
            .@"i32.popcnt" => try op_alu_int.emitI32Popcnt(&ctx, &ins),
            .@"block" => try op_control.emitBlock(&ctx, &ins),
            .@"loop" => try op_control.emitLoop(&ctx, &ins),
            .@"br" => try op_control.emitBr(&ctx, &ins),
            .@"call_indirect" => try op_call.emitCallIndirect(&ctx, &ins),
            .@"call" => try op_call.emitCall(&ctx, &ins),
            .@"memory.size" => {
                // Wasm memory.size returns current size in 64-KiB pages.
                // X27 carries the byte limit; pages = bytes >> 16.
                // Pop nothing (Wasm signature: () → i32). Push the
                // result vreg.
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wd = try gpr.resolveGpr(alloc, result);
                try gpr.writeU32(allocator, &buf, inst.encLsrImmW(wd, 27, 16));
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
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wd = try gpr.resolveGpr(alloc, result);
                try gpr.writeU32(allocator, &buf, inst.encMovnImmW(wd, 0));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.load", .@"i32.load8_s", .@"i32.load8_u",
            .@"i32.load16_s", .@"i32.load16_u",
            .@"i64.load", .@"i64.load8_s", .@"i64.load8_u",
            .@"i64.load16_s", .@"i64.load16_u",
            .@"i64.load32_s", .@"i64.load32_u",
            .@"f32.load", .@"f64.load",
            .@"i32.store", .@"i32.store8", .@"i32.store16",
            .@"i64.store", .@"i64.store8", .@"i64.store16", .@"i64.store32",
            .@"f32.store", .@"f64.store",
            => try op_memory.emitMemOp(&ctx, &ins),
            .@"br_table" => try op_control.emitBrTable(&ctx, &ins),
            .@"if" => try op_control.emitIf(&ctx, &ins),
            .@"else" => try op_control.emitElse(&ctx, &ins),
            .@"br_if" => try op_control.emitBrIf(&ctx, &ins),
            .@"end" => {
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
                        const src_vn = try gpr.resolveFp(alloc, top_vreg);
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
                if (frame_bytes > 0) {
                    try gpr.writeU32(allocator, &buf, inst.encAddImm12(31, 31, @intCast(frame_bytes)));
                }
                try gpr.writeU32(allocator, &buf, encLdpFpLrPostIdx());
                try gpr.writeU32(allocator, &buf, inst.encRet(abi.link_register));

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
                        try gpr.writeU32(allocator, &buf, inst.encAddImm12(31, 31, @intCast(frame_bytes)));
                    }
                    try gpr.writeU32(allocator, &buf, encLdpFpLrPostIdx());
                    try gpr.writeU32(allocator, &buf, inst.encRet(abi.link_register));
                    for (bounds_fixups.items) |fx_byte| {
                        const disp_words: i32 = @as(i32, @intCast(trap_byte)) -
                            @as(i32, @intCast(fx_byte));
                        const orig = std.mem.readInt(u32, buf.items[fx_byte..][0..4], .little);
                        // Recover cond from lower 4 bits of B.cond placeholder.
                        const cond: inst.Cond = @enumFromInt(@as(u4, @intCast(orig & 0xF)));
                        const new_word = inst.encBCond(cond, @divExact(disp_words, 4));
                        std.mem.writeInt(u32, buf.items[fx_byte..][0..4], new_word, .little);
                    }
                }
                break;
            },
            else => return Error.UnsupportedOp,
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
