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

const std = @import("std");

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

/// `MOVUPS [RBP + disp8], xmm` (0F 11 /r) — 128-bit unaligned
/// packed-single store to a stack slot. §9.9 / 9.9-e-2 v128
/// local-store path; mirror of `encStoreXmmF32MemRBP` minus the
/// F3 prefix (no prefix → MOVUPS form per Intel SDM Vol 2A).
/// Use MOVUPS rather than MOVAPS because the v128 local slot's
/// RBP-relative offset depends on `localDisp` and is not
/// guaranteed to be 16-byte aligned.
pub fn encStoreXmmV128MemRBP(disp: i8, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x11);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVUPS xmm, [RBP + disp8]` (0F 10 /r) — 128-bit load.
pub fn encLoadXmmV128MemRBP(dst: Xmm, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOVUPS [RBP + disp32], xmm` — disp32 form of
/// `encStoreXmmV128MemRBP`.
pub fn encStoreXmmV128MemRBPDisp32(disp: i32, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
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

/// `MOVUPS xmm, [RBP + disp32]` — disp32 form of
/// `encLoadXmmV128MemRBP`.
pub fn encLoadXmmV128MemRBPDisp32(dst: Xmm, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
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

/// `MOVUPS xmm, [base + disp32]` and the store direction — 128-bit
/// unaligned packed-single load/store at a 32-bit displacement
/// from `base`. ADR-0052 §3 — v128 global.get/set emit pattern:
/// the runtime-ptr scratch (RAX) is reloaded with `globals_base`
/// once via `MOV RAX, [R15 + globals_base_off]`, then MOVUPS
/// references `[RAX + globals_offsets[idx]]`. `base.low3() == 4`
/// (RSP/R12) is rejected by the encoder because ModR/M=10b with
/// rm=100 escapes to SIB; v128 global storage never uses RSP as
/// base, so the rejection is a guard not a constraint.
pub fn encMovupsXmmMemBaseDisp32(is_store: bool, xmm: Xmm, base: Gpr, disp: i32) EncodedInsn {
    std.debug.assert(base.low3() != 4); // SIB escape — unsupported here
    var enc: EncodedInsn = .{};
    if (xmm.extBit() != 0 or base.extBit() != 0) {
        enc.push(encodeRex(false, xmm.extBit(), 0, base.extBit()));
    }
    enc.push(0x0F);
    enc.push(if (is_store) @as(u8, 0x11) else 0x10);
    enc.push(encodeModrm(0b10, xmm.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOVUPS xmm, [base+idx]` and the store direction — 128-bit
/// unaligned packed-single load/store with SIB scale=1 (no
/// displacement). No prefix (SSE base-set MOVUPS is the no-prefix
/// form per Intel SDM Vol 2A "MOVUPS"; the 66/F2/F3 prefixed
/// forms are MOVUPD/MOVSD/MOVSS respectively).
/// `is_store` toggles opcode 0x10 (load) / 0x11 (store).
/// xmm goes into ModR/M.reg, base into SIB.base, idx into
/// SIB.index. Used by v128.load / v128.store (Wasm spec §4.4.7).
pub fn encMovupsMemBaseIdx(is_store: bool, xmm: Xmm, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
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

/// SSE2 / SSE4.1 packed integer binop family — internal helper.
/// The public per-op encoders below differ in the opcode byte
/// and (for SSE4.1 ops like PMULLD) an optional secondary escape
/// byte (0x38 for the 66 0F 38 .. group; 0x3A for the imm8-bearing
/// 66 0F 3A .. group already used by `encRoundss`/`encRoundsd`).
/// Following ARM64's `inst_neon.encAdd16B/8H/4S/2D` pattern (per
/// ROADMAP P7 backend parity), each public encoder is its own
/// self-documenting wrapper rather than a single parameterised
/// entry point — the call site reads the op family directly from
/// the function name.
///
/// `escape2 == 0` skips the secondary escape byte (canonical SSE2
/// form: 66 [REX?] 0F <opcode> /r). `escape2 == 0x38` selects the
/// SSE4.1 / SSSE3 form (e.g. PMULLD): 66 [REX?] 0F 38 <opcode> /r.
///
/// Wasm spec §4.4.4 (packed integer arithmetic) — element-wise
/// wraparound. Intel SDM Vol 2 PADDB/PADDW/PADDD/PADDQ +
/// PSUBB/PSUBW/PSUBD/PSUBQ + PMULLW (SSE2) + PMULLD (SSE4.1).
fn encSsePackedIntBinopExt(escape2: u8, opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    if (escape2 != 0) enc.push(escape2);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// Backward-compatible wrapper for the no-secondary-escape SSE2
/// path. Existing add/sub encoders dispatch through this one.
fn encSsePackedIntBinop(opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0, opcode, dst, src);
}

/// `PADDB xmm, xmm` (66 [REX?] 0F FC /r) — packed 8-bit add (16
/// lanes). Wasm `i8x16.add`.
pub fn encPaddB(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFC, dst, src);
}

/// `PADDW xmm, xmm` (66 [REX?] 0F FD /r) — packed 16-bit add (8
/// lanes). Wasm `i16x8.add`.
pub fn encPaddW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFD, dst, src);
}

/// `PADDD xmm, xmm` (66 [REX?] 0F FE /r) — packed 32-bit add (4
/// lanes). Wasm `i32x4.add`. dst = dst + src (two-address; the
/// caller copies `MOVAPS dst, lhs` before this op when dst != lhs).
pub fn encPaddD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFE, dst, src);
}

/// `PADDQ xmm, xmm` (66 [REX?] 0F D4 /r) — packed 64-bit add (2
/// lanes). Wasm `i64x2.add`.
pub fn encPaddQ(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD4, dst, src);
}

/// `PSUBB xmm, xmm` (66 [REX?] 0F F8 /r) — packed 8-bit sub.
/// Wasm `i8x16.sub`.
pub fn encPsubB(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF8, dst, src);
}

/// `PSUBW xmm, xmm` (66 [REX?] 0F F9 /r) — packed 16-bit sub.
/// Wasm `i16x8.sub`.
pub fn encPsubW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF9, dst, src);
}

/// `PSUBD xmm, xmm` (66 [REX?] 0F FA /r) — packed 32-bit sub.
/// Wasm `i32x4.sub`.
pub fn encPsubD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFA, dst, src);
}

/// `PSUBQ xmm, xmm` (66 [REX?] 0F FB /r) — packed 64-bit sub.
/// Wasm `i64x2.sub`.
pub fn encPsubQ(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFB, dst, src);
}

/// `PMULLW xmm, xmm` (66 [REX?] 0F D5 /r) — SSE2 packed 16-bit
/// multiply, low 16 bits per lane (8 lanes). Wasm `i16x8.mul`
/// (Wasm spec §4.4.4 — modular wraparound at the lane width).
pub fn encPmullW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD5, dst, src);
}

/// `PMULLD xmm, xmm` (66 [REX?] 0F 38 40 /r) — SSE4.1 packed
/// 32-bit multiply, low 32 bits per lane (4 lanes). Wasm
/// `i32x4.mul` (Wasm spec §4.4.4 — modular wraparound at the
/// lane width). Per ADR-0041 §"5. SSE4.1 minimum baseline" this
/// is the first SSE4.1-exclusive op zwasm v2 emits; runtime CPU
/// feature detection at engine init refuses to start on hosts
/// lacking SSE4.1.
pub fn encPmullD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x40, dst, src);
}

/// `PMULUDQ xmm, xmm` (66 [REX?] 0F F4 /r) — SSE2 packed unsigned
/// 32×32 → 64 multiply. Reads the **low 32 bits** of each 64-bit
/// lane in source and destination; produces a 64-bit unsigned
/// product per 64-bit lane (2 lanes total). Used by `i64x2.mul`
/// synthesis (which has no native SSE4.1 instruction; AVX-512
/// VPMULLQ is beyond ADR-0041's baseline).
pub fn encPmuludq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF4, dst, src);
}

/// `PMULDQ xmm, xmm` (66 [REX?] 0F 38 28 /r) — SSE4.1 packed
/// SIGNED 32×32 → 64 multiply. Reads the **low 32 bits** of each
/// 64-bit lane in source and destination as signed i32; produces
/// a signed i64 product per 64-bit lane (2 lanes total). Wasm
/// `i64x2.extmul_{low,high}_i32x4_s` per cranelift `lower.isle`
/// extmul rule.
pub fn encPmuldq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x28, dst, src);
}

/// SSE2 packed shift-by-immediate /X-group helper. The
/// `66 0F <opcode> /<group> ib` encoding has ModR/M.reg = group
/// code (selecting the op within the family) and ModR/M.rm = the
/// XMM being shifted in-place. Opcodes encode the lane width:
///   0x71 = W-form (16-bit lanes)
///   0x72 = D-form (32-bit lanes)
///   0x73 = Q-form (64-bit lanes)
/// Group codes (constant per op):
///   /2 = PSRLW / PSRLD / PSRLQ (logical shift right)
///   /4 = PSRAW / PSRAD          (arithmetic shift right; no Q-form)
///   /6 = PSLLW / PSLLD / PSLLQ  (logical shift left)
///
/// REX.B applies when the destination is XMM8..XMM15 (touches
/// ModR/M.rm). REX.R is unused (group code lives in reg field
/// but is a constant, not a register).
fn encSsePackedShiftImmGroup(opcode: u8, group: u3, dst: Xmm, count: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0) {
        enc.push(encodeRex(false, 0, 0, dst.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, group, dst.low3()));
    enc.push(count);
    return enc;
}

/// `PSLLD xmm, imm8` (66 [REX.B?] 0F 72 /6 ib) — SSE2 packed
/// 32-bit logical shift left by immediate count. Used by §9.7-ad
/// FP abs/neg sign-mask synthesis: PCMPEQB ones + PSLLD-imm 31
/// → 0x80000000 per dword.
pub fn encPslldImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x72, 6, dst, count);
}

/// `PSLLW xmm, imm8` (66 [REX.B?] 0F 71 /6 ib) — SSE2 packed
/// 16-bit logical shift left by immediate count. Used by §9.7-aq
/// `i32x4.extadd_pairwise_i16x8_u` sign-flip-mask synthesis:
/// PCMPEQB ones + PSLLW-imm 15 → 0x8000 per word (high bit set).
pub fn encPsllwImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x71, 6, dst, count);
}

/// `PSRLW xmm, imm8` (66 [REX.B?] 0F 71 /2 ib) — SSE2 packed
/// 16-bit logical shift right by immediate count. Used by
/// §9.7-v `i8x16.shr_u` synthesis: shift 0xFFFF replicated by
/// 8 to produce 0x00FF per word, then by `c` to produce
/// `0x00FF >> c` whose low byte is the per-byte mask `0xFF >> c`.
pub fn encPsrlwImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x71, 2, dst, count);
}

/// `PSRLD xmm, imm8` (66 [REX.B?] 0F 72 /2 ib) — SSE2 packed
/// 32-bit logical shift right by immediate count. Used by f32x4
/// fmin/fmax NaN-correction synthesis to compute the
/// `nan_fraction_mask` (cranelift `lower.isle` shift=10).
pub fn encPsrldImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x72, 2, dst, count);
}

/// `PSRLQ xmm, imm8` (66 [REX.B?] 0F 73 /2 ib) — SSE2 packed
/// 64-bit logical shift right by immediate count. Used by
/// i64x2.mul synthesis (extract high dword) and f64x2 fmin/fmax
/// NaN-correction synthesis (shift=13).
pub fn encPsrlqImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x73, 2, dst, count);
}

/// `PSLLQ xmm, imm8` (66 [REX.B?] 0F 73 /6 ib) — SSE2 packed
/// 64-bit logical shift left by immediate count. Used by
/// i64x2.mul synthesis to position the cross-term sum in the
/// high 32 bits before adding to the low product.
pub fn encPsllqImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x73, 6, dst, count);
}

/// `ORPS xmm, xmm` ([REX?] 0F 56 /r) — SSE bitwise OR of packed
/// single-precision FP values. Bit-identical to integer 128-bit
/// OR but in the FP unit (saves a domain-crossing penalty on
/// older microarchitectures). Wasm: f32x4.fmin synthesis.
pub fn encOrps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x56, dst, src);
}

/// `ORPD xmm, xmm` (66 [REX?] 0F 56 /r) — SSE2 bitwise OR for f64x2
/// fmin synthesis.
pub fn encOrpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x56, dst, src);
}

/// `XORPS xmm, xmm` ([REX?] 0F 57 /r) — SSE bitwise XOR. Wasm:
/// f32x4.fmax synthesis (max_xor = max1 XOR max2).
pub fn encXorps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x57, dst, src);
}

/// `XORPD xmm, xmm` (66 [REX?] 0F 57 /r) — SSE2 bitwise XOR for
/// f64x2.fmax synthesis.
pub fn encXorpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x57, dst, src);
}

/// `ANDPS xmm, xmm` ([REX?] 0F 54 /r) — SSE bitwise AND of packed
/// single-precision FP values. Wasm: NaN-mask propagation in
/// trunc-sat synthesis.
pub fn encAndps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x54, dst, src);
}

/// `ANDPD xmm, xmm` (66 [REX?] 0F 54 /r) — SSE2 bitwise AND.
pub fn encAndpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x54, dst, src);
}

/// `ANDNPS xmm, xmm` ([REX?] 0F 55 /r) — SSE bitwise AND-NOT:
/// `dst = ~dst & src`. Wasm: f32x4.fmin/fmax synthesis (mask off
/// non-canonical NaN payload bits).
pub fn encAndnps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x55, dst, src);
}

/// `ANDNPD xmm, xmm` (66 [REX?] 0F 55 /r) — SSE2 bitwise AND-NOT
/// for f64x2 fmin/fmax synthesis.
pub fn encAndnpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x55, dst, src);
}

/// `PSHUFD xmm, xmm, imm8` (66 [REX?] 0F 70 /r ib) — SSE2 shuffle
/// 32-bit lanes from `src` into `dst` per a 4-lane permutation
/// imm8. Each pair of imm8 bits selects a source lane: bits[1:0]
/// → dst lane 0, bits[3:2] → lane 1, bits[5:4] → lane 2,
/// bits[7:6] → lane 3. `imm8 = 0x00` broadcasts source lane 0 to
/// every destination lane (used by `i32x4.splat` after a MOVD
/// loads the scalar i32 into the low 32 bits of the XMM).
pub fn encPshufd(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x70);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

/// `PEXTRD r/m32, xmm, imm8` (66 [REX?] 0F 3A 16 /r ib) — SSE4.1
/// extract a 32-bit lane from `xmm_src` (lane 0..3 selected by
/// `lane` immediate) into `gpr_dst`. Per Intel SDM the
/// ModR/M.reg field carries the **source XMM** (not the dst GPR);
/// ModR/M.r/m carries the destination GPR. REX.R applies to the
/// XMM (reg field); REX.B applies to the GPR (r/m field).
///
/// Used by `i32x4.extract_lane` (Wasm spec §4.4.3 lane access).
pub fn encPextrD(gpr_dst: Gpr, xmm_src: Xmm, lane: u2) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_src.extBit() != 0 or gpr_dst.extBit() != 0) {
        enc.push(encodeRex(false, xmm_src.extBit(), 0, gpr_dst.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x16);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PEXTRQ r/m64, xmm, imm8` (66 REX.W 0F 3A 16 /r ib) — SSE4.1
/// REX.W variant of PEXTRD: extract a 64-bit lane (lane = u1; 0
/// or 1) from `xmm_src` into `gpr_dst`. Same opcode byte (0x16);
/// REX.W=1 promotes the operand size.
///
/// Used by `i64x2.extract_lane` (Wasm spec §4.4.3 lane access).
pub fn encPextrQ(gpr_dst: Gpr, xmm_src: Xmm, lane: u1) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    enc.push(encodeRex(true, xmm_src.extBit(), 0, gpr_dst.extBit()));
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x16);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PINSRD xmm, r/m32, imm8` (66 [REX?] 0F 3A 22 /r ib) — SSE4.1
/// insert a 32-bit value from `gpr_src` into lane `lane` of
/// `xmm_dst`. The other three lanes of `xmm_dst` are preserved
/// (caller is responsible for `MOVAPS xmm_dst, input_xmm` first
/// when the result vreg differs from the input v128 vreg).
///
/// Per Intel SDM the ModR/M.reg field carries the **destination
/// XMM** (RVMI shape); ModR/M.r/m carries the source GPR. REX.R
/// applies to the XMM, REX.B to the GPR — opposite operand
/// orientation from PEXTRD's RMI shape.
///
/// Used by `i32x4.replace_lane` (Wasm spec §4.4.3 lane access).
pub fn encPinsrD(xmm_dst: Xmm, gpr_src: Gpr, lane: u2) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(false, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x22);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PINSRQ xmm, r/m64, imm8` (66 REX.W 0F 3A 22 /r ib) — SSE4.1
/// 64-bit counterpart of PINSRD. REX.W is mandatory (selects
/// 64-bit operand). Lane is `u1` (only 2 lanes per i64x2 vector).
/// Used by `i64x2.replace_lane`.
pub fn encPinsrQ(xmm_dst: Xmm, gpr_src: Gpr, lane: u1) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    // REX.W is mandatory for the 64-bit form, regardless of
    // whether the operand registers extend.
    enc.push(encodeRex(true, xmm_dst.extBit(), 0, gpr_src.extBit()));
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x22);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PEXTRB r/m8, xmm, imm8` (66 [REX?] 0F 3A 14 /r ib) — SSE4.1
/// extract a byte (8-bit) lane from `xmm_src` (lane 0..15) into
/// the low 8 bits of `gpr_dst`, **zero-extended to 32 bits**.
/// Used by `i8x16.extract_lane_u`; `i8x16.extract_lane_s` calls
/// this then `MOVSX r32, r8` for sign-extension.
///
/// Same RMI operand encoding as PEXTRD (ModR/M.reg = source XMM,
/// ModR/M.r/m = destination GPR).
pub fn encPextrB(gpr_dst: Gpr, xmm_src: Xmm, lane: u4) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_src.extBit() != 0 or gpr_dst.extBit() != 0) {
        enc.push(encodeRex(false, xmm_src.extBit(), 0, gpr_dst.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x14);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PEXTRW r32, xmm, imm8` (66 [REX?] 0F C5 /r ib) — SSE2 form
/// (NOT the SSE4.1 mem-capable 0F 3A 15 form). Extracts a 16-bit
/// lane (0..7) into the low 16 bits of `gpr_dst`, zero-extended
/// to 32 bits. Used by `i16x8.extract_lane_u`;
/// `i16x8.extract_lane_s` follows up with `MOVSX r32, r16`.
///
/// Operand encoding: ModR/M.reg = destination GPR (RMI shape;
/// note this is **opposite** orientation from PEXTRB/D/Q which
/// place the source XMM in reg). REX.R applies to the GPR;
/// REX.B applies to the XMM.
pub fn encPextrW(gpr_dst: Gpr, xmm_src: Xmm, lane: u3) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (gpr_dst.extBit() != 0 or xmm_src.extBit() != 0) {
        enc.push(encodeRex(false, gpr_dst.extBit(), 0, xmm_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xC5);
    enc.push(encodeModrm(0b11, gpr_dst.low3(), xmm_src.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PINSRB xmm, r/m32, imm8` (66 [REX?] 0F 3A 20 /r ib) — SSE4.1
/// insert a byte (low 8 bits of `gpr_src`) into lane 0..15 of
/// `xmm_dst`. Other lanes preserved. Used by `i8x16.replace_lane`.
/// Same RVMI operand encoding as PINSRD (XMM dst in ModR/M.reg,
/// GPR src in r/m).
pub fn encPinsrB(xmm_dst: Xmm, gpr_src: Gpr, lane: u4) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(false, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x20);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PINSRW xmm, r/m32, imm8` (66 [REX?] 0F C4 /r ib) — SSE2 form
/// of word-insert (predates SSE4.1's 3A 21 mem-capable form).
/// Inserts the low 16 bits of `gpr_src` into lane 0..7 of
/// `xmm_dst`. Used by `i16x8.replace_lane`.
/// RVMI operand encoding (XMM dst in reg, GPR src in r/m).
pub fn encPinsrW(xmm_dst: Xmm, gpr_src: Gpr, lane: u3) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(false, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xC4);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PXOR xmm, xmm` (66 [REX?] 0F EF /r) — SSE2 packed XOR; the
/// `PXOR x, x` self-XOR idiom produces a zeroed XMM in 1 byte
/// less than `MOVAPS x, <const0>`. Used by `i8x16.splat` synth
/// to build the all-zero PSHUFB control mask (each byte = 0
/// indexes lane 0 of the source — broadcasting it to all 16
/// destination bytes).
pub fn encPxor(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEF, dst, src);
}

/// `PSHUFB xmm, xmm` (66 [REX?] 0F 38 00 /r) — SSSE3 packed
/// shuffle bytes. For each output byte position i, the
/// instruction reads the corresponding byte of the second
/// operand (the control mask) and uses its low 4 bits to
/// index a byte of the first operand (the destination), or
/// zeroes the output when the high bit of the control byte
/// is set. Used by `i8x16.splat` with an all-zero control to
/// broadcast lane 0.
pub fn encPshufb(dst: Xmm, ctrl: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x00, dst, ctrl);
}

/// `PSHUFLW xmm, xmm, imm8` (F2 [REX?] 0F 70 /r ib) — SSE2
/// shuffle low 4 packed words. The imm8 selects 4 source words
/// (2 bits each) within the lower 64 bits of `src`, writing the
/// chosen 4 words to the lower 64 of `dst`; the upper 64 of
/// `dst` is copied verbatim from `src`. Used by `i16x8.splat`
/// to broadcast the low word of `src` across the four lower
/// lanes (then PSHUFD broadcasts the lower 64 to the upper 64).
pub fn encPshuflw(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x70);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

/// `PUNPCKLQDQ xmm, xmm` (66 [REX?] 0F 6C /r) — SSE2 unpack low
/// qwords. Takes qword 0 of `dst` followed by qword 0 of `src`
/// to produce a 128-bit result `(src.q[0], dst.q[0])` written
/// to `dst`. The `PUNPCKLQDQ x, x` self-unpack idiom broadcasts
/// the low qword to both lanes — used by `i64x2.splat` after
/// `MOVQ xmm, src_gpr` zero-extends the i64 source into the low
/// qword of the XMM.
pub fn encPunpcklqdq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x6C, dst, src);
}

/// `PCMPEQB xmm, xmm` (66 [REX?] 0F 74 /r) — SSE2 packed 8-bit
/// equality compare. Each output byte is 0xFF when the
/// corresponding source/dest bytes match, else 0x00. Wasm
/// `i8x16.eq`. The self-PCMPEQB idiom (`PCMPEQB x, x`) generates
/// an all-ones XMM in 4-5 bytes — used for NOT-via-PXOR in the
/// `ne` path.
pub fn encPcmpeqB(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x74, dst, src);
}

/// `PCMPEQW xmm, xmm` (66 [REX?] 0F 75 /r) — SSE2 packed 16-bit
/// equality compare. 8 lanes. Wasm `i16x8.eq`.
pub fn encPcmpeqW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x75, dst, src);
}

/// `PCMPEQD xmm, xmm` (66 [REX?] 0F 76 /r) — SSE2 packed 32-bit
/// equality compare. 4 lanes. Wasm `i32x4.eq`.
pub fn encPcmpeqD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x76, dst, src);
}

/// `PCMPEQQ xmm, xmm` (66 [REX?] 0F 38 29 /r) — SSE4.1 packed
/// 64-bit equality compare. 2 lanes. Wasm `i64x2.eq`. Per
/// ADR-0041 §"5. SSE4.1 minimum baseline" — i32x4.mul (PMULLD)
/// and PEXTR* opened the SSE4.1 surface; PCMPEQQ continues it.
pub fn encPcmpeqQ(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x29, dst, src);
}

/// `PCMPGTB xmm, xmm` (66 [REX?] 0F 64 /r) — SSE2 packed 8-bit
/// **signed** greater-than. Each output byte is 0xFF when the
/// dst byte > src byte (signed), else 0x00. Wasm
/// `i8x16.gt_s` direct; Wasm `i8x16.lt_s` synthesises via
/// operand swap; Wasm `i8x16.le_s` / `ge_s` synthesise by
/// applying NOT (PXOR with all-ones) to gt / lt result.
pub fn encPcmpgtB(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x64, dst, src);
}

/// `PCMPGTW xmm, xmm` (66 [REX?] 0F 65 /r) — SSE2 packed 16-bit
/// signed greater-than.
pub fn encPcmpgtW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x65, dst, src);
}

/// `PCMPGTD xmm, xmm` (66 [REX?] 0F 66 /r) — SSE2 packed 32-bit
/// signed greater-than.
pub fn encPcmpgtD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x66, dst, src);
}

/// `PCMPGTQ xmm, xmm` (66 [REX?] 0F 38 37 /r) — SSE4.2 packed
/// 64-bit signed greater-than. 2 lanes. Wasm `i64x2.gt_s` direct;
/// `i64x2.lt_s` via operand swap; `i64x2.le_s` / `ge_s` via NOT
/// (PXOR with all-ones). Per ADR-0041 §"5. SSE4.2 minimum
/// baseline" (post-9.7-m amend) — chosen over Cranelift's 9-instr
/// SSE4.1 synthesis (`inst.isle:3179-3191`) because Steam April
/// 2026 reports 98.18% SSE4.2 adoption and the synthesis costs
/// ~8× the JIT bytes per call.
pub fn encPcmpgtQ(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x37, dst, src);
}

// §9.7-n unsigned compare primitives — PMAXU* / PMINU*. Each
// computes the per-lane unsigned max/min of dst and src, writing
// the result back to dst. Used by `emitV128IntCmpUnsigned`
// (cranelift idiom: lower.isle:2016-2080) — `eq(max, b)` then
// NOT gives `a > b` unsigned; `eq(a, max)` gives `a >= b`
// unsigned (and dual for min/lt/le).

/// SSE single-precision packed FP binop helper. Same shape as
/// `encSsePackedIntBinop` but **without** the 66 prefix — PS-form
/// SSE-original instructions encode as `[REX?] 0F <opcode> /r`
/// while PD/Int forms add the 66 prefix. Used by ADDPS / SUBPS /
/// MULPS / DIVPS / MINPS / MAXPS / SQRTPS encoders.
fn encSseFpPsBinop(opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `ADDPS xmm, xmm` ([REX?] 0F 58 /r) — SSE packed single-precision
/// add (4 lanes). Wasm `f32x4.add`.
pub fn encAddps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x58, dst, src);
}

/// `SUBPS xmm, xmm` ([REX?] 0F 5C /r) — SSE packed single-precision
/// subtract (4 lanes). Wasm `f32x4.sub`.
pub fn encSubps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5C, dst, src);
}

/// `MULPS xmm, xmm` ([REX?] 0F 59 /r) — SSE packed single-precision
/// multiply (4 lanes). Wasm `f32x4.mul`.
pub fn encMulps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x59, dst, src);
}

/// `DIVPS xmm, xmm` ([REX?] 0F 5E /r) — SSE packed single-precision
/// divide (4 lanes). Wasm `f32x4.div`.
pub fn encDivps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5E, dst, src);
}

/// `SQRTPS xmm, xmm` ([REX?] 0F 51 /r) — SSE packed single-precision
/// square-root (4 lanes; unary, dst gets sqrt(src)). Wasm
/// `f32x4.sqrt`. NaN handling is canonical per IEEE-754: NaN
/// inputs propagate to NaN output, matching Wasm spec.
pub fn encSqrtps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x51, dst, src);
}

/// `MINPS xmm, xmm` ([REX?] 0F 5D /r) — SSE packed single-precision
/// min. Used by f32x4.fmin synthesis (NOT Wasm `f32x4.min` direct
/// because SSE MINPS uses "if unordered, return src2" semantics
/// that differ from Wasm's IEEE-754-2019 minimum). The synthesis
/// in op_simd.emitV128FpMin wraps MINPS twice with NaN/zero
/// correction.
pub fn encMinps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5D, dst, src);
}

/// `MAXPS xmm, xmm` ([REX?] 0F 5F /r) — SSE packed single-precision
/// max. f32x4.fmax synthesis primitive (see encMinps note).
pub fn encMaxps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5F, dst, src);
}

/// `MINPD xmm, xmm` (66 [REX?] 0F 5D /r) — SSE2 packed double-precision
/// min. f64x2.fmin synthesis primitive.
pub fn encMinpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x5D, dst, src);
}

/// `MAXPD xmm, xmm` (66 [REX?] 0F 5F /r) — SSE2 packed double-precision
/// max. f64x2.fmax synthesis primitive.
pub fn encMaxpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x5F, dst, src);
}

/// `ADDPD xmm, xmm` (66 [REX?] 0F 58 /r) — SSE2 packed double-precision
/// add (2 lanes). Wasm `f64x2.add`. Reuses `encSsePackedIntBinop`
/// for the 66+0F prefix shape; the int/fp distinction is purely
/// in the opcode byte.
pub fn encAddpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x58, dst, src);
}

/// `SUBPD xmm, xmm` (66 [REX?] 0F 5C /r) — SSE2 f64x2.sub.
pub fn encSubpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x5C, dst, src);
}

/// `MULPD xmm, xmm` (66 [REX?] 0F 59 /r) — SSE2 f64x2.mul.
pub fn encMulpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x59, dst, src);
}

/// `DIVPD xmm, xmm` (66 [REX?] 0F 5E /r) — SSE2 f64x2.div.
pub fn encDivpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x5E, dst, src);
}

/// `SQRTPD xmm, xmm` (66 [REX?] 0F 51 /r) — SSE2 f64x2.sqrt
/// (unary; dst = sqrt(src)).
pub fn encSqrtpd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x51, dst, src);
}

/// `CMPPS xmm, xmm, imm8` ([REX?] 0F C2 /r ib) — SSE packed
/// single-precision compare. Each lane gets all-ones (mask) if the
/// predicate is true on the lane, else all-zeros. **No 66 prefix**
/// (PS variants are SSE-original, not SSE2-promoted). imm8 is the
/// predicate per Intel SDM Vol 2A "CMPPS" Table 3-7:
///   0 = EQ (ordered, quiet) — Wasm `f32x4.eq`
///   1 = LT (ordered, signaling) — Wasm `f32x4.lt`; via swap covers `gt`
///   2 = LE (ordered, signaling) — Wasm `f32x4.le`; via swap covers `ge`
///   4 = NEQ (unordered, quiet) — Wasm `f32x4.ne` (NaN ⇒ true)
///
/// `gt` and `ge` lower as CMPPS(b, a) with predicate 1 / 2 per
/// cranelift `lower.isle:2169-2172` — no native ordered-gt
/// predicate exists in the legacy 0..7 imm8 range.
pub fn encCmpps(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xC2);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

/// `CMPPD xmm, xmm, imm8` (66 [REX?] 0F C2 /r ib) — SSE2 packed
/// double-precision compare. Same imm8 predicate space as CMPPS.
/// Wasm `f64x2.{eq, ne, lt, le}` direct; `gt` / `ge` swap operands
/// + use predicate 1 / 2 per cranelift.
pub fn encCmppd(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xC2);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

// §9.7-t shift primitives — SSE2 packed shift with count from
// xmm src register (low 64 bits). Wasm `iN.shl/shr_s/shr_u(v, c)`
// where c is an i32; we mask c to lane-width-1 bits then load it
// into the low 32 of a scratch xmm via MOVD before invoking the
// shift instruction. Per Intel SDM, PSLL*/PSRL*/PSRA* read the
// count from the low 64 bits of src; values exceeding lane width
// produce all-zero (PSLL/PSRL) or sign-extended (PSRA) lanes —
// this differs from Wasm's spec semantics ("shift by c mod
// lane_width") only when c >= lane_width, which the explicit
// AND-mask handles.

/// `PSLLW xmm, xmm` (66 [REX?] 0F F1 /r) — SSE2 packed 16-bit
/// logical shift-left. Count from low 64 bits of src.
pub fn encPsllwReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF1, dst, src);
}

/// `PSLLD xmm, xmm` (66 [REX?] 0F F2 /r) — SSE2 packed 32-bit
/// logical shift-left.
pub fn encPslldReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF2, dst, src);
}

/// `PSLLQ xmm, xmm` (66 [REX?] 0F F3 /r) — SSE2 packed 64-bit
/// logical shift-left.
pub fn encPsllqReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF3, dst, src);
}

/// `PSRLW xmm, xmm` (66 [REX?] 0F D1 /r) — SSE2 packed 16-bit
/// logical shift-right.
pub fn encPsrlwReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD1, dst, src);
}

/// `PSRLD xmm, xmm` (66 [REX?] 0F D2 /r) — SSE2 packed 32-bit
/// logical shift-right.
pub fn encPsrldReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD2, dst, src);
}

/// `PSRLQ xmm, xmm` (66 [REX?] 0F D3 /r) — SSE2 packed 64-bit
/// logical shift-right.
pub fn encPsrlqReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD3, dst, src);
}

/// `PSRAW xmm, xmm` (66 [REX?] 0F E1 /r) — SSE2 packed 16-bit
/// arithmetic (signed) shift-right. Sign-extends.
pub fn encPsrawReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE1, dst, src);
}

/// `PSRAD xmm, xmm` (66 [REX?] 0F E2 /r) — SSE2 packed 32-bit
/// arithmetic (signed) shift-right. Sign-extends. Note: PSRAQ
/// (64-bit signed) is NOT in SSE — added in AVX-512. i64x2.shr_s
/// must synthesise (§9.7-u via PSRLQ + sign-bit fixup).
pub fn encPsradReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE2, dst, src);
}

/// `PSUBQ xmm, xmm` (66 [REX?] 0F FB /r) — SSE2 packed 64-bit
/// integer subtract. Wasm `i64x2.sub` (already covered via
/// emitV128IntBinop in 9.7-b). Also used by §9.7-u
/// `i64x2.shr_s` synthesis to apply the sign-bit fixup
/// per cranelift `lower.isle:951`.
pub fn encPsubq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFB, dst, src);
}

// §9.7-ad FP round primitives — SSE4.1 ROUNDPS/ROUNDPD with imm8
// rounding mode. imm8 layout: bit[3] = suppress precision exception
// (always set to 1 for Wasm), bit[2] = use MXCSR rounding (0 to use
// imm[1:0]), bits[1:0] = mode: 00 nearest-even, 01 floor (toward
// -inf), 10 ceil (toward +inf), 11 trunc (toward zero).

/// `ROUNDPS xmm, xmm, imm8` (66 [REX?] 0F 3A 08 /r ib) — SSE4.1
/// round 4 packed f32 lanes per imm8 mode. Used by Wasm
/// `f32x4.{ceil, floor, trunc, nearest}`.
pub fn encRoundps(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x08);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

/// `ROUNDPD xmm, xmm, imm8` (66 [REX?] 0F 3A 09 /r ib) — SSE4.1
/// round 2 packed f64 lanes per imm8 mode. Wasm
/// `f64x2.{ceil, floor, trunc, nearest}`.
pub fn encRoundpd(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x09);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

// §9.7-ab FP convert primitives — SSE2 packed FP/int
// conversions. Wasm `f32x4.convert_i32x4_s`, `f64x2.convert_
// low_i32x4_s`, `f64x2.promote_low_f32x4`, `f32x4.demote_
// f64x2_zero`. All single-instruction unary ops with src/dst
// reg-reg encoding.

/// `CVTDQ2PS xmm, xmm` ([REX?] 0F 5B /r) — SSE2 convert 4
/// packed signed i32 to 4 packed f32. No mandatory prefix.
/// Wasm `f32x4.convert_i32x4_s`.
pub fn encCvtdq2ps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5B, dst, src);
}

/// `CVTPS2PD xmm, xmm` ([REX?] 0F 5A /r) — SSE2 convert 2 low
/// packed f32 (64 bits of src) to 2 packed f64. Wasm
/// `f64x2.promote_low_f32x4`.
pub fn encCvtps2pd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x5A, dst, src);
}

/// `CVTPD2PS xmm, xmm` (66 [REX?] 0F 5A /r) — SSE2 convert 2
/// packed f64 to 2 low packed f32 (high 64 of dst zeroed).
/// Wasm `f32x4.demote_f64x2_zero` (the "_zero" suffix matches
/// CVTPD2PS's high-half zeroing).
pub fn encCvtpd2ps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x5A, dst, src);
}

/// `CVTDQ2PD xmm, xmm` (F3 [REX?] 0F E6 /r) — SSE2 convert 2
/// low packed signed i32 (low 64 of src) to 2 packed f64.
/// Mandatory F3 prefix (different from typical packed-int
/// 66-prefix family). Wasm `f64x2.convert_low_i32x4_s`.
pub fn encCvtdq2pd(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xE6);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `PMADDUBSW xmm, xmm` (66 [REX?] 0F 38 04 /r) — SSSE3 packed
/// multiply-and-add pairs with **mixed-sign** inputs: dst is read
/// as 16 unsigned i8 lanes, src as 16 signed i8 lanes; each
/// adjacent pair is multiplied and summed into a saturated i16.
/// Used by Wasm `i16x8.extadd_pairwise_i8x16_{s,u}` synthesis with
/// a +1 multiplier vector — the saturating sum of two i8/u8
/// values fits in i16 (max u8+u8 = 510, min i8+i8 = -256), so the
/// saturation never triggers and we get clean pairwise add.
pub fn encPmaddubsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x04, dst, src);
}

/// `PMULHRSW xmm, xmm` (66 [REX?] 0F 38 0B /r) — SSSE3 packed
/// multiply 8 i16 lanes with rounding and right-shift by 15.
/// Result lane = ((x * y + 0x4000) >> 15) clamped to [-32768, 32767].
/// Maps directly to Wasm `i16x8.q15mulr_sat_s` (Q15 fixed-point
/// multiply-round-saturate).
pub fn encPmulhrsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x0B, dst, src);
}

/// `PMADDWD xmm, xmm` (66 [REX?] 0F F5 /r) — SSE2 multiply 8 pairs
/// of i16 lanes producing i32, then horizontally add adjacent
/// 32-bit products. Result is 4 i32 lanes (pairwise dot product).
/// Wasm `i32x4.dot_i16x8_s`. Wrapping semantics on the inner i32
/// products match the Wasm spec (INT16_MIN^2 + INT16_MIN^2 wraps
/// modulo 2^32; not saturated).
pub fn encPmaddwd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF5, dst, src);
}

/// `CVTTPS2DQ xmm, xmm` (F3 [REX?] 0F 5B /r) — SSE2 truncating
/// convert 4 packed f32 to 4 packed signed i32. Out-of-range
/// values and NaN both produce 0x80000000 (sentinel for trap-on-
/// overflow modes; Wasm `i32x4.trunc_sat_f32x4_s` corrects this
/// downstream via XOR fix-up). Mandatory F3 prefix.
pub fn encCvttps2dq(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x5B);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `PSRAD xmm, imm8` (66 [REX.B?] 0F 72 /4 ib) — SSE2 packed 32-bit
/// arithmetic shift right by immediate count (sign-fill). Used by
/// §9.7-ae `i32x4.trunc_sat_f32x4_s` for the bit-31 sign-extend
/// fix-up step. Distinct from PSRAD-by-reg which lives in shifts.
pub fn encPsradImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x72, 4, dst, count);
}

/// `SHUFPS xmm, xmm, imm8` ([REX?] 0F C6 /r ib) — SSE shuffle
/// 4 packed single-precision lanes per imm8 selector. imm8 bits
/// [1:0]=lane0_src, [3:2]=lane1_src, [5:4]=lane2_src,
/// [7:6]=lane3_src; lanes 0-1 of result come from dst, lanes 2-3
/// from src. Used by Wasm `i32x4.trunc_sat_f64x2_u_zero` to gather
/// the low 32 of each f64 lane into i32x4 lanes 0/1 with lanes
/// 2/3 zeroed.
pub fn encShufps(dst: Xmm, src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0xC6);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(imm8);
    return enc;
}

/// `UNPCKLPS xmm, xmm` ([REX?] 0F 14 /r) — SSE interleave low
/// 32-bit (single-precision) lanes from dst and src into dst.
/// Output lanes: [dst[0], src[0], dst[1], src[1]]. Used by Wasm
/// `f64x2.convert_low_i32x4_u` synthesis to interleave i32 lanes
/// with 0x43300000 mask, producing a f64 mantissa-overlay.
pub fn encUnpcklps(dst: Xmm, src: Xmm) EncodedInsn {
    return encSseFpPsBinop(0x14, dst, src);
}

/// `CVTTPD2DQ xmm, xmm` (66 [REX?] 0F E6 /r) — SSE2 truncating
/// convert 2 packed f64 → 2 packed i32 in low half of dst (high
/// half of dst zeroed automatically — matches Wasm `_zero` suffix).
/// OOR / NaN / +inf → 0x80000000 (INT32_MIN sentinel; downstream
/// recipe must pre-clamp + NaN-mask to get spec-conformant output).
pub fn encCvttpd2dq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE6, dst, src);
}

/// `MOVUPS xmm, [RIP+disp32]` placeholder — SSE PC-relative
/// 16-byte unaligned load. Encoding: `[REX.R] 0F 10 /r ModR/M`
/// where ModR/M = mod=00, reg=dst.low3, r/m=101 (RIP-relative
/// addressing in long mode). The disp32 field is initialised to
/// 0; the caller computes its byte offset post-append and records
/// a `SimdConstFixup` for the post-emit fixup pass to patch.
///
/// 6 bytes (no REX) for XMM0..XMM7; 7 bytes (REX.R) for
/// XMM8..XMM15. Use MOVUPS rather than MOVDQA to avoid requiring
/// 16-byte alignment of the const-pool (the post-emit pass still
/// pads to 16 bytes for cache-line hygiene, but MOVUPS's
/// permissiveness gives flexibility for future relocations).
pub fn encMovupsXmmRipRelPlaceholder(dst: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, 0));
    }
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(0x05 | (@as(u8, dst.low3()) << 3)); // mod=00, r/m=101
    enc.push(0x00); // disp32[0]
    enc.push(0x00); // disp32[1]
    enc.push(0x00); // disp32[2]
    enc.push(0x00); // disp32[3]
    return enc;
}

/// Patch the disp32 field of a previously-emitted MOVUPS-RIP-rel
/// placeholder. The disp32 byte offset is computed by the caller
/// at emit time: `buf.len - 4` immediately after appending the
/// placeholder slice. `disp32` is the signed PC-relative offset
/// from the post-instruction byte to the target.
pub fn patchRipRelDisp32(buf: []u8, disp32_byte_offset: u32, disp32: i32) void {
    std.mem.writeInt(i32, buf[disp32_byte_offset..][0..4], disp32, .little);
}

// §9.7-z abs primitives — SSSE3 PABSB/W/D compute per-lane
// absolute value of signed integers. PABSQ doesn't exist in
// pre-AVX-512 SSE; i64x2.abs synthesises via sign-mask PXOR/PSUBQ
// per cranelift `lower.isle:vec_int_abs` rule.

/// `PABSB xmm, xmm` (66 [REX?] 0F 38 1C /r) — SSSE3 packed
/// absolute value of 16 signed bytes. Wasm `i8x16.abs`.
pub fn encPabsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x1C, dst, src);
}

/// `PABSW xmm, xmm` (66 [REX?] 0F 38 1D /r) — SSSE3 packed abs of
/// 8 signed words. Wasm `i16x8.abs`.
pub fn encPabsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x1D, dst, src);
}

/// `PABSD xmm, xmm` (66 [REX?] 0F 38 1E /r) — SSSE3 packed abs of
/// 4 signed dwords. Wasm `i32x4.abs`.
pub fn encPabsd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x1E, dst, src);
}

// §9.7-x extend low/high primitives — SSE4.1 PMOVSX*/PMOVZX*
// sign/zero-extend the low 8 bytes (or 4 i16, or 2 i32) of src
// into the corresponding wider lanes of dst. A-form encoding
// (dst in ModR/M.reg, src in r/m). For HIGH-half extends, callers
// run PSHUFD imm=0xEE first to swap the upper 64 bits into the
// lower 64 position, then PMOVSX/ZX from there.

/// `PMOVSXBW xmm, xmm` (66 [REX?] 0F 38 20 /r) — SSE4.1 sign-
/// extend 8 i8 lanes (low 64 of src) → 8 i16 lanes.
pub fn encPmovsxbw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x20, dst, src);
}

/// `PMOVSXWD xmm, xmm` (66 [REX?] 0F 38 23 /r) — SSE4.1 sign-
/// extend 4 i16 lanes (low 64 of src) → 4 i32 lanes.
pub fn encPmovsxwd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x23, dst, src);
}

/// `PMOVSXDQ xmm, xmm` (66 [REX?] 0F 38 25 /r) — SSE4.1 sign-
/// extend 2 i32 lanes (low 64 of src) → 2 i64 lanes.
pub fn encPmovsxdq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x25, dst, src);
}

/// `PMOVZXBW xmm, xmm` (66 [REX?] 0F 38 30 /r) — SSE4.1 zero-
/// extend 8 u8 lanes → 8 u16 lanes.
pub fn encPmovzxbw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x30, dst, src);
}

/// `PMOVZXWD xmm, xmm` (66 [REX?] 0F 38 33 /r) — SSE4.1 zero-
/// extend 4 u16 lanes → 4 u32 lanes.
pub fn encPmovzxwd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x33, dst, src);
}

/// `PMOVZXDQ xmm, xmm` (66 [REX?] 0F 38 35 /r) — SSE4.1 zero-
/// extend 2 u32 lanes → 2 u64 lanes.
pub fn encPmovzxdq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x35, dst, src);
}

/// `PUNPCKLBW xmm, xmm` (66 [REX?] 0F 60 /r) — SSE2 unpack low
/// 8 bytes from each operand into 8 interleaved word lanes
/// (dst.byte[2i] = dst.byte[i]; dst.byte[2i+1] = src.byte[i]).
/// Used by §9.7-w `i8x16.shr_s` synthesis to sign-extend low
/// 8 bytes of source by interleaving with a sign-mask byte
/// pattern.
pub fn encPunpcklbw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x60, dst, src);
}

/// `PUNPCKHBW xmm, xmm` (66 [REX?] 0F 68 /r) — SSE2 unpack high
/// 8 bytes (dst.byte[2i] = dst.byte[8+i]; dst.byte[2i+1] =
/// src.byte[8+i]). Used by `i8x16.shr_s` synthesis for the
/// high-half sign extension.
pub fn encPunpckhbw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x68, dst, src);
}

// `encMovdXmmFromR32` is defined earlier in this file (line ~179)
// for the lane-0 splat path; reused here by §9.7-t shift handlers
// to load shift count into the low 32 bits of a scratch xmm.

/// `PACKSSWB xmm, xmm` (66 [REX?] 0F 63 /r) — SSE2 pack 8 signed
/// 16-bit lanes from each operand into 16 saturated 8-bit lanes
/// (low half from dst, high half from src). Used by `i8x16.
/// narrow_i16x8_s` (Wasm spec) and `i16x8.bitmask` synthesis.
pub fn encPacksswb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x63, dst, src);
}

/// `PACKSSDW xmm, xmm` (66 [REX?] 0F 6B /r) — SSE2 pack 4 signed
/// 32-bit lanes from each operand into 8 saturated 16-bit lanes.
/// Wasm `i16x8.narrow_i32x4_s`.
pub fn encPackssdw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x6B, dst, src);
}

/// `PACKUSWB xmm, xmm` (66 [REX?] 0F 67 /r) — SSE2 pack 8 signed
/// 16-bit lanes (each clamped to unsigned u8 range) into 16
/// unsigned 8-bit lanes. Wasm `i8x16.narrow_i16x8_u`.
pub fn encPackuswb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x67, dst, src);
}

/// `PACKUSDW xmm, xmm` (66 [REX?] 0F 38 2B /r) — SSE4.1 pack 4
/// signed 32-bit lanes (each clamped to unsigned u16 range) into
/// 8 unsigned 16-bit lanes. Wasm `i16x8.narrow_i32x4_u`.
pub fn encPackusdw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x2B, dst, src);
}

/// SSE/SSE2 RM-form helper: GPR destination in ModR/M.reg, XMM
/// source in ModR/M.r/m. Used by MOVMSK* / PMOVMSKB which extract
/// per-lane high bits into a GPR. REX.R extends the GPR (reg
/// field); REX.B extends the XMM (r/m field) — opposite of the
/// PEXTR* encoding which puts the XMM in reg.
fn encSseXmmToGprRM(prefix_66: bool, opcode: u8, gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (prefix_66) enc.push(0x66);
    if (gpr_dst.extBit() != 0 or xmm_src.extBit() != 0) {
        enc.push(encodeRex(false, gpr_dst.extBit(), 0, xmm_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, gpr_dst.low3(), xmm_src.low3()));
    return enc;
}

/// `MOVMSKPS r32, xmm` ([REX?] 0F 50 /r) — SSE extract per-lane
/// high bit of 4 single-precision lanes into the low 4 bits of a
/// GPR. Wasm `i32x4.bitmask` direct (high bit of each i32 lane).
pub fn encMovmskps(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    return encSseXmmToGprRM(false, 0x50, gpr_dst, xmm_src);
}

/// `MOVMSKPD r32, xmm` (66 [REX?] 0F 50 /r) — SSE2 extract per-
/// lane high bit of 2 double-precision lanes into the low 2 bits
/// of a GPR. Wasm `i64x2.bitmask` direct (high bit of each i64
/// lane).
pub fn encMovmskpd(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    return encSseXmmToGprRM(true, 0x50, gpr_dst, xmm_src);
}

/// `PMOVMSKB r32, xmm` (66 [REX?] 0F D7 /r) — SSE2 extract per-
/// byte high bit of 16 byte lanes into the low 16 bits of a GPR.
/// Wasm `i8x16.bitmask` direct; also used by `i16x8.bitmask`
/// synthesis (after PACKSSWB) and the `all_true` family per
/// cranelift `lower.isle:4946-4949` (Rule 0 SSE2 fallback).
pub fn encPmovmskb(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    return encSseXmmToGprRM(true, 0xD7, gpr_dst, xmm_src);
}

/// `PAND xmm, xmm` (66 [REX?] 0F DB /r) — SSE2 bitwise AND on
/// 128-bit values. Wasm `v128.and`.
pub fn encPand(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDB, dst, src);
}

/// `POR xmm, xmm` (66 [REX?] 0F EB /r) — SSE2 bitwise OR on
/// 128-bit values. Wasm `v128.or`.
pub fn encPor(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEB, dst, src);
}

/// `PANDN xmm, xmm` (66 [REX?] 0F DF /r) — SSE2 bitwise AND-NOT:
/// `dst = ~dst & src`. Wasm `v128.andnot(a, b) = a & ~b` lowers
/// via `MOVAPS scratch, b ; PANDN scratch, a ; MOVAPS dst,
/// scratch` because PANDN's first operand is the NEGATED side.
pub fn encPandn(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDF, dst, src);
}

/// `PTEST xmm, xmm` (66 [REX?] 0F 38 17 /r) — SSE4.1 bitwise test
/// without writing the destination. Sets EFLAGS.ZF=1 if all bits
/// of `dst & src` are zero else ZF=0; sets CF=1 if `~dst & src`
/// is zero. Used by `v128.any_true`: PTEST xmm, xmm + SETNZ +
/// MOVZX. Per Intel SDM Vol 2A "PTEST".
pub fn encPtest(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x17, dst, src);
}

/// `PMAXUB xmm, xmm` (66 [REX?] 0F DE /r) — SSE2 packed unsigned
/// 8-bit max (16 lanes).
pub fn encPmaxub(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDE, dst, src);
}

/// `PMINUB xmm, xmm` (66 [REX?] 0F DA /r) — SSE2 packed unsigned
/// 8-bit min (16 lanes).
pub fn encPminub(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDA, dst, src);
}

/// `PMAXUW xmm, xmm` (66 [REX?] 0F 38 3E /r) — SSE4.1 packed
/// unsigned 16-bit max (8 lanes).
pub fn encPmaxuw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3E, dst, src);
}

/// `PMINUW xmm, xmm` (66 [REX?] 0F 38 3A /r) — SSE4.1 packed
/// unsigned 16-bit min (8 lanes).
pub fn encPminuw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3A, dst, src);
}

/// `PMAXUD xmm, xmm` (66 [REX?] 0F 38 3F /r) — SSE4.1 packed
/// unsigned 32-bit max (4 lanes).
pub fn encPmaxud(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3F, dst, src);
}

/// `PMAXSD xmm, xmm` (66 [REX?] 0F 38 3D /r) — SSE4.1 packed
/// signed 32-bit max (4 lanes).
pub fn encPmaxsd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3D, dst, src);
}

/// `PMINSB xmm, xmm` (66 [REX?] 0F 38 38 /r) — SSE4.1 packed
/// signed 8-bit min (16 lanes).
pub fn encPminsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x38, dst, src);
}

/// `PMAXSB xmm, xmm` (66 [REX?] 0F 38 3C /r) — SSE4.1 packed
/// signed 8-bit max (16 lanes).
pub fn encPmaxsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3C, dst, src);
}

/// `PMINSW xmm, xmm` (66 [REX?] 0F EA /r) — SSE2 packed signed
/// 16-bit min (8 lanes).
pub fn encPminsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEA, dst, src);
}

/// `PMAXSW xmm, xmm` (66 [REX?] 0F EE /r) — SSE2 packed signed
/// 16-bit max (8 lanes).
pub fn encPmaxsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEE, dst, src);
}

/// `PMINSD xmm, xmm` (66 [REX?] 0F 38 39 /r) — SSE4.1 packed
/// signed 32-bit min (4 lanes).
pub fn encPminsd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x39, dst, src);
}

/// `PADDSB xmm, xmm` (66 [REX?] 0F EC /r) — SSE2 packed signed
/// 8-bit saturating add (16 lanes; clamps to [INT8_MIN, INT8_MAX]).
pub fn encPaddsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEC, dst, src);
}

/// `PADDSW xmm, xmm` (66 [REX?] 0F ED /r) — SSE2 packed signed
/// 16-bit saturating add (8 lanes; clamps to [INT16_MIN, INT16_MAX]).
pub fn encPaddsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xED, dst, src);
}

/// `PSUBSB xmm, xmm` (66 [REX?] 0F E8 /r) — SSE2 packed signed
/// 8-bit saturating subtract (16 lanes; clamps to [INT8_MIN, INT8_MAX]).
pub fn encPsubsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE8, dst, src);
}

/// `PSUBSW xmm, xmm` (66 [REX?] 0F E9 /r) — SSE2 packed signed
/// 16-bit saturating subtract (8 lanes; clamps to [INT16_MIN, INT16_MAX]).
pub fn encPsubsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE9, dst, src);
}

/// `PADDUSB xmm, xmm` (66 [REX?] 0F DC /r) — SSE2 packed unsigned
/// 8-bit saturating add (16 lanes; clamps to [0, UINT8_MAX]).
pub fn encPaddusb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDC, dst, src);
}

/// `PADDUSW xmm, xmm` (66 [REX?] 0F DD /r) — SSE2 packed unsigned
/// 16-bit saturating add (8 lanes; clamps to [0, UINT16_MAX]).
pub fn encPaddusw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDD, dst, src);
}

/// `PSUBUSB xmm, xmm` (66 [REX?] 0F D8 /r) — SSE2 packed unsigned
/// 8-bit saturating subtract (16 lanes; clamps to [0, UINT8_MAX]).
pub fn encPsubusb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD8, dst, src);
}

/// `PSUBUSW xmm, xmm` (66 [REX?] 0F D9 /r) — SSE2 packed unsigned
/// 16-bit saturating subtract (8 lanes; clamps to [0, UINT16_MAX]).
pub fn encPsubusw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD9, dst, src);
}

/// `PAVGB xmm, xmm` (66 [REX?] 0F E0 /r) — SSE2 packed unsigned
/// 8-bit average-rounded (16 lanes; (a+b+1) >> 1 per lane).
pub fn encPavgb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE0, dst, src);
}

/// `PAVGW xmm, xmm` (66 [REX?] 0F E3 /r) — SSE2 packed unsigned
/// 16-bit average-rounded (8 lanes; (a+b+1) >> 1 per lane).
pub fn encPavgw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE3, dst, src);
}

/// `PMINUD xmm, xmm` (66 [REX?] 0F 38 3B /r) — SSE4.1 packed
/// unsigned 32-bit min (4 lanes).
pub fn encPminud(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3B, dst, src);
}

/// `MOVSD xmm, xmm` (F2 [REX?] 0F 10 /r — register-register
/// form with ModR/M.mod=11) — copies the low 64 bits of `src`
/// into the low 64 bits of `dst`, **preserving** the upper 64
/// bits of `dst`. (The mem→reg load form zero-fills the upper
/// 64; the reg→reg form does NOT, per Intel SDM Vol 2.) Used by
/// `f64x2.replace_lane` lane=0 to overwrite the low qword while
/// preserving the high qword from the input vec.
pub fn encMovsdXmmXmm(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF2);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x10);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOVLHPS xmm, xmm` (0F 16 /r) — moves the low 64 bits of
/// `src` into the **high** 64 bits of `dst`; the low 64 bits of
/// `dst` are preserved. Used by `f64x2.replace_lane` lane=1
/// to overwrite the high qword (where the scalar `value` arrives
/// in its XMM home's low qword, so we shuttle it up to dst's
/// high qword).
pub fn encMovlhps(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x16);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `INSERTPS xmm, xmm/m32, imm8` (66 [REX?] 0F 3A 21 /r ib) —
/// SSE4.1 insert scalar single-precision. Per Intel SDM:
///   imm8[7:6] = count_s (source lane index, 0..3)
///   imm8[5:4] = count_d (destination lane index, 0..3)
///   imm8[3:0] = ZMASK (zero-out bits — 1 zeros the corresponding
///                       destination dword lane)
/// Used by `f32x4.replace_lane` with `count_s = 0` (the scalar
/// f32 lives in the source XMM's low 32 bits), `count_d = lane`
/// (Wasm's lane immediate), and `ZMASK = 0` (no zeroing).
///
/// RVMI operand encoding: ModR/M.reg = destination XMM, .r/m =
/// source XMM. Same orientation as PINSRD.
pub fn encInsertps(xmm_dst: Xmm, xmm_src: Xmm, imm8: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_dst.extBit() != 0 or xmm_src.extBit() != 0) {
        enc.push(encodeRex(false, xmm_dst.extBit(), 0, xmm_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x21);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), xmm_src.low3()));
    enc.push(imm8);
    return enc;
}

const testing = std.testing;

test "encPaddD: low XMMs (xmm0, xmm1) — no REX, 4 bytes" {
    const enc = encPaddD(.xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xFE, 0xC1 }, enc.slice());
}

test "encPaddD: dst extended (xmm8, xmm1) — REX.R only" {
    const enc = encPaddD(.xmm8, .xmm1);
    // 66 44 0F FE C1: REX = 0x40 | R(0x4) — encodeRex(false, 1, 0, 0) = 0x44.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x44, 0x0F, 0xFE, 0xC1 }, enc.slice());
}

test "encPaddD: src extended (xmm0, xmm9) — REX.B only" {
    const enc = encPaddD(.xmm0, .xmm9);
    // 66 41 0F FE C1: REX.B = 0x41.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0xFE, 0xC1 }, enc.slice());
}

test "encPaddD: both extended (xmm8, xmm13) — REX.R + REX.B" {
    const enc = encPaddD(.xmm8, .xmm13);
    // 66 45 0F FE C5: REX = 0x45.  ModR/M = mod=11, reg=0, rm=5 → 0xC5.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xFE, 0xC5 }, enc.slice());
}

test "encPaddB / encPaddW / encPaddQ opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xFC, 0xC1 }, encPaddB(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xFD, 0xC1 }, encPaddW(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD4, 0xC1 }, encPaddQ(.xmm0, .xmm1).slice());
}

test "encPsubB / encPsubW / encPsubD / encPsubQ opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF8, 0xC1 }, encPsubB(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF9, 0xC1 }, encPsubW(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xFA, 0xC1 }, encPsubD(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xFB, 0xC1 }, encPsubQ(.xmm0, .xmm1).slice());
}

test "encPsubD: REX.R+B path (xmm8, xmm13) carries opcode 0xFA" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xFA, 0xC5 }, encPsubD(.xmm8, .xmm13).slice());
}

test "encPmullW: SSE2 i16x8.mul opcode 0xD5 (xmm0, xmm1) — 4 bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD5, 0xC1 }, encPmullW(.xmm0, .xmm1).slice());
}

test "encPmullD: SSE4.1 i32x4.mul (xmm0, xmm1) — 5 bytes with 0x38 escape" {
    // 66 0F 38 40 C1 — escape2 = 0x38, opcode = 0x40.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x40, 0xC1 }, encPmullD(.xmm0, .xmm1).slice());
}

test "encPmullD: SSE4.1 with REX.R+B (xmm8, xmm13) — 6 bytes" {
    // 66 45 0F 38 40 C5 — REX = 0x45 between 0x66 and 0x0F.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x38, 0x40, 0xC5 }, encPmullD(.xmm8, .xmm13).slice());
}

test "encPmuldq: SSE4.1 (xmm0, xmm1) opcode 0x38 0x28 — 5 bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x28, 0xC1 }, encPmuldq(.xmm0, .xmm1).slice());
}

test "encPmuludq: SSE2 (xmm0, xmm1) opcode 0xF4 — 4 bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF4, 0xC1 }, encPmuludq(.xmm0, .xmm1).slice());
}

test "encPmuludq: REX.R+B (xmm8, xmm13) — 5 bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xF4, 0xC5 }, encPmuludq(.xmm8, .xmm13).slice());
}

test "encPslldImm: PSLLD xmm0, 31 — group /6, opcode=0x72 (D-form)" {
    // 66 0F 72 F0 1F — ModR/M = 11 110 000 (mod=11, reg=6, rm=0).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x72, 0xF0, 0x1F }, encPslldImm(.xmm0, 31).slice());
}

test "encRoundps / encRoundpd opcode bytes (xmm0, xmm1, imm=0x0A ceil+suppress)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x08, 0xC1, 0x0A }, encRoundps(.xmm0, .xmm1, 0x0A).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x09, 0xC1, 0x0A }, encRoundpd(.xmm0, .xmm1, 0x0A).slice());
}

test "encPsllwImm: PSLLW xmm0, 15 — group /6, opcode=0x71 (W-form)" {
    // 66 0F 71 F0 0F — ModR/M = 11 110 000 (mod=11, reg=6, rm=0).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x71, 0xF0, 0x0F }, encPsllwImm(.xmm0, 15).slice());
}

test "encPsrlwImm: PSRLW xmm0, 8 — group /2, opcode=0x71 (W-form)" {
    // 66 0F 71 D0 08 — ModR/M = 11 010 000 (mod=11, reg=2, rm=0).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x71, 0xD0, 0x08 }, encPsrlwImm(.xmm0, 8).slice());
}

test "encPsrldImm: PSRLD xmm0, 10 — group /2, opcode=0x72 (D-form)" {
    // 66 0F 72 D0 0A — ModR/M = 11 010 000 = 0xD0 (mod=11, reg=2, rm=0).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x72, 0xD0, 0x0A }, encPsrldImm(.xmm0, 10).slice());
}

test "encPsrldImm: PSRLD xmm15, 10 — REX.B (xmm15)" {
    // 66 41 0F 72 D7 0A — REX.B = 0x41; ModR/M = 11 010 111 = 0xD7.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0x72, 0xD7, 0x0A }, encPsrldImm(.xmm15, 10).slice());
}

test "encPsllwReg / encPslldReg / encPsllqReg opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF1, 0xC1 }, encPsllwReg(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF2, 0xC1 }, encPslldReg(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF3, 0xC1 }, encPsllqReg(.xmm0, .xmm1).slice());
}

test "encPsrlwReg / encPsrldReg / encPsrlqReg opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD1, 0xC1 }, encPsrlwReg(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD2, 0xC1 }, encPsrldReg(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD3, 0xC1 }, encPsrlqReg(.xmm0, .xmm1).slice());
}

test "encPsrawReg / encPsradReg opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xE1, 0xC1 }, encPsrawReg(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xE2, 0xC1 }, encPsradReg(.xmm0, .xmm1).slice());
}

test "encPsubq opcode bytes (xmm0, xmm1) — SSE2 packed 64-bit subtract" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xFB, 0xC1 }, encPsubq(.xmm0, .xmm1).slice());
}

test "encCvtdq2ps / encCvtps2pd opcode bytes (xmm0, xmm1) — no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5B, 0xC1 }, encCvtdq2ps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5A, 0xC1 }, encCvtps2pd(.xmm0, .xmm1).slice());
}

test "encCvtpd2ps opcode bytes (xmm0, xmm1) — 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5A, 0xC1 }, encCvtpd2ps(.xmm0, .xmm1).slice());
}

test "encCvtdq2pd opcode bytes (xmm0, xmm1) — F3 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0xE6, 0xC1 }, encCvtdq2pd(.xmm0, .xmm1).slice());
}

test "encPmaddubsw: SSSE3 (xmm0, xmm1) opcode 0x38 0x04" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x04, 0xC1 }, encPmaddubsw(.xmm0, .xmm1).slice());
}

test "encPmulhrsw / encPmaddwd opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x0B, 0xC1 }, encPmulhrsw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF5, 0xC1 }, encPmaddwd(.xmm0, .xmm1).slice());
}

test "encShufps: SSE (xmm0, xmm1, imm=0x88) opcode 0F C6" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xC6, 0xC1, 0x88 }, encShufps(.xmm0, .xmm1, 0x88).slice());
}

test "encUnpcklps: SSE (xmm0, xmm1) opcode 0F 14" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x14, 0xC1 }, encUnpcklps(.xmm0, .xmm1).slice());
}

test "encCvttpd2dq: SSE2 (xmm0, xmm1) opcode 66 0F E6" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xE6, 0xC1 }, encCvttpd2dq(.xmm0, .xmm1).slice());
}

test "encMovupsXmmRipRelPlaceholder: XMM0 → 6 bytes (0F 10 05 00 00 00 00)" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x10, 0x05, 0x00, 0x00, 0x00, 0x00 }, encMovupsXmmRipRelPlaceholder(.xmm0).slice());
}

test "encMovupsXmmRipRelPlaceholder: XMM8 → 7 bytes with REX.R (44 0F 10 05 00 00 00 00)" {
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0x10, 0x05, 0x00, 0x00, 0x00, 0x00 }, encMovupsXmmRipRelPlaceholder(.xmm8).slice());
}

test "encMovupsXmmRipRelPlaceholder: XMM3 → ModR/M = 0x1D" {
    // ModR/M = mod=00 (0b00) | reg=3 (0b011) << 3 | r/m=5 (0b101) = 0x1D
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x10, 0x1D, 0x00, 0x00, 0x00, 0x00 }, encMovupsXmmRipRelPlaceholder(.xmm3).slice());
}

test "patchRipRelDisp32: writes signed disp32 to buf at offset" {
    var buf: [8]u8 = .{ 0, 0, 0, 0, 0xAA, 0xBB, 0xCC, 0xDD };
    patchRipRelDisp32(buf[0..], 4, -16);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0xF0, 0xFF, 0xFF, 0xFF }, &buf);
}

test "encCvttps2dq: F3 0F 5B /r" {
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x5B, 0xC1 }, encCvttps2dq(.xmm0, .xmm1).slice());
}

test "encPsradImm: PSRAD xmm0, 31 — group /4, opcode=0x72 (D-form)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x72, 0xE0, 0x1F }, encPsradImm(.xmm0, 31).slice());
}

test "encPabsb / encPabsw / encPabsd opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x1C, 0xC1 }, encPabsb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x1D, 0xC1 }, encPabsw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x1E, 0xC1 }, encPabsd(.xmm0, .xmm1).slice());
}

test "encPmovsxbw / encPmovsxwd / encPmovsxdq opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x20, 0xC1 }, encPmovsxbw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x23, 0xC1 }, encPmovsxwd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x25, 0xC1 }, encPmovsxdq(.xmm0, .xmm1).slice());
}

test "encPmovzxbw / encPmovzxwd / encPmovzxdq opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x30, 0xC1 }, encPmovzxbw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x33, 0xC1 }, encPmovzxwd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x35, 0xC1 }, encPmovzxdq(.xmm0, .xmm1).slice());
}

test "encPunpcklbw / encPunpckhbw opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x60, 0xC1 }, encPunpcklbw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x68, 0xC1 }, encPunpckhbw(.xmm0, .xmm1).slice());
}

test "encMovdXmmFromR32: xmm0, eax — 66 0F 6E ModRM" {
    // 66 0F 6E C0 — ModR/M = 11 000 000 (reg=0=xmm0, rm=0=eax).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x6E, 0xC0 }, encMovdXmmFromR32(.xmm0, .rax).slice());
}

test "encMovdXmmFromR32: xmm14, r10 — REX.R + REX.B" {
    // 66 45 0F 6E F2 — REX = 0x45; ModR/M = 11 110 010 (reg=6=xmm14.lo3, rm=2=r10.lo3).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x6E, 0xF2 }, encMovdXmmFromR32(.xmm14, .r10).slice());
}

test "encPacksswb opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x63, 0xC1 }, encPacksswb(.xmm0, .xmm1).slice());
}

test "encPackssdw / encPackuswb / encPackusdw opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x6B, 0xC1 }, encPackssdw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x67, 0xC1 }, encPackuswb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x2B, 0xC1 }, encPackusdw(.xmm0, .xmm1).slice());
}

test "encMovmskps: rax, xmm0 — no 66 prefix, RM (r32 in reg, xmm in r/m)" {
    // 0F 50 C0 — ModR/M = 11 000 000 (mod=11, reg=0=rax, rm=0=xmm0).
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x50, 0xC0 }, encMovmskps(.rax, .xmm0).slice());
}

test "encMovmskpd: rcx, xmm5 — 66 prefix, RM" {
    // 66 0F 50 CD — ModR/M = 11 001 101 (reg=1=rcx, rm=5=xmm5).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x50, 0xCD }, encMovmskpd(.rcx, .xmm5).slice());
}

test "encPmovmskb: rdx, xmm0 — 66 prefix, opcode 0xD7" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD7, 0xD0 }, encPmovmskb(.rdx, .xmm0).slice());
}

test "encPmovmskb: r10, xmm14 — REX.R + REX.B" {
    // 66 45 0F D7 D6 — REX = R(1<<2) | B(1) = 0x45;
    // ModR/M = 11 010 110 (reg=2=r10.lo3, rm=6=xmm14.lo3).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xD7, 0xD6 }, encPmovmskb(.r10, .xmm14).slice());
}

test "encPand / encPor / encPandn opcode bytes (xmm0, xmm1) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xDB, 0xC1 }, encPand(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xEB, 0xC1 }, encPor(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xDF, 0xC1 }, encPandn(.xmm0, .xmm1).slice());
}

test "encPtest opcode bytes (xmm0, xmm1) — SSE4.1 with 66 + 0x38 escape" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x17, 0xC1 }, encPtest(.xmm0, .xmm1).slice());
}

test "encPand: REX.R+B (xmm9, xmm10)" {
    // 66 45 0F DB CA — REX = 0x45; ModR/M = 11 001 010 = 0xCA.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xDB, 0xCA }, encPand(.xmm9, .xmm10).slice());
}

test "encMinps / encMaxps opcode bytes (xmm0, xmm1) — SSE no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5D, 0xC1 }, encMinps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5F, 0xC1 }, encMaxps(.xmm0, .xmm1).slice());
}

test "encMinpd / encMaxpd opcode bytes (xmm0, xmm1) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5D, 0xC1 }, encMinpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5F, 0xC1 }, encMaxpd(.xmm0, .xmm1).slice());
}

test "encOrps / encXorps / encAndps / encAndnps opcode bytes (xmm0, xmm1) — SSE no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x56, 0xC1 }, encOrps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x57, 0xC1 }, encXorps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x54, 0xC1 }, encAndps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x55, 0xC1 }, encAndnps(.xmm0, .xmm1).slice());
}

test "encOrpd / encXorpd / encAndnpd opcode bytes (xmm0, xmm1) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x56, 0xC1 }, encOrpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x57, 0xC1 }, encXorpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x55, 0xC1 }, encAndnpd(.xmm0, .xmm1).slice());
}

test "encPsrlqImm: PSRLQ xmm0, 32 — group /2, imm8=0x20" {
    // 66 0F 73 D0 20 — ModR/M = 11 010 000 = 0xD0 (mod=11, reg=2, rm=0).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x73, 0xD0, 0x20 }, encPsrlqImm(.xmm0, 32).slice());
}

test "encPsrlqImm: PSRLQ xmm14, 32 — REX.B + group /2" {
    // 66 41 0F 73 D6 20 — REX.B=0x41, ModR/M = 11 010 110 = 0xD6.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0x73, 0xD6, 0x20 }, encPsrlqImm(.xmm14, 32).slice());
}

test "encPsllqImm: PSLLQ xmm0, 32 — group /6, imm8=0x20" {
    // 66 0F 73 F0 20 — ModR/M = 11 110 000 = 0xF0 (mod=11, reg=6, rm=0).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x73, 0xF0, 0x20 }, encPsllqImm(.xmm0, 32).slice());
}

test "encPsllqImm: PSLLQ xmm14, 32 — REX.B + group /6" {
    // 66 41 0F 73 F6 20 — REX.B=0x41, ModR/M = 11 110 110 = 0xF6.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0x73, 0xF6, 0x20 }, encPsllqImm(.xmm14, 32).slice());
}

test "encPshufd: broadcast lane 0 (xmm0, xmm0, 0x00) — 5 bytes no REX" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x70, 0xC0, 0x00 }, encPshufd(.xmm0, .xmm0, 0x00).slice());
}

test "encPshufd: REX.R+B (xmm8, xmm13, 0x00)" {
    // 66 45 0F 70 C5 00 — REX = 0x45, ModR/M = 11 000 101 = 0xC5.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x70, 0xC5, 0x00 }, encPshufd(.xmm8, .xmm13, 0x00).slice());
}

test "encPextrD: lane 0 (rax, xmm0, 0) — 6 bytes no REX" {
    // 66 0F 3A 16 C0 00 — ModR/M.reg = xmm_src.low3() = 0,
    // ModR/M.rm = gpr_dst.low3() = 0 → 0xC0.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x16, 0xC0, 0x00 }, encPextrD(.rax, .xmm0, 0).slice());
}

test "encPextrD: lane 3 (rax, xmm0, 3)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x16, 0xC0, 0x03 }, encPextrD(.rax, .xmm0, 3).slice());
}

test "encPextrD: REX.R+B (r9, xmm8, 1) — high gpr + high xmm" {
    // 66 45 0F 3A 16 C1 01 — REX.R for xmm_src (0x44) | REX.B for
    // gpr_dst (0x41) → 0x45; ModR/M = 11 000 001 = 0xC1.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x3A, 0x16, 0xC1, 0x01 }, encPextrD(.r9, .xmm8, 1).slice());
}

test "encPextrQ: lane 0 (rax, xmm0, 0) — 7 bytes with REX.W" {
    // 66 48 0F 3A 16 C0 00 — REX = 0x48 (W=1, no extension bits).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x48, 0x0F, 0x3A, 0x16, 0xC0, 0x00 }, encPextrQ(.rax, .xmm0, 0).slice());
}

test "encPextrQ: lane 1 + REX.W+R+B (r9, xmm8, 1)" {
    // 66 4D 0F 3A 16 C1 01 — REX = 0x40 | W(8) | R(4) | B(1) = 0x4D.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x4D, 0x0F, 0x3A, 0x16, 0xC1, 0x01 }, encPextrQ(.r9, .xmm8, 1).slice());
}

test "encPinsrD: lane 0 (xmm0, rax, 0) — 7 bytes no REX" {
    // 66 0F 3A 22 C0 00 — ModR/M.reg = xmm_dst (0), .rm = gpr_src (0)
    // → 0xC0. Inverse operand orientation from PEXTRD.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x22, 0xC0, 0x00 }, encPinsrD(.xmm0, .rax, 0).slice());
}

test "encPinsrD: lane 3 (xmm0, rax, 3)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x22, 0xC0, 0x03 }, encPinsrD(.xmm0, .rax, 3).slice());
}

test "encPinsrD: REX.R+B (xmm8, r9, 2)" {
    // 66 45 0F 3A 22 C1 02 — REX.R from xmm_dst | REX.B from gpr_src.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x3A, 0x22, 0xC1, 0x02 }, encPinsrD(.xmm8, .r9, 2).slice());
}

test "encPinsrQ: lane 0 (xmm0, rax, 0) — REX.W mandatory, 7 bytes" {
    // 66 48 0F 3A 22 C0 00 — REX.W=0x48 forces 64-bit operand.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x48, 0x0F, 0x3A, 0x22, 0xC0, 0x00 }, encPinsrQ(.xmm0, .rax, 0).slice());
}

test "encPinsrQ: lane 1, REX.W+R+B (xmm8, r9, 1)" {
    // 66 4D 0F 3A 22 C1 01 — REX.W (0x48) | R (0x04) | B (0x01) = 0x4D.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x4D, 0x0F, 0x3A, 0x22, 0xC1, 0x01 }, encPinsrQ(.xmm8, .r9, 1).slice());
}

test "encPextrB: lane 5 (rax, xmm0, 5) — RMI shape, opcode 0x14" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x14, 0xC0, 0x05 }, encPextrB(.rax, .xmm0, 5).slice());
}

test "encPextrW: lane 7 (rax, xmm0, 7) — SSE2 form opcode 0xC5, RMI" {
    // 66 0F C5 C0 07 — ModR/M.reg = gpr (0), .rm = xmm (0).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xC5, 0xC0, 0x07 }, encPextrW(.rax, .xmm0, 7).slice());
}

test "encPextrW: REX.R+B (r9, xmm8, 0) — REX.R for gpr, REX.B for xmm" {
    // 66 45 0F C5 C8 00 — REX = 0x40 | R (gpr.extBit=1<<2=0x4) |
    // B (xmm.extBit=1) = 0x45; ModR/M = 11 001 000 = 0xC8.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xC5, 0xC8, 0x00 }, encPextrW(.r9, .xmm8, 0).slice());
}

test "encPinsrB: lane 15 (xmm0, rax, 15) — RVMI shape, opcode 0x20" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x20, 0xC0, 0x0F }, encPinsrB(.xmm0, .rax, 15).slice());
}

test "encPinsrW: lane 3 (xmm0, rax, 3) — SSE2 form opcode 0xC4" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xC4, 0xC0, 0x03 }, encPinsrW(.xmm0, .rax, 3).slice());
}

test "encPinsrW: REX.R+B (xmm8, r9, 7)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xC4, 0xC1, 0x07 }, encPinsrW(.xmm8, .r9, 7).slice());
}

test "encPxor: self-XOR zero idiom (xmm14, xmm14) — opcode 0xEF" {
    // 66 45 0F EF F6 — REX.R+B for XMM14 in both fields, ModR/M=11 110 110.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xEF, 0xF6 }, encPxor(.xmm14, .xmm14).slice());
}

test "encPshufb: SSSE3 broadcast (xmm0, xmm14) — opcode 0x38 0x00" {
    // 66 41 0F 38 00 C6 — REX.B for ctrl XMM14, ModR/M=11 000 110.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0x38, 0x00, 0xC6 }, encPshufb(.xmm0, .xmm14).slice());
}

test "encPshuflw: low-4 broadcast (xmm0, xmm0, 0x00) — F2 0F 70 /r ib" {
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x70, 0xC0, 0x00 }, encPshuflw(.xmm0, .xmm0, 0x00).slice());
}

test "encPshuflw: REX.R+B (xmm8, xmm13, 0x00)" {
    // F2 45 0F 70 C5 00 — REX = 0x45.
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x45, 0x0F, 0x70, 0xC5, 0x00 }, encPshuflw(.xmm8, .xmm13, 0x00).slice());
}

test "encPunpcklqdq: self-unpack (xmm0, xmm0) — opcode 0x6C" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x6C, 0xC0 }, encPunpcklqdq(.xmm0, .xmm0).slice());
}

test "encPunpcklqdq: REX.R+B (xmm8, xmm8)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x6C, 0xC0 }, encPunpcklqdq(.xmm8, .xmm8).slice());
}

test "encInsertps: lane 1 with count_s=0, ZMASK=0 (xmm0, xmm1, 0x10)" {
    // 66 0F 3A 21 C1 10 — imm = (0<<6)|(1<<4)|0 = 0x10.
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x21, 0xC1, 0x10 }, encInsertps(.xmm0, .xmm1, 0x10).slice());
}

test "encInsertps: REX.R+B (xmm8, xmm9, 0x30) — lane 3" {
    // 66 45 0F 3A 21 C1 30
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x3A, 0x21, 0xC1, 0x30 }, encInsertps(.xmm8, .xmm9, 0x30).slice());
}

test "encMovsdXmmXmm: reg-reg (xmm0, xmm1) — F2 0F 10 with mod=11" {
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x10, 0xC1 }, encMovsdXmmXmm(.xmm0, .xmm1).slice());
}

test "encMovsdXmmXmm: REX.R+B (xmm8, xmm9)" {
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x45, 0x0F, 0x10, 0xC1 }, encMovsdXmmXmm(.xmm8, .xmm9).slice());
}

test "encMovlhps: reg-reg (xmm0, xmm1) — 0F 16 /r" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x16, 0xC1 }, encMovlhps(.xmm0, .xmm1).slice());
}

test "encMovlhps: REX.R+B (xmm8, xmm9)" {
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0x16, 0xC1 }, encMovlhps(.xmm8, .xmm9).slice());
}

test "encPcmpeqB / W / D opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x74, 0xC1 }, encPcmpeqB(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x75, 0xC1 }, encPcmpeqW(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x76, 0xC1 }, encPcmpeqD(.xmm0, .xmm1).slice());
}

test "encPcmpeqQ: SSE4.1 (xmm0, xmm1) — 0x38 escape, opcode 0x29" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x29, 0xC1 }, encPcmpeqQ(.xmm0, .xmm1).slice());
}

test "encPcmpeqB: REX.R+B self-eq idiom for all-ones (xmm14, xmm14)" {
    // 66 45 0F 74 F6 — REX = 0x40 | R(1<<2) | B(1) = 0x45;
    // ModR/M = 11 110 110 = 0xF6 (mod=11, reg=6, rm=6).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x74, 0xF6 }, encPcmpeqB(.xmm14, .xmm14).slice());
}

test "encPcmpgtB / W / D opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x64, 0xC1 }, encPcmpgtB(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x65, 0xC1 }, encPcmpgtW(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x66, 0xC1 }, encPcmpgtD(.xmm0, .xmm1).slice());
}

test "encPcmpgtD: REX.R+B (xmm8, xmm13)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x66, 0xC5 }, encPcmpgtD(.xmm8, .xmm13).slice());
}

test "encPcmpgtQ: SSE4.2 (xmm0, xmm1) — 0x38 escape, opcode 0x37" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x37, 0xC1 }, encPcmpgtQ(.xmm0, .xmm1).slice());
}

test "encPcmpgtQ: REX.R+B (xmm8, xmm13)" {
    // 66 45 0F 38 37 C5 — REX = 0x40 | R(1<<2) | B(1) = 0x45;
    // ModR/M = 11 000 101 = 0xC5 (mod=11, reg=0 [xmm8 low3], rm=5 [xmm13 low3]).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x38, 0x37, 0xC5 }, encPcmpgtQ(.xmm8, .xmm13).slice());
}

test "encAddps / encSubps / encMulps / encDivps / encSqrtps opcode bytes (xmm0, xmm1) — SSE no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x58, 0xC1 }, encAddps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5C, 0xC1 }, encSubps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x59, 0xC1 }, encMulps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x5E, 0xC1 }, encDivps(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x51, 0xC1 }, encSqrtps(.xmm0, .xmm1).slice());
}

test "encAddpd / encSubpd / encMulpd / encDivpd / encSqrtpd opcode bytes (xmm0, xmm1) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x58, 0xC1 }, encAddpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5C, 0xC1 }, encSubpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x59, 0xC1 }, encMulpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x5E, 0xC1 }, encDivpd(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x51, 0xC1 }, encSqrtpd(.xmm0, .xmm1).slice());
}

test "encAddps: REX.R+B (xmm10, xmm12)" {
    // 45 0F 58 D4 — REX = 0x40 | R(1<<2) | B(1) = 0x45;
    // ModR/M = 11 010 100 = 0xD4 (mod=11, reg=2, rm=4).
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0x58, 0xD4 }, encAddps(.xmm10, .xmm12).slice());
}

test "encCmpps opcode bytes (xmm0, xmm1, imm=0x01 LT) — SSE no 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xC2, 0xC1, 0x01 }, encCmpps(.xmm0, .xmm1, 0x01).slice());
}

test "encCmpps: REX.R+B (xmm10, xmm12, imm=0x04 NEQ)" {
    // 45 0F C2 D4 04 — REX = 0x40 | R(1<<2) | B(1) = 0x45;
    // ModR/M = 11 010 100 = 0xD4 (mod=11, reg=2 [xmm10 low3], rm=4 [xmm12 low3]).
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0xC2, 0xD4, 0x04 }, encCmpps(.xmm10, .xmm12, 0x04).slice());
}

test "encCmppd opcode bytes (xmm0, xmm1, imm=0x00 EQ) — SSE2 with 66 prefix" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xC2, 0xC1, 0x00 }, encCmppd(.xmm0, .xmm1, 0x00).slice());
}

test "encPmaxub / encPminub opcode bytes (xmm0, xmm1) — SSE2" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xDE, 0xC1 }, encPmaxub(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xDA, 0xC1 }, encPminub(.xmm0, .xmm1).slice());
}

test "encPmaxuw / encPminuw / encPmaxud / encPminud opcode bytes (xmm0, xmm1) — SSE4.1" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x3E, 0xC1 }, encPmaxuw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x3A, 0xC1 }, encPminuw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x3F, 0xC1 }, encPmaxud(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x3B, 0xC1 }, encPminud(.xmm0, .xmm1).slice());
}

test "encPmaxud: REX.R+B (xmm14, xmm15) — covers spill-stage scratch range" {
    // 66 45 0F 38 3F F7 — REX = 0x40 | R(1<<2) | B(1) = 0x45;
    // ModR/M = 11 110 111 = 0xF7 (mod=11, reg=6 [xmm14 low3], rm=7 [xmm15 low3]).
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x38, 0x3F, 0xF7 }, encPmaxud(.xmm14, .xmm15).slice());
}

test "encPminsb / encPmaxsb / encPminsd opcode bytes — SSE4.1 signed min/max" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x38, 0xC1 }, encPminsb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x3C, 0xC1 }, encPmaxsb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x39, 0xC1 }, encPminsd(.xmm0, .xmm1).slice());
}

test "encPminsw / encPmaxsw opcode bytes — SSE2 signed 16-bit min/max" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xEA, 0xC1 }, encPminsw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xEE, 0xC1 }, encPmaxsw(.xmm0, .xmm1).slice());
}

test "encPaddsb / encPaddsw / encPsubsb / encPsubsw opcode bytes — SSE2 signed sat arith" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xEC, 0xC1 }, encPaddsb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xED, 0xC1 }, encPaddsw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xE8, 0xC1 }, encPsubsb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xE9, 0xC1 }, encPsubsw(.xmm0, .xmm1).slice());
}

test "encPaddusb / encPaddusw / encPsubusb / encPsubusw opcode bytes — SSE2 unsigned sat arith" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xDC, 0xC1 }, encPaddusb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xDD, 0xC1 }, encPaddusw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD8, 0xC1 }, encPsubusb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD9, 0xC1 }, encPsubusw(.xmm0, .xmm1).slice());
}

test "encPavgb / encPavgw opcode bytes — SSE2 unsigned avgr" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xE0, 0xC1 }, encPavgb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xE3, 0xC1 }, encPavgw(.xmm0, .xmm1).slice());
}

test "encStoreXmmV128MemRBP: [RBP-16], xmm0 — `movups [rbp-16], xmm0` → 0F 11 45 F0" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x11, 0x45, 0xF0 }, encStoreXmmV128MemRBP(-16, .xmm0).slice());
}

test "encLoadXmmV128MemRBP: xmm0, [RBP-16] — `movups xmm0, [rbp-16]` → 0F 10 45 F0" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x10, 0x45, 0xF0 }, encLoadXmmV128MemRBP(.xmm0, -16).slice());
}

test "encStoreXmmV128MemRBP: [RBP+0], xmm0 — disp8=0 form" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x11, 0x45, 0x00 }, encStoreXmmV128MemRBP(0, .xmm0).slice());
}

test "encStoreXmmV128MemRBPDisp32: [RBP-1024], xmm15 — REX.R + disp32" {
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0x11, 0xBD, 0x00, 0xFC, 0xFF, 0xFF }, encStoreXmmV128MemRBPDisp32(-1024, .xmm15).slice());
}

test "encLoadXmmV128MemRBPDisp32: xmm15, [RBP-1024] — REX.R + disp32" {
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0x10, 0xBD, 0x00, 0xFC, 0xFF, 0xFF }, encLoadXmmV128MemRBPDisp32(.xmm15, -1024).slice());
}
