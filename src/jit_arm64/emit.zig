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

const zir = @import("../ir/zir.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const regalloc = @import("../jit/regalloc.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirInstr = zir.ZirInstr;
const ZirOp = zir.ZirOp;
const Xn = inst.Xn;

pub const Error = error{
    AllocationMissing,
    UnsupportedOp,
    SlotOverflow,
    OutOfMemory,
};

pub const EmitOutput = struct {
    /// Encoded function body bytes (little-endian u32 stream).
    /// Caller owns; pair with `deinit` to free.
    bytes: []u8,
    /// Distinct GPR slots used (mirrors `Allocation.n_slots`).
    /// The §9.7 / 7.4 gate consults this for stack-frame sizing
    /// when the spill follow-up lands.
    n_slots: u8,
};

pub fn deinit(allocator: Allocator, out: EmitOutput) void {
    if (out.bytes.len != 0) allocator.free(out.bytes);
}

/// Emit ARM64 machine code for `func`. Requires `alloc.slots`
/// to be populated (call `regalloc.compute` first; pass the
/// `Allocation` here).
pub fn compile(
    allocator: Allocator,
    func: *const ZirFunc,
    alloc: regalloc.Allocation,
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
    const frame_bytes_unaligned: u32 = num_locals * 8;
    const frame_bytes: u32 = (frame_bytes_unaligned + 15) & ~@as(u32, 15);
    try writeU32(allocator, &buf, encStpFpLrPreIdx());
    try writeU32(allocator, &buf, encMovSpToFp());
    if (frame_bytes > 0) {
        if (frame_bytes >= (@as(u32, 1) << 12)) return Error.SlotOverflow;
        try writeU32(allocator, &buf, inst.encSubImm12(31, 31, @intCast(frame_bytes)));
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

    for (func.instrs.items, 0..) |ins, pc| {
        _ = pc;
        switch (ins.op) {
            .@"i32.const" => {
                // The const's destination vreg is the next-to-be-pushed
                // vreg id. Slot it and emit MOVZ + optional MOVK lanes.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
                try emitConstU32(allocator, &buf, xd, ins.payload);
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i64.const" => {
                // ZirInstr packs u64 across (payload, extra):
                //   low_32 = payload, high_32 = extra.
                // Emit MOVZ (low 16) + MOVK lanes for any non-zero
                // upper lane. MOVZ zeros, MOVK keeps lower lanes.
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
                const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
                const lane0: u16 = @truncate(value & 0xFFFF);
                const lane1: u16 = @truncate((value >> 16) & 0xFFFF);
                const lane2: u16 = @truncate((value >> 32) & 0xFFFF);
                const lane3: u16 = @truncate((value >> 48) & 0xFFFF);
                try writeU32(allocator, &buf, inst.encMovzImm16(xd, lane0));
                if (lane1 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(xd, lane1, 1));
                if (lane2 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(xd, lane2, 2));
                if (lane3 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(xd, lane3, 3));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"i64.add",
            .@"i64.sub",
            .@"i64.mul",
            .@"i64.and",
            .@"i64.or",
            .@"i64.xor",
            => {
                // Binary i64 ALU: pop rhs, lhs; allocate result;
                // emit X-variant op (64-bit semantics; no
                // zero-extension fixup since i64 is the full
                // register).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const xm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const word: u32 = switch (ins.op) {
                    .@"i64.add" => inst.encAddReg(xd, xn, xm),
                    .@"i64.sub" => inst.encSubReg(xd, xn, xm),
                    .@"i64.mul" => inst.encMulReg(xd, xn, xm),
                    .@"i64.and" => inst.encAndReg(xd, xn, xm),
                    .@"i64.or"  => inst.encOrrReg(xd, xn, xm),
                    .@"i64.xor" => inst.encEorReg(xd, xn, xm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
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
            => {
                // 2-instr CMP-X + CSET-W. CMP is X-variant (64-bit
                // compare); CSET writes 0/1 to a W-register (the
                // i32 result type per Wasm spec).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const xm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const cond: inst.Cond = switch (ins.op) {
                    .@"i64.eq"   => .eq,
                    .@"i64.ne"   => .ne,
                    .@"i64.lt_s" => .lt,
                    .@"i64.lt_u" => .lo,
                    .@"i64.gt_s" => .gt,
                    .@"i64.gt_u" => .hi,
                    .@"i64.le_s" => .le,
                    .@"i64.le_u" => .ls,
                    .@"i64.ge_s" => .ge,
                    .@"i64.ge_u" => .hs,
                    else => unreachable,
                };
                try writeU32(allocator, &buf, inst.encCmpRegX(xn, xm));
                try writeU32(allocator, &buf, inst.encCsetW(wd, cond));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.eqz" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encCmpImmX(xn, 0));
                try writeU32(allocator, &buf, inst.encCsetW(wd, .eq));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.shl",
            .@"i64.shr_s",
            .@"i64.shr_u",
            .@"i64.rotr",
            => {
                // Direct X-variant shifts.
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const xm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const word: u32 = switch (ins.op) {
                    .@"i64.shl"   => inst.encLslvRegX(xd, xn, xm),
                    .@"i64.shr_s" => inst.encAsrvRegX(xd, xn, xm),
                    .@"i64.shr_u" => inst.encLsrvRegX(xd, xn, xm),
                    .@"i64.rotr"  => inst.encRorvRegX(xd, xn, xm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.rotl" => {
                // No direct LEFT rotate on ARM. rotl(val, n) =
                // ror(val, 64-n). 3-instr sequence with IP0 (X16)
                // as scratch:
                //   MOVZ X16, #64
                //   SUB  X16, X16, Xcount
                //   ROR  Xd,  Xval, X16
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const xm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const ip0: inst.Xn = 16;
                try writeU32(allocator, &buf, inst.encMovzImm16(ip0, 64));
                try writeU32(allocator, &buf, inst.encSubReg(ip0, ip0, xm));
                try writeU32(allocator, &buf, inst.encRorvRegX(xd, xn, ip0));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.clz" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encClzX(xd, xn));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.ctz" => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const xd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encRbitX(xd, xn));
                try writeU32(allocator, &buf, inst.encClzX(xd, xd));
                try pushed_vregs.append(allocator, result);
            },
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
                const vd = abi.fpSlotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
                const w_scratch = abi.slotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
                try emitConstU32(allocator, &buf, w_scratch, ins.payload);
                try writeU32(allocator, &buf, inst.encFmovStoFromW(vd, w_scratch));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"f64.const" => {
                // Similar to f32.const but for 64-bit (FMOV D, X).
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const vd = abi.fpSlotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
                const x_scratch = abi.slotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
                const value: u64 = (@as(u64, ins.extra) << 32) | @as(u64, ins.payload);
                const lane0: u16 = @truncate(value & 0xFFFF);
                const lane1: u16 = @truncate((value >> 16) & 0xFFFF);
                const lane2: u16 = @truncate((value >> 32) & 0xFFFF);
                const lane3: u16 = @truncate((value >> 48) & 0xFFFF);
                try writeU32(allocator, &buf, inst.encMovzImm16(x_scratch, lane0));
                if (lane1 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane1, 1));
                if (lane2 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane2, 2));
                if (lane3 != 0) try writeU32(allocator, &buf, inst.encMovkImm16(x_scratch, lane3, 3));
                try writeU32(allocator, &buf, inst.encFmovDtoFromX(vd, x_scratch));
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
            => {
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = abi.fpSlotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const vm = abi.fpSlotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const vd = abi.fpSlotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const word: u32 = switch (ins.op) {
                    .@"f32.add" => inst.encFAddS(vd, vn, vm),
                    .@"f32.sub" => inst.encFSubS(vd, vn, vm),
                    .@"f32.mul" => inst.encFMulS(vd, vn, vm),
                    .@"f32.div" => inst.encFDivS(vd, vn, vm),
                    .@"f64.add" => inst.encFAddD(vd, vn, vm),
                    .@"f64.sub" => inst.encFSubD(vd, vn, vm),
                    .@"f64.mul" => inst.encFMulD(vd, vn, vm),
                    .@"f64.div" => inst.encFDivD(vd, vn, vm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
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
            => {
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = abi.fpSlotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const vd = abi.fpSlotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const word: u32 = switch (ins.op) {
                    .@"f32.abs"     => inst.encFAbsS(vd, vn),
                    .@"f32.neg"     => inst.encFNegS(vd, vn),
                    .@"f32.sqrt"    => inst.encFSqrtS(vd, vn),
                    .@"f32.ceil"    => inst.encFRintPS(vd, vn),
                    .@"f32.floor"   => inst.encFRintMS(vd, vn),
                    .@"f32.trunc"   => inst.encFRintZS(vd, vn),
                    .@"f32.nearest" => inst.encFRintNS(vd, vn),
                    .@"f64.abs"     => inst.encFAbsD(vd, vn),
                    .@"f64.neg"     => inst.encFNegD(vd, vn),
                    .@"f64.sqrt"    => inst.encFSqrtD(vd, vn),
                    .@"f64.ceil"    => inst.encFRintPD(vd, vn),
                    .@"f64.floor"   => inst.encFRintMD(vd, vn),
                    .@"f64.trunc"   => inst.encFRintZD(vd, vn),
                    .@"f64.nearest" => inst.encFRintND(vd, vn),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"f32.min",
            .@"f32.max",
            .@"f64.min",
            .@"f64.max",
            => {
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = abi.fpSlotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const vm = abi.fpSlotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const vd = abi.fpSlotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const word: u32 = switch (ins.op) {
                    .@"f32.min" => inst.encFMinS(vd, vn, vm),
                    .@"f32.max" => inst.encFMaxS(vd, vn, vm),
                    .@"f64.min" => inst.encFMinD(vd, vn, vm),
                    .@"f64.max" => inst.encFMaxD(vd, vn, vm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
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
            => {
                // FCMP S/D → CSET W. Wasm FP cmps are ordered:
                // NaN inputs always yield false. The ARM Cond
                // codes used here naturally satisfy that:
                // - eq/ne: EQ/NE (Z flag; FCMP unordered → Z=0,V=1).
                // - lt: MI (N=1; FCMP unordered → N=0).
                // - gt: GT (Z=0 ∧ N=V).
                // - le: LS (C=0 ∨ Z=1; FCMP unordered → C=1).
                // - ge: GE (N=V; FCMP unordered → N=0,V=1 → false).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const vn = abi.fpSlotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const vm = abi.fpSlotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const is_d = switch (ins.op) {
                    .@"f64.eq", .@"f64.ne", .@"f64.lt", .@"f64.gt", .@"f64.le", .@"f64.ge" => true,
                    else => false,
                };
                const cond: inst.Cond = switch (ins.op) {
                    .@"f32.eq", .@"f64.eq" => .eq,
                    .@"f32.ne", .@"f64.ne" => .ne,
                    .@"f32.lt", .@"f64.lt" => .mi,
                    .@"f32.gt", .@"f64.gt" => .gt,
                    .@"f32.le", .@"f64.le" => .ls,
                    .@"f32.ge", .@"f64.ge" => .ge,
                    else => unreachable,
                };
                try writeU32(allocator, &buf, if (is_d) inst.encFCmpD(vn, vm) else inst.encFCmpS(vn, vm));
                try writeU32(allocator, &buf, inst.encCsetW(wd, cond));
                try pushed_vregs.append(allocator, result);
            },
            .@"i64.popcnt" => {
                // 64-bit popcount via SIMD: same shape as i32.popcnt
                // but FMOV D (not S) stages the full 64 bits into
                // V31's lower 64. CNT/ADDV/UMOV are unchanged
                // (operate on lower 8 bytes regardless of whether
                // upper 4 came from FMOV S or full 8 bytes from
                // FMOV D). Result fits in W (max 64 < 256).
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const xn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const v_scratch: inst.Vn = 31;
                try writeU32(allocator, &buf, inst.encFmovDtoFromX(v_scratch, xn));
                try writeU32(allocator, &buf, inst.encCntV8B(v_scratch, v_scratch));
                try writeU32(allocator, &buf, inst.encAddvB8B(v_scratch, v_scratch));
                try writeU32(allocator, &buf, inst.encUmovWFromVB0(wd, v_scratch));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.add",
            .@"i32.sub",
            .@"i32.mul",
            .@"i32.and",
            .@"i32.or",
            .@"i32.xor",
            .@"i32.shl",
            .@"i32.shr_s",
            .@"i32.shr_u",
            => {
                // Binary i32 ALU: pop rhs, lhs; allocate result;
                // emit a W-variant op so the upper 32 bits stay
                // zero-extended (Wasm i32 wraps mod 2^32).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const word: u32 = switch (ins.op) {
                    .@"i32.add"   => inst.encAddRegW(wd, wn, wm),
                    .@"i32.sub"   => inst.encSubRegW(wd, wn, wm),
                    .@"i32.mul"   => inst.encMulRegW(wd, wn, wm),
                    .@"i32.and"   => inst.encAndRegW(wd, wn, wm),
                    .@"i32.or"    => inst.encOrrRegW(wd, wn, wm),
                    .@"i32.xor"   => inst.encEorRegW(wd, wn, wm),
                    .@"i32.shl"   => inst.encLslvRegW(wd, wn, wm),
                    .@"i32.shr_s" => inst.encAsrvRegW(wd, wn, wm),
                    .@"i32.shr_u" => inst.encLsrvRegW(wd, wn, wm),
                    else => unreachable,
                };
                try writeU32(allocator, &buf, word);
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.rotr" => {
                // rotr is direct: `RORV Wd, Wn, Wm`.
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encRorvRegW(wd, wn, wm));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.rotl" => {
                // ARM has only ROR; rotl(val, n) = ror(val, 32-n).
                // 3-instr sequence using IP0 (W16) as scratch (not
                // in the regalloc pool, safe to clobber):
                //   MOVZ W16, #32
                //   SUB  W16, W16, Wcount
                //   ROR  Wd,  Wval, W16
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const ip0: Xn = 16;
                try writeU32(allocator, &buf, inst.encMovzImm16(ip0, 32));
                try writeU32(allocator, &buf, inst.encSubRegW(ip0, ip0, wm));
                try writeU32(allocator, &buf, inst.encRorvRegW(wd, wn, ip0));
                try pushed_vregs.append(allocator, result);
            },
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
            => {
                // 2-instr CMP + CSET pattern. Each Wasm cmp maps
                // to an ARM `Cond` (set-if-true).
                if (pushed_vregs.items.len < 2) return Error.AllocationMissing;
                const rhs = pushed_vregs.pop().?;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wm = abi.slotToReg(alloc.slots[rhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const cond: inst.Cond = switch (ins.op) {
                    .@"i32.eq"   => .eq,
                    .@"i32.ne"   => .ne,
                    .@"i32.lt_s" => .lt,
                    .@"i32.lt_u" => .lo,
                    .@"i32.gt_s" => .gt,
                    .@"i32.gt_u" => .hi,
                    .@"i32.le_s" => .le,
                    .@"i32.le_u" => .ls,
                    .@"i32.ge_s" => .ge,
                    .@"i32.ge_u" => .hs,
                    else => unreachable,
                };
                try writeU32(allocator, &buf, inst.encCmpRegW(wn, wm));
                try writeU32(allocator, &buf, inst.encCsetW(wd, cond));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.eqz" => {
                // Compare against #0 then CSET EQ.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encCmpImmW(wn, 0));
                try writeU32(allocator, &buf, inst.encCsetW(wd, .eq));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.clz" => {
                // CLZ has a direct ARM op: `CLZ Wd, Wn`.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encClzW(wd, wn));
                try pushed_vregs.append(allocator, result);
            },
            .@"i32.ctz" => {
                // No direct CTZ on ARM; emit RBIT + CLZ (canonical
                // 2-instr idiom — RBIT reverses bits, CLZ then
                // counts trailing zeros of the original).
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encRbitW(wd, wn));
                try writeU32(allocator, &buf, inst.encClzW(wd, wd));
                try pushed_vregs.append(allocator, result);
            },
            .@"local.get" => {
                // Push a fresh vreg holding the value loaded from
                // [SP, #(local_idx * 8)].
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const vreg = next_vreg;
                next_vreg += 1;
                if (vreg >= alloc.slots.len) return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encLdrImmW(wd, 31, offset));
                try pushed_vregs.append(allocator, vreg);
            },
            .@"local.set" => {
                // Pop top vreg, write to [SP, #(local_idx * 8)].
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const src = pushed_vregs.pop().?;
                const ws = abi.slotToReg(alloc.slots[src]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encStrImmW(ws, 31, offset));
            },
            .@"local.tee" => {
                // Write top vreg to [SP, #(local_idx * 8)] WITHOUT
                // popping — the value remains pushed.
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const local_idx = ins.payload;
                if (local_idx >= num_locals) return Error.UnsupportedOp;
                const offset: u14 = @intCast(local_idx * 8);
                const src = pushed_vregs.items[pushed_vregs.items.len - 1];
                const ws = abi.slotToReg(alloc.slots[src]) orelse return Error.SlotOverflow;
                try writeU32(allocator, &buf, inst.encStrImmW(ws, 31, offset));
            },
            .@"i32.popcnt" => {
                // ARM has no GPR-side popcount; the canonical idiom
                // moves the value to a V-register, runs SIMD CNT
                // per-byte, sums 8 bytes via ADDV, and extracts the
                // sum back to a GPR. 4-instr sequence using V31 as
                // scratch (caller-saved per AAPCS64; never in the
                // integer regalloc pool).
                if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
                const lhs = pushed_vregs.pop().?;
                const result = next_vreg;
                next_vreg += 1;
                if (result >= alloc.slots.len) return Error.SlotOverflow;
                const wn = abi.slotToReg(alloc.slots[lhs]) orelse return Error.SlotOverflow;
                const wd = abi.slotToReg(alloc.slots[result]) orelse return Error.SlotOverflow;
                const v_scratch: inst.Vn = 31;
                try writeU32(allocator, &buf, inst.encFmovStoFromW(v_scratch, wn));
                try writeU32(allocator, &buf, inst.encCntV8B(v_scratch, v_scratch));
                try writeU32(allocator, &buf, inst.encAddvB8B(v_scratch, v_scratch));
                try writeU32(allocator, &buf, inst.encUmovWFromVB0(wd, v_scratch));
                try pushed_vregs.append(allocator, result);
            },
            .@"end" => {
                // Function-level end: marshal the top-of-stack vreg
                // into the result register, then run the epilogue.
                // AAPCS64 §6.4: integer / pointer returns in X0;
                // floating-point returns in V0 (S0 for f32, D0
                // for f64). Only fires once per function in the
                // 7.3 skeleton (multi-end via blocks lands later).
                if (pushed_vregs.items.len > 0 and func.sig.results.len > 0) {
                    const top_vreg = pushed_vregs.items[pushed_vregs.items.len - 1];
                    const result_kind = func.sig.results[0];
                    const is_fp = switch (result_kind) {
                        .f32, .f64 => true,
                        .i32, .i64, .v128, .funcref, .externref => false,
                    };
                    if (is_fp) {
                        const src_vn = abi.fpSlotToReg(alloc.slots[top_vreg]) orelse return Error.SlotOverflow;
                        if (src_vn != 0) {
                            // FMOV S0, Sn or FMOV D0, Dn — encoded
                            // via the FP-FP move (FMOV reg-reg).
                            // Encoding: `0 0 0 11110 type 1 0000 0 10 0000 [Rn:5] [Rd:5]`
                            // type = 00 single → 0x1E204000
                            // type = 01 double → 0x1E604000
                            const base: u32 = if (result_kind == .f64) 0x1E604000 else 0x1E204000;
                            try writeU32(allocator, &buf, base | (@as(u32, src_vn) << 5));
                        }
                    } else {
                        const src_xn = abi.slotToReg(alloc.slots[top_vreg]) orelse return Error.SlotOverflow;
                        if (src_xn != 0) {
                            // MOV X0, Xsrc — encoded as ORR X0, XZR, Xsrc.
                            try writeU32(allocator, &buf, encOrrZrIntoX0(src_xn));
                        }
                    }
                }
                if (frame_bytes > 0) {
                    try writeU32(allocator, &buf, inst.encAddImm12(31, 31, @intCast(frame_bytes)));
                }
                try writeU32(allocator, &buf, encLdpFpLrPostIdx());
                try writeU32(allocator, &buf, inst.encRet(abi.link_register));
                break;
            },
            else => return Error.UnsupportedOp,
        }
    }

    return .{
        .bytes = try buf.toOwnedSlice(allocator),
        .n_slots = alloc.n_slots,
    };
}

fn writeU32(allocator: Allocator, buf: *std.ArrayList(u8), word: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    try buf.appendSlice(allocator, &bytes);
}

/// Emit a 32-bit constant into Xd via MOVZ + MOVK pairs.
/// Strategy: MOVZ Xd, #(lo16); if hi16 != 0, MOVK Xd, #hi16, lsl #16.
/// (For a full 64-bit constant — Phase 9+ — extend to 4 lanes.)
fn emitConstU32(allocator: Allocator, buf: *std.ArrayList(u8), xd: Xn, value: u32) !void {
    const lo16: u16 = @truncate(value & 0xFFFF);
    const hi16: u16 = @truncate(value >> 16);
    try writeU32(allocator, buf, inst.encMovzImm16(xd, lo16));
    if (hi16 != 0) {
        try writeU32(allocator, buf, inst.encMovkImm16(xd, hi16, 1));
    }
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

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const liveness_mod = @import("../ir/liveness.zig");

test "compile: empty body without liveness errors" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, empty_alloc));
}

test "compile: empty function (no instrs, empty liveness) emits prologue+epilogue" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty_alloc: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    // No `end` op in the stream → emit walks zero instrs and
    // returns just the prologue (no epilogue). That's the expected
    // shape for a malformed body; the §9.7 / 7.4 gate filters such
    // funcs at validate-time, so emit doesn't enforce well-formedness.
    const out = try compile(testing.allocator, &f, empty_alloc);
    defer deinit(testing.allocator, out);
    // 2 prologue u32s = 8 bytes.
    try testing.expectEqual(@as(usize, 8), out.bytes.len);
    try testing.expectEqual(@as(u32, 0xA9BF7BFD), std.mem.readInt(u32, out.bytes[0..4], .little));
    try testing.expectEqual(@as(u32, 0x910003FD), std.mem.readInt(u32, out.bytes[4..8], .little));
}

test "compile: (i32.const 42) end yields 5-instr body returning 42 in X0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);

    // Expected stream: STP / MOV-FP-SP / MOVZ-X9-#42 / MOV-X0-X9 / LDP / RET
    // = 6 u32 words = 24 bytes.
    try testing.expectEqual(@as(usize, 24), out.bytes.len);

    // Word 0: STP prologue.
    try testing.expectEqual(@as(u32, 0xA9BF7BFD), std.mem.readInt(u32, out.bytes[0..4], .little));
    // Word 1: MOV X29, SP.
    try testing.expectEqual(@as(u32, 0x910003FD), std.mem.readInt(u32, out.bytes[4..8], .little));
    // Word 2: MOVZ X9, #42 — slot 0 → X9 per abi.slotToReg.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[8..12], .little));
    // Word 3: MOV X0, X9 (ORR X0, XZR, X9).
    try testing.expectEqual(@as(u32, 0xAA0903E0), std.mem.readInt(u32, out.bytes[12..16], .little));
    // Word 4: LDP epilogue.
    try testing.expectEqual(@as(u32, 0xA8C17BFD), std.mem.readInt(u32, out.bytes[16..20], .little));
    // Word 5: RET.
    try testing.expectEqual(@as(u32, 0xD65F03C0), std.mem.readInt(u32, out.bytes[20..24], .little));
}

test "compile: i32.const 0x12345678 emits MOVZ + MOVK (full 32-bit)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x12345678 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);

    // 7 u32s now: STP / MOV-FP-SP / MOVZ / MOVK / MOV-X0 / LDP / RET.
    try testing.expectEqual(@as(usize, 28), out.bytes.len);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0x5678)), std.mem.readInt(u32, out.bytes[8..12], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x1234, 1)), std.mem.readInt(u32, out.bytes[12..16], .little));
}

test "compile: unsupported op surfaces UnsupportedOp" {
    // f32.copysign not yet handled — sub-d5 scope (needs bit
    // manipulation via FMOV W↔S detour).
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.copysign" });
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty));
}

test "compile: (i32.const 7) (i32.const 5) i32.add end → returns 12 in X0" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    // 3 vregs: vreg0 = const 7, vreg1 = const 5, vreg2 = add result.
    // vreg0 dies at pc=2 (consumed by add); vreg1 dies at pc=2;
    // vreg2 dies at pc=3 (end).
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    // Greedy regalloc would assign slot 0 to vreg0, slot 1 to
    // vreg1 (overlap), slot 0 again to vreg2 (vreg0 + vreg1 die
    // at the add's pc=2, so slot 0 frees AT use). Hand-supplied
    // allocation matches what greedy produces.
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);

    // Stream: STP / MOV-FP / MOVZ X9 #7 / MOVZ X10 #5 / ADD X9 X9 X10 /
    //         MOV X0 X9 / LDP / RET = 8 u32s = 32 bytes.
    try testing.expectEqual(@as(usize, 32), out.bytes.len);
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 7)),  std.mem.readInt(u32, out.bytes[8..12], .little));
    try testing.expectEqual(@as(u32, inst.encMovzImm16(10, 5)), std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encAddRegW(9, 9, 10)), std.mem.readInt(u32, out.bytes[16..20], .little));
}

test "compile: i32.sub / i32.mul / i32.and / i32.or / i32.xor / i32.shl / i32.shr_s / i32.shr_u each emit correct W-variant ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i32.sub",   .want_word_at_offset = inst.encSubRegW(9, 9, 10) },
        .{ .op = .@"i32.mul",   .want_word_at_offset = inst.encMulRegW(9, 9, 10) },
        .{ .op = .@"i32.and",   .want_word_at_offset = inst.encAndRegW(9, 9, 10) },
        .{ .op = .@"i32.or",    .want_word_at_offset = inst.encOrrRegW(9, 9, 10) },
        .{ .op = .@"i32.xor",   .want_word_at_offset = inst.encEorRegW(9, 9, 10) },
        .{ .op = .@"i32.shl",   .want_word_at_offset = inst.encLslvRegW(9, 9, 10) },
        .{ .op = .@"i32.shr_s", .want_word_at_offset = inst.encAsrvRegW(9, 9, 10) },
        .{ .op = .@"i32.shr_u", .want_word_at_offset = inst.encLsrvRegW(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        // ALU op lives at u32 offset 4 (= byte 16).
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[16..20], .little));
    }
}

test "compile: stack underflow on ALU op with 1 pushed vreg surfaces AllocationMissing" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.add" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    try testing.expectError(Error.AllocationMissing, compile(testing.allocator, &f, alloc));
}

test "compile: i32.rotr emits single RORV W-variant" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.rotr" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // Stream: STP / MOV-FP / MOVZ #FF / MOVZ #4 / RORV / MOV X0 / LDP / RET
    // = 8 u32s. RORV at byte 16.
    try testing.expectEqual(@as(u32, inst.encRorvRegW(9, 9, 10)), std.mem.readInt(u32, out.bytes[16..20], .little));
}

test "compile: i32.rotl emits 3-instr NEG-via-MOVZ-SUB + RORV sequence" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 4 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.rotl" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // After 4 prologue+const u32s (16 bytes), expect:
    // MOVZ W16, #32  /  SUB W16, W16, W10  /  RORV W9, W9, W16
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 32)),    std.mem.readInt(u32, out.bytes[16..20], .little));
    try testing.expectEqual(@as(u32, inst.encSubRegW(16, 16, 10)),  std.mem.readInt(u32, out.bytes[20..24], .little));
    try testing.expectEqual(@as(u32, inst.encRorvRegW(9, 9, 16)),   std.mem.readInt(u32, out.bytes[24..28], .little));
}

test "compile: i32 cmp ops each emit CMP + CSET with the right Cond mapping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"i32.eq",   .want_cond = .eq },
        .{ .op = .@"i32.ne",   .want_cond = .ne },
        .{ .op = .@"i32.lt_s", .want_cond = .lt },
        .{ .op = .@"i32.lt_u", .want_cond = .lo },
        .{ .op = .@"i32.gt_s", .want_cond = .gt },
        .{ .op = .@"i32.gt_u", .want_cond = .hi },
        .{ .op = .@"i32.le_s", .want_cond = .le },
        .{ .op = .@"i32.le_u", .want_cond = .ls },
        .{ .op = .@"i32.ge_s", .want_cond = .ge },
        .{ .op = .@"i32.ge_u", .want_cond = .hs },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        // CMP at byte 16, CSET at byte 20.
        try testing.expectEqual(@as(u32, inst.encCmpRegW(9, 10)), std.mem.readInt(u32, out.bytes[16..20], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[20..24], .little));
    }
}

test "compile: i32.clz emits direct CLZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xFF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9-#FF (12 bytes): CLZ W9, W9.
    try testing.expectEqual(@as(u32, inst.encClzW(9, 9)), std.mem.readInt(u32, out.bytes[12..16], .little));
}

test "compile: i32.ctz emits RBIT + CLZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x100 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.ctz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9-#0x100 (12 bytes): RBIT W9, W9 / CLZ W9, W9.
    try testing.expectEqual(@as(u32, inst.encRbitW(9, 9)), std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encClzW(9, 9)),  std.mem.readInt(u32, out.bytes[16..20], .little));
}

test "compile: i32.popcnt emits 4-instr V-register SIMD pattern" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0xDEADBEEF });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.popcnt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9/MOVK-W9 (16 bytes) — 0xDEADBEEF
    // needs both lanes — the popcnt sequence starts.
    // FMOV S31, W9
    try testing.expectEqual(@as(u32, inst.encFmovStoFromW(31, 9)),     std.mem.readInt(u32, out.bytes[16..20], .little));
    // CNT V31.8B, V31.8B
    try testing.expectEqual(@as(u32, inst.encCntV8B(31, 31)),          std.mem.readInt(u32, out.bytes[20..24], .little));
    // ADDV B31, V31.8B
    try testing.expectEqual(@as(u32, inst.encAddvB8B(31, 31)),         std.mem.readInt(u32, out.bytes[24..28], .little));
    // UMOV W9, V31.B[0]
    try testing.expectEqual(@as(u32, inst.encUmovWFromVB0(9, 31)),     std.mem.readInt(u32, out.bytes[28..32], .little));
}

test "compile: 1 local — prologue includes SUB SP,SP,#16; epilogue ADD SP,SP,#16" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{.i32};
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);

    // Stream: STP / MOV-FP / SUB-SP-#16 / MOVZ W9 #7 / STR W9 [SP,#0] /
    //         LDR W9 [SP,#0] / MOV X0 X9 / ADD-SP-#16 / LDP / RET = 10 u32s = 40 bytes.
    try testing.expectEqual(@as(usize, 40), out.bytes.len);
    // Word 2: SUB SP, SP, #16.
    try testing.expectEqual(@as(u32, inst.encSubImm12(31, 31, 16)), std.mem.readInt(u32, out.bytes[8..12], .little));
    // Word 4: STR W9, [SP, #0].
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 0)),    std.mem.readInt(u32, out.bytes[16..20], .little));
    // Word 5: LDR W9, [SP, #0].
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 0)),    std.mem.readInt(u32, out.bytes[20..24], .little));
    // Word 7: ADD SP, SP, #16.
    try testing.expectEqual(@as(u32, inst.encAddImm12(31, 31, 16)), std.mem.readInt(u32, out.bytes[28..32], .little));
}

test "compile: 3 locals — frame rounds up to 32 bytes (3*8=24 → align to 32)" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{ .i32, .i32, .i32 };
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.set", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 2 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // Word 2: SUB SP, SP, #32 (3*8=24 → aligned 32).
    try testing.expectEqual(@as(u32, inst.encSubImm12(31, 31, 32)), std.mem.readInt(u32, out.bytes[8..12], .little));
    // local.set 2 → STR at offset 2*8=16. Word 4 (after STP/MOV-FP/SUB/MOVZ).
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 16)),   std.mem.readInt(u32, out.bytes[16..20], .little));
    // local.get 2 → LDR at offset 16. Word 5.
    try testing.expectEqual(@as(u32, inst.encLdrImmW(9, 31, 16)),   std.mem.readInt(u32, out.bytes[20..24], .little));
}

test "compile: local.tee writes to local but keeps value pushed" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const locals = [_]zir.ValType{.i32};
    var f = ZirFunc.init(0, sig, &locals);
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 42 });
    try f.instrs.append(testing.allocator, .{ .op = .@"local.tee", .payload = 0 });
    // After tee, vreg0 still on stack. end consumes it.
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
    } };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // Stream: STP / MOV-FP / SUB-SP / MOVZ W9 #42 / STR W9 [SP,#0] /
    //         MOV X0 X9 / ADD-SP / LDP / RET = 9 u32s = 36 bytes.
    try testing.expectEqual(@as(usize, 36), out.bytes.len);
    // Word 4: STR (the tee).
    try testing.expectEqual(@as(u32, inst.encStrImmW(9, 31, 0)), std.mem.readInt(u32, out.bytes[16..20], .little));
    // Word 5: MOV X0, X9 (the kept-on-stack value, then end consumes it).
    try testing.expectEqual(@as(u32, 0xAA0903E0), std.mem.readInt(u32, out.bytes[20..24], .little));
}

test "compile: i64.const small value emits single MOVZ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 42, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // Single MOVZ X9, #42 at byte 8.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 42)), std.mem.readInt(u32, out.bytes[8..12], .little));
}

test "compile: i64.const 0xCAFEBABEDEADBEEF emits MOVZ + 3 MOVK lanes" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 0xCAFEBABEDEADBEEF: low_32=0xDEADBEEF, high_32=0xCAFEBABE.
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xDEADBEEF, .extra = 0xCAFEBABE });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // MOVZ #BEEF / MOVK #DEAD lsl 16 / MOVK #BABE lsl 32 / MOVK #CAFE lsl 48.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0xBEEF)),       std.mem.readInt(u32, out.bytes[8..12],  .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xDEAD, 1)),    std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xBABE, 2)),    std.mem.readInt(u32, out.bytes[16..20], .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0xCAFE, 3)),    std.mem.readInt(u32, out.bytes[20..24], .little));
}

test "compile: i64.add / sub / mul / and / or / xor each emit X-variant ALU op" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i64.add", .want_word_at_offset = inst.encAddReg(9, 9, 10) },
        .{ .op = .@"i64.sub", .want_word_at_offset = inst.encSubReg(9, 9, 10) },
        .{ .op = .@"i64.mul", .want_word_at_offset = inst.encMulReg(9, 9, 10) },
        .{ .op = .@"i64.and", .want_word_at_offset = inst.encAndReg(9, 9, 10) },
        .{ .op = .@"i64.or",  .want_word_at_offset = inst.encOrrReg(9, 9, 10) },
        .{ .op = .@"i64.xor", .want_word_at_offset = inst.encEorReg(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[16..20], .little));
    }
}

test "compile: i64 cmp ops each emit CMP-X + CSET-W with the right Cond mapping" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"i64.eq",   .want_cond = .eq },
        .{ .op = .@"i64.ne",   .want_cond = .ne },
        .{ .op = .@"i64.lt_s", .want_cond = .lt },
        .{ .op = .@"i64.lt_u", .want_cond = .lo },
        .{ .op = .@"i64.gt_s", .want_cond = .gt },
        .{ .op = .@"i64.gt_u", .want_cond = .hi },
        .{ .op = .@"i64.le_s", .want_cond = .le },
        .{ .op = .@"i64.le_u", .want_cond = .ls },
        .{ .op = .@"i64.ge_s", .want_cond = .ge },
        .{ .op = .@"i64.ge_u", .want_cond = .hs },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        try testing.expectEqual(@as(u32, inst.encCmpRegX(9, 10)),        std.mem.readInt(u32, out.bytes[16..20], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[20..24], .little));
    }
}

test "compile: i64 shifts emit X-variant LSLV/LSRV/ASRV/RORV" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"i64.shl",   .want_word_at_offset = inst.encLslvRegX(9, 9, 10) },
        .{ .op = .@"i64.shr_s", .want_word_at_offset = inst.encAsrvRegX(9, 9, 10) },
        .{ .op = .@"i64.shr_u", .want_word_at_offset = inst.encLsrvRegX(9, 9, 10) },
        .{ .op = .@"i64.rotr",  .want_word_at_offset = inst.encRorvRegX(9, 9, 10) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 7, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 5, .extra = 0 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[16..20], .little));
    }
}

test "compile: i64.rotl emits 3-instr X-variant NEG-via-MOVZ-#64-SUB + RORV" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 4, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.rotl" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u8{ 0, 1, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // After 4 prologue+const u32s (16 bytes):
    // MOVZ X16, #64 / SUB X16, X16, X10 / RORV X9, X9, X16.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(16, 64)),    std.mem.readInt(u32, out.bytes[16..20], .little));
    try testing.expectEqual(@as(u32, inst.encSubReg(16, 16, 10)),   std.mem.readInt(u32, out.bytes[20..24], .little));
    try testing.expectEqual(@as(u32, inst.encRorvRegX(9, 9, 16)),   std.mem.readInt(u32, out.bytes[24..28], .little));
}

test "compile: i64.clz emits direct CLZ X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.clz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    try testing.expectEqual(@as(u32, inst.encClzX(9, 9)), std.mem.readInt(u32, out.bytes[12..16], .little));
}

test "compile: i64.ctz emits RBIT-X + CLZ-X" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0x100, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.ctz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    try testing.expectEqual(@as(u32, inst.encRbitX(9, 9)), std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encClzX(9, 9)),  std.mem.readInt(u32, out.bytes[16..20], .little));
}

test "compile: i64.popcnt emits FMOV-D + CNT/ADDV/UMOV V-register pattern" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xFF, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.popcnt" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-X9 (12 bytes):
    // FMOV D31, X9 / CNT V31.8B / ADDV B31 / UMOV W9.
    try testing.expectEqual(@as(u32, inst.encFmovDtoFromX(31, 9)),     std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encCntV8B(31, 31)),          std.mem.readInt(u32, out.bytes[16..20], .little));
    try testing.expectEqual(@as(u32, inst.encAddvB8B(31, 31)),         std.mem.readInt(u32, out.bytes[20..24], .little));
    try testing.expectEqual(@as(u32, inst.encUmovWFromVB0(9, 31)),     std.mem.readInt(u32, out.bytes[24..28], .little));
}

test "compile: f32.const emits emitConstU32 + FMOV S, W" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    // 1.0f bits = 0x3F800000.
    try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{.{ .def_pc = 0, .last_use_pc = 1 }} };
    const slots = [_]u8{0};
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP (8 bytes): MOVZ + MOVK (lo=0x0000, hi=0x3F80)
    // — but lo=0 so just MOVK fires? No wait: emitConstU32 always
    // emits MOVZ (low 16) and conditionally MOVK (high 16). For
    // 0x3F800000: low 16 = 0x0000, high 16 = 0x3F80. MOVZ #0; MOVK
    // #0x3F80 lsl 16; FMOV S16, W9.
    try testing.expectEqual(@as(u32, inst.encMovzImm16(9, 0)),       std.mem.readInt(u32, out.bytes[8..12],  .little));
    try testing.expectEqual(@as(u32, inst.encMovkImm16(9, 0x3F80, 1)), std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encFmovStoFromW(16, 9)),    std.mem.readInt(u32, out.bytes[16..20], .little));
    // end with f32 result → FMOV S0, S16 = 0x1E204000 | (16<<5) = 0x1E204200.
    try testing.expectEqual(@as(u32, 0x1E204200),                     std.mem.readInt(u32, out.bytes[20..24], .little));
}

test "compile: f32 binary ALU each emits S-form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"f32.add", .want_word_at_offset = inst.encFAddS(16, 16, 17) },
        .{ .op = .@"f32.sub", .want_word_at_offset = inst.encFSubS(16, 16, 17) },
        .{ .op = .@"f32.mul", .want_word_at_offset = inst.encFMulS(16, 16, 17) },
        .{ .op = .@"f32.div", .want_word_at_offset = inst.encFDivS(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        // Each f32.const emits MOVZ + MOVK + FMOV (3 u32s = 12 bytes).
        // After STP/MOV-FP (8) + 2 consts (24) = byte 32, FP ALU fires.
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[32..36], .little));
    }
}

test "compile: f32 cmps each emit FCMP-S + CSET-W with right Cond" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    const cases = [_]struct { op: zir.ZirOp, want_cond: inst.Cond }{
        .{ .op = .@"f32.eq", .want_cond = .eq },
        .{ .op = .@"f32.ne", .want_cond = .ne },
        .{ .op = .@"f32.lt", .want_cond = .mi },
        .{ .op = .@"f32.gt", .want_cond = .gt },
        .{ .op = .@"f32.le", .want_cond = .ls },
        .{ .op = .@"f32.ge", .want_cond = .ge },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        // FCMP at byte 32; CSET at byte 36.
        try testing.expectEqual(@as(u32, inst.encFCmpS(16, 17)),         std.mem.readInt(u32, out.bytes[32..36], .little));
        try testing.expectEqual(@as(u32, inst.encCsetW(9, c.want_cond)), std.mem.readInt(u32, out.bytes[36..40], .little));
    }
}

test "compile: f32 unary ops + min/max each emit correct encoding" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f32 } };
    const Case = struct {
        op: zir.ZirOp,
        binary: bool,
        want_word_at_offset: u32,
    };
    const cases = [_]Case{
        .{ .op = .@"f32.abs",     .binary = false, .want_word_at_offset = inst.encFAbsS(16, 16) },
        .{ .op = .@"f32.neg",     .binary = false, .want_word_at_offset = inst.encFNegS(16, 16) },
        .{ .op = .@"f32.sqrt",    .binary = false, .want_word_at_offset = inst.encFSqrtS(16, 16) },
        .{ .op = .@"f32.ceil",    .binary = false, .want_word_at_offset = inst.encFRintPS(16, 16) },
        .{ .op = .@"f32.floor",   .binary = false, .want_word_at_offset = inst.encFRintMS(16, 16) },
        .{ .op = .@"f32.trunc",   .binary = false, .want_word_at_offset = inst.encFRintZS(16, 16) },
        .{ .op = .@"f32.nearest", .binary = false, .want_word_at_offset = inst.encFRintNS(16, 16) },
        .{ .op = .@"f32.min",     .binary = true,  .want_word_at_offset = inst.encFMinS(16, 16, 17) },
        .{ .op = .@"f32.max",     .binary = true,  .want_word_at_offset = inst.encFMaxS(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x3F800000 });
        var ranges_buf: [3]zir.LiveRange = undefined;
        if (c.binary) {
            try f.instrs.append(testing.allocator, .{ .op = .@"f32.const", .payload = 0x40000000 });
            try f.instrs.append(testing.allocator, .{ .op = c.op });
            ranges_buf[0] = .{ .def_pc = 0, .last_use_pc = 2 };
            ranges_buf[1] = .{ .def_pc = 1, .last_use_pc = 2 };
            ranges_buf[2] = .{ .def_pc = 2, .last_use_pc = 3 };
            try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        } else {
            try f.instrs.append(testing.allocator, .{ .op = c.op });
            ranges_buf[0] = .{ .def_pc = 0, .last_use_pc = 1 };
            ranges_buf[1] = .{ .def_pc = 1, .last_use_pc = 2 };
            try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        }
        f.liveness = .{ .ranges = if (c.binary) ranges_buf[0..3] else ranges_buf[0..2] };
        const slots_binary = [_]u8{ 0, 1, 0 };
        const slots_unary = [_]u8{ 0, 0 };
        const alloc: regalloc.Allocation = if (c.binary)
            .{ .slots = &slots_binary, .n_slots = 2 }
        else
            .{ .slots = &slots_unary, .n_slots = 1 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        // For unary: 1 const = 3 u32s (MOVZ + MOVK for 0x3F800000 + FMOV S);
        //   STP/MOV-FP (8) + const (12) = byte 20, op fires at byte 20.
        // For binary: 2 consts = 6 u32s = 24 bytes;
        //   STP/MOV-FP (8) + 2 consts (24) = byte 32.
        const op_offset: usize = if (c.binary) 32 else 20;
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[op_offset..op_offset+4][0..4], .little));
    }
}

test "compile: f64 binary ALU each emits D-form" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .f64 } };
    const cases = [_]struct { op: zir.ZirOp, want_word_at_offset: u32 }{
        .{ .op = .@"f64.add", .want_word_at_offset = inst.encFAddD(16, 16, 17) },
        .{ .op = .@"f64.sub", .want_word_at_offset = inst.encFSubD(16, 16, 17) },
        .{ .op = .@"f64.mul", .want_word_at_offset = inst.encFMulD(16, 16, 17) },
        .{ .op = .@"f64.div", .want_word_at_offset = inst.encFDivD(16, 16, 17) },
    };
    for (cases) |c| {
        var f = ZirFunc.init(0, sig, &.{});
        defer f.deinit(testing.allocator);
        // 1.0 + 2.0 (f64 bits): payload = lo32, extra = hi32.
        try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0x00000000, .extra = 0x3FF00000 });
        try f.instrs.append(testing.allocator, .{ .op = .@"f64.const", .payload = 0x00000000, .extra = 0x40000000 });
        try f.instrs.append(testing.allocator, .{ .op = c.op });
        try f.instrs.append(testing.allocator, .{ .op = .@"end" });
        f.liveness = .{ .ranges = &[_]zir.LiveRange{
            .{ .def_pc = 0, .last_use_pc = 2 },
            .{ .def_pc = 1, .last_use_pc = 2 },
            .{ .def_pc = 2, .last_use_pc = 3 },
        } };
        const slots = [_]u8{ 0, 1, 0 };
        const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 2 };
        const out = try compile(testing.allocator, &f, alloc);
        defer deinit(testing.allocator, out);
        // f64.const 1.0: bits=0x3FF0000000000000. Lanes: lo=0, l1=0,
        // l2=0, l3=0x3FF0. Only lane 3 nonzero (besides lane 0).
        // So const emits MOVZ + MOVK lane3 + FMOV D = 3 u32s.
        // f64.const 2.0: bits=0x4000000000000000. Lane 3 = 0x4000.
        // Same shape.
        // After STP/MOV-FP (8) + 2 consts (24) = byte 32, ALU fires.
        try testing.expectEqual(c.want_word_at_offset, std.mem.readInt(u32, out.bytes[32..36], .little));
    }
}

test "compile: i64.eqz emits CMP-X-imm-0 + CSET EQ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0, .extra = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    try testing.expectEqual(@as(u32, inst.encCmpImmX(9, 0)),    std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encCsetW(9, .eq)),    std.mem.readInt(u32, out.bytes[16..20], .little));
}

test "compile: function with non-empty params surfaces UnsupportedOp" {
    const params = [_]zir.ValType{.i32};
    const sig: zir.FuncType = .{ .params = &params, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    f.liveness = .{ .ranges = &.{} };
    const empty: regalloc.Allocation = .{ .slots = &.{}, .n_slots = 0 };
    try testing.expectError(Error.UnsupportedOp, compile(testing.allocator, &f, empty));
}

test "compile: i32.eqz emits CMP-imm-0 + CSET EQ" {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.eqz" });
    try f.instrs.append(testing.allocator, .{ .op = .@"end" });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 1 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u8{ 0, 0 };
    const alloc: regalloc.Allocation = .{ .slots = &slots, .n_slots = 1 };
    const out = try compile(testing.allocator, &f, alloc);
    defer deinit(testing.allocator, out);
    // After STP/MOV-FP/MOVZ-W9-#0 (12 bytes): CMP W9,#0 / CSET W9,EQ.
    try testing.expectEqual(@as(u32, inst.encCmpImmW(9, 0)),   std.mem.readInt(u32, out.bytes[12..16], .little));
    try testing.expectEqual(@as(u32, inst.encCsetW(9, .eq)),   std.mem.readInt(u32, out.bytes[16..20], .little));
}

comptime {
    _ = liveness_mod; // hook upstream module so future regalloc tests are reachable
}
