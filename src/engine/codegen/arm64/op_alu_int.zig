//! ARM64 emit pass — integer ALU / bit-op handlers (i32 + i64).
//!
//! Per ADR-0021 sub-deliverable b (§9.7 / 7.5d sub-b emit.zig
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
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");

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
    const xn = try gpr.resolveGpr(ctx.alloc, args.lhs);
    const xm = try gpr.resolveGpr(ctx.alloc, args.rhs);
    const xd = try gpr.resolveGpr(ctx.alloc, args.result);
    const word: u32 = switch (ins.op) {
        .@"i64.add" => inst.encAddReg(xd, xn, xm),
        .@"i64.sub" => inst.encSubReg(xd, xn, xm),
        .@"i64.mul" => inst.encMulReg(xd, xn, xm),
        .@"i64.and" => inst.encAndReg(xd, xn, xm),
        .@"i64.or"  => inst.encOrrReg(xd, xn, xm),
        .@"i64.xor" => inst.encEorReg(xd, xn, xm),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64 compare (eq..ge_u): CMP-X + CSET-W. The result is a W
/// (32-bit 0/1) per Wasm spec; CMP is 64-bit.
pub fn emitI64Compare(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const xn = try gpr.resolveGpr(ctx.alloc, args.lhs);
    const xm = try gpr.resolveGpr(ctx.alloc, args.rhs);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
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
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(xn, xm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, cond));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.eqz: CMP-X #0 + CSET-W .eq.
pub fn emitI64Eqz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.resolveGpr(ctx.alloc, args.src);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(xn, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, .eq));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64 shifts: shl, shr_s, shr_u, rotr — direct X-variant ops.
pub fn emitI64Shift(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const xn = try gpr.resolveGpr(ctx.alloc, args.lhs);
    const xm = try gpr.resolveGpr(ctx.alloc, args.rhs);
    const xd = try gpr.resolveGpr(ctx.alloc, args.result);
    const word: u32 = switch (ins.op) {
        .@"i64.shl"   => inst.encLslvRegX(xd, xn, xm),
        .@"i64.shr_s" => inst.encAsrvRegX(xd, xn, xm),
        .@"i64.shr_u" => inst.encLsrvRegX(xd, xn, xm),
        .@"i64.rotr"  => inst.encRorvRegX(xd, xn, xm),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.rotl: ARM has no direct LEFT rotate. rotl(val, n) =
/// ror(val, 64-n). 3-instr sequence with IP0 (X16) as scratch:
///   MOVZ X16, #64 ; SUB X16, X16, Xcount ; ROR Xd, Xval, X16
pub fn emitI64Rotl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const xn = try gpr.resolveGpr(ctx.alloc, args.lhs);
    const xm = try gpr.resolveGpr(ctx.alloc, args.rhs);
    const xd = try gpr.resolveGpr(ctx.alloc, args.result);
    const ip0: Xn = 16;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip0, 64));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubReg(ip0, ip0, xm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRorvRegX(xd, xn, ip0));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.clz: direct CLZ-X.
pub fn emitI64Clz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.resolveGpr(ctx.alloc, args.src);
    const xd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encClzX(xd, xn));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.ctz: RBIT + CLZ (no direct CTZ on ARM).
pub fn emitI64Ctz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.resolveGpr(ctx.alloc, args.src);
    const xd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRbitX(xd, xn));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encClzX(xd, xd));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i64.popcnt: 64-bit popcount via SIMD. FMOV D stages full
/// 64 bits into V31; CNT/ADDV/UMOV are the same shape as i32
/// (operate on lower 8 bytes regardless). Result fits in W.
pub fn emitI64Popcnt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.resolveGpr(ctx.alloc, args.src);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    const v_scratch: inst.Vn = 31;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovDtoFromX(v_scratch, xn));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCntV8B(v_scratch, v_scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddvB8B(v_scratch, v_scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encUmovWFromVB0(wd, v_scratch));
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
    const wn = try gpr.resolveGpr(ctx.alloc, args.lhs);
    const wm = try gpr.resolveGpr(ctx.alloc, args.rhs);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
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
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.rotr: direct RORV-W.
pub fn emitI32Rotr(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.lhs);
    const wm = try gpr.resolveGpr(ctx.alloc, args.rhs);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRorvRegW(wd, wn, wm));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.rotl: rotl(val, n) = ror(val, 32-n). 3-instr sequence
/// using IP0 (W16) as scratch.
pub fn emitI32Rotl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.lhs);
    const wm = try gpr.resolveGpr(ctx.alloc, args.rhs);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    const ip0: Xn = 16;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip0, 32));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubRegW(ip0, ip0, wm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRorvRegW(wd, wn, ip0));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32 compare (eq..ge_u): CMP-W + CSET-W.
pub fn emitI32Compare(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.lhs);
    const wm = try gpr.resolveGpr(ctx.alloc, args.rhs);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
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
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(wn, wm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, cond));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.eqz: CMP-W #0 + CSET-W .eq.
pub fn emitI32Eqz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.src);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(wn, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, .eq));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.clz: direct CLZ-W.
pub fn emitI32Clz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.src);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encClzW(wd, wn));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.ctz: RBIT-W + CLZ-W (no direct CTZ).
pub fn emitI32Ctz(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.src);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encRbitW(wd, wn));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encClzW(wd, wd));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// i32.popcnt: SIMD CNT + ADDV + UMOV via V31 scratch
/// (ARM has no GPR-side popcount).
pub fn emitI32Popcnt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.src);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    const v_scratch: inst.Vn = 31;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovStoFromW(v_scratch, wn));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCntV8B(v_scratch, v_scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddvB8B(v_scratch, v_scratch));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encUmovWFromVB0(wd, v_scratch));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
