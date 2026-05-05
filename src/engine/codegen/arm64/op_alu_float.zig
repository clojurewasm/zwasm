//! ARM64 emit pass — floating-point ALU / cmp / round handlers
//! (f32 + f64).
//!
//! Per ADR-0021 sub-deliverable b (§9.7 / 7.5d sub-b emit.zig
//! 9-module split): all ZirOp handlers whose inputs and outputs
//! are FP-class (f32 / f64). Cross-class conversions
//! (f*.convert_i*, i*.trunc_f*, *.reinterpret_*, demote/promote)
//! live in op_convert.zig (chunk 5).
//!
//! Handlers in this module:
//!   - f32 / f64 binary: add, sub, mul, div — direct FADD/FSUB/
//!     FMUL/FDIV per width.
//!   - f32 / f64 unary: abs, neg, sqrt, ceil, floor, trunc,
//!     nearest — direct FABS/FNEG/FSQRT + FRINT{P,M,Z,N} per
//!     width.
//!   - f32 / f64 copysign — ARM has no single op; emit FMOV →
//!     bit-mask detour using IP0/IP1 + the GPR mapping of the
//!     result slot as scratch.
//!   - f32 / f64 min, max — direct FMIN/FMAX per width.
//!   - f32 / f64 compare (eq..ge) — FCMP + CSET-W. Wasm FP cmp
//!     is ordered (NaN → false); ARM Cond codes naturally satisfy
//!     this for the codes used (.eq/.ne/.mi/.gt/.ls/.ge).
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

/// f32 / f64 binary ALU: add, sub, mul, div.
pub fn emitFloatBinary(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const vn = try gpr.resolveFp(ctx.alloc, args.lhs);
    const vm = try gpr.resolveFp(ctx.alloc, args.rhs);
    const vd = try gpr.resolveFp(ctx.alloc, args.result);
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
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// f32 / f64 unary: abs, neg, sqrt, ceil, floor, trunc, nearest.
/// Rounding maps to FRINT{P,M,Z,N} (positive / minus / zero /
/// nearest-even).
pub fn emitFloatUnary(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popUnary();
    const vn = try gpr.resolveFp(ctx.alloc, args.src);
    const vd = try gpr.resolveFp(ctx.alloc, args.result);
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
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// f32 / f64 copysign. ARM has no single copysign; emit FMOV →
/// bit-mask detour. Wasm: result = (|x|) | sign(y).
///
/// 8-instr sequence using IP0 (X16) as mask scratch + IP1 (X17)
/// as sign scratch + W_a = the GPR mapping of the result slot
/// (same slot id as the V-result, distinct physical reg):
///
///   MOVZ X16, #0
///   MOVK X16, #0x8000, lsl #(16 for f32 / 48 for f64)
///   FMOV W_a, S_x  (or X_a, D_x for f64)
///   BIC W_a, W_a, W16   ; magnitude of x
///   FMOV W17, S_y  (or X17, D_y)
///   AND W17, W17, W16   ; sign of y
///   ORR W_a, W_a, W17
///   FMOV S_d, W_a  (or D_d, X_a)
pub fn emitFloatCopysign(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary(); // lhs = magnitude source, rhs = sign source
    const vn_x = try gpr.resolveFp(ctx.alloc, args.lhs);
    const vm_y = try gpr.resolveFp(ctx.alloc, args.rhs);
    const vd = try gpr.resolveFp(ctx.alloc, args.result);
    const w_a = try gpr.resolveGpr(ctx.alloc, args.result);
    const ip0: Xn = 16;
    const ip1: Xn = 17;
    const is_d = ins.op == .@"f64.copysign";
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip0, 0));
    const mask_lsl_hw: u2 = if (is_d) 3 else 1;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip0, 0x8000, mask_lsl_hw));
    if (is_d) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovXFromD(w_a, vn_x));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBicRegX(w_a, w_a, ip0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovXFromD(ip1, vm_y));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAndReg(ip1, ip1, ip0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(w_a, w_a, ip1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovDtoFromX(vd, w_a));
    } else {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovWFromS(w_a, vn_x));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBicRegW(w_a, w_a, ip0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovWFromS(ip1, vm_y));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAndRegW(ip1, ip1, ip0));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(w_a, w_a, ip1));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovStoFromW(vd, w_a));
    }
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// f32 / f64 min, max — direct FMIN / FMAX per width.
pub fn emitFloatMinMax(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const vn = try gpr.resolveFp(ctx.alloc, args.lhs);
    const vm = try gpr.resolveFp(ctx.alloc, args.rhs);
    const vd = try gpr.resolveFp(ctx.alloc, args.result);
    const word: u32 = switch (ins.op) {
        .@"f32.min" => inst.encFMinS(vd, vn, vm),
        .@"f32.max" => inst.encFMaxS(vd, vn, vm),
        .@"f64.min" => inst.encFMinD(vd, vn, vm),
        .@"f64.max" => inst.encFMaxD(vd, vn, vm),
        else => unreachable,
    };
    try gpr.writeU32(ctx.allocator, ctx.buf, word);
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}

/// f32 / f64 compare (eq, ne, lt, gt, le, ge). FCMP S/D → CSET W.
/// Wasm FP cmp is ordered: NaN inputs always yield false. The ARM
/// Cond codes used here naturally satisfy that:
/// - eq/ne: EQ/NE (Z flag; FCMP unordered → Z=0,V=1).
/// - lt: MI (N=1; FCMP unordered → N=0).
/// - gt: GT (Z=0 ∧ N=V).
/// - le: LS (C=0 ∨ Z=1; FCMP unordered → C=1).
/// - ge: GE (N=V; FCMP unordered → N=0,V=1 → false).
pub fn emitFloatCompare(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const args = try ctx.popBinary();
    const vn = try gpr.resolveFp(ctx.alloc, args.lhs);
    const vm = try gpr.resolveFp(ctx.alloc, args.rhs);
    const wd = try gpr.resolveGpr(ctx.alloc, args.result);
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
    try gpr.writeU32(ctx.allocator, ctx.buf, if (is_d) inst.encFCmpD(vn, vm) else inst.encFCmpS(vn, vm));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(wd, cond));
    try ctx.pushed_vregs.append(ctx.allocator, args.result);
}
