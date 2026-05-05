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
const trace = @import("../../../diagnostic/trace.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;

/// Errors raised by the x86_64 emit pass. Mirrors arm64's set
/// so the §9.7 / 7.11 differential can match shapes; new
/// per-arch errors get added here as their consumers land.
pub const Error = error{
    AllocationMissing,
    UnsupportedOp,
    SlotOverflow,
    OutOfMemory,
};

/// Pending `CALL rel32` site requiring linker patch. Shape
/// mirrors arm64's CallFixup so the post-emit linker can reuse
/// the same fixup-record contract.
pub const CallFixup = struct {
    byte_offset: u32,
    target_func_idx: u32,
};

/// Why a Label was pushed on the control stack. block / loop /
/// if_then / else_open mirror arm64's LabelKind for parity at
/// the §9.7 / 7.11 three-way differential.
const LabelKind = enum { block, loop, if_then, else_open };

/// Forward-jump fixup awaiting target resolution. `byte_offset`
/// is the position of the JMP/Jcc instruction's first byte;
/// `insn_size` is 5 (JMP rel32) or 6 (Jcc rel32). `emitEndIntra`
/// patches the disp32 field via `inst.patchRel32`.
const Fixup = struct {
    byte_offset: u32,
    insn_size: u8,
};

/// One frame on the per-function control stack.
///   target_byte_offset — for `.loop`, the byte offset of the
///       loop entry. For `.block` / `.if_then` / `.else_open`,
///       undefined until `end`.
///   pending — branch fixups awaiting target resolution.
///   if_skip_byte — when `.if_then`, the byte offset of the
///       JE that skips the then-body. Patched at `else` (to
///       else-body start) or at `end` (to end of if). Cleared
///       when transitioning to `.else_open`.
///   merge_top_vreg — D-027 fix mirror (per ADR-0014 §6.K.5):
///       for `(if (result T))` blocks, the then arm's result
///       vreg is captured at `else`; the else arm's result is
///       MOVed into this vreg's register at the if-frame's
///       `end` so both paths converge on the same physical reg.
///       Null for blocks without arity OR when no `else` was
///       emitted.
const Label = struct {
    kind: LabelKind,
    target_byte_offset: u32,
    pending: std.ArrayList(Fixup),
    if_skip_byte: ?u32 = null,
    merge_top_vreg: ?u32 = null,
};

pub const EmitOutput = struct {
    bytes: []u8,
    n_slots: u8,
    call_fixups: []CallFixup,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
    if (out.call_fixups.len != 0) allocator.free(out.call_fixups);
}

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
    _ = func_sigs;
    _ = module_types;
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
                .@"global.get", .@"global.set",
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
        try buf.appendSlice(allocator, inst.encMovRR(.q, .r15, .rdi).slice());
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
            => try emitI32Binary(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.eq", .@"i32.ne",
            .@"i32.lt_s", .@"i32.lt_u", .@"i32.gt_s", .@"i32.gt_u",
            .@"i32.le_s", .@"i32.le_u", .@"i32.ge_s", .@"i32.ge_u",
            => try emitI32Compare(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.eqz" => try emitI32Eqz(allocator, &buf, alloc, &pushed_vregs, &next_vreg),
            .@"i32.shl", .@"i32.shr_s", .@"i32.shr_u",
            .@"i32.rotl", .@"i32.rotr",
            => try emitI32Shift(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.clz", .@"i32.ctz", .@"i32.popcnt",
            => try emitI32Bitcount(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"i32.wrap_i64", .@"i64.extend_i32_u", .@"i64.extend_i32_s",
            => try emitConvertWidth(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.op),
            .@"local.get" => try emitLocalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, num_locals, uses_runtime_ptr, ins.payload),
            .@"local.set" => try emitLocalSet(allocator, &buf, alloc, &pushed_vregs, num_locals, uses_runtime_ptr, ins.payload),
            .@"local.tee" => try emitLocalTee(allocator, &buf, alloc, &pushed_vregs, num_locals, uses_runtime_ptr, ins.payload),
            .@"i32.load", .@"i32.load8_s", .@"i32.load8_u",
            .@"i32.load16_s", .@"i32.load16_u",
            .@"i32.store", .@"i32.store8", .@"i32.store16",
            => try emitMemOp(allocator, &buf, alloc, &pushed_vregs, &next_vreg, &bounds_fixups, ins.op, ins.payload, func.func_idx),
            .@"global.get" => try emitI32GlobalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, ins.payload),
            .@"global.set" => try emitI32GlobalSet(allocator, &buf, alloc, &pushed_vregs, ins.payload),
            .@"block" => try emitBlock(allocator, &labels),
            .@"loop" => try emitLoop(allocator, &buf, &labels),
            .@"br" => try emitBr(allocator, &buf, &labels, ins.payload),
            .@"br_if" => try emitBrIf(allocator, &buf, alloc, &pushed_vregs, &labels, ins.payload),
            .@"br_table" => try emitBrTable(allocator, &buf, func, alloc, &pushed_vregs, &labels, ins.payload, ins.extra),
            .@"if" => try emitIf(allocator, &buf, alloc, &pushed_vregs, &labels),
            .@"else" => try emitElse(allocator, &buf, &pushed_vregs, &labels),
            .@"end" => {
                // Two distinct forms (mirrors arm64/emit.zig):
                // (A) Intra-function `end`: pops a label, patches
                //     forward fixups (block) / no-op for loop.
                // (B) Function-level `end`: marshals result, runs
                //     epilogue, returns. Disambiguation: empty
                //     label stack → form (B).
                if (labels.items.len > 0) {
                    try emitEndIntra(allocator, &buf, &pushed_vregs, alloc, &labels);
                    continue;
                }
                if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
                    const top = pushed_vregs.items[pushed_vregs.items.len - 1];
                    if (top >= alloc.slots.len) return Error.SlotOverflow;
                    const slot_id = alloc.slots[top];
                    const src = abi.slotToReg(slot_id) orelse return Error.SlotOverflow;
                    if (src != abi.return_gpr) {
                        // MOV EAX, src — Width.d zero-extends to
                        // 64 bits, matching Wasm i32 ABI.
                        try buf.appendSlice(allocator, inst.encMovRR(.d, abi.return_gpr, src).slice());
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
        .call_fixups = &.{},
    };
}

/// Binary i32 ALU handler (add / sub / mul / and / or / xor).
/// Pop rhs + lhs, allocate result vreg, emit MOV dst, lhs ;
/// OP dst, rhs (always-MOV form — the peephole that elides the
/// MOV when dst == lhs lands when regalloc starts reusing slots
/// for in-place updates).
///
/// **Constraint**: dst must not equal rhs (MOV dst, lhs would
/// clobber rhs before OP reads it). With fresh-vreg-per-op
/// allocation this never fires; surfaces as `UnsupportedOp`
/// when the regalloc port needs to handle slot reuse.
fn emitI32Binary(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
    if (dst_r == rhs_r and dst_r != lhs_r) return Error.UnsupportedOp;

    if (dst_r != lhs_r) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, dst_r, lhs_r).slice());
    }
    const enc = switch (op) {
        .@"i32.add" => inst.encAddRR(.d, dst_r, rhs_r),
        .@"i32.sub" => inst.encSubRR(.d, dst_r, rhs_r),
        .@"i32.mul" => inst.encImulRR(.d, dst_r, rhs_r),
        .@"i32.and" => inst.encAndRR(.d, dst_r, rhs_r),
        .@"i32.or"  => inst.encOrRR(.d, dst_r, rhs_r),
        .@"i32.xor" => inst.encXorRR(.d, dst_r, rhs_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());
    try pushed_vregs.append(allocator, result_v);
}

/// i32 compare handler (eq / ne / lt_s / lt_u / gt_s / gt_u /
/// le_s / le_u / ge_s / ge_u — 10 ops). x86_64 pattern:
///
///   CMP lhs, rhs           ; sets EFLAGS based on lhs - rhs
///   SETcc dst_low8         ; writes 0 / 1 to low byte of dst
///   MOVZX dst, dst_low8    ; zero-extend to 32 bits
///
/// Wasm result type i32 (0 or 1). Total ~10 bytes per compare
/// (3 instr × 3-4 bytes each with REX). Signed vs unsigned
/// distinction is the cc code only — operand encoding is
/// identical.
fn emitI32Compare(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    const cc: inst.Cond = switch (op) {
        .@"i32.eq"   => .e,
        .@"i32.ne"   => .ne,
        .@"i32.lt_s" => .l,
        .@"i32.lt_u" => .b,
        .@"i32.gt_s" => .g,
        .@"i32.gt_u" => .a,
        .@"i32.le_s" => .le,
        .@"i32.le_u" => .be,
        .@"i32.ge_s" => .ge,
        .@"i32.ge_u" => .ae,
        else => unreachable,
    };

    try buf.appendSlice(allocator, inst.encCmpRR(.d, lhs_r, rhs_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(cc, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// `i32.eqz` handler — unary "is the operand zero?". Emits
/// TEST src, src ; SETE dst_low8 ; MOVZX dst, dst_low8. Same
/// 3-instr shape as compare; operand reuse means no separate
/// rhs vreg.
fn emitI32Eqz(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    try buf.appendSlice(allocator, inst.encTestRR(.d, src_r, src_r).slice());
    try buf.appendSlice(allocator, inst.encSetccR(.e, dst_r).slice());
    try buf.appendSlice(allocator, inst.encMovzxR32R8(dst_r, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// i32 shift / rotate handler (shl / shr_s / shr_u / rotl / rotr,
/// 5 ops). x86_64 SHL/SHR/SAR/ROL/ROR with variable count
/// require the count in CL (RCX low byte). Emit:
///
///   MOV ECX, rhs       ; (skip if rhs already in RCX — never
///                        the case since RCX is excluded from
///                        the regalloc pool per abi.zig)
///   MOV dst, lhs       ; (skip if dst == lhs)
///   <op> dst, CL       ; D3 / kind
///
/// Wasm shift count is implicit-modulo-(width); x86_64 SHL/SHR
/// also mask the count by (width - 1), so the semantics line up
/// without an extra AND.
///
/// Constraints (caller cannot violate without UnsupportedOp):
/// - dst != RCX: RCX is the count register; would self-clobber.
///   In practice this never fires because abi.allocatable_gprs
///   excludes RCX.
/// - dst != rhs (when dst != lhs): the MOV dst, lhs would clobber
///   rhs before the shift reads CL. Guard mirrors emitI32Binary.
fn emitI32Shift(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const rhs_v = pushed_vregs.pop().?;
    const lhs_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const lhs_r = abi.slotToReg(alloc.slots[lhs_v]) orelse return Error.SlotOverflow;
    const rhs_r = abi.slotToReg(alloc.slots[rhs_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
    if (dst_r == .rcx) return Error.UnsupportedOp;
    if (dst_r == rhs_r and dst_r != lhs_r) return Error.UnsupportedOp;

    // 1. Move shift count into ECX (CL is the low byte).
    if (rhs_r != .rcx) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, .rcx, rhs_r).slice());
    }
    // 2. Materialise lhs into dst (skip if already same reg).
    if (dst_r != lhs_r) {
        try buf.appendSlice(allocator, inst.encMovRR(.d, dst_r, lhs_r).slice());
    }
    // 3. Shift / rotate.
    const kind: inst.ShiftKind = switch (op) {
        .@"i32.shl"   => .shl,
        .@"i32.shr_s" => .sar,
        .@"i32.shr_u" => .shr,
        .@"i32.rotl"  => .rol,
        .@"i32.rotr"  => .ror,
        else => unreachable,
    };
    try buf.appendSlice(allocator, inst.encShiftRCl(.d, kind, dst_r).slice());

    try pushed_vregs.append(allocator, result_v);
}

/// i32 bit-count handler (clz / ctz / popcnt — 3 ops). Direct
/// 1:1 mapping to LZCNT / TZCNT / POPCNT (BMI1 + POPCNT
/// extensions). All three:
/// - Take src in r/m and write dst in reg (operand-role
///   inversion vs the ADD/SUB/CMP family).
/// - Return 32 for input 0 (LZCNT/TZCNT) which matches Wasm
///   spec — the older BSR/BSF would leave dst undefined at 0
///   and would need a fixup; LZCNT/TZCNT exist exactly to
///   provide defined-at-zero semantics.
fn emitI32Bitcount(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    const enc = switch (op) {
        .@"i32.clz"    => inst.encLzcntR32(dst_r, src_r),
        .@"i32.ctz"    => inst.encTzcntR32(dst_r, src_r),
        .@"i32.popcnt" => inst.encPopcntR32(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());

    try pushed_vregs.append(allocator, result_v);
}

/// i32 ↔ i64 width-cross handler — `i32.wrap_i64` and
/// `i64.extend_i32_u` both lower to `MOV r32_dst, r32_src`
/// (the 32-bit write zero-extends the upper half of the
/// destination's 64-bit slot, matching Wasm's value-class
/// representation). `i64.extend_i32_s` lowers to MOVSXD.
/// Mirrors arm64/op_convert.zig's emitWrap32 / emitExtendI32S.
fn emitConvertWidth(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;

    const enc = switch (op) {
        .@"i32.wrap_i64", .@"i64.extend_i32_u" => inst.encMovRR(.d, dst_r, src_r),
        .@"i64.extend_i32_s" => inst.encMovsxdR64R32(dst_r, src_r),
        else => unreachable,
    };
    try buf.appendSlice(allocator, enc.slice());

    try pushed_vregs.append(allocator, result_v);
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

/// `block` — push a forward-resolving label frame. No code
/// emitted; the matching `end` patches all `pending` fixups.
fn emitBlock(allocator: Allocator, labels: *std.ArrayList(Label)) Error!void {
    try labels.append(allocator, .{
        .kind = .block,
        .target_byte_offset = 0,
        .pending = .empty,
    });
}

/// `loop` — push a backward-resolving label frame. Captures
/// the current buf offset as the loop entry; subsequent `br`
/// to this label resolves to a backward JMP with concrete disp.
fn emitLoop(allocator: Allocator, buf: *std.ArrayList(u8), labels: *std.ArrayList(Label)) Error!void {
    try labels.append(allocator, .{
        .kind = .loop,
        .target_byte_offset = @intCast(buf.items.len),
        .pending = .empty,
    });
}

/// `br N` — unconditional branch to label at depth N (0 =
/// innermost). Loop targets resolve immediately to a concrete
/// disp; block targets emit a placeholder JMP rel32 and append
/// a `Fixup` for the matching `end` to patch.
fn emitBr(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    labels: *std.ArrayList(Label),
    depth: u32,
) Error!void {
    if (depth >= labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = labels.items.len - 1 - depth;
    const tgt = &labels.items[tgt_idx];
    const at: u32 = @intCast(buf.items.len);
    if (tgt.kind == .loop) {
        // Backward branch: target known. disp = target - (at + 5).
        const disp: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
            @as(i32, @intCast(at)) - 5;
        try buf.appendSlice(allocator, inst.encJmpRel32(disp).slice());
    } else {
        // Forward branch: emit placeholder; queue fixup.
        try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
        try tgt.pending.append(allocator, .{ .byte_offset = at, .insn_size = 5 });
    }
}

/// Unified handler for x86_64 i32 memory ops (loads + stores
/// + narrowed forms). Mirrors arm64/op_memory.zig:emitMemOp's
/// shape: shared eff-addr / bounds-check prologue, per-op final
/// LDR/STR encoding.
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
/// Per Wasm 1.0 spec (memory.{load,store} 系): trap iff
/// `eff_addr + access_size > mem_limit` where access_size ∈
/// {1, 2, 4, 8}. u64 演算で overflow 不可 (max ≈ 2^33+7).
///
/// RAX/RCX/RDX は regalloc pool 外 (allocatable_caller_saved_
/// scratch_gprs = R10+R11 のみ; RAX/RCX/RDX は scratch 用に reserved)。
/// shifts は RCX を CL として使うが、shift handler と memory handler
/// は同一 op 内で交差しないため、RCX を bounds-check scratch として
/// 使うのは安全。
fn emitMemOp(
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
        .@"i32.store", .@"i32.store8", .@"i32.store16" => true,
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
        .@"i32.load8_s", .@"i32.load8_u", .@"i32.store8" => 1,
        .@"i32.load16_s", .@"i32.load16_u", .@"i32.store16" => 2,
        .@"i32.load", .@"i32.store" => 4,
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
        const src_r = abi.slotToReg(alloc.slots[val_v]) orelse return Error.SlotOverflow;
        const enc = switch (op) {
            .@"i32.store"   => inst.encStoreR32MemBaseIdx(src_r, .rax, .rdx),
            .@"i32.store8"  => inst.encStoreR8MemBaseIdx(src_r, .rax, .rdx),
            .@"i32.store16" => inst.encStoreR16MemBaseIdx(src_r, .rax, .rdx),
            else => unreachable,
        };
        try buf.appendSlice(allocator, enc.slice());
    } else {
        const result_v = next_vreg.*;
        next_vreg.* += 1;
        if (result_v >= alloc.slots.len) return Error.SlotOverflow;
        const dst_r = abi.slotToReg(alloc.slots[result_v]) orelse return Error.SlotOverflow;
        const enc = switch (op) {
            .@"i32.load"     => inst.encMovR32FromBaseIdx(dst_r, .rax, .rdx),
            .@"i32.load8_s"  => inst.encMovsxR32_8MemBaseIdx(dst_r, .rax, .rdx),
            .@"i32.load8_u"  => inst.encMovzxR32_8MemBaseIdx(dst_r, .rax, .rdx),
            .@"i32.load16_s" => inst.encMovsxR32_16MemBaseIdx(dst_r, .rax, .rdx),
            .@"i32.load16_u" => inst.encMovzxR32_16MemBaseIdx(dst_r, .rax, .rdx),
            else => unreachable,
        };
        try buf.appendSlice(allocator, enc.slice());
        try pushed_vregs.append(allocator, result_v);
    }
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

/// Emit a single `JMP target_for_depth` for one br_table case
/// (or the trailing default). Backward (loop) → concrete disp;
/// forward (block / if family) → placeholder + Fixup append.
/// Shared between the per-case loop and the default tail.
fn emitBrTableJmp(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    labels: *std.ArrayList(Label),
    depth: u32,
) Error!void {
    if (depth >= labels.items.len) return Error.UnsupportedOp;
    const tgt_idx = labels.items.len - 1 - depth;
    const tgt = &labels.items[tgt_idx];
    const at: u32 = @intCast(buf.items.len);
    if (tgt.kind == .loop) {
        const disp: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
            @as(i32, @intCast(at)) - 5;
        try buf.appendSlice(allocator, inst.encJmpRel32(disp).slice());
    } else {
        try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
        try tgt.pending.append(allocator, .{ .byte_offset = at, .insn_size = 5 });
    }
}

/// `br_table` — pop index; emit a CMP+JNE-skip+JMP chain for
/// each in-range case, then an unconditional JMP to the default.
///
/// ZirInstr encoding (mvp.zig:brTableOp):
///   payload = count   (number of in-range targets)
///   extra   = start   (offset into func.branch_targets)
/// branch_targets[start..start+count] = case depths
/// branch_targets[start+count]        = default depth
///
/// Per-case sequence (10-11 bytes):
///   CMP idx, i        (3-4 bytes; REX.B if idx ∈ R8..R15)
///   JNE +5            (2 bytes; skip the JMP if idx != i)
///   JMP target        (5 bytes; placeholder/concrete per kind)
///
/// **Cap**: count ≤ 127 (CMP r/m32, imm8 sign-extended). Larger
/// requires the imm32 form; surfaces as UnsupportedOp.
fn emitBrTable(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
    count: u32,
    start: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    if (count > 127) return Error.UnsupportedOp;
    const idx_v = pushed_vregs.pop().?;
    const idx_r = abi.slotToReg(alloc.slots[idx_v]) orelse return Error.SlotOverflow;
    const targets = func.branch_targets.items;
    if (start + count >= targets.len) return Error.UnsupportedOp;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try buf.appendSlice(allocator, inst.encCmpRImm8(.d, idx_r, @intCast(i)).slice());
        try buf.appendSlice(allocator, inst.encJccRel8(.ne, 5).slice());
        try emitBrTableJmp(allocator, buf, labels, targets[start + i]);
    }
    try emitBrTableJmp(allocator, buf, labels, targets[start + count]);
}

/// `br_if N` — pop cond, branch to label at depth N if cond is
/// non-zero. Emit TEST cond, cond ; Jcc(NE) target. Backward
/// (loop) target → concrete disp; forward (block / if) target
/// → placeholder + Fixup append.
fn emitBrIf(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
    depth: u32,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const cond_v = pushed_vregs.pop().?;
    const cond_r = abi.slotToReg(alloc.slots[cond_v]) orelse return Error.SlotOverflow;
    if (depth >= labels.items.len) return Error.UnsupportedOp;
    try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
    const tgt_idx = labels.items.len - 1 - depth;
    const tgt = &labels.items[tgt_idx];
    const at: u32 = @intCast(buf.items.len);
    if (tgt.kind == .loop) {
        const disp: i32 = @as(i32, @intCast(tgt.target_byte_offset)) -
            @as(i32, @intCast(at)) - 6;
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, disp).slice());
    } else {
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());
        try tgt.pending.append(allocator, .{ .byte_offset = at, .insn_size = 6 });
    }
}

/// `if` — pop cond, emit TEST cond, cond ; JE skip_placeholder.
/// Push label.if_then with the JE byte offset recorded; the
/// matching `else` patches it to else-body start, or the
/// matching `end` patches it to end-of-if (no-else case).
fn emitIf(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const cond_v = pushed_vregs.pop().?;
    const cond_r = abi.slotToReg(alloc.slots[cond_v]) orelse return Error.SlotOverflow;
    try buf.appendSlice(allocator, inst.encTestRR(.d, cond_r, cond_r).slice());
    const skip_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.e, 0).slice()); // JE = skip if cond==0
    try labels.append(allocator, .{
        .kind = .if_then,
        .target_byte_offset = 0,
        .pending = .empty,
        .if_skip_byte = skip_at,
    });
}

/// `else` — emit JMP placeholder (jump from end-of-then to
/// end-of-if), patch the if's JE to current byte (= start of
/// else-body), transition label to .else_open. Captures the
/// then arm's top vreg as the merge target per the D-027
/// equivalent (ADR-0014 §6.K.5).
fn emitElse(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    pushed_vregs: *std.ArrayList(u32),
    labels: *std.ArrayList(Label),
) Error!void {
    if (labels.items.len == 0 or
        labels.items[labels.items.len - 1].kind != .if_then)
    {
        return Error.UnsupportedOp;
    }
    const lbl_idx = labels.items.len - 1;
    if (pushed_vregs.items.len > 0) {
        labels.items[lbl_idx].merge_top_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
    }
    const jmp_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());
    const else_start: u32 = @intCast(buf.items.len);
    const lbl = &labels.items[lbl_idx];
    const skip_at = lbl.if_skip_byte.?;
    const skip_disp: i32 = @as(i32, @intCast(else_start)) -
        @as(i32, @intCast(skip_at)) - 6;
    inst.patchRel32(buf.items, skip_at, 6, skip_disp);
    lbl.if_skip_byte = null;
    lbl.kind = .else_open;
    try lbl.pending.append(allocator, .{ .byte_offset = jmp_at, .insn_size = 5 });
}

/// Intra-function `end` — pops a label and patches its forward
/// fixups + the if-skip-Jcc (if still pending) + emits the
/// merge MOV when an else_open frame had a captured merge
/// target. Caller (compile()) gates on `labels.len > 0`;
/// the function-level `end` shape stays inline.
fn emitEndIntra(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    pushed_vregs: *std.ArrayList(u32),
    alloc: regalloc.Allocation,
    labels: *std.ArrayList(Label),
) Error!void {
    var lbl = labels.pop().?;
    defer lbl.pending.deinit(allocator);

    // D-027 mirror: if this is an .else_open label with a
    // captured merge target, MOV merge_reg ← else_result_reg
    // BEFORE the join label so both arms converge on the same
    // physical register. Then drop the else arm's result vreg.
    if (lbl.kind == .else_open and lbl.merge_top_vreg != null) {
        if (pushed_vregs.items.len < 2) return Error.UnsupportedOp;
        const else_result = pushed_vregs.pop().?;
        const merge_vreg = lbl.merge_top_vreg.?;
        if (pushed_vregs.items[pushed_vregs.items.len - 1] != merge_vreg) {
            return Error.UnsupportedOp;
        }
        const merge_reg = abi.slotToReg(alloc.slots[merge_vreg]) orelse return Error.SlotOverflow;
        const else_reg = abi.slotToReg(alloc.slots[else_result]) orelse return Error.SlotOverflow;
        if (merge_reg != else_reg) {
            try buf.appendSlice(allocator, inst.encMovRR(.d, merge_reg, else_reg).slice());
        }
    }

    const target: u32 = @intCast(buf.items.len);
    // Patch the if-then's skip-Jcc if it's still pending (no
    // `else` was encountered).
    if (lbl.if_skip_byte) |skip_at| {
        const disp: i32 = @as(i32, @intCast(target)) -
            @as(i32, @intCast(skip_at)) - 6;
        inst.patchRel32(buf.items, skip_at, 6, disp);
    }
    // Patch all forward fixups (block / if_then / else_open).
    // Loop has no pending fixups.
    if (lbl.kind != .loop) {
        for (lbl.pending.items) |fx| {
            const disp: i32 = @as(i32, @intCast(target)) -
                @as(i32, @intCast(fx.byte_offset)) - @as(i32, fx.insn_size);
            inst.patchRel32(buf.items, fx.byte_offset, fx.insn_size, disp);
        }
    }
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
    // Spot-check the prologue (verifies ADR-0026 structure):
    try testing.expectEqualSlices(u8, &.{ 0x55, 0x41, 0x57, 0x48, 0x89, 0xE5, 0x49, 0x89, 0xFF, 0x48, 0x83, 0xEC, 0x08 }, out.bytes[0..13]);
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
