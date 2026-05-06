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
const abi = @import("abi.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");
const label_mod = @import("label.zig");
const op_alu_int = @import("op_alu_int.zig");
const op_alu_float = @import("op_alu_float.zig");
const op_convert = @import("op_convert.zig");
const op_memory = @import("op_memory.zig");
const op_control = @import("op_control.zig");

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
) Error!EmitOutput {
    if (alloc.slots.len != (func.liveness orelse return Error.AllocationMissing).ranges.len) {
        return Error.AllocationMissing;
    }
    if (func.sig.params.len > 0) return Error.UnsupportedOp;
    const num_locals: u32 = @intCast(func.locals.len);
    if (num_locals > 15) return Error.UnsupportedOp;

    // Prescan: does this function need the runtime-ptr save?
    // Per ADR-0026, memory ops (and future calls / call_indirect)
    // require RDI captured into R15 at function entry. Functions
    // that don't touch memory or make calls keep the simpler 1-PUSH
    // prologue, preserving backward-compat with the existing skel
    // / ALU / control tests.
    // **Same-class grep target**: i64 / f32 / f64 memory ops will
    // be added to BOTH this prescan AND emitMemOp's `access_size`
    // switch + dispatch arm in `body switch` simultaneously. Forgetting
    // either one leads to "uses_runtime_ptr=false but R15 referenced"
    // class bugs (silent invalid instruction stream). See D-030 for
    // the planned discharge timing (post-7.7 op surface completion).
    const uses_runtime_ptr = blk: {
        for (func.instrs.items) |ins| {
            switch (ins.op) {
                .@"i32.load", .@"i32.load8_s", .@"i32.load8_u",
                .@"i32.load16_s", .@"i32.load16_u",
                .@"i32.store", .@"i32.store8", .@"i32.store16",
                .@"f32.load", .@"f64.load",
                .@"f32.store", .@"f64.store",
                .@"global.get", .@"global.set",
                .@"call",
                .@"call_indirect",
                => break :blk true,
                else => {},
            }
        }
        break :blk false;
    };

    // Frame-bytes formula depends on prologue shape (SysV §3.2.2
    // 16-byte stack alignment; CALL pushes ret addr → entry RSP
    // ≡ 8 mod 16; PUSH RBP → 0 mod 16; PUSH R15 → 8 mod 16):
    //   - 1-PUSH:  frame ≡ 0 mod 16  (current shape; rounds up locals_bytes to 16)
    //   - 2-PUSH:  frame ≡ 8 mod 16  (per ADR-0026 prologue)
    const locals_bytes: u32 = num_locals * 8;
    const frame_bytes: u32 = if (uses_runtime_ptr)
        ((locals_bytes + 7) & ~@as(u32, 15)) + 8
    else
        (locals_bytes + 15) & ~@as(u32, 15);

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
        // MOV R15, <entry_arg0> — entry shim's runtime_ptr snapshot.
        // Cc-pivot per ADR-0026: SysV passes *const JitRuntime in
        // RDI; Win64 in RCX. Both encodings are 3 bytes (REX.W+B
        // + opcode + modrm) so the prologue's frame-bytes formula
        // stays Cc-agnostic.
        try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.runtime_ptr_save_gpr, abi.current.entry_arg0_gpr).slice());
    }
    if (frame_bytes > 0) {
        try buf.appendSlice(allocator, inst.encSubRSpImm8(@intCast(frame_bytes)).slice());
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

    // Direct-call placeholders awaiting linker patch.
    var call_fixups: std.ArrayList(CallFixup) = .empty;
    errdefer call_fixups.deinit(allocator);

    for (func.instrs.items) |ins| {
        switch (ins.op) {
            .@"i32.const" => {
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const slot_id = alloc.slots[vreg];
                const dst = abi.slotToReg(slot_id) orelse return Error.SlotOverflow;
                try buf.appendSlice(allocator, inst.encMovImm32W(dst, ins.payload).slice());
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i32.add", .@"i32.sub", .@"i32.mul",
            .@"i32.and", .@"i32.or", .@"i32.xor",
            => try op_alu_int.emitI32Binary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.eq", .@"i32.ne",
            .@"i32.lt_s", .@"i32.lt_u", .@"i32.gt_s", .@"i32.gt_u",
            .@"i32.le_s", .@"i32.le_u", .@"i32.ge_s", .@"i32.ge_u",
            => try op_alu_int.emitI32Compare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.eqz" => try op_alu_int.emitI32Eqz(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32.shl", .@"i32.shr_s", .@"i32.shr_u",
            .@"i32.rotl", .@"i32.rotr",
            => try op_alu_int.emitI32Shift(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.clz", .@"i32.ctz", .@"i32.popcnt",
            => try op_alu_int.emitI32Bitcount(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.wrap_i64", .@"i64.extend_i32_u", .@"i64.extend_i32_s",
            => try op_alu_int.emitConvertWidth(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"call" => try emitCall(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &call_fixups, func_sigs, ins.payload),
            .@"call_indirect" => try emitCallIndirect(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, module_types, ins.payload),
            .@"f32.const", .@"f64.const",
            => try op_alu_float.emitFpConst(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op, ins.payload, ins.extra),
            .@"f32.add", .@"f32.sub", .@"f32.mul", .@"f32.div",
            .@"f64.add", .@"f64.sub", .@"f64.mul", .@"f64.div",
            => try op_alu_float.emitFpBinary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"f32.eq", .@"f32.ne", .@"f32.lt", .@"f32.gt", .@"f32.le", .@"f32.ge",
            .@"f64.eq", .@"f64.ne", .@"f64.lt", .@"f64.gt", .@"f64.le", .@"f64.ge",
            => try op_alu_float.emitFpCompare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"f32.abs", .@"f32.neg", .@"f32.sqrt",
            .@"f32.ceil", .@"f32.floor", .@"f32.trunc", .@"f32.nearest",
            .@"f64.abs", .@"f64.neg", .@"f64.sqrt",
            .@"f64.ceil", .@"f64.floor", .@"f64.trunc", .@"f64.nearest",
            => try op_alu_float.emitFpUnary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"f32.copysign", .@"f64.copysign",
            => try op_alu_float.emitFpCopysign(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"f32.min", .@"f32.max", .@"f64.min", .@"f64.max",
            => try op_alu_float.emitFpMinMax(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"f64.promote_f32", .@"f32.demote_f64",
            .@"i32.reinterpret_f32", .@"i64.reinterpret_f64",
            .@"f32.reinterpret_i32", .@"f64.reinterpret_i64",
            .@"f32.convert_i32_s", .@"f32.convert_i64_s",
            .@"f64.convert_i32_s", .@"f64.convert_i64_s",
            .@"f32.convert_i32_u", .@"f64.convert_i32_u",
            => try op_convert.emitFpConvertSimple(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"f32.convert_i64_u", .@"f64.convert_i64_u",
            => try op_convert.emitFpConvertI64Unsigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.trunc_sat_f32_s", .@"i32.trunc_sat_f64_s",
            .@"i64.trunc_sat_f32_s", .@"i64.trunc_sat_f64_s",
            => try op_convert.emitFpTruncSatSigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.trunc_sat_f32_u", .@"i32.trunc_sat_f64_u",
            => try op_convert.emitFpTruncSatU32(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i64.trunc_sat_f32_u", .@"i64.trunc_sat_f64_u",
            => try op_convert.emitFpTruncSatU64(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.trunc_f32_s", .@"i32.trunc_f64_s",
            .@"i64.trunc_f32_s", .@"i64.trunc_f64_s",
            => try op_convert.emitFpTruncTrapSigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, ins.op),
            .@"i32.trunc_f32_u", .@"i32.trunc_f64_u",
            .@"i64.trunc_f32_u", .@"i64.trunc_f64_u",
            => try op_convert.emitFpTruncTrapUnsigned(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, ins.op),
            .@"local.get" => try emitLocalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, num_locals, uses_runtime_ptr, ins.payload),
            .@"local.set" => try emitLocalSet(allocator, &buf, alloc, &pushed_vregs, num_locals, uses_runtime_ptr, ins.payload),
            .@"local.tee" => try emitLocalTee(allocator, &buf, alloc, &pushed_vregs, num_locals, uses_runtime_ptr, ins.payload),
            .@"i32.load", .@"i32.load8_s", .@"i32.load8_u",
            .@"i32.load16_s", .@"i32.load16_u",
            .@"i32.store", .@"i32.store8", .@"i32.store16",
            .@"f32.load", .@"f64.load",
            .@"f32.store", .@"f64.store",
            => try op_memory.emitMemOp(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, ins.op, ins.payload, func.func_idx),
            .@"global.get" => try emitI32GlobalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.payload),
            .@"global.set" => try emitI32GlobalSet(allocator, &buf, alloc, &pushed_vregs, ins.payload),
            .@"block" => try op_control.emitBlock(allocator, &labels),
            .@"loop" => try op_control.emitLoop(allocator, &buf, &labels),
            .@"br" => try op_control.emitBr(allocator, &buf, &labels, ins.payload),
            .@"br_if" => try op_control.emitBrIf(allocator, &buf, alloc, &pushed_vregs, &labels, ins.payload),
            .@"br_table" => try op_control.emitBrTable(allocator, &buf, func, alloc, &pushed_vregs, &labels, ins.payload, ins.extra),
            .@"if" => try op_control.emitIf(allocator, &buf, alloc, &pushed_vregs, &labels),
            .@"else" => try op_control.emitElse(allocator, &buf, &pushed_vregs, &labels),
            .@"end" => {
                // Two distinct forms (mirrors arm64/emit.zig):
                // (A) Intra-function `end`: pops a label, patches
                //     forward fixups (block) / no-op for loop.
                // (B) Function-level `end`: marshals result, runs
                //     epilogue, returns. Disambiguation: empty
                //     label stack → form (B).
                if (labels.items.len > 0) {
                    try op_control.emitEndIntra(allocator, &buf, &pushed_vregs, alloc, &labels);
                    continue;
                }
                if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
                    const top = pushed_vregs.items[pushed_vregs.items.len - 1];
                    if (top >= alloc.slots.len) return Error.SlotOverflow;
                    const slot_id = alloc.slots[top];
                    switch (func.sig.results[0]) {
                        .i32, .funcref, .externref => {
                            const src = abi.slotToReg(slot_id) orelse return Error.SlotOverflow;
                            if (src != abi.return_gpr) {
                                // MOV EAX, src — Width.d zero-extends
                                // the upper 32 bits of RAX, matching
                                // the SysV i32 / 32-bit-pointer ABI.
                                try buf.appendSlice(allocator, inst.encMovRR(.d, abi.return_gpr, src).slice());
                            }
                        },
                        .i64 => {
                            const src = abi.slotToReg(slot_id) orelse return Error.SlotOverflow;
                            if (src != abi.return_gpr) {
                                // MOV RAX, src — Width.q preserves
                                // the full 64 bits; .d would silently
                                // truncate (D-032 root cause).
                                try buf.appendSlice(allocator, inst.encMovRR(.q, abi.return_gpr, src).slice());
                            }
                        },
                        .f32, .f64 => {
                            const src_x = abi.fpSlotToReg(slot_id) orelse return Error.SlotOverflow;
                            if (src_x != abi.return_xmm) {
                                // MOVAPS XMM0, src_xmm — copies the
                                // full 128-bit XMM. Sufficient for
                                // both f32 (low 32 used) and f64
                                // (low 64 used). Mirrors ARM64's
                                // FMOV S0/D0 marshal at
                                // arm64/emit.zig:475-503 but does
                                // not need width discrimination on
                                // x86_64.
                                try buf.appendSlice(allocator, inst.encMovapsXmmXmm(abi.return_xmm, src_x).slice());
                            }
                        },
                        .v128 => return Error.UnsupportedOp,
                    }
                }
                // Epilogue: ADD RSP, frame ; POP R15? ; POP RBP ; RET.
                if (frame_bytes > 0) {
                    try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(frame_bytes)).slice());
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
                if (bounds_fixups.items.len > 0) {
                    const trap_byte: u32 = @intCast(buf.items.len);
                    try buf.appendSlice(allocator, inst.encStoreImm32MemDisp32(abi.runtime_ptr_save_gpr, jit_abi.trap_flag_off, 1).slice());
                    try buf.appendSlice(allocator, inst.encXorRR(.d, .rax, .rax).slice()); // XOR EAX, EAX (return = 0)
                    if (frame_bytes > 0) {
                        try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(frame_bytes)).slice());
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

/// Direct call: `call N`. Mirrors arm64/op_call.zig's emitCall
/// — marshals args into SysV arg regs, restores RDI from R15
/// (caller-saved RDI may have been clobbered earlier), emits
/// CALL placeholder + records CallFixup for the post-emit
/// linker, captures return into the next vreg.
///
/// **Scope**: i32 args + i32 / void return only. f32/f64/i64
/// args + return surface as UnsupportedOp (lifted alongside
/// 7.7-fp / globals i64 chunks).
fn emitCall(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    call_fixups: *std.ArrayList(CallFixup),
    func_sigs: []const zir.FuncType,
    callee_idx: u32,
) Error!void {
    if (callee_idx >= func_sigs.len) return Error.AllocationMissing;
    const callee_sig = func_sigs[callee_idx];

    try marshalCallArgs(allocator, buf, alloc, pushed_vregs, callee_sig);

    // Restore <entry_arg0> = runtime_ptr from R15 before
    // transferring control. The callee's prologue captures arg0
    // into its own R15 (per ADR-0026). entry_arg0 is caller-
    // saved in both SysV (RDI) and Win64 (RCX) and may have been
    // clobbered by an earlier call.
    try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());

    // Win64 ABI: caller reserves 32 bytes of shadow space below
    // the call site for the callee to optionally spill its 4
    // register args. SysV has no shadow space. The reservation
    // is per-call (simpler than prologue-batched) and stays
    // 16-byte-aligned with the post-CALL push of return addr.
    try emitShadowAlloc(allocator, buf);

    // CALL placeholder; linker patches via call_fixups once
    // function-body offsets are known.
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encCallRel32(0).slice());
    try call_fixups.append(allocator, .{
        .byte_offset = fixup_at,
        .target_func_idx = callee_idx,
    });

    try emitShadowFree(allocator, buf);

    try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, callee_sig);
}

/// Reserve Win64 shadow space below the upcoming CALL. SysV
/// no-op (shadow_space_bytes = 0). Per ADR-0026 / Microsoft x64.
fn emitShadowAlloc(allocator: Allocator, buf: *std.ArrayList(u8)) Error!void {
    if (abi.current.shadow_space_bytes == 0) return;
    try buf.appendSlice(allocator, inst.encSubRSpImm8(@intCast(abi.current.shadow_space_bytes)).slice());
}

/// Free Win64 shadow space after CALL returns. SysV no-op.
fn emitShadowFree(allocator: Allocator, buf: *std.ArrayList(u8)) Error!void {
    if (abi.current.shadow_space_bytes == 0) return;
    try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(abi.current.shadow_space_bytes)).slice());
}

/// Indirect call: `call_indirect type_idx`. Pops the index,
/// marshals args, runs bounds + sig checks (both branch to the
/// shared trap stub via bounds_fixups), loads the funcptr from
/// `funcptr_base[idx]`, restores RDI = runtime_ptr, and CALLs
/// through RAX.
///
/// **Scratch register strategy**: RAX is used as scratch
/// throughout. RAX is NOT in the regalloc pool (`abi.zig`
/// excludes it as `return_gpr`), so it cannot collide with any
/// live vreg. This avoids needing a `spill_stage_gprs`
/// reservation (the arm64 X16/X17 mirror) for x86_64 — RAX is
/// dead from prologue through every instruction up to the CALL
/// itself, then comes alive holding the return value.
///
/// **JitRuntime invariant access** per ADR-0026: each of
/// `table_size`, `typeidx_base`, `funcptr_base` reloads from
/// `[R15 + offset]` at point of use rather than holding
/// callee-saved slots. The cost (3 extra MOVs vs ARM64's
/// 3 reserved-reg reads) is accepted per ADR-0026 §"Decision".
fn emitCallIndirect(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    module_types: []const zir.FuncType,
    type_idx: u32,
) Error!void {
    if (type_idx >= module_types.len) return Error.AllocationMissing;
    const callee_sig = module_types[type_idx];

    // Stack at entry: [args..., idx]. Pop idx first.
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_vreg = pushed_vregs.pop().?;
    const idx_r = abi.slotToReg(alloc.slots[idx_vreg]) orelse return Error.SlotOverflow;

    try marshalCallArgs(allocator, buf, alloc, pushed_vregs, callee_sig);

    // Bounds: MOV EAX, [R15 + table_size_off] ; CMP idx_r, EAX ; JAE trap.
    try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.table_size_off).slice());
    try buf.appendSlice(allocator, inst.encCmpRR(.d, idx_r, .rax).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());
        try bounds_fixups.append(allocator, fixup_at);
    }

    // Sig: MOV RAX, [R15 + typeidx_base_off] (load u32* table)
    //      MOV EAX, [RAX + idx_r * 4]        (load expected typeidx)
    //      CMP EAX, type_idx (imm32) ; JNE trap.
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.typeidx_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovR32FromBaseIdxLsl2(.rax, .rax, idx_r).slice());
    try buf.appendSlice(allocator, inst.encCmpRImm32(.rax, type_idx).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());
        try bounds_fixups.append(allocator, fixup_at);
    }

    // Funcptr: MOV RAX, [R15 + funcptr_base_off] ; MOV RAX, [RAX + idx_r*8].
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.funcptr_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromBaseIdxLsl3(.rax, .rax, idx_r).slice());

    // Restore <entry_arg0> = runtime_ptr (callee's prologue reads
    // it as its inbound JitRuntime ptr per ADR-0026: RDI on SysV,
    // RCX on Win64).
    try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());

    // Win64 shadow space (32 bytes; SysV no-op).
    try emitShadowAlloc(allocator, buf);

    // CALL RAX (indirect).
    try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());

    try emitShadowFree(allocator, buf);

    try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, callee_sig);
}

/// Marshal call arguments per SysV x86_64 §3.2.3: pop N arg
/// vregs in REVERSE (top-of-stack = rightmost arg), then emit
/// MOV from each arg's home register into RSI, RDX, RCX, R8,
/// R9 (skipping RDI = runtime_ptr per ADR-0026).
///
/// **No source-clobber risk by construction**: the regalloc
/// pool (R10, R11 + RBX, R12-R14) is disjoint from the SysV
/// arg regs (RDI..R9), so naive sequential MOV per arg is
/// correct without parallel-move analysis. Mirrors arm64's
/// constraint (op_call.zig § marshalCallArgs).
///
/// **Scope**: ≤ 5 i32 user-visible args (RSI..R9 — RDI is
/// reserved for runtime_ptr). f32/f64/i64 args surface as
/// UnsupportedOp.
fn marshalCallArgs(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    callee_sig: zir.FuncType,
) Error!void {
    const n_args: u32 = @intCast(callee_sig.params.len);
    if (n_args == 0) return;
    if (pushed_vregs.items.len < n_args) return Error.AllocationMissing;

    var arg_vregs: [5]u32 = undefined;
    if (n_args > arg_vregs.len) return Error.UnsupportedOp;
    var i: u32 = n_args;
    while (i > 0) {
        i -= 1;
        arg_vregs[i] = pushed_vregs.pop().?;
    }

    // arg_gprs slot 0 carries `*const JitRuntime` (RDI on SysV,
    // RCX on Win64) — skip; user args start at slot 1.
    //   SysV: arg_gprs[1..6] = RSI, RDX, RCX, R8, R9 (5 user GPRs)
    //   Win64: arg_gprs[1..4] = RDX, R8, R9 (3 user GPRs)
    var gpr_arg_slot: usize = 1;
    var k: u32 = 0;
    while (k < n_args) : (k += 1) {
        const src_vreg = arg_vregs[k];
        switch (callee_sig.params[k]) {
            .i32 => {
                if (gpr_arg_slot >= abi.current.arg_gprs.len) return Error.UnsupportedOp;
                const dst = abi.current.arg_gprs[gpr_arg_slot];
                const src = abi.slotToReg(alloc.slots[src_vreg]) orelse return Error.SlotOverflow;
                if (src != dst) {
                    try buf.appendSlice(allocator, inst.encMovRR(.d, dst, src).slice());
                }
                gpr_arg_slot += 1;
            },
            .i64, .f32, .f64, .v128, .funcref, .externref => return Error.UnsupportedOp,
        }
    }
}

/// Capture a call's return value into the next vreg per SysV
/// §3.2.1: i32 → EAX. Single-result MVP only — multi-value
/// returns (Wasm 2.0) land at sub-g3 follow-up. Void callees
/// push nothing.
fn captureCallResult(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    callee_sig: zir.FuncType,
) Error!void {
    if (callee_sig.results.len == 0) return;
    if (callee_sig.results.len > 1) return Error.UnsupportedOp;

    const result = next_vreg.*;
    next_vreg.* += 1;
    if (result >= alloc.slots.len) return Error.AllocationMissing;

    switch (callee_sig.results[0]) {
        .i32 => {
            const dst = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
            if (dst != abi.return_gpr) {
                try buf.appendSlice(allocator, inst.encMovRR(.d, dst, abi.return_gpr).slice());
            }
        },
        .i64, .f32, .f64, .v128, .funcref, .externref => return Error.UnsupportedOp,
    }
    try pushed_vregs.append(allocator, result);
}

/// Compute the i8 displacement for local index `idx`. Layout:
///   local 0 at [RBP - 8],  local K at [RBP - 8*(K+1)]
///       when !uses_runtime_ptr (1-PUSH prologue).
///   local 0 at [RBP - 16], local K at [RBP - 8 - 8*(K+1)]
///       when  uses_runtime_ptr (R15 occupies [RBP-8]).
/// Surfaces `UnsupportedOp` for indices the i8 disp cannot
/// reach (15 locals max either way; coincidentally same cap).
fn localDisp(idx: u32, num_locals: u32, uses_runtime_ptr: bool) Error!i8 {
    if (idx >= num_locals) return Error.UnsupportedOp;
    if (idx >= 16) return Error.UnsupportedOp;
    const base_off: i32 = if (uses_runtime_ptr) -8 else 0;
    const off: i32 = base_off - @as(i32, @intCast((idx + 1) * 8));
    if (off < -128) return Error.UnsupportedOp;
    return @intCast(off);
}

/// `local.get K` — push a fresh vreg holding the value loaded
/// from [RBP + localDisp(K)].
fn emitLocalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    num_locals: u32,
    uses_runtime_ptr: bool,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, num_locals, uses_runtime_ptr);
    const vreg = next_vreg.*;
    next_vreg.* += 1;
    if (vreg >= alloc.slots.len) return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
    try buf.appendSlice(allocator, inst.encLoadR32MemRBP(dst_r, disp).slice());
    try pushed_vregs.append(allocator, vreg);
}

/// `local.set K` — pop the top vreg and store its low 32 bits
/// into [RBP + localDisp(K)].
fn emitLocalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    num_locals: u32,
    uses_runtime_ptr: bool,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, num_locals, uses_runtime_ptr);
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    try buf.appendSlice(allocator, inst.encStoreR32MemRBP(disp, src_r).slice());
}

/// `local.tee K` — store the top vreg's low 32 bits into
/// [RBP + localDisp(K)] WITHOUT popping.
fn emitLocalTee(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    num_locals: u32,
    uses_runtime_ptr: bool,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, num_locals, uses_runtime_ptr);
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.items[pushed_vregs.items.len - 1];
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    try buf.appendSlice(allocator, inst.encStoreR32MemRBP(disp, src_r).slice());
}

/// `global.get N` (i32) — load `[globals_base + N*8]` low 32 bits
/// into a fresh dst vreg. Per ADR-0027 + ADR-0026 reload pattern:
///
///   MOV RAX, [R15 + globals_base_off]  ; reload globals_base ptr
///   MOV R<dst>, [RAX + N*8]            ; load i32 (low 4 bytes of slot)
///
/// idx range: u32 from ZirInstr.payload; byte_offset = idx * 8
/// must fit i32 (≈ 268M globals max), well beyond Wasm spec.
fn emitI32GlobalGet(
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

/// `global.set N` (i32) — pop a vreg, store its low 32 bits to
/// `[globals_base + N*8]`. Upper 4 bytes of the slot left
/// untouched (i32-typed globals; slot zero-init at module load).
fn emitI32GlobalSet(
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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "compile: empty body without liveness errors AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: empty function (no instrs) emits prologue only" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Prologue only: 55 48 89 E5 = 4 bytes (push rbp + mov rbp, rsp).
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x48, 0x89, 0xE5 }, out.bytes);
}

test "compile: (i32.const 42) end → 15 bytes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55                       PUSH RBP
    //   48 89 E5                 MOV RBP, RSP
    //   41 BA 2A 00 00 00        MOV R10D, #42 (slot 0 = R10)
    //   44 89 D0                 MOV EAX, R10D (return marshalling)
    //   5D                       POP RBP
    //   C3                       RET
    // Total: 1 + 3 + 6 + 3 + 1 + 1 = 15 bytes.
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x2A, 0x00, 0x00, 0x00,
        0x44, 0x89, 0xD0,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 0xDEADBEEF) end — little-endian imm32" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Differs from the 42 case only at the imm32 bytes (offsets 6..10).
    try testing.expectEqual(@as(usize, 15), out.bytes.len);
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, out.bytes[6..10]);
}

test "compile: void function with `end` only emits prologue + epilogue" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // 55 48 89 E5 5D C3 = 6 bytes (prologue + pop + ret; no return marshalling).
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x48, 0x89, 0xE5, 0x5D, 0xC3 }, out.bytes);
}

test "compile: function with 1 local + (i32.const 42) (local.set 0) (local.get 0) end" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &[_]zir.ValType{.i32});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 }, // const
        .{ .def_pc = 2, .last_use_pc = 3 }, // local.get result
    } };
    const slots = [_]u8{ 0, 1 }; // R10D, R11D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                    PUSH RBP ; MOV RBP, RSP
    //   48 83 EC 10                    SUB RSP, 16            (1 local → 16 aligned)
    //   41 BA 2A 00 00 00              MOV R10D, #42          (const)
    //   44 89 55 F8                    MOV [RBP-8], R10D      (local.set 0)
    //   44 8B 5D F8                    MOV R11D, [RBP-8]      (local.get 0)
    //   44 89 D8                       MOV EAX, R11D
    //   48 83 C4 10                    ADD RSP, 16
    //   5D                             POP RBP
    //   C3                             RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x48, 0x83, 0xEC, 0x10,
        0x41, 0xBA, 0x2A, 0x00, 0x00, 0x00,
        0x44, 0x89, 0x55, 0xF8,
        0x44, 0x8B, 0x5D, 0xF8,
        0x44, 0x89, 0xD8,
        0x48, 0x83, 0xC4, 0x10,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: local.tee preserves stack — uses top vreg without popping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &[_]zir.ValType{.i32});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.tee", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0}; // R10D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // local.tee writes [RBP-8] but doesn't pop, so the top vreg
    // (R10D) is still on the stack for the `end` to marshal into EAX.
    // Expected: prologue+SUB(8) + MOV R10D #7 + MOV [RBP-8] R10D
    // + MOV EAX R10D + ADD RSP + POP RBP + RET.
    // Spot-check: STORE [RBP-8] R10D = 44 89 55 F8 at offset 14..18,
    // followed by MOV EAX, R10D = 44 89 D0 at 18..21.
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x55, 0xF8 }, out.bytes[14..18]);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0xD0 }, out.bytes[18..21]);
}

test "compile: (block (br 0) end) end — forward br with end-patch" {
    // Empty block with br to its own end. Then function-end.
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // intra: closes block
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // function-level
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                    prologue (no SUB RSP — no locals)
    //   E9 00 00 00 00                 JMP rel32, patched to disp=0 (target = next byte)
    //   5D                             POP RBP (function-level end)
    //   C3                             RET
    // The JMP's disp is 0 because the patch site is at offset 4
    // (after prologue) + insn_size 5 → next instruction at offset 9,
    // which IS the block's end target. Disp = 9 - 9 = 0.
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xE9, 0x00, 0x00, 0x00, 0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (loop (br 0) end) end — backward br with concrete disp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" }); // intra: closes loop (no patch)
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, empty_alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // loop captures byte_offset = 4 (post-prologue). br at offset 4
    // emits JMP with disp = 4 - 4 - 5 = -5. So bytes:
    //   55 48 89 E5                    prologue
    //   E9 FB FF FF FF                 JMP -5 (back to loop entry — infinite loop)
    //   5D C3                          POP RBP ; RET (unreachable but emitted)
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0xE9, 0xFB, 0xFF, 0xFF, 0xFF,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 1) (if) (i32.const 7) (end) end — single-arm if; JE patched" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"if" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected layout (no SUB RSP, no return marshalling):
    //   55 48 89 E5                    prologue              [0..4]
    //   41 BA 01 00 00 00              MOV R10D, #1          [4..10]
    //   45 85 D2                       TEST R10D, R10D       [10..13]
    //   0F 84 06 00 00 00              JE +6 (skip then-body) [13..19]
    //   41 BB 07 00 00 00              MOV R11D, #7          [19..25]
    //   5D                             POP RBP               [25]
    //   C3                             RET                   [26]
    // JE disp = 25 - 19 = 6 (skip from after JE to past then-body's
    // i32.const 7). Then-body is 6 bytes (MOV R11D #7).
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x01, 0x00, 0x00, 0x00,
        0x45, 0x85, 0xD2,
        0x0F, 0x84, 0x06, 0x00, 0x00, 0x00,
        0x41, 0xBB, 0x07, 0x00, 0x00, 0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (block (i32.const 0) (br_if 0) end) end — Jcc forward fixup" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_if", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected:
    //   55 48 89 E5                    prologue              [0..4]
    //   41 BA 00 00 00 00              MOV R10D, #0          [4..10]
    //   45 85 D2                       TEST R10D, R10D       [10..13]
    //   0F 85 00 00 00 00              JNE +0 (block-end)    [13..19] disp = 19-19 = 0
    //   5D C3                          POP RBP ; RET         [19..21]
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x00, 0x00, 0x00, 0x00,
        0x45, 0x85, 0xD2,
        0x0F, 0x85, 0x00, 0x00, 0x00, 0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (loop (i32.const 0) (br_if 0) end) end — Jcc backward concrete disp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"loop" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_if", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // loop entry at offset 4 (post-prologue). br_if Jcc at offset
    // 13; disp = 4 - 13 - 6 = -15 = 0xFFFFFFF1.
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x00, 0x00, 0x00, 0x00,
        0x45, 0x85, 0xD2,
        0x0F, 0x85, 0xF1, 0xFF, 0xFF, 0xFF,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: br_table — single case + default both → block end" {
    // (block (i32.const 0) (br_table 1 0 0) end) end
    // count=1, case 0 → block (depth 0), default → block (depth 0).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.branch_targets.append(testing.allocator, 0); // case 0 depth
    try f.branch_targets.append(testing.allocator, 0); // default depth
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_table", .payload = 1, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                    prologue              [0..4]
    //   41 BA 00 00 00 00              MOV R10D, #0          [4..10]
    //   41 83 FA 00                    CMP R10D, 0           [10..14]
    //   75 05                          JNE +5 (skip JMP)     [14..16]
    //   E9 05 00 00 00                 JMP case-0 → block end (forward fixup; patched to disp=5) [16..21]
    //   E9 00 00 00 00                 JMP default → block end (forward fixup; patched to disp=0) [21..26]
    //   5D C3                          POP RBP ; RET         [26..28]
    // Block end target = 26. case JMP at 16 → disp=26-16-5=5. default JMP at 21 → disp=26-21-5=0.
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x00, 0x00, 0x00, 0x00,
        0x41, 0x83, 0xFA, 0x00,
        0x75, 0x05,
        0xE9, 0x05, 0x00, 0x00, 0x00,
        0xE9, 0x00, 0x00, 0x00, 0x00,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: br_table count > 127 → UnsupportedOp (i8 cap)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < 129) : (i += 1) try f.branch_targets.append(testing.allocator, 0);
    try f.instrs.append(testing.allocator, .{ .op = .@"block" });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"br_table", .payload = 128, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: (i32.const 0) i32.load offset=0 end — ADR-0026 prologue + bounds check + load" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 }, // const → idx
        .{ .def_pc = 1, .last_use_pc = 2 }, // load result
    } };
    const slots = [_]u8{ 0, 1 }; // R10D, R11D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // ADR-0026 prologue (uses_runtime_ptr=true):
    //   55                          PUSH RBP                          [0]
    //   41 57                       PUSH R15                          [1..3]
    //   48 89 E5                    MOV RBP, RSP                      [3..6]
    //   49 89 FF                    MOV R15, RDI                      [6..9]
    //   48 83 EC 08                 SUB RSP, 8 (locals=0 → frame=8)   [9..13]
    // Body:
    //   41 BA 00 00 00 00           MOV R10D, #0   (idx vreg 0)       [13..19]
    //   49 8B 87 00 00 00 00        MOV RAX, [R15 + 0] (vm_base)      [19..26]
    //   89 D2                       MOV EDX, R10D (zero-extend idx)   [26..28]
    //                  ↑ encMovRR(.d, .rdx, .r10): src=r10 → REX.R=1, dst=rdx → REX.B=0
    //                    Actually wait, encMovRR: first arg is dst, second is src.
    //                    encMovRR(.d, .rdx, .r10) → src=r10 (REX.R=1), dst=rdx (REX.B=0).
    //                    REX.R=1 needed for src=R10 → REX = 0x44.
    //                    ModR/M: mod=11, reg=src.low3=2 (r10), rm=dst.low3=2 (rdx)
    //                          → 11 010 010 = 0xD2. Hmm, but that's REG=R10 → ECX_low3=2,
    //                            and RM=RDX low3=2. So the byte is the same. OK ModR/M = D2.
    //                    Total: 44 89 D2 (3 bytes).
    //   44 89 D2                    MOV EDX, R10D                     [26..29]
    //   48 8D 4A 04                 LEA RCX, [RDX + 4] (ea + size=4)  [29..33]
    //   49 3B 8F 08 00 00 00        CMP RCX, [R15 + 8]                [33..40]
    //   0F 87 ?? ?? ?? ??           JA trap_stub (placeholder)        [40..46]
    //   44 8B 1C 10                 MOV R11D, [RAX + RDX]             [46..50]
    //   44 89 D8                    MOV EAX, R11D (return marshalling)[50..53]
    // Epilogue:
    //   48 83 C4 08                 ADD RSP, 8                        [53..57]
    //   41 5F                       POP R15                           [57..59]
    //   5D                          POP RBP                           [59]
    //   C3                          RET                               [60]
    // Trap stub:
    //   41 C7 87 28 00 00 00 01 00 00 00   MOV [R15+40], 1            [61..72]
    //   31 C0                              XOR EAX, EAX               [72..74]
    //   48 83 C4 08                        ADD RSP, 8                 [74..78]
    //   41 5F                              POP R15                    [78..80]
    //   5D                                 POP RBP                    [80]
    //   C3                                 RET                        [81]
    //
    // JA patch: trap_byte = 61. fixup_byte = 40, insn_size = 6.
    //   disp = 61 - 40 - 6 = 15 = 0x0F.
    //
    // Total length: 82 bytes (spec-strict bounds adds 4-byte LEA before CMP).
    try testing.expectEqual(@as(usize, 82), out.bytes.len);
    // Spot-check the prologue (verifies ADR-0026 structure).
    // The MOV R15, <entry_arg0> byte differs by Cc; derive the
    // expected sequence dynamically so this works on both SysV
    // and Win64 builds.
    const exp_push_rbp = inst.encPushR(.rbp);
    const exp_push_r15 = inst.encPushR(.r15);
    const exp_mov_rbp_rsp = inst.encMovRR(.q, .rbp, .rsp);
    const exp_mov_r15_arg0 = inst.encMovRR(.q, abi.current.runtime_ptr_save_gpr, abi.current.entry_arg0_gpr);
    const exp_sub_rsp_8 = inst.encSubRSpImm8(8);
    var exp_prologue: [13]u8 = undefined;
    var off: usize = 0;
    @memcpy(exp_prologue[off .. off + exp_push_rbp.len], exp_push_rbp.slice()); off += exp_push_rbp.len;
    @memcpy(exp_prologue[off .. off + exp_push_r15.len], exp_push_r15.slice()); off += exp_push_r15.len;
    @memcpy(exp_prologue[off .. off + exp_mov_rbp_rsp.len], exp_mov_rbp_rsp.slice()); off += exp_mov_rbp_rsp.len;
    @memcpy(exp_prologue[off .. off + exp_mov_r15_arg0.len], exp_mov_r15_arg0.slice()); off += exp_mov_r15_arg0.len;
    @memcpy(exp_prologue[off .. off + exp_sub_rsp_8.len], exp_sub_rsp_8.slice()); off += exp_sub_rsp_8.len;
    try testing.expectEqual(@as(usize, 13), off);
    try testing.expectEqualSlices(u8, &exp_prologue, out.bytes[0..13]);
    // Spot-check the JA placeholder is patched (disp = 15 = 0x0F): JA = 0x0F 0x87 at byte 40.
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x87, 0x0F, 0x00, 0x00, 0x00 }, out.bytes[40..46]);
    // Spot-check trap stub starts at 61 with the trap_flag store:
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xC7, 0x87, 0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }, out.bytes[61..72]);
}

test "compile: i32.load with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: (i32.const 0)(i32.const 99) i32.store offset=0 — store path" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });   // idx
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99 });  // value
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 }, // idx (R10D)
        .{ .def_pc = 1, .last_use_pc = 2 }, // value (R11D)
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Prologue: 13 bytes (PUSH RBP / PUSH R15 / MOV RBP,RSP / MOV R15,RDI / SUB RSP,8)
    // Body (spec-strict bounds: LEA RCX,[RDX+4] before CMP/JA):
    //   41 BA 00 00 00 00              MOV R10D, 0   (idx)            6 bytes
    //   41 BB 63 00 00 00              MOV R11D, 99  (value)          6
    //   49 8B 87 00 00 00 00           MOV RAX, [R15 + 0]             7
    //   44 89 D2                       MOV EDX, R10D                  3
    //   48 8D 4A 04                    LEA RCX, [RDX + 4]             4
    //   49 3B 8F 08 00 00 00           CMP RCX, [R15 + 8]             7
    //   0F 87 ?? ?? ?? ??              JA trap_stub (placeholder)     6
    //   44 89 1C 10                    MOV [RAX + RDX], R11D          4
    //   (no return marshalling — sig.results.len == 0)
    // Epilogue: ADD RSP,8 / POP R15 / POP RBP / RET                  8
    // Trap stub: 21 bytes
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x1C, 0x10 }, out.bytes[13 + 6 + 6 + 7 + 3 + 4 + 7 + 6 ..][0..4]);
    // Verify the JA was patched (disp != 0); JA = 0x0F 0x87
    const ja_at = 13 + 6 + 6 + 7 + 3 + 4 + 7;
    try testing.expect(out.bytes[ja_at] == 0x0F and out.bytes[ja_at + 1] == 0x87);
    const disp = std.mem.readInt(i32, out.bytes[ja_at + 2 ..][0..4], .little);
    try testing.expect(disp > 0); // forward to trap stub
}

test "compile: (i32.const 0) i32.load8_u → MOVZX r8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load8_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Find MOVZX r32, byte ptr [RAX + RDX]: REX.R + 0F B6 1C 10
    // dst is R11D → REX = 0x44, then 0F B6 1C 10
    const expected = [_]u8{ 0x44, 0x0F, 0xB6, 0x1C, 0x10 };
    // The load is the last body insn before return marshalling (MOV EAX, R11D).
    // Search; not asserting the exact offset to avoid coupling to prologue width.
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 0) i32.load16_s → MOVSX r16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.load16_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // MOVSX r32, word ptr [RAX + RDX] for R11D: REX.R + 0F BF 1C 10
    const expected = [_]u8{ 0x44, 0x0F, 0xBF, 0x1C, 0x10 };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 0)(i32.const 7) i32.store8 → MOV r8 store" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store8" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // MOV [RAX + RDX], R11B (8-bit): forced REX (REX.R for R11) → 44 88 1C 10
    const expected = [_]u8{ 0x44, 0x88, 0x1C, 0x10 };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: i32.store with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.store" }); // needs 2 vregs, has 1
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: global.get 0 — emits ADR-0027 reload-from-runtime-ptr (i32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"global.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0}; // R10D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Body should contain the 2-instruction global.get sequence:
    //   MOV RAX, [R15 + globals_base_off=48] →  49 8B 87 30 00 00 00
    //   MOV R10D, [RAX + 0]                  →  44 8B 90 00 00 00 00
    const expected = [_]u8{
        0x49, 0x8B, 0x87, 0x30, 0x00, 0x00, 0x00, // MOV RAX, [R15 + 48]
        0x44, 0x8B, 0x90, 0x00, 0x00, 0x00, 0x00, // MOV R10D, [RAX + 0]
    };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: (i32.const 42) global.set 1 — emits ADR-0027 reload + store (i32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Body should contain the global.set sequence:
    //   MOV RAX, [R15 + 48]                  →  49 8B 87 30 00 00 00
    //   MOV [RAX + 8], R10D  (idx=1, byte_off=8) →  44 89 90 08 00 00 00
    const expected = [_]u8{
        0x49, 0x8B, 0x87, 0x30, 0x00, 0x00, 0x00,
        0x44, 0x89, 0x90, 0x08, 0x00, 0x00, 0x00,
    };
    var found = false;
    var i: usize = 0;
    while (i + expected.len <= out.bytes.len) : (i += 1) {
        if (std.mem.eql(u8, out.bytes[i..][0..expected.len], &expected)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "compile: global.set with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"global.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty, &.{}, &.{}));
}

test "compile: br with depth out of range → UnsupportedOp" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0 }); // no enclosing block/loop
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: function with > 15 locals → UnsupportedOp (i8 disp range)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const sixteen_locals = [_]zir.ValType{.i32} ** 16;
    var f = ZirFunc.init(0, sig, &sixteen_locals);
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: function with params → UnsupportedOp (skeleton scope)" {
    const sig: zir.FuncType = .{ .params = &[_]zir.ValType{.i32}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty_alloc, &.{}, &.{}));
}

test "compile: (i32.const 7) (i32.const 5) i32.add end — verifies ADD is emitted" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 }; // R10D, R11D, EBX
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55                       PUSH RBP
    //   48 89 E5                 MOV RBP, RSP
    //   41 BA 07 00 00 00        MOV R10D, #7  (vreg 0 → slot 0 → R10)
    //   41 BB 05 00 00 00        MOV R11D, #5  (vreg 1 → slot 1 → R11)
    //   44 89 D3                 MOV EBX, R10D (vreg 2 → slot 2 → RBX, lhs lift)
    //   44 01 DB                 ADD EBX, R11D (rhs add)
    //   89 D8                    MOV EAX, EBX  (return marshalling)
    //   5D                       POP RBP
    //   C3                       RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x07, 0x00, 0x00, 0x00,
        0x41, 0xBB, 0x05, 0x00, 0x00, 0x00,
        0x44, 0x89, 0xD3,
        0x44, 0x01, 0xDB,
        0x89, 0xD8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 8) (i32.const 3) i32.sub end — SUB opcode 29" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 3 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.sub" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Spot-check: SUB EBX, R11D = 44 29 DB lives at offset 19..22.
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x29, 0xDB }, out.bytes[19..22]);
}

test "compile: (i32.const 6) (i32.const 7) i32.mul end — IMUL 0F AF" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 6 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.mul" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // IMUL r9, r/m9 has flipped REX semantics. dst=EBX (R=0), src=R11D (B=1)
    // → REX = 0x41. ModR/M: mod=11, reg=011 (ebx), rm=011 (r11) → DB.
    // So 41 0F AF DB at offset 19..23.
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x0F, 0xAF, 0xDB }, out.bytes[19..23]);
}

test "compile: (i32.const 7) (i32.const 5) i32.eq end — CMP+SETE+MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eq" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 }; // R10D, R11D, EBX
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   41 BA 07 00 00 00               MOV R10D, #7
    //   41 BB 05 00 00 00               MOV R11D, #5
    //   45 39 DA                        CMP R10D, R11D
    //   40 0F 94 C3                     SETE BL
    //   40 0F B6 DB                     MOVZX EBX, BL
    //   89 D8                           MOV EAX, EBX
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x07, 0x00, 0x00, 0x00,
        0x41, 0xBB, 0x05, 0x00, 0x00, 0x00,
        0x45, 0x39, 0xDA,
        0x40, 0x0F, 0x94, 0xC3,
        0x40, 0x0F, 0xB6, 0xDB,
        0x89, 0xD8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.lt_s vs i32.lt_u — different cc codes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{ .{ .op = .@"i32.lt_s", .cc = @as(u8, 0x9C) }, .{ .op = .@"i32.lt_u", .cc = @as(u8, 0x92) } }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 2 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 2 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // SETcc opcode byte lives at offset 19+1+1 = 21 (after CMP's 3 bytes + REX).
        // Layout: [prologue 4][2× movimm 12][cmp 3] = 19, then SETcc REX(40) at 19,
        // 0x0F at 20, opcode at 21.
        try testing.expectEqual(case.cc, out.bytes[21]);
    }
}

test "compile: (i32.const 0) i32.eqz end — TEST+SETE+MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 }; // R10D, R11D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   41 BA 00 00 00 00               MOV R10D, #0
    //   45 85 D2                        TEST R10D, R10D
    //   41 0F 94 C3                     SETE R11B   (REX.B for r11)
    //   45 0F B6 DB                     MOVZX R11D, R11B
    //   44 89 D8                        MOV EAX, R11D
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x00, 0x00, 0x00, 0x00,
        0x45, 0x85, 0xD2,
        0x41, 0x0F, 0x94, 0xC3,
        0x45, 0x0F, 0xB6, 0xDB,
        0x44, 0x89, 0xD8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: (i32.const 1) (i32.const 4) i32.shl end — MOV CL + MOV dst + SHL CL" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.shl" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 }; // R10D, R11D, EBX
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                     prologue
    //   41 BA 01 00 00 00               MOV R10D, #1     (vreg 0 = lhs)
    //   41 BB 04 00 00 00               MOV R11D, #4     (vreg 1 = rhs)
    //   44 89 D9                        MOV ECX, R11D    (rhs → CL count)
    //   44 89 D3                        MOV EBX, R10D    (lhs → dst)
    //   D3 E3                           SHL EBX, CL
    //   89 D8                           MOV EAX, EBX
    //   5D C3                           POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x01, 0x00, 0x00, 0x00,
        0x41, 0xBB, 0x04, 0x00, 0x00, 0x00,
        0x44, 0x89, 0xD9,
        0x44, 0x89, 0xD3,
        0xD3, 0xE3,
        0x89, 0xD8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.shr_s vs i32.shr_u — kind byte differs (sar D3 fb vs shr D3 eb)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{
        .{ .op = .@"i32.shr_s", .modrm = @as(u8, 0xFB) },
        .{ .op = .@"i32.shr_u", .modrm = @as(u8, 0xEB) },
    }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 100 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 2 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 2 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // Layout: 4 prologue + 6+6 imm32 + 3 mov-cl + 3 mov-dst = 22, then D3 at 22, ModR/M at 23.
        try testing.expectEqual(@as(u8, 0xD3), out.bytes[22]);
        try testing.expectEqual(case.modrm, out.bytes[23]);
    }
}

test "compile: (i32.const 8) i32.clz end — LZCNT" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 8 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 }; // R10D, R11D
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);

    // Expected stream:
    //   55 48 89 E5                    prologue
    //   41 BA 08 00 00 00              MOV R10D, #8
    //   F3 45 0F BD DA                 LZCNT R11D, R10D (dst=R11 reg, src=R10 r/m)
    //   44 89 D8                       MOV EAX, R11D
    //   5D C3                          POP RBP ; RET
    const expected = [_]u8{
        0x55,
        0x48, 0x89, 0xE5,
        0x41, 0xBA, 0x08, 0x00, 0x00, 0x00,
        0xF3, 0x45, 0x0F, 0xBD, 0xDA,
        0x44, 0x89, 0xD8,
        0x5D,
        0xC3,
    };
    try testing.expectEqualSlices(u8, &expected, out.bytes);
}

test "compile: i32.clz vs i32.ctz vs i32.popcnt — opcode byte differs" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    inline for (.{
        .{ .op = .@"i32.clz",    .opcode = @as(u8, 0xBD) },
        .{ .op = .@"i32.ctz",    .opcode = @as(u8, 0xBC) },
        .{ .op = .@"i32.popcnt", .opcode = @as(u8, 0xB8) },
    }) |case| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
        try f.instrs.append(testing.allocator, .{ .op = case.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 1 },
            .{ .def_pc = 1, .last_use_pc = 2 },
        } };
        const slots = [_]u8{ 0, 1 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
        defer deinit(testing.allocator, out);
        // Layout: 4 prologue + 6 imm32 = 10. Then F3 at 10, REX at 11,
        // 0x0F at 12, opcode at 13.
        try testing.expectEqual(@as(u8, 0xF3), out.bytes[10]);
        try testing.expectEqual(@as(u8, 0x0F), out.bytes[12]);
        try testing.expectEqual(case.opcode, out.bytes[13]);
    }
}

test "compile: i32.eqz with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" }); // no operand on stack
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: i32.wrap_i64 emits MOV r32_dst, r32_src (self-MOV zero-extends)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // x86_64 doesn't yet have i64.const; use i32.const as the i64-typed
    // source stand-in (emit pass doesn't validate types).
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xCAFE });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // Both vregs in slot 0 → R10. wrap-op materialises as self-MOV
    // (still issued: the 32-bit write zeroes the upper half).
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout: 4 prologue + 6 imm32 = 10. Then MOV R10D, R10D = 3 bytes.
    const expected = inst.encMovRR(.d, .r10, .r10);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[10 .. 10 + expected.len]);
}

test "compile: i64.extend_i32_u emits MOV r32_dst, r32_src" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const expected = inst.encMovRR(.d, .r10, .r10);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[10 .. 10 + expected.len]);
}

test "compile: i64.extend_i32_s emits MOVSXD r64_dst, r32_src" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // Sign-bit set source — extend_i32_s should produce a negative i64.
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFFFFFFFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout: 4 prologue + 6 imm32 = 10. Then MOVSXD R10, R10D = 3 bytes.
    const expected = inst.encMovsxdR64R32(.r10, .r10);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[10 .. 10 + expected.len]);
}

test "compile: call N — 0 args, void return — emits MOV RDI,R15 + CALL + fixup" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };

    const slots = [_]u8{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{});
    defer deinit(testing.allocator, out);

    // Prologue (uses_runtime_ptr=true since `call` triggers prescan):
    //   PUSH RBP        55              (1 byte)
    //   PUSH R15        41 57           (2 bytes) → 3
    //   MOV RBP, RSP    48 89 e5        (3 bytes) → 6
    //   MOV R15, RDI    49 89 fd        (3 bytes) → 9
    //   SUB RSP, 8      48 83 ec 08     (4 bytes) → 13   (frame_bytes=8 for N=0 + uses_rtp)
    // Body starts at byte 13.
    //   MOV RDI, R15    4c 89 ff        (3 bytes) → 16
    //   CALL rel32      e8 00 00 00 00  (5 bytes) → 21
    // Cc-pivot: assert MOV <entry_arg0>, R15 (RDI on SysV, RCX
    // on Win64). encMovRR length is 3 in both cases (only modrm
    // byte differs); the call-fixup byte offset stays at 16.
    const expected_mov = inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.current.runtime_ptr_save_gpr);
    try testing.expectEqualSlices(u8, expected_mov.slice(), out.bytes[13 .. 13 + expected_mov.len]);
    // Win64 shadow space: SUB RSP, 32 (4-byte encoding) must
    // precede the CALL; ADD RSP, 32 (4-byte encoding) follows.
    // SysV: no SUB/ADD; the byte at offset 16 is the CALL opcode.
    const shadow_enc_len: u32 = if (abi.current.shadow_space_bytes > 0) 4 else 0;
    if (shadow_enc_len > 0) {
        const expected_sub = inst.encSubRSpImm8(@intCast(abi.current.shadow_space_bytes));
        try testing.expectEqualSlices(u8, expected_sub.slice(), out.bytes[16 .. 16 + expected_sub.len]);
        const post_call: u32 = 16 + shadow_enc_len + 5;
        const expected_add = inst.encAddRSpImm8(@intCast(abi.current.shadow_space_bytes));
        try testing.expectEqualSlices(u8, expected_add.slice(), out.bytes[post_call .. post_call + expected_add.len]);
    }
    // CALL byte offset = post-prologue (13) + MOV <arg0>, R15
    // (3) + shadow encoding length. SysV: 16; Win64: 20.
    const call_off: u32 = 16 + shadow_enc_len;
    const expected_call = inst.encCallRel32(0);
    try testing.expectEqualSlices(u8, expected_call.slice(), out.bytes[call_off .. call_off + expected_call.len]);

    try testing.expectEqual(@as(usize, 1), out.call_fixups.len);
    try testing.expectEqual(call_off, out.call_fixups[0].byte_offset);
    try testing.expectEqual(@as(u32, 1), out.call_fixups[0].target_func_idx);
}

test "compile: call N — 0 args, i32 return — captures EAX into result vreg" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u8{0}; // result vreg → R10
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{});
    defer deinit(testing.allocator, out);

    // Body layout (post-prologue at 13). Capture-result offset
    // shifts by 2× shadow encoding (SUB before + ADD after the
    // 5-byte CALL). SysV: 21; Win64: 29.
    const shadow_enc_len: u32 = if (abi.current.shadow_space_bytes > 0) 4 else 0;
    const capture_off: u32 = 13 + 3 + shadow_enc_len + 5 + shadow_enc_len;
    const expected_capture = inst.encMovRR(.d, .r10, .rax);
    try testing.expectEqualSlices(u8, expected_capture.slice(), out.bytes[capture_off .. capture_off + expected_capture.len]);
}

test "compile: call N — 1 i32 arg — marshals top-of-stack into arg_gprs[1] (RSI on SysV, RDX on Win64)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{.i32}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{ sig, callee_sig };

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u8{0}; // arg vreg → R10
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &func_sigs, &.{});
    defer deinit(testing.allocator, out);

    // Body layout (post-prologue at 13). Cc-pivot derives the
    // marshalling target from `abi.current.arg_gprs[1]`.
    //   MOV R10D, 42                     (6 bytes) → 19
    //   MOV <arg1>, R10D                 (3 bytes) → 22  marshal
    //   MOV <arg0>, R15                  (3 bytes) → 25  runtime_ptr restore
    //   CALL rel32                       (5 bytes) → 30
    const expected_marshal = inst.encMovRR(.d, abi.current.arg_gprs[1], .r10);
    try testing.expectEqualSlices(u8, expected_marshal.slice(), out.bytes[19 .. 19 + expected_marshal.len]);
}

test "compile: call_indirect — bounds + sig (JAE+JNE → trap stub) + CALL RAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const callee_sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const module_types = [_]zir.FuncType{callee_sig};

    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };

    const slots = [_]u8{0}; // idx vreg → R10
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &module_types);
    defer deinit(testing.allocator, out);

    // Body starts at byte 13 (uses_runtime_ptr=true prologue).
    //   [13..19]  MOV R10D, 5             (i32.const, 6 bytes)
    //   [19..26]  MOV EAX, [R15 + 24]     (load table_size)
    //   [26..29]  CMP R10D, EAX           (bounds compare)
    //   [29..35]  JAE rel32 placeholder   (bounds fixup)
    //   [35..42]  MOV RAX, [R15 + 32]     (load typeidx_base)
    //   [42..46]  MOV EAX, [RAX + R10*4]  (load expected typeidx)
    //   [46..52]  CMP EAX, 0              (sig compare to type_idx=0)
    //   [52..58]  JNE rel32 placeholder   (sig fixup)
    //   [58..65]  MOV RAX, [R15 + 16]     (load funcptr_base)
    //   [65..69]  MOV RAX, [RAX + R10*8]  (load funcptr)
    //   [69..72]  MOV RDI, R15            (restore runtime_ptr)
    //   [72..74]  CALL RAX                (indirect)
    const expected_table_size_load = inst.encMovR32FromMemDisp32(.rax, .r15, 24);
    try testing.expectEqualSlices(u8, expected_table_size_load.slice(), out.bytes[19 .. 19 + expected_table_size_load.len]);
    // JAE/JNE rel32 disp32 is patched at function-tail to point at the
    // trap stub; assert only the opcode bytes (0F 83 / 0F 85).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[29]);
    try testing.expectEqual(@as(u8, 0x83), out.bytes[30]);
    const expected_typeidx_load = inst.encMovR32FromBaseIdxLsl2(.rax, .rax, .r10);
    try testing.expectEqualSlices(u8, expected_typeidx_load.slice(), out.bytes[42 .. 42 + expected_typeidx_load.len]);
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[52]);
    try testing.expectEqual(@as(u8, 0x85), out.bytes[53]);
    const expected_funcptr_load = inst.encMovR64FromBaseIdxLsl3(.rax, .rax, .r10);
    try testing.expectEqualSlices(u8, expected_funcptr_load.slice(), out.bytes[65 .. 65 + expected_funcptr_load.len]);
    // Cc-pivot: CALL RAX shifts by `shadow_space_bytes` encoding
    // length (Win64 inserts SUB RSP, 32 before the indirect CALL).
    const shadow_enc_len: u32 = if (abi.current.shadow_space_bytes > 0) 4 else 0;
    const call_off: u32 = 72 + shadow_enc_len;
    const expected_call = inst.encCallReg(.rax);
    try testing.expectEqualSlices(u8, expected_call.slice(), out.bytes[call_off .. call_off + expected_call.len]);
}

test "compile: f32.const — MOV EAX,bits + MOVD XMM8,EAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0f bit pattern = 0x3F800000.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0}; // FP slot 0 → XMM8
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Prologue (uses_runtime_ptr=false; no calls/memory) = 4 bytes.
    //   PUSH RBP        55              (1)
    //   MOV RBP, RSP    48 89 e5        (3) → 4
    // Body:
    //   MOV EAX, bits   b8 + 4 imm      (5) → 9
    //   MOVD XMM8,EAX   66 44 0f 6e c0  (5) → 14
    const expected_imm = inst.encMovImm32W(.rax, 0x3F800000);
    try testing.expectEqualSlices(u8, expected_imm.slice(), out.bytes[4 .. 4 + expected_imm.len]);
    const expected_movd = inst.encMovdXmmFromR32(.xmm8, .rax);
    try testing.expectEqualSlices(u8, expected_movd.slice(), out.bytes[9 .. 9 + expected_movd.len]);
}

test "compile: f64.const — MOVABS RAX,bits + MOVQ XMM8,RAX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0 bit pattern = 0x3FF0000000000000. Split into payload + extra.
    const bits: u64 = 0x3FF0000000000000;
    try f.instrs.append(testing.allocator, .{
        .op = .@"f64.const",
        .payload = @truncate(bits),
        .extra = @truncate(bits >> 32),
    });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Body layout (post-prologue at 4):
    //   MOVABS RAX,bits 48 b8 + 8 imm   (10) → 14
    //   MOVQ XMM8,RAX   66 4c 0f 6e c0  (5)  → 19
    const expected_imm = inst.encMovImm64Q(.rax, bits);
    try testing.expectEqualSlices(u8, expected_imm.slice(), out.bytes[4 .. 4 + expected_imm.len]);
    const expected_movq = inst.encMovqXmmFromR64(.xmm8, .rax);
    try testing.expectEqualSlices(u8, expected_movq.slice(), out.bytes[14 .. 14 + expected_movq.len]);
}

test "compile: f32.add — MOVAPS XMM10,XMM8 + ADDSS XMM10,XMM9" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // FP slots 0,1,2 → XMM8, XMM9, XMM10.
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Body layout (4-byte prologue):
    //   [4..14]  f32.const 0x3F800000 (10 bytes: MOV EAX + MOVD XMM8)
    //   [14..24] f32.const 0x40000000 (10 bytes: MOV EAX + MOVD XMM9)
    //   [24..28] MOVAPS XMM10, XMM8   (4 bytes)
    //   [28..33] ADDSS XMM10, XMM9    (5 bytes)
    const expected_movaps = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[24 .. 24 + expected_movaps.len]);
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[28 .. 28 + expected_addss.len]);
}

test "compile: f64.mul — MOVAPS XMM10,XMM8 + MULSD XMM10,XMM9" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0 = 0x3FF0000000000000 split low/high.
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    // 2.0 = 0x4000000000000000 split low/high.
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.mul" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Body layout (4-byte prologue):
    //   [4..19]  f64.const 1.0 (15 bytes: MOVABS RAX + MOVQ XMM8,RAX)
    //   [19..34] f64.const 2.0 (15 bytes)
    //   [34..38] MOVAPS XMM10, XMM8 (4 bytes)
    //   [38..43] MULSD XMM10, XMM9  (5 bytes)
    const expected_movaps = inst.encMovapsXmmXmm(.xmm10, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[34 .. 34 + expected_movaps.len]);
    const expected_mulsd = inst.encSseScalarBinary(.f64, 0x59, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_mulsd.slice(), out.bytes[38 .. 38 + expected_mulsd.len]);
}

test "compile: f64.promote_f32 — CVTSS2SD XMM9, XMM8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.promote_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]: CVTSS2SD XMM9, XMM8 at [14..19].
    const expected = inst.encSseScalarBinary(.f32, 0x5A, .xmm9, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[14 .. 14 + expected.len]);
}

test "compile: i32.reinterpret_f32 — MOVD R10D, XMM8 (XMM→GPR bit-cast)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.reinterpret_f32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // FP slot 0 → XMM8; result GPR slot 0 → R10.
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]: MOVD R10D, XMM8 at [14..19].
    const expected = inst.encMovdR32FromXmm(.r10, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[14 .. 14 + expected.len]);
}

test "compile: f32.reinterpret_i32 — MOVD XMM8, R10D (GPR→XMM bit-cast)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.reinterpret_i32" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 → R10; FP slot 0 → XMM8.
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After i32.const at [4..10] (6 bytes for R10): MOVD XMM8, R10D at [10..15].
    const expected = inst.encMovdXmmFromR32(.xmm8, .r10);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[10 .. 10 + expected.len]);
}

test "compile: f32.load — emit MOVSS xmm_dst, [rax + rdx] after eff-addr/bounds-check" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.load", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 (idx) → R10; FP slot 0 (result) → XMM8.
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Verify the f32.load handler emits MOVSS XMM8, [RAX + RDX]
    // somewhere in the byte stream after the bounds prologue.
    const expected = inst.encMovssMovsdMemBaseIdx(.f32, false, .xmm8, .rax, .rdx);
    try testing.expect(std.mem.find(u8, out.bytes, expected.slice()) != null);
}

test "compile: f64.store — emit MOVSD [rax+rdx], xmm_src + bounds prologue with size=8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // i32.const 0 (idx) ; f64.const 1.0 (val) ; f64.store 0 ; end
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.store", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 (idx) → R10; FP slot 1 (val) → XMM9.
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Verify the f64.store emits MOVSD [RAX+RDX], XMM9.
    const expected = inst.encMovssMovsdMemBaseIdx(.f64, true, .xmm9, .rax, .rdx);
    try testing.expect(std.mem.find(u8, out.bytes, expected.slice()) != null);
    // Verify the LEA bounds-check uses access_size=8 (the disp8
    // immediate in encLeaR64BaseDisp8 is the access_size byte).
    // Search for an LEA that has 8 as its disp byte; rough check
    // by looking for the LEA opcode + ModRM + disp8=0x08 sequence.
    // (The encoder is encLeaR64BaseDisp8(.rcx, .rdx, 8).)
    const expected_lea = inst.encLeaR64BaseDisp8(.rcx, .rdx, 8);
    try testing.expect(std.mem.find(u8, out.bytes, expected_lea.slice()) != null);
}

test "compile: i32.trunc_f32_u — Wasm 1.0 trapping unsigned via .q-trick" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const neg_one = inst.encMovImm32W(.rax, 0xBF800000);
    const upper = inst.encMovImm32W(.rax, 0x4F800000);
    const cvt = inst.encCvttScalar2Int(.f32, true, .r10, .xmm8);
    try testing.expect(std.mem.find(u8, out.bytes, neg_one.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, cvt.slice()) != null);
}

test "compile: i64.trunc_f64_u — Wasm 1.0 trapping with 2^63 split path" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_f64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    const neg_one = inst.encMovImm64Q(.rax, 0xBFF0000000000000);
    const upper = inst.encMovImm64Q(.rax, 0x43F0000000000000);
    const split = inst.encMovImm64Q(.rax, 0x43E0000000000000);
    const subss = inst.encSseScalarBinary(.f64, 0x5C, .xmm6, .xmm7);
    const sign = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expect(std.mem.find(u8, out.bytes, neg_one.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, split.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, subss.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, sign.slice()) != null);
}

test "compile: i32.trunc_f32_s — Wasm 1.0 trapping; NaN/upper/lower → bounds_fixups" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Verify presence of the 3 thresholds + CVTTSS2SI in the
    // emitted byte stream (full layout asserted via opcode+
    // boundary checks rather than every offset).
    const upper = inst.encMovImm32W(.rax, 0x4F000000); // 2^31
    const lower = inst.encMovImm32W(.rax, 0xCF000000); // -2^31
    const cvt = inst.encCvttScalar2Int(.f32, false, .r10, .xmm8);
    try testing.expect(std.mem.find(u8, out.bytes, upper.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, lower.slice()) != null);
    try testing.expect(std.mem.find(u8, out.bytes, cvt.slice()) != null);
}

test "compile: i64.trunc_sat_f32_u — 2^63 split path with SUBSS + sign-bit OR" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Verify a few key encoder outputs are present (full byte
    // sequence is too long to assert exhaustively).
    // Find threshold MOV (0x5F800000 for 2^64 f32) and the SUBSS
    // op in the high path.
    const threshold_max = inst.encMovImm32W(.rax, 0x5F800000);
    const threshold_split = inst.encMovImm32W(.rax, 0x5F000000);
    // Also verify SUBSS XMM6, XMM7 in the high path.
    const subss = inst.encSseScalarBinary(.f32, 0x5C, .xmm6, .xmm7);
    // OR R10, RCX (full 64-bit) for the sign-bit restore.
    const or_q = inst.encOrRR(.q, .r10, .rcx);
    // MOVABS R10, UINT64_MAX in the max path.
    const max_mov = inst.encMovImm64Q(.r10, 0xFFFFFFFFFFFFFFFF);
    const bytes = out.bytes;
    try testing.expect(std.mem.find(u8, bytes, threshold_max.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, threshold_split.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, subss.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, or_q.slice()) != null);
    try testing.expect(std.mem.find(u8, bytes, max_mov.slice()) != null);
}

test "compile: i32.trunc_sat_f32_u — UCOMI/JP + clamp paths + CVTTSS2SI .q form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]:
    //   [14..18] UCOMISS XMM8, XMM8     (4 bytes; REX.R+B)
    //   [18..24] JP rel32 zero_path     (6 bytes)
    //   [24..27] XORPS XMM7, XMM7       (3 bytes; no prefix, no REX)
    //   [27..31] UCOMISS XMM8, XMM7     (4 bytes; REX.R only)
    //   [31..37] JBE rel32 zero_path    (6 bytes)
    //   [37..42] MOV EAX, 0x4F800000    (5 bytes; no REX)
    //   [42..46] MOVD XMM7, EAX         (4 bytes; no REX)
    //   [46..50] UCOMISS XMM8, XMM7     (4 bytes)
    //   [50..56] JAE rel32 max_path     (6 bytes)
    //   [56..61] CVTTSS2SI R10, XMM8 .q (5 bytes)
    //   [61..66] JMP rel32 done         (5 bytes)
    //   zero_path at 66
    const expected_xorps = inst.encSsePackedBinary(.f32, 0x57, .xmm7, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorps.slice(), out.bytes[24 .. 24 + expected_xorps.len]);
    const expected_thresh = inst.encMovImm32W(.rax, 0x4F800000);
    try testing.expectEqualSlices(u8, expected_thresh.slice(), out.bytes[37 .. 37 + expected_thresh.len]);
    const expected_cvt = inst.encCvttScalar2Int(.f32, true, .r10, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[56 .. 56 + expected_cvt.len]);
    // JP/JBE/JAE rel32 opcode bytes (disps patched at end-of-emit).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[18]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[19]);
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[31]);
    try testing.expectEqual(@as(u8, 0x86), out.bytes[32]); // Jcc.be = 6
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[50]);
    try testing.expectEqual(@as(u8, 0x83), out.bytes[51]); // Jcc.ae = 3
}

test "compile: i32.trunc_sat_f32_s — CVTTSS2SI + CMP INT_MIN + branch saturation" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.trunc_sat_f32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // FP slot 0 → XMM8; result GPR slot 0 → R10.
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]:
    //   [14..19] CVTTSS2SI R10D, XMM8     (5 bytes; F3 + REX + 0F + 2C + ModRM)
    //   [19..26] CMP R10D, 0x80000000    (7 bytes; REX.B + 81 + ModRM + imm32)
    //   [26..32] JNE rel32 (placeholder) (6 bytes)
    //   [32..36] UCOMISS XMM8, XMM8       (4 bytes)
    //   [36..42] JP rel32 nan_path        (6 bytes)
    //   [42..46] XORPS XMM7, XMM7         (4 bytes; no prefix, no REX since xmm7<xmm8)
    //   [46..50] UCOMISS XMM8, XMM7       (4 bytes; REX for xmm8 only)
    const expected_cvt = inst.encCvttScalar2Int(.f32, false, .r10, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[14 .. 14 + expected_cvt.len]);
    const expected_cmp = inst.encCmpRImm32(.r10, 0x80000000);
    try testing.expectEqualSlices(u8, expected_cmp.slice(), out.bytes[19 .. 19 + expected_cmp.len]);
    // JNE / JP / JBE rel32 opcode bytes (disps patched at end-of-emit).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[26]);
    try testing.expectEqual(@as(u8, 0x85), out.bytes[27]); // Jcc.ne = 5
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[36]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[37]); // Jcc.p = A
    const expected_xorps = inst.encSsePackedBinary(.f32, 0x57, .xmm7, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorps.slice(), out.bytes[42 .. 42 + expected_xorps.len]);
}

test "compile: i64.trunc_sat_f64_s — CVTTSD2SI .q + i64 sentinel via MOVABS+CMP r/r" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.trunc_sat_f64_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f64.const at [4..19]:
    //   [19..24]  CVTTSD2SI R10, XMM8 (5 bytes; F2 + REX.W+R+B + 0F + 2C + ModRM 0xD0)
    //   [24..34]  MOVABS RCX, INT_MIN_i64 (10 bytes)
    //   [34..37]  CMP R10, RCX (3 bytes; REX.W+R + 39 + ModRM)
    const expected_cvt = inst.encCvttScalar2Int(.f64, true, .r10, .xmm8);
    try testing.expectEqualSlices(u8, expected_cvt.slice(), out.bytes[19 .. 19 + expected_cvt.len]);
    const expected_min = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_min.slice(), out.bytes[24 .. 24 + expected_min.len]);
    const expected_cmp = inst.encCmpRR(.q, .r10, .rcx);
    try testing.expectEqualSlices(u8, expected_cmp.slice(), out.bytes[34 .. 34 + expected_cmp.len]);
}

test "compile: f32.convert_i32_u — CVTSI2SS XMM8, R10 (REX.W on i32 src for zero-extend trick)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFFFFFFFF }); // u32 max
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // i32.const 0xFFFFFFFF at [4..10]; CVTSI2SS XMM8, R10 (i64 form) at [10..15].
    const expected = inst.encCvtsi2Scalar(.f32, true, .xmm8, .r10);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[10 .. 10 + expected.len]);
}

test "compile: f32.convert_i64_u — branch-based slow-path emit" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // i32.const placeholder for i64 source (synthetic; emit doesn't validate types).
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i64_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // i32.const at [4..10]. Then:
    //   [10..13] TEST R10, R10            (3 bytes; REX.W + REX.R + REX.B = 4D + 85 + D2)
    //   [13..19] JS rel32 placeholder     (6 bytes)
    //   [19..24] CVTSI2SS XMM8, R10 i64   (5 bytes; F3 + REX.W+R+B + 0F 2A C2)
    //   [24..29] JMP rel32 to end         (5 bytes)
    //   slow_path at 29:
    const expected_test = inst.encTestRR(.q, .r10, .r10);
    try testing.expectEqualSlices(u8, expected_test.slice(), out.bytes[10 .. 10 + expected_test.len]);
    // JS rel32 opcode bytes (disp patched at end-of-emit).
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[13]);
    try testing.expectEqual(@as(u8, 0x88), out.bytes[14]); // Jcc.s = 8
    const expected_pos_cvt = inst.encCvtsi2Scalar(.f32, true, .xmm8, .r10);
    try testing.expectEqualSlices(u8, expected_pos_cvt.slice(), out.bytes[19 .. 19 + expected_pos_cvt.len]);
    // JMP rel32 opcode at 24.
    try testing.expectEqual(@as(u8, 0xE9), out.bytes[24]);
    // Slow path starts at 29: MOV RAX, R10 (3 bytes; REX.W+R = 4C 89 D0)
    const expected_mov_rax = inst.encMovRR(.q, .rax, .r10);
    try testing.expectEqualSlices(u8, expected_mov_rax.slice(), out.bytes[29 .. 29 + expected_mov_rax.len]);
    // After slow path: MOV RAX (3) + SHR RAX (4) + MOV RCX (3) + AND RCX (4) + OR (3) +
    //                  CVTSI2SS (5) + ADDSS dst,dst (5) = 27 bytes. Slow path ends at 29+27=56.
    // Verify ADDSS is the final slow-path insn (5 bytes).
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm8, .xmm8);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[51 .. 51 + expected_addss.len]);
    // Verify JS rel32 disp points at slow_path (29).
    const js_disp = std.mem.readInt(i32, out.bytes[15..19], .little);
    try testing.expectEqual(@as(i32, 29 - 13 - 6), js_disp);
    // Verify JMP rel32 disp points at end (56).
    const jmp_disp = std.mem.readInt(i32, out.bytes[25..29], .little);
    try testing.expectEqual(@as(i32, 56 - 24 - 5), jmp_disp);
}

test "compile: f32.convert_i32_s — CVTSI2SS XMM8, R10D" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.convert_i32_s" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After i32.const at [4..10]: CVTSI2SS XMM8, R10D at [10..15].
    const expected = inst.encCvtsi2Scalar(.f32, false, .xmm8, .r10);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[10 .. 10 + expected.len]);
}

test "compile: f32.min — branch-based emit (UCOMISS + JP/JE + 3 paths)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.min" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Body offsets after 2× f32.const (10+10=20 bytes) at 4..24:
    //   [24..28] UCOMISS XMM8, XMM9     (4 bytes)
    //   [28..34] JP rel32 (placeholder) (6 bytes)
    //   [34..40] JE rel32 (placeholder) (6 bytes)
    //   [40..44] MOVAPS XMM10, XMM8     (4 bytes)
    //   [44..49] MINSS XMM10, XMM9      (5 bytes; F3 + REX + 0F + 5D + ModRM)
    //   [49..54] JMP rel32              (5 bytes)
    //   [54..58] MOVAPS XMM10, XMM8     (eq path)
    //   [58..62] ORPS XMM10, XMM9       (4 bytes)
    //   [62..67] JMP rel32              (5 bytes)
    //   [67..71] MOVAPS XMM10, XMM8     (nan path)
    //   [71..76] ADDSS XMM10, XMM9      (5 bytes)
    const expected_ucomi = inst.encUcomiss(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomi.slice(), out.bytes[24 .. 24 + expected_ucomi.len]);
    // JP / JE rel32 disps are patched; assert opcode bytes only.
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[28]);
    try testing.expectEqual(@as(u8, 0x8A), out.bytes[29]); // Jcc.p = A
    try testing.expectEqual(@as(u8, 0x0F), out.bytes[34]);
    try testing.expectEqual(@as(u8, 0x84), out.bytes[35]); // Jcc.e = 4
    const expected_minss = inst.encSseScalarBinary(.f32, 0x5D, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_minss.slice(), out.bytes[44 .. 44 + expected_minss.len]);
    const expected_orps = inst.encSsePackedBinary(.f32, 0x56, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_orps.slice(), out.bytes[58 .. 58 + expected_orps.len]);
    const expected_addss = inst.encSseScalarBinary(.f32, 0x58, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_addss.slice(), out.bytes[71 .. 71 + expected_addss.len]);

    // Verify JP rel32 disp is patched correctly to point at nan_path (byte 67).
    const jp_disp = std.mem.readInt(i32, out.bytes[30..34], .little);
    try testing.expectEqual(@as(i32, 67 - 28 - 6), jp_disp);
    // Verify JE rel32 disp points at eq_path (byte 54).
    const je_disp = std.mem.readInt(i32, out.bytes[36..40], .little);
    try testing.expectEqual(@as(i32, 54 - 34 - 6), je_disp);
}

test "compile: f64.max — eq path uses ANDPD, common uses MAXSD" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.max" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f64.const (15+15=30 bytes) at body 4..34:
    //   [34..39] UCOMISD XMM8, XMM9   (5 bytes: 66 prefix + REX)
    //   [39..45] JP rel32             (6 bytes)
    //   [45..51] JE rel32             (6 bytes)
    //   [51..55] MOVAPS XMM10, XMM8   (4 bytes; common path)
    //   [55..60] MAXSD XMM10, XMM9    (5 bytes; F2 + REX + 0F + 5F + ModRM)
    //   [60..65] JMP rel32 (common)
    //   [65..69] MOVAPS XMM10, XMM8   (eq path)
    //   [69..74] ANDPD XMM10, XMM9    (5 bytes; 66 + REX + 0F + 54 + ModRM)
    const expected_ucomi = inst.encUcomisd(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomi.slice(), out.bytes[34 .. 34 + expected_ucomi.len]);
    const expected_maxsd = inst.encSseScalarBinary(.f64, 0x5F, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_maxsd.slice(), out.bytes[55 .. 55 + expected_maxsd.len]);
    const expected_andpd = inst.encSsePackedBinary(.f64, 0x54, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, expected_andpd.slice(), out.bytes[69 .. 69 + expected_andpd.len]);
}

test "compile: f32.copysign — bit-twiddle via RAX/RDX/RCX scratches" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40400000 }); // 3.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xBF800000 }); // -1.0
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f32.const (10+10=20 bytes) at body offset 4..24:
    //   [24..29] MOVD EAX, XMM8        (5 bytes)
    //   [29..34] MOVD EDX, XMM9        (5 bytes)
    //   [34..39] MOV ECX, 0x7FFFFFFF   (5 bytes)
    //   [39..41] AND EAX, ECX          (2 bytes)
    //   [41..46] MOV ECX, 0x80000000   (5 bytes)
    //   [46..48] AND EDX, ECX          (2 bytes)
    //   [48..50] OR EAX, EDX           (2 bytes)
    //   [50..55] MOVD XMM10, EAX       (5 bytes)
    const expected_movd_lhs = inst.encMovdR32FromXmm(.rax, .xmm8);
    try testing.expectEqualSlices(u8, expected_movd_lhs.slice(), out.bytes[24 .. 24 + expected_movd_lhs.len]);
    const expected_mag_mask = inst.encMovImm32W(.rcx, 0x7FFFFFFF);
    try testing.expectEqualSlices(u8, expected_mag_mask.slice(), out.bytes[34 .. 34 + expected_mag_mask.len]);
    const expected_or = inst.encOrRR(.d, .rax, .rdx);
    try testing.expectEqualSlices(u8, expected_or.slice(), out.bytes[48 .. 48 + expected_or.len]);
    const expected_final_movd = inst.encMovdXmmFromR32(.xmm10, .rax);
    try testing.expectEqualSlices(u8, expected_final_movd.slice(), out.bytes[50 .. 50 + expected_final_movd.len]);
}

test "compile: f64.copysign — same shape with .q widths and MOVABS masks" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40080000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0xBFF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.copysign" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 2 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 3 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f64.const (15+15=30 bytes) at body offset 4..34:
    //   [34..39] MOVQ RAX, XMM8        (5 bytes; 66 + REX.W + REX.R + ...)
    //   [39..44] MOVQ RDX, XMM9
    //   [44..54] MOVABS RCX, 0x7FFF... (10 bytes)
    //   [54..57] AND RAX, RCX          (3 bytes; REX.W)
    //   [57..67] MOVABS RCX, 0x8000... (10 bytes)
    //   [67..70] AND RDX, RCX
    //   [70..73] OR RAX, RDX
    //   [73..78] MOVQ XMM10, RAX
    const expected_movq_lhs = inst.encMovqR64FromXmm(.rax, .xmm8);
    try testing.expectEqualSlices(u8, expected_movq_lhs.slice(), out.bytes[34 .. 34 + expected_movq_lhs.len]);
    const expected_mag = inst.encMovImm64Q(.rcx, 0x7FFFFFFFFFFFFFFF);
    try testing.expectEqualSlices(u8, expected_mag.slice(), out.bytes[44 .. 44 + expected_mag.len]);
    const expected_sign = inst.encMovImm64Q(.rcx, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_sign.slice(), out.bytes[57 .. 57 + expected_sign.len]);
    const expected_movq_dst = inst.encMovqXmmFromR64(.xmm10, .rax);
    try testing.expectEqualSlices(u8, expected_movq_dst.slice(), out.bytes[73 .. 73 + expected_movq_dst.len]);
}

test "compile: f32.sqrt — SQRTSS XMM9, XMM8" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40800000 }); // 4.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.sqrt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]: SQRTSS XMM9, XMM8 at [14..19].
    const expected = inst.encSseScalarBinary(.f32, 0x51, .xmm9, .xmm8);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[14 .. 14 + expected.len]);
}

test "compile: f64.ceil — ROUNDSD XMM9, XMM8, mode=2" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF80000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.ceil" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f64.const at [4..19]: ROUNDSD XMM9, XMM8, 2 at [19..26].
    const expected = inst.encRoundsd(.xmm9, .xmm8, 2);
    try testing.expectEqualSlices(u8, expected.slice(), out.bytes[19 .. 19 + expected.len]);
}

test "compile: f32.abs — mask materialisation + MOVAPS + ANDPS" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0xBF800000 }); // -1.0f
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.abs" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f32.const at [4..14]:
    //   [14..19] MOV EAX, 0x7FFFFFFF (5 bytes)
    //   [19..23] MOVD XMM7, EAX      (4 bytes; no REX since xmm7 < xmm8 and rax < r8)
    //   [23..27] MOVAPS XMM9, XMM8   (4 bytes; REX.R+REX.B)
    //   [27..31] ANDPS XMM9, XMM7    (4 bytes; REX.R only since xmm7 < xmm8)
    const expected_mask = inst.encMovImm32W(.rax, 0x7FFFFFFF);
    try testing.expectEqualSlices(u8, expected_mask.slice(), out.bytes[14 .. 14 + expected_mask.len]);
    const expected_andps = inst.encSsePackedBinary(.f32, 0x54, .xmm9, .xmm7);
    try testing.expectEqualSlices(u8, expected_andps.slice(), out.bytes[27 .. 27 + expected_andps.len]);
}

test "compile: f64.neg — XORPD with sign-bit mask" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.neg" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After f64.const at [4..19]:
    //   [19..29] MOVABS RAX, 0x80...0 (10 bytes)
    //   [29..34] MOVQ XMM7, RAX       (5 bytes)
    //   [34..38] MOVAPS XMM9, XMM8    (4 bytes)
    //   [38..43] XORPD XMM9, XMM7     (5 bytes; 66 prefix + REX.R + 0F 57 + ModRM)
    const expected_mask = inst.encMovImm64Q(.rax, 0x8000000000000000);
    try testing.expectEqualSlices(u8, expected_mask.slice(), out.bytes[19 .. 19 + expected_mask.len]);
    const expected_xorpd = inst.encSsePackedBinary(.f64, 0x57, .xmm9, .xmm7);
    try testing.expectEqualSlices(u8, expected_xorpd.slice(), out.bytes[38 .. 38 + expected_xorpd.len]);
}

test "compile: f32.lt — UCOMISS swapped + SETA + MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.lt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Slots 0,1 → XMM8, XMM9; slot 2 (i32 result) → R10.
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f32.const (10+10=20 bytes) at body offset 4..24:
    //   [24..28] UCOMISS XMM9, XMM8 (swap; 4 bytes: REX 45 0F 2E C8)
    //   [28..32] SETA R10B (4 bytes: 41 0F 97 C2)
    //   [32..36] MOVZX R10D, R10B (4 bytes: 45 0F B6 D2)
    const expected_ucomiss = inst.encUcomiss(.xmm9, .xmm8); // swapped: a=rhs, b=lhs
    try testing.expectEqualSlices(u8, expected_ucomiss.slice(), out.bytes[24 .. 24 + expected_ucomiss.len]);
    const expected_seta = inst.encSetccR(.a, .r10);
    try testing.expectEqualSlices(u8, expected_seta.slice(), out.bytes[28 .. 28 + expected_seta.len]);
}

test "compile: f32.eq — UCOMISS + SETNP/SETE + AND combine" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.eq" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // After 2× f32.const (20 bytes) at body offset 4..24:
    //   [24..28] UCOMISS XMM8, XMM9   (4 bytes; no swap for eq)
    //   [28..32] SETNP AL             (4 bytes: 40 0F 9B C0)
    //   [32..36] MOVZX EAX, AL        (4 bytes: 40 0F B6 C0)
    //   [36..40] SETE R10B            (4 bytes: 41 0F 94 C2)
    //   [40..44] MOVZX R10D, R10B
    //   [44..47] AND R10D, EAX        (3 bytes: 44 21 c2)
    const expected_ucomiss = inst.encUcomiss(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomiss.slice(), out.bytes[24 .. 24 + expected_ucomiss.len]);
    const expected_setnp = inst.encSetccR(.np, .rax);
    try testing.expectEqualSlices(u8, expected_setnp.slice(), out.bytes[28 .. 28 + expected_setnp.len]);
    const expected_and = inst.encAndRR(.d, .r10, .rax);
    try testing.expectEqualSlices(u8, expected_and.slice(), out.bytes[44 .. 44 + expected_and.len]);
}

test "compile: f64.gt — UCOMISD + SETA + MOVZX" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x40000000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0, .extra = 0x3FF00000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f64.gt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // 2× f64.const = 30 bytes at [4..34]. Then at [34..]:
    //   UCOMISD XMM8, XMM9 (5 bytes; 66 prefix + REX)
    const expected_ucomisd = inst.encUcomisd(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, expected_ucomisd.slice(), out.bytes[34 .. 34 + expected_ucomisd.len]);
}

test "compile: f32.add stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.add" }); // missing rhs
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: call_indirect — out-of-range type_idx → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"call_indirect", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: call N — out-of-range callee_idx → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    const func_sigs = [_]zir.FuncType{sig}; // only idx 0 exists
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{} };
    const slots = [_]u8{};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &func_sigs, &.{}));
}

test "compile: i32.wrap_i64 with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.wrap_i64" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

test "compile: i32.add with stack underflow → AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" }); // missing 2nd operand
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 1 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}

// FP / i64 -aware function-level `end` return marshal (D-032).
// `f32.const` / `f64.const` push their value onto an XMM slot;
// `i64.extend_i32_u` pushes a full 64-bit GPR result. The
// pre-fix end handler emitted `MOV EAX, r32(slotToReg(slot))`
// for *every* result type, which (a) read the wrong physical
// reg for FP results (fpSlotToReg ≠ slotToReg for the same
// slot id) and (b) truncated i64 to i32 by using .d width.
// The fix dispatches on `func.sig.results[0]`:
//   .i32/.funcref/.externref → MOV EAX, src   (.d, current)
//   .i64                     → MOV RAX, src   (.q, full width)
//   .f32/.f64                → MOVAPS XMM0, src_xmm
//   .v128                    → UnsupportedOp (deferred)
// MOVAPS works for both f32 and f64: x86_64 returns FP values in
// XMM0 with full register width, so a single 128-bit register
// move is sufficient (vs ARM64's FMOV S0/D0 size-discriminated
// move). See ARM64 reference at arm64/emit.zig:475-503.

test "compile: f32.const → end emits MOVAPS XMM0, XMM8 (FP-aware return marshal)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f32} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0}; // FP slot 0 → XMM8.
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout (uses_runtime_ptr = false, frame_bytes = 0):
    //   [0..4]   prologue: PUSH RBP ; MOV RBP, RSP
    //   [4..14]  f32.const: MOV EAX, bits ; MOVD XMM8, EAX
    //   [14..18] end FP marshal: MOVAPS XMM0, XMM8 (4 bytes)
    //   [18..20] epilogue: POP RBP ; RET
    const expected_movaps = inst.encMovapsXmmXmm(.xmm0, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[14 .. 14 + expected_movaps.len]);
    try testing.expectEqual(@as(usize, 20), out.bytes.len);
}

test "compile: f64.const → end emits MOVAPS XMM0, XMM8 (same MOVAPS works for f64)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.f64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const bits: u64 = 0x3FF0000000000000; // 1.0
    try f.instrs.append(testing.allocator, .{
        .op = .@"f64.const",
        .payload = @truncate(bits),
        .extra = @truncate(bits >> 32),
    });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout:
    //   [0..4]   prologue
    //   [4..19]  f64.const: MOVABS RAX, bits ; MOVQ XMM8, RAX
    //   [19..23] end FP marshal: MOVAPS XMM0, XMM8
    //   [23..25] epilogue
    const expected_movaps = inst.encMovapsXmmXmm(.xmm0, .xmm8);
    try testing.expectEqualSlices(u8, expected_movaps.slice(), out.bytes[19 .. 19 + expected_movaps.len]);
    try testing.expectEqual(@as(usize, 25), out.bytes.len);
}

test "compile: i64-result end emits MOV RAX, src (.q full width avoids truncation)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.i64} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x12345678 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.extend_i32_u" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    // GPR slot 0 → R10. Both vregs share slot id 0 (sub-7.5d shape).
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc, &.{}, &.{});
    defer deinit(testing.allocator, out);
    // Layout:
    //   [0..4]   prologue
    //   [4..10]  i32.const: MOV R10D, imm32 (REX.B + opcode + 4-byte imm = 6 bytes)
    //   [10..13] i64.extend_i32_u: MOV R10D, R10D (.d, 3 bytes)
    //   [13..16] end i64 marshal: MOV RAX, R10 (.q, 3 bytes)
    //   [16..18] epilogue
    const expected_movrr = inst.encMovRR(.q, .rax, .r10);
    try testing.expectEqualSlices(u8, expected_movrr.slice(), out.bytes[13 .. 13 + expected_movrr.len]);
    try testing.expectEqual(@as(usize, 18), out.bytes.len);
}

test "compile: v128-result end → UnsupportedOp (v128 marshalling deferred)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{.v128} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // v128 producer ops are not yet implemented; reuse f32.const
    // to push an FP slot whose result_kind discriminator forces
    // the end handler down the v128 arm. The test asserts the
    // end handler refuses unknown-width returns rather than
    // silently emitting truncating MOV EAX bytes.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, alloc, &.{}, &.{}));
}
