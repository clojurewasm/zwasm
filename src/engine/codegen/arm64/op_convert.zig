//! ARM64 emit pass — cross-class conversion handlers.
//!
//! Per ADR-0021 sub-deliverable b (§9.7 / 7.5d sub-b emit.zig
//! 9-module split): all ZirOp handlers that cross the GPR ↔ FP
//! type boundary OR change width / sign-extension semantics
//! within the same class, *with the exception of trapping trunc*
//! (i32.trunc_f32_s, …) which depends on the trap-stub bounds-
//! check machinery and ships alongside `bounds_check.zig` in a
//! later chunk.
//!
//! Handlers in this module:
//!   - i32.wrap_i64 / i64.extend_i32_u — both lower to MOV Wd, Wn
//!     (W-write zeros upper 32 bits).
//!   - i64.extend_i32_s — SXTW (sign-extend 32-bit into 64-bit).
//!   - f*.convert_i*_* — int → float (SCVTF / UCVTF, 8 variants).
//!   - i*.trunc_sat_f*_* — Wasm 2.0 saturating trunc (8 variants).
//!     ARM64 FCVTZS / FCVTZU natively saturate on overflow and
//!     return 0 for NaN, matching Wasm 2.0 spec.
//!   - i32.reinterpret_f32 / i64.reinterpret_f64 — FMOV {W,X} from
//!     {S,D} (bit-cast, FP → GPR).
//!   - f32.reinterpret_i32 / f64.reinterpret_i64 — FMOV {S,D} from
//!     {W,X} (bit-cast, GPR → FP).
//!   - f32.demote_f64 / f64.promote_f32 — FCVT (FP-width crossing).
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// `i32.wrap_i64` and `i64.extend_i32_u` both lower to MOV Wd, Wn
/// (= ORR Wd, WZR, Wn). The W-write implicitly zeros upper 32 bits
/// of the X register.
pub fn emitWrap32(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.src);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(wd, 31, wn));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// `i64.extend_i32_s` — SXTW Xd, Wn (sign-extend 32 → 64).
pub fn emitExtendI32S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.src);
    const xd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSxtw(xd, wn));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// Int → float convert. Source is GPR (i32 → W, i64 → X), dest
/// is V (f32 → S, f64 → D). 8 variants total: SCVTF (signed) /
/// UCVTF (unsigned) × {SfromW, SfromX, DfromW, DfromX}.
pub fn emitConvertIntToFloat(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const src = try gpr.resolveGpr(ctx.alloc, args.src);
    const vd = try gpr.resolveFp(ctx.alloc, args.result);
    const word: u32 = switch (ins.op) {
        .@"f32.convert_i32_s" => inst.encScvtfSFromW(vd, src),
        .@"f32.convert_i32_u" => inst.encUcvtfSFromW(vd, src),
        .@"f32.convert_i64_s" => inst.encScvtfSFromX(vd, src),
        .@"f32.convert_i64_u" => inst.encUcvtfSFromX(vd, src),
        .@"f64.convert_i32_s" => inst.encScvtfDFromW(vd, src),
        .@"f64.convert_i32_u" => inst.encUcvtfDFromW(vd, src),
        .@"f64.convert_i64_s" => inst.encScvtfDFromX(vd, src),
        .@"f64.convert_i64_u" => inst.encUcvtfDFromX(vd, src),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// Wasm 2.0 saturating trunc — float → int with saturation. ARM64
/// FCVTZS / FCVTZU natively saturate on overflow and return 0 for
/// NaN, matching Wasm 2.0 spec exactly. Source is V (S/D), dest is
/// GPR (W/X). 8 variants: signed/unsigned × {WfromS, WfromD,
/// XfromS, XfromD}.
pub fn emitTruncSat(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const vn = try gpr.resolveFp(ctx.alloc, args.src);
    const dest = try gpr.resolveGpr(ctx.alloc, args.result);
    const word: u32 = switch (ins.op) {
        .@"i32.trunc_sat_f32_s" => inst.encFcvtzsWFromS(dest, vn),
        .@"i32.trunc_sat_f32_u" => inst.encFcvtzuWFromS(dest, vn),
        .@"i32.trunc_sat_f64_s" => inst.encFcvtzsWFromD(dest, vn),
        .@"i32.trunc_sat_f64_u" => inst.encFcvtzuWFromD(dest, vn),
        .@"i64.trunc_sat_f32_s" => inst.encFcvtzsXFromS(dest, vn),
        .@"i64.trunc_sat_f32_u" => inst.encFcvtzuXFromS(dest, vn),
        .@"i64.trunc_sat_f64_s" => inst.encFcvtzsXFromD(dest, vn),
        .@"i64.trunc_sat_f64_u" => inst.encFcvtzuXFromD(dest, vn),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// `i32.reinterpret_f32` — FMOV Wd, Sn (bit-cast, no value change).
pub fn emitReinterpretI32FromF32(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const vn = try gpr.resolveFp(ctx.alloc, args.src);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovWFromS(wd, vn));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// `i64.reinterpret_f64` — FMOV Xd, Dn (bit-cast).
pub fn emitReinterpretI64FromF64(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const vn = try gpr.resolveFp(ctx.alloc, args.src);
    const xd = try gpr.resolveGpr(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovXFromD(xd, vn));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// `f32.reinterpret_i32` — FMOV Sd, Wn (bit-cast).
pub fn emitReinterpretF32FromI32(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const wn = try gpr.resolveGpr(ctx.alloc, args.src);
    const vd = try gpr.resolveFp(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovStoFromW(vd, wn));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// `f64.reinterpret_i64` — FMOV Dd, Xn (bit-cast).
pub fn emitReinterpretF64FromI64(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const xn = try gpr.resolveGpr(ctx.alloc, args.src);
    const vd = try gpr.resolveFp(ctx.alloc, args.result);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovDtoFromX(vd, xn));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// `f32.demote_f64` and `f64.promote_f32`. Both src and dest are
/// V slots. FCVT shrinks/widens the FP value preserving NaN /
/// inf / sign per IEEE-754.
pub fn emitFloatDemotePromote(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const vn = try gpr.resolveFp(ctx.alloc, args.src);
    const vd = try gpr.resolveFp(ctx.alloc, args.result);
    const word: u32 = switch (ins.op) {
        .@"f32.demote_f64"  => inst.encFcvtSFromD(vd, vn),
        .@"f64.promote_f32" => inst.encFcvtDFromS(vd, vn),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
