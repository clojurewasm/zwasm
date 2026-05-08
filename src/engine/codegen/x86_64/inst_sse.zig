//! x86_64 SSE / scalar FP encoder family — Intel SDM Vol 2
//! §3.2 MOVAPS/MOVD/MOVQ + Vol 2 §3.5 SSE/SSE2 scalar arithmetic
//! (ADDSS/ADDSD/MULSS/…/UCOMISS/UCOMISD) + Vol 2 §3.5 SSE4.1
//! ROUNDSS/ROUNDSD + Vol 2 §3.5 CVTSI2SS/CVTTSS2SI conversions.
//! Covers MOVSS / MOVSD memory ops with SIB base+index addressing
//! and RBP / RSP disp8 / disp32 stack-slot variants.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const inst = @import("inst.zig");
const reg_class = @import("reg_class.zig");

const Gpr = reg_class.Gpr;
const Xmm = reg_class.Xmm;
const EncodedInsn = inst.EncodedInsn;
const SseScalarKind = inst.SseScalarKind;
const SsePackedKind = inst.SsePackedKind;
const encodeRex = inst.encodeRex;
const encodeModrm = inst.encodeModrm;
const encodeSib = inst.encodeSib;

/// `MOVSS [RBP + disp8], xmm` (F3 0F 11 /r) — store 32-bit FP
/// scalar to a stack slot. f32 local-store path (chunk 7).
pub fn encStoreXmmF32MemRBP(disp: i8, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVSS xmm, [RBP + disp8]` (F3 0F 10 /r).
pub fn encLoadXmmF32MemRBP(dst: Xmm, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVSD [RBP + disp8], xmm` (F2 0F 11 /r) — 64-bit FP store.
pub fn encStoreXmmF64MemRBP(disp: i8, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVSD xmm, [RBP + disp8]` (F2 0F 10 /r).
pub fn encLoadXmmF64MemRBP(dst: Xmm, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVSS [RBP + disp32], xmm` — disp32 form of `encStoreXmmF32MemRBP`.
pub fn encStoreXmmF32MemRBPDisp32(disp: i32, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSS xmm, [RBP + disp32]` — disp32 form of `encLoadXmmF32MemRBP`.
pub fn encLoadXmmF32MemRBPDisp32(dst: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b10, dst.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSD [RBP + disp32], xmm` — disp32 form of `encStoreXmmF64MemRBP`.
pub fn encStoreXmmF64MemRBPDisp32(disp: i32, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSD xmm, [RBP + disp32]` — disp32 form of `encLoadXmmF64MemRBP`.
pub fn encLoadXmmF64MemRBPDisp32(dst: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b10, dst.low3(), 0b101));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSS [RSP + disp32], xmm` (F3 0F 11 /r). f32 caller-side
/// stack arg.
pub fn encStoreXmmF32MemRSPDisp32(src: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b100));
    enc.push(0x24);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVSD [RSP + disp32], xmm` (F2 0F 11 /r). f64 caller-side
/// stack arg.
pub fn encStoreXmmF64MemRSPDisp32(src: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b10, src.low3(), 0b100));
    enc.push(0x24);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVD xmm, r/m32` (0x66 prefix + 0x0F 0x6E /r) — copy a
/// 32-bit GPR's low half into an XMM (zero-extends the high
/// 96 bits). xmm in ModR/M.reg, gpr in r/m. Used by f32.const
/// to plant the IEEE-754 bit pattern in an XMM slot.
pub fn encMovdXmmFromR32(xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(false, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x6E);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVQ xmm, r/m64` (0x66 prefix + REX.W + 0x0F 0x6E /r) —
/// 64-bit MOVD-equivalent. REX.W is mandatory. Used by
/// f64.const after the bit pattern is materialised in a GPR
/// via MOVABS.
pub fn encMovqXmmFromR64(xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    enc.push(encodeRex(true, xmm_dst.extBit(), 0, gpr_src.extBit()));
    enc.push(0x0F);
    enc.push(0x6E);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVAPS xmm, xmm` (0x0F 0x28 /r) — 128-bit aligned move
/// between XMM registers. Used as the FP equivalent of
/// `MOV r32, r32` (lhs → dst before the SSE binary op).
/// dst occupies ModR/M.reg, src occupies r/m.
pub fn encMovapsXmmXmm(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x28);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVSS / MOVSD xmm,[base+idx]` and the store direction —
/// scalar single/double FP load/store with SIB scale=1 (no
/// displacement). `is_store` toggles opcode 0x10 (load) / 0x11
/// (store). `scalar_kind` selects the F3 (f32) / F2 (f64) prefix.
/// xmm goes into ModR/M.reg, base into SIB.base, idx into
/// SIB.index.
pub fn encMovssMovsdMemBaseIdx(scalar_kind: SseScalarKind, is_store: bool, xmm: Xmm, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@intFromEnum(scalar_kind));
    if (xmm.extBit() != 0 or base.extBit() != 0 or idx.extBit() != 0) {
        enc.push(encodeRex(false, xmm.extBit(), idx.extBit(), base.extBit()));
    }
    enc.push(0x0F);
    enc.push(if (is_store) @as(u8, 0x11) else 0x10);
    enc.push(encodeModrm(0b00, xmm.low3(), 0b100)); // mod=00, rm=4 → SIB
    enc.push(encodeSib(0b00, idx.low3(), base.low3())); // scale=1
    return enc;
}

/// `CVTTSS2SI r/m32 or r/m64, xmm/m32-or-64` family — scalar
/// truncating float→signed-int conversion.
///   F3 [REX?] 0F 2C /r (CVTTSS2SI; src f32 via prefix)
///   F2 [REX?] 0F 2C /r (CVTTSD2SI; src f64 via prefix)
/// `dst_is_64` toggles REX.W for the i64 destination variant.
/// dst is in ModR/M.reg (gpr), src is in r/m (xmm).
///
/// **Saturation behaviour**: returns INT_MIN of the destination
/// width (0x80000000 for r32, 0x8000000000000000 for r64) when
/// the source is NaN OR out of range. Used as the sentinel by
/// emitFpTruncSatSigned to drive the spec-correct saturation.
pub fn encCvttScalar2Int(scalar_kind: SseScalarKind, dst_is_64: bool, gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@intFromEnum(scalar_kind));
    if (dst_is_64 or gpr_dst.extBit() != 0 or xmm_src.extBit() != 0) {
        enc.push(encodeRex(dst_is_64, gpr_dst.extBit(), 0, xmm_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2C);
    enc.push(encodeModrm(0b11, gpr_dst.low3(), xmm_src.low3()));
    return enc;
}

/// `CVTSI2SS xmm, r/m32` / `CVTSI2SD xmm, r/m64` family —
/// signed integer to scalar float conversion.
///   F3 [REX?] 0F 2A /r (CVTSI2SS, src f32-aware via prefix)
///   F2 [REX?] 0F 2A /r (CVTSI2SD)
/// `src_is_64` toggles REX.W for the i64 source variant.
/// xmm in ModR/M.reg, gpr in r/m.
pub fn encCvtsi2Scalar(scalar_kind: SseScalarKind, src_is_64: bool, xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@intFromEnum(scalar_kind));
    if (src_is_64 or xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(src_is_64, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2A);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVD r/m32, xmm` (0x66 + 0x0F 0x7E /r) — extract the low
/// 32 bits of an XMM into a GPR. Mirror of `encMovdXmmFromR32`.
/// xmm in ModR/M.reg, gpr in r/m.
pub fn encMovdR32FromXmm(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_src.extBit() != 0 or gpr_dst.extBit() != 0) {
        enc.push(encodeRex(false, xmm_src.extBit(), 0, gpr_dst.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x7E);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    return enc;
}

/// `MOVQ r/m64, xmm` (0x66 + REX.W + 0x0F 0x7E /r) — extract
/// the low 64 bits of an XMM into a GPR. REX.W mandatory.
pub fn encMovqR64FromXmm(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    enc.push(encodeRex(true, xmm_src.extBit(), 0, gpr_dst.extBit()));
    enc.push(0x0F);
    enc.push(0x7E);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    return enc;
}

/// SSE2 packed bitwise binary (ANDPS/ANDPD/ORPS/ORPD/XORPS/XORPD).
/// Encoding: `[<prefix>] [REX?] 0x0F <opcode> ModR/M`. Used by
/// abs (ANDPS/ANDPD with 0x7F.. mask) and neg (XORPS/XORPD with
/// 0x80.. sign bit). Opcode: 0x54=AND, 0x56=OR, 0x57=XOR.
pub fn encSsePackedBinary(kind: SsePackedKind, opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (kind != .f32) enc.push(@intFromEnum(kind));
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `ROUNDSS xmm, xmm/m32, imm8` (66 0F 3A 0A /r ib) — SSE4.1
/// scalar single-precision round with mode imm8: 0=nearest
/// (ties to even), 1=floor (toward -inf), 2=ceil (toward +inf),
/// 3=trunc (toward zero), 4=current MXCSR rounding mode.
pub fn encRoundss(dst: Xmm, src: Xmm, mode: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x0A);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(mode);
    return enc;
}

/// `ROUNDSD xmm, xmm/m64, imm8` (66 0F 3A 0B /r ib) — SSE4.1
/// scalar double-precision round; same mode encoding as ROUNDSS.
pub fn encRoundsd(dst: Xmm, src: Xmm, mode: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x0B);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(mode);
    return enc;
}

/// `UCOMISS xmm, xmm/m32` (0x0F 0x2E /r) — Unordered Compare
/// Scalar Single. Sets ZF / CF / PF on the comparison result:
/// equal → ZF=1, CF=0, PF=0; less → ZF=0, CF=1, PF=0; greater →
/// ZF=0, CF=0, PF=0; unordered (NaN) → ZF=1, CF=1, PF=1. Used
/// by emitFpCompare to drive SETcc.
pub fn encUcomiss(a: Xmm, b: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (a.extBit() != 0 or b.extBit() != 0) {
        enc.push(encodeRex(false, a.extBit(), 0, b.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2E);
    enc.push(encodeModrm(0b11, a.low3(), b.low3()));
    return enc;
}

/// `UCOMISD xmm, xmm/m64` (0x66 prefix + 0x0F 0x2E /r) —
/// double-precision counterpart of UCOMISS. Same flag
/// semantics.
pub fn encUcomisd(a: Xmm, b: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (a.extBit() != 0 or b.extBit() != 0) {
        enc.push(encodeRex(false, a.extBit(), 0, b.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2E);
    enc.push(encodeModrm(0b11, a.low3(), b.low3()));
    return enc;
}

/// SSE2 scalar binary op (ADDSS / ADDSD / SUBSS / SUBSD /
/// MULSS / MULSD / DIVSS / DIVSD). Encoding:
///   <prefix> [REX?] 0x0F <opcode> ModR/M
/// where `<prefix>` is F3 (f32) or F2 (f64); `<opcode>` is
/// 0x58 (add), 0x5C (sub), 0x59 (mul), 0x5E (div).
/// dst occupies ModR/M.reg, src occupies r/m.
pub fn encSseScalarBinary(kind: SseScalarKind, opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@intFromEnum(kind));
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}
