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
    // Skeleton scope: ≤ 15 locals (i8-disp range covers offsets
    // -8 .. -120). 16+ locals require disp32 + imm32 SUB/ADD,
    // out of scope here (will land alongside the regalloc /
    // spill port).
    const num_locals: u32 = @intCast(func.locals.len);
    if (num_locals > 15) return Error.UnsupportedOp;
    const frame_bytes_unaligned: u32 = num_locals * 8;
    const frame_bytes: u32 = (frame_bytes_unaligned + 15) & ~@as(u32, 15);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // ============================================================
    // Prologue: PUSH RBP ; MOV RBP, RSP ; SUB RSP, #frame
    //
    // After PUSH RBP + MOV RBP, RSP: RBP holds the on-entry RSP
    // (post-PUSH). SUB RSP, frame_bytes drops the stack to make
    // room for locals; each i32 local occupies an 8-byte slot
    // for stable 8-byte alignment + disp8 addressing.
    //
    // Local layout (Wasm ZirFunc.locals): local K at
    // [RBP - 8*(K+1)]. Frame size rounds up to 16 bytes per
    // SysV §3.2.2 (RSP must stay 16-byte aligned at any call).
    // ============================================================
    try buf.appendSlice(allocator, inst.encPushR(.rbp).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rbp, .rsp).slice());
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
            .@"local.get" => try emitLocalGet(allocator, &buf, alloc, &pushed_vregs, &next_vreg, num_locals, ins.payload),
            .@"local.set" => try emitLocalSet(allocator, &buf, alloc, &pushed_vregs, num_locals, ins.payload),
            .@"local.tee" => try emitLocalTee(allocator, &buf, alloc, &pushed_vregs, num_locals, ins.payload),
            .@"end" => {
                // Function-level end (skeleton: no label stack
                // yet, so every `end` is the function-level form).
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
                // Epilogue: ADD RSP, #frame ; POP RBP ; RET.
                if (frame_bytes > 0) {
                    try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(frame_bytes)).slice());
                }
                try buf.appendSlice(allocator, inst.encPopR(.rbp).slice());
                try buf.appendSlice(allocator, inst.encRet().slice());
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

/// Compute the i8 displacement for local index `idx`. Layout:
/// local 0 at [RBP - 8], local K at [RBP - 8*(K+1)]. Surfaces
/// `UnsupportedOp` for indices the i8 disp cannot reach (idx >=
/// 16 → -136, out of i8 range).
fn localDisp(idx: u32, num_locals: u32) Error!i8 {
    if (idx >= num_locals) return Error.UnsupportedOp;
    if (idx >= 16) return Error.UnsupportedOp;
    const off: i32 = -@as(i32, @intCast((idx + 1) * 8));
    return @intCast(off);
}

/// `local.get K` — push a fresh vreg holding the value loaded
/// from [RBP - 8*(K+1)].
fn emitLocalGet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    num_locals: u32,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, num_locals);
    const vreg = next_vreg.*;
    next_vreg.* += 1;
    if (vreg >= alloc.slots.len) return Error.SlotOverflow;
    const dst_r = abi.slotToReg(alloc.slots[vreg]) orelse return Error.SlotOverflow;
    try buf.appendSlice(allocator, inst.encLoadR32MemRBP(dst_r, disp).slice());
    try pushed_vregs.append(allocator, vreg);
}

/// `local.set K` — pop the top vreg and store its low 32 bits
/// into [RBP - 8*(K+1)].
fn emitLocalSet(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    num_locals: u32,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, num_locals);
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    try buf.appendSlice(allocator, inst.encStoreR32MemRBP(disp, src_r).slice());
}

/// `local.tee K` — store the top vreg's low 32 bits into
/// [RBP - 8*(K+1)] WITHOUT popping.
fn emitLocalTee(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    num_locals: u32,
    idx: u32,
) Error!void {
    const disp = try localDisp(idx, num_locals);
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.items[pushed_vregs.items.len - 1];
    const src_r = abi.slotToReg(alloc.slots[src_v]) orelse return Error.SlotOverflow;
    try buf.appendSlice(allocator, inst.encStoreR32MemRBP(disp, src_r).slice());
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
