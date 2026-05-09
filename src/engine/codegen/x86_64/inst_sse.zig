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

/// SSE2 packed shift-by-immediate /X-group helper. The
/// `66 0F 73 /<group> ib` encoding has ModR/M.reg = group code
/// (selecting the op within the family) and ModR/M.rm = the XMM
/// being shifted in-place. Group codes used:
///   /2 = PSRLQ (logical shift right)
///   /6 = PSLLQ (logical shift left)
///
/// REX.B applies when the destination is XMM8..XMM15 (touches
/// ModR/M.rm). REX.R is unused (group code lives in reg field
/// but is a constant, not a register). Encoded bytes:
///   66 [REX.B?] 0F 73 [11 <group> rm.low3] <imm8>
fn encSsePackedShiftImmGroup(group: u3, dst: Xmm, count: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0) {
        enc.push(encodeRex(false, 0, 0, dst.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x73);
    enc.push(encodeModrm(0b11, group, dst.low3()));
    enc.push(count);
    return enc;
}

/// `PSRLQ xmm, imm8` (66 [REX.B?] 0F 73 /2 ib) — SSE2 packed
/// 64-bit logical shift right by immediate count. Used by
/// i64x2.mul synthesis to extract the high 32 bits of each
/// 64-bit lane into the low half (a_hi → low(scratch)).
pub fn encPsrlqImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(2, dst, count);
}

/// `PSLLQ xmm, imm8` (66 [REX.B?] 0F 73 /6 ib) — SSE2 packed
/// 64-bit logical shift left by immediate count. Used by
/// i64x2.mul synthesis to position the cross-term sum in the
/// high 32 bits before adding to the low product.
pub fn encPsllqImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(6, dst, count);
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

test "encPmuludq: SSE2 (xmm0, xmm1) opcode 0xF4 — 4 bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF4, 0xC1 }, encPmuludq(.xmm0, .xmm1).slice());
}

test "encPmuludq: REX.R+B (xmm8, xmm13) — 5 bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xF4, 0xC5 }, encPmuludq(.xmm8, .xmm13).slice());
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
