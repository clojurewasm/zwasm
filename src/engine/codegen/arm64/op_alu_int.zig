//! ARM64 emit pass — integer ALU / bit-op handlers (i32 + i64).
//!
//! Per ADR-0021 sub-deliverable b (emit.zig
//! 9-module split): all ZirOp handlers whose inputs and outputs
//! are GPR-class (i32 / i64). FP arithmetic + cross-class
//! conversions live in sibling op_alu_float.zig + op_convert.zig
//! (extracted in subsequent chunks).
//!
//! Sub-splitting the planned `ops_alu.zig` into op_alu_int +
//! op_alu_float keeps every module under ADR-0021's 400-LOC
//! cap. The "≤ 9 modules" target in ADR-0021 §Decision is
//! approximate ("~9"); honouring the per-module LOC cap
//! takes precedence over module count.
//!
//! Handlers in this module:
//!   - i32 / i64 binary: add, sub, mul, and, or, xor, shl,
//!     shr_s, shr_u (i32 group includes shifts; i64 shifts split
//!     so i64.rotr lands with shifts and i64.rotl is its own
//!     handler — same shape as v1).
//!   - i32 / i64 compare: eq, ne, lt_s, lt_u, gt_s, gt_u,
//!     le_s, le_u, ge_s, ge_u — emits CMP + CSET<cond>.
//!   - i32 / i64 eqz: CMP #0 + CSET .eq.
//!   - i32 / i64 rotr / rotl: ARM has only ROR; rotl emulates
//!     via 3-instr (MOVZ + SUB + ROR).
//!   - i32 / i64 clz: direct CLZ.
//!   - i32 / i64 ctz: RBIT + CLZ canonical idiom (no direct CTZ).
//!   - i32 / i64 popcnt: SIMD CNT + ADDV + UMOV via V31 scratch
//!     (ARM has no GPR-side popcount).
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_fp = @import("inst_fp.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const abi = @import("abi.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;
const Xn = inst.Xn;

// `popBinary` / `popUnary` live as methods on EmitCtx (ctx.zig)
// so every op-handler module reuses the same operand-pop /
// result-allocate convention.

// ============================================================
// i64 ALU
// ============================================================

/// Binary i64 ALU: add / sub / mul / and / or / xor.
/// Direct X-variant ops (64-bit semantics; no zero-extension fixup).
pub fn emitI64Binary(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const word: u32 = switch (ins.op) {
        .@"i64.add" => inst.encAddReg(xd, xn, xm),
        .@"i64.sub" => inst.encSubReg(xd, xn, xm),
        .@"i64.mul" => inst.encMulReg(xd, xn, xm),
        .@"i64.and" => inst.encAndReg(xd, xn, xm),
        .@"i64.or" => inst.encOrrReg(xd, xn, xm),
        .@"i64.xor" => inst.encEorReg(xd, xn, xm),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64 compare (eq..ge_u): CMP-X + CSET-W. The result is a W
/// (32-bit 0/1) per Wasm spec; CMP is 64-bit.
pub fn emitI64Compare(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const cond: inst.Cond = switch (ins.op) {
        .@"i64.eq" => .eq,
        .@"i64.ne" => .ne,
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
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(xn, xm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, cond));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.eqz: CMP-X #0 + CSET-W .eq.
pub fn emitI64Eqz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xn, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, .eq));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64 shifts: shl, shr_s, shr_u, rotr — direct X-variant ops.
pub fn emitI64Shift(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const word: u32 = switch (ins.op) {
        .@"i64.shl" => inst.encLslvRegX(xd, xn, xm),
        .@"i64.shr_s" => inst.encAsrvRegX(xd, xn, xm),
        .@"i64.shr_u" => inst.encLsrvRegX(xd, xn, xm),
        .@"i64.rotr" => inst.encRorvRegX(xd, xn, xm),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.rotl: ARM has no direct LEFT rotate. rotl(val, n) =
/// ror(val, 64-n). 3-instr sequence with IP0 (X16) as scratch:
///   MOVZ X16, #64 ; SUB X16, X16, Xcount ; ROR Xd, Xval, X16
pub fn emitI64Rotl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const ip0: Xn = 16;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip0, 64));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubReg(ip0, ip0, xm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRorvRegX(xd, xn, ip0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.clz: direct CLZ-X.
pub fn emitI64Clz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encClzX(xd, xn));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.ctz: RBIT + CLZ (no direct CTZ on ARM).
pub fn emitI64Ctz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRbitX(xd, xn));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encClzX(xd, xd));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.popcnt: 64-bit popcount via SIMD. FMOV D stages full
/// 64 bits into V31; CNT/ADDV/UMOV are the same shape as i32
/// (operate on lower 8 bytes regardless). Result fits in W.
pub fn emitI64Popcnt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const v_scratch: inst.Vn = 31;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovDtoFromX(v_scratch, xn));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCntV8B(v_scratch, v_scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddvB8B(v_scratch, v_scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encUmovWFromVB0(wd, v_scratch));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

// ============================================================
// i32 ALU
// ============================================================

/// Binary i32 ALU: add / sub / mul / and / or / xor / shl /
/// shr_s / shr_u — W-variant ops keep upper 32 bits zero
/// (Wasm i32 wraps mod 2^32).
pub fn emitI32Binary(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    // D-034 spill-aware: stage 0 for lhs, stage 1 for rhs (so two
    // spilled operands don't collide), stage 0 reused for result
    // (lhs has been consumed by the op already).
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const wm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const word: u32 = switch (ins.op) {
        .@"i32.add" => inst.encAddRegW(wd, wn, wm),
        .@"i32.sub" => inst.encSubRegW(wd, wn, wm),
        .@"i32.mul" => inst.encMulRegW(wd, wn, wm),
        .@"i32.and" => inst.encAndRegW(wd, wn, wm),
        .@"i32.or" => inst.encOrrRegW(wd, wn, wm),
        .@"i32.xor" => inst.encEorRegW(wd, wn, wm),
        .@"i32.shl" => inst.encLslvRegW(wd, wn, wm),
        .@"i32.shr_s" => inst.encAsrvRegW(wd, wn, wm),
        .@"i32.shr_u" => inst.encLsrvRegW(wd, wn, wm),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.rotr: direct RORV-W.
pub fn emitI32Rotr(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const wm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRorvRegW(wd, wn, wm));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.rotl: rotl(val, n) = ror(val, 32-n). 3-instr sequence
/// using IP0 (W16) as scratch.
pub fn emitI32Rotl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const wm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const ip0: Xn = 16;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip0, 32));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubRegW(ip0, ip0, wm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRorvRegW(wd, wn, ip0));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32 compare (eq..ge_u): CMP-W + CSET-W.
pub fn emitI32Compare(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const wm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const cond: inst.Cond = switch (ins.op) {
        .@"i32.eq" => .eq,
        .@"i32.ne" => .ne,
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
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(wn, wm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, cond));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.eqz: CMP-W #0 + CSET-W .eq.
pub fn emitI32Eqz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(wn, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, .eq));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.clz: direct CLZ-W.
pub fn emitI32Clz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encClzW(wd, wn));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.ctz: RBIT-W + CLZ-W (no direct CTZ).
pub fn emitI32Ctz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRbitW(wd, wn));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encClzW(wd, wd));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.popcnt: SIMD CNT + ADDV + UMOV via V31 scratch
/// (ARM has no GPR-side popcount).
pub fn emitI32Popcnt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    const v_scratch: inst.Vn = 31;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_fp.encFmovStoFromW(v_scratch, wn));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCntV8B(v_scratch, v_scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddvB8B(v_scratch, v_scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encUmovWFromVB0(wd, v_scratch));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

// ============================================================
// Wasm 2.0 sign-extension ops
// ============================================================

/// Wasm spec §4.4.1.4 (i32.extend8_s) — pop one i32, push the
/// sign-extended low 8 bits as i32. ARM64 lowering: SXTB W (alias
/// of SBFM Wd, Wn, #0, #7; Arm IHI 0055 §C6.2.220). The W-form
/// implicitly zero-extends the upper 32 bits of the X register.
pub fn emitI32Extend8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxtbW(wd, wn));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// Wasm spec §4.4.1.4 (i32.extend16_s) — sign-extend low 16 bits.
/// ARM64 SXTH W (Arm IHI 0055 §C6.2.220).
pub fn emitI32Extend16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxthW(wd, wn));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// Wasm spec §4.4.1.4 (i64.extend8_s) — pop i64, sign-extend low
/// 8 bits. ARM64 SXTB X (alias SBFM Xd, Xn, #0, #7).
pub fn emitI64Extend8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxtbX(xd, xn));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// Wasm spec §4.4.1.4 (i64.extend16_s) — ARM64 SXTH X.
pub fn emitI64Extend16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxthX(xd, xn));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// Wasm spec §4.4.1.4 (i64.extend32_s) — sign-extend low 32 bits
/// of i64. ARM64 SXTW (alias SBFM Xd, Xn, #0, #31). Reuses the
/// existing `encSxtw` encoder shared with `i64.extend_i32_s`.
pub fn emitI64Extend32S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.src, 0);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxtw(xd, xn));
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

// ============================================================
// Integer divide / remainder
// ============================================================

/// Emit a divide-by-zero trap check for `divisor`. Uses
/// CMP + B.EQ placeholder so the trap-stub patcher in emit.zig
/// recognises it as a B.cond fixup. `is_64` selects CMP-X
/// (for i64 divisors) vs CMP-W (i32 divisors) — width matters
/// because a non-zero i64 with the low 32 bits zero would
/// falsely trap under CMP-W.
fn emitDivByZeroCheck(ctx: *EmitCtx, divisor: inst.Xn, is_64: bool) Error!void {
    if (is_64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(divisor, 0));
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(divisor, 0));
    }
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.eq, 0));
    try ctx.divzero_fixups.append(ctx.allocator, fixup_at);
}

/// Wasm spec §4.4.1.1 (`i32.div_s` / `i64.div_s`) — signed
/// division traps on `INT_MIN / -1` (the quotient `2^(N-1)`
/// is unrepresentable in N-bit two's complement). On ARM64
/// `SDIV` silently produces `INT_MIN` for that input pair, so
/// the spec-mandated trap is a per-handler check, not a CPU
/// exception. (`i32.rem_s` / `i64.rem_s` deliberately do NOT
/// trap on this input — the SDIV+MSUB sequence already returns
/// the spec-correct result `0` because `MSUB` arithmetic wraps
/// in the 32/64-bit domain.)
///
/// Sequence (4 instructions, 16 bytes):
///   CMN  divisor, #1       ; Z=1 iff divisor == -1
///   B.NE +3 words          ; skip overflow trap when divisor != -1
///   NEGS WZR/XZR, dividend ; V=1 iff dividend == INT_MIN
///   B.VS trap_stub         ; both conditions met → trap
fn emitDivSignedOverflowCheck(
    ctx: *EmitCtx,
    dividend: inst.Xn,
    divisor: inst.Xn,
    is_64: bool,
) Error!void {
    if (is_64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmnImmX(divisor, 1));
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmnImmW(divisor, 1));
    }
    // disp_words = 3 means PC = B.NE_addr + 12 = past the next two
    // instructions (NEGS + B.VS). The next handler op (SDIV) lands
    // at the skip target.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 3));
    if (is_64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encNegsRegX(dividend));
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encNegsRegW(dividend));
    }
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.vs, 0));
    try ctx.overflow_fixups.append(ctx.allocator, fixup_at);
}

/// Wasm spec §4.4.1.1 (i32.div_s / i32.div_u / i32.rem_s /
/// i32.rem_u) — pop two i32, push quotient or remainder. Wasm
/// traps on divide-by-zero (all four ops); div_s additionally
/// traps on signed overflow (INT_MIN / -1). rem_s does NOT trap
/// on overflow; the result is 0 by spec.
///
/// ARM64 lowering:
///   CBZ  Wm, trap_stub          ; div-by-zero check
///   (for div_s only:)
///     CMN  Wm, #1               ; Wm == -1?
///     B.NE skip
///     CMP  Wn, #0x80000000      ; would need movz; instead use
///       MOVZ X16, #0x8000, lsl #16; CMP Wn, W16; B.EQ trap
///     skip:
///   <UDIV / SDIV>  Wd, Wn, Wm    ; unsigned/signed quotient
///   (for rem ops:)
///     MSUB Wd, Wd, Wm, Wn       ; rem = Wn - (Wd × Wm)
///
/// `i32.div_s` additionally traps on the `INT_MIN / -1`
/// overflow case (Wasm spec §4.4.1.1). `i32.rem_s` does NOT
/// trap on the same input — the `SDIV` then `MSUB` sequence
/// produces the spec-correct value `0` (INT_MIN - INT_MIN*(-1)
/// wraps to 0 in 32-bit). The overflow check therefore guards
/// `div_s` only; see `emitDivSignedOverflowCheck`.
pub fn emitI32DivRem(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const wn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const wm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const wd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    try emitDivByZeroCheck(ctx, wm, false);
    if (ins.op == .@"i32.div_s") {
        try emitDivSignedOverflowCheck(ctx, wn, wm, false);
    }
    const is_signed = switch (ins.op) {
        .@"i32.div_s", .@"i32.rem_s" => true,
        .@"i32.div_u", .@"i32.rem_u" => false,
        else => unreachable,
    };
    const is_rem = (ins.op == .@"i32.rem_s" or ins.op == .@"i32.rem_u");
    // D-085 fix: SDIV writes wd, which the regalloc
    // may have aliased to wn (lhs) OR wm (rhs). For pure div this
    // is fine (no further reads of wn/wm). For rem, MSUB(wd, wd, wm,
    // wn) reads Wn=wd / Wm=wm / Wa=wn — if wd aliases wm, Wm reads
    // post-SDIV quotient instead of original divisor; if wd aliases
    // wn, Wa reads quotient instead of original lhs. Both cases
    // silently miscompile (D-085 surfaced on INT_MIN/-1 where the
    // alias-corrupted result is INT_MIN instead of spec-mandated 0).
    // Fix: stash wn AND wm in IP0 (X16) / IP1 (X17) before SDIV, use
    // the stashed copies in MSUB. IP0/IP1 are intra-procedure
    // scratch (`single_slot_dual_meaning.md`); never in the regalloc
    // pool. 2 extra MOV (= ORR Wd, WZR, Wm alias) instructions per
    // rem; div is unchanged.
    const ip0: inst.Xn = 16; // IP0 / X16 — stashes wn
    const ip1: inst.Xn = 17; // IP1 / X17 — stashes wm
    if (is_rem) {
        // MOV W16, Wn ; MOV W17, Wm (both via ORR Wd, WZR, Wm alias)
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip0, 31, wn));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip1, 31, wm));
    }
    const div_word: u32 = if (is_signed)
        inst.encSdivRegW(wd, wn, wm)
    else
        inst.encUdivRegW(wd, wn, wm);
    try gpr.writeU32(ctx.allocator, ctx.buf, div_word);
    if (is_rem) {
        // wd = stashed_wn - quotient(wd) × stashed_wm
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMsubRegW(wd, wd, ip1, ip0));
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// Wasm spec §4.4.1.1 (i64.div_s / i64.div_u / i64.rem_s /
/// i64.rem_u) — 64-bit counterpart of `emitI32DivRem`. Same
/// shape; X-form encoders. `i64.div_s` traps on the
/// `INT_MIN_64 / -1` overflow per the same spec clause; `rem_s`
/// does not (the SDIV+MSUB sequence wraps to 0).
pub fn emitI64DivRem(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const xn = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.lhs, 0);
    const xm = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.rhs, 1);
    const xd = try gpr.gprDefSpilled(ctx.alloc, args.result, 0);
    // Div-by-zero check: CMP-X xm, #0 + B.EQ trap (full 64-bit
    // compare so a non-zero i64 with low 32 bits zero — e.g. 2^32
    // — does not falsely trap).
    try emitDivByZeroCheck(ctx, xm, true);
    if (ins.op == .@"i64.div_s") {
        try emitDivSignedOverflowCheck(ctx, xn, xm, true);
    }
    const is_signed = switch (ins.op) {
        .@"i64.div_s", .@"i64.rem_s" => true,
        .@"i64.div_u", .@"i64.rem_u" => false,
        else => unreachable,
    };
    const is_rem_64 = (ins.op == .@"i64.rem_s" or ins.op == .@"i64.rem_u");
    // D-085 mirror: same alias preservation as the
    // i32 path. SDIV writes xd which may alias xn or xm; MSUB then
    // reads Wm and Wa expecting originals. Stash via IP0/IP1.
    const ip0_64: inst.Xn = 16;
    const ip1_64: inst.Xn = 17;
    if (is_rem_64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(ip0_64, 31, xn));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(ip1_64, 31, xm));
    }
    const div_word: u32 = if (is_signed)
        inst.encSdivRegX(xd, xn, xm)
    else
        inst.encUdivRegX(xd, xn, xm);
    try gpr.writeU32(ctx.allocator, ctx.buf, div_word);
    if (is_rem_64) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMsubRegX(xd, xd, ip1_64, ip0_64));
    }
    try gpr.gprStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, args.result, 0);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

// Wasm wide-arithmetic (ADR-0168 v0.2) — the first 2-result ops.
// Computed into ip0/ip1 (non-allocatable scratch) to avoid clobbering
// a still-needed operand mid-carry-chain, then captured into the two
// result vregs (mirror op_call captureCallResult: next_vreg++ ×2).

/// Store scratch reg `src` into result vreg `vreg`'s slot. Mirrors
/// gprStoreSpilled's slot dispatch for a value already in a fixed reg.
fn captureWideResult(ctx: *EmitCtx, vreg: u32, src: Xn) Error!void {
    if (vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    switch (ctx.alloc.slot(vreg, .gpr)) {
        .reg => |id| {
            const xd = abi.slotToReg(id) orelse return Error.SlotOverflow;
            if (xd != src) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(xd, 31, src));
        },
        .spill => |off| {
            const abs_off: u32 = ctx.spill_base_off + off;
            try gpr.frameStrGpr(ctx.allocator, ctx.buf, src, abs_off, false, abi.spill_stage_gprs[0]);
        },
    }
    try ctx.pushed_vregs.append(ctx.allocator, vreg);
}

/// `i64.add128` / `i64.sub128` — pop [a_lo, a_hi, b_lo, b_hi], push
/// [r_lo, r_hi]. ADDS/SUBS sets carry; ADC/SBC consumes it. The operand
/// loads between the two are LDR/MOV (no NZCV clobber) so the carry
/// survives. r_lo→ip0, r_hi→ip1.
pub fn emitWideAddSub128(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 4) return Error.AllocationMissing;
    const b_hi_v = ctx.pushed_vregs.pop().?;
    const b_lo_v = ctx.pushed_vregs.pop().?;
    const a_hi_v = ctx.pushed_vregs.pop().?;
    const a_lo_v = ctx.pushed_vregs.pop().?;
    const ip0 = abi.ip_gprs[0];
    const ip1 = abi.ip_gprs[1];
    const is_sub = ins.op == .@"i64.sub128";
    const b_lo = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, b_lo_v, 0);
    const a_lo = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, a_lo_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (is_sub) inst.encSubsReg(ip0, a_lo, b_lo) else inst.encAddsReg(ip0, a_lo, b_lo));
    const b_hi = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, b_hi_v, 0);
    const a_hi = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, a_hi_v, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, if (is_sub) inst.encSbcReg(ip1, a_hi, b_hi) else inst.encAdcReg(ip1, a_hi, b_hi));
    const r_lo = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    try captureWideResult(ctx, r_lo, ip0);
    const r_hi = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    try captureWideResult(ctx, r_hi, ip1);
}

/// `i64.mul_wide_s` / `i64.mul_wide_u` — pop [a, b], push [lo, hi] of
/// the full 128-bit product. MUL→lo (ip0), UMULH/SMULH→hi (ip1).
pub fn emitWideMul(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ctx.pushed_vregs.items.len < 2) return Error.AllocationMissing;
    const b_v = ctx.pushed_vregs.pop().?;
    const a_v = ctx.pushed_vregs.pop().?;
    const ip0 = abi.ip_gprs[0];
    const ip1 = abi.ip_gprs[1];
    const a = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, a_v, 0);
    const b = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, b_v, 1);
    const signed = ins.op == .@"i64.mul_wide_s";
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMulReg(ip0, a, b)); // low 64
    try gpr.writeU32(ctx.allocator, ctx.buf, if (signed) inst.encSmulh(ip1, a, b) else inst.encUmulh(ip1, a, b)); // high 64
    const r_lo = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    try captureWideResult(ctx, r_lo, ip0);
    const r_hi = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    try captureWideResult(ctx, r_hi, ip1);
}
