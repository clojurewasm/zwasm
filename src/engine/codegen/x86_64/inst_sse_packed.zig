// FILE-SIZE-EXEMPT: uniform pure-encoder catalog (per ADR-0075)
//! x86_64 SSE2/SSSE3/SSE4.1/SSE4.2 packed-integer encoder family —
//! all `encP*` shape encoders (PADD/PSUB/PMUL/PCMP/PMIN/PMAX/PAND/
//! POR/PXOR/PANDN/PSHUF*/PSHUFB/PSLL*/PSRL*/PSRA*/PEXTR*/PINSR*/
//! PMOVSX*/PMOVZX*/PACK*/PUNPCK*/PABS*/PADDS*/PSUBS*/PADDUS*/
//! PSUBUS*/PAVG*/PTEST/PMADDUBSW/PMULHRSW/PMADDWD/PMOVMSKB/MOVMSK*).
//!
//! Split from `inst_sse.zig` per ADR-0041 +
//! `.dev/phase10_prep/track_b_source_split.md` §4.2 (x86_64 encoder
//! source partition; chunk B/6).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3.

const std = @import("std");

const inst = @import("inst.zig");
const reg_class = @import("reg_class.zig");

const Gpr = reg_class.Gpr;
const Xmm = reg_class.Xmm;
const EncodedInsn = inst.EncodedInsn;
const encodeRex = inst.encodeRex;
const encodeModrm = inst.encodeModrm;

/// SSE2 / SSE4.1 packed integer binop family — internal helper.
/// `escape2 == 0` skips the secondary escape byte (canonical SSE2
/// form: 66 [REX?] 0F <opcode> /r). `escape2 == 0x38` selects the
/// SSE4.1 / SSSE3 form: 66 [REX?] 0F 38 <opcode> /r.
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

/// SSE/SSE2 RM-form helper: GPR destination in ModR/M.reg, XMM
/// source in ModR/M.r/m. Used by MOVMSK* / PMOVMSKB which extract
/// per-lane high bits into a GPR.
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

// ---------------------------------------------------------------
// PADD / PSUB / PMUL family — Wasm spec §4.4.4 packed integer
// arithmetic. PADDB/W/D/Q + PSUBB/W/D/Q + PMULLW (SSE2) + PMULLD
// (SSE4.1) + PMULUDQ (SSE2 u32×u32→u64) + PMULDQ (SSE4.1 i32×i32→i64).
// ---------------------------------------------------------------

/// `PADDB xmm, xmm` (66 [REX?] 0F FC /r) — Wasm `i8x16.add`.
pub fn encPaddB(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFC, dst, src);
}

/// `PADDW xmm, xmm` (66 [REX?] 0F FD /r) — Wasm `i16x8.add`.
pub fn encPaddW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFD, dst, src);
}

/// `PADDD xmm, xmm` (66 [REX?] 0F FE /r) — Wasm `i32x4.add`.
pub fn encPaddD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFE, dst, src);
}

/// `PADDQ xmm, xmm` (66 [REX?] 0F D4 /r) — Wasm `i64x2.add`.
pub fn encPaddQ(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD4, dst, src);
}

/// `PSUBB xmm, xmm` (66 [REX?] 0F F8 /r) — Wasm `i8x16.sub`.
pub fn encPsubB(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF8, dst, src);
}

/// `PSUBW xmm, xmm` (66 [REX?] 0F F9 /r) — Wasm `i16x8.sub`.
pub fn encPsubW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF9, dst, src);
}

/// `PSUBD xmm, xmm` (66 [REX?] 0F FA /r) — Wasm `i32x4.sub`.
pub fn encPsubD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFA, dst, src);
}

/// `PSUBQ xmm, xmm` (66 [REX?] 0F FB /r) — Wasm `i64x2.sub`.
pub fn encPsubQ(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFB, dst, src);
}

/// `PMULLW xmm, xmm` (66 [REX?] 0F D5 /r) — Wasm `i16x8.mul`.
pub fn encPmullW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD5, dst, src);
}

/// `PMULLD xmm, xmm` (66 [REX?] 0F 38 40 /r) — SSE4.1 Wasm `i32x4.mul`.
pub fn encPmullD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x40, dst, src);
}

/// `PMULUDQ xmm, xmm` (66 [REX?] 0F F4 /r) — SSE2 u32×u32 → u64.
pub fn encPmuludq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF4, dst, src);
}

/// `PMULDQ xmm, xmm` (66 [REX?] 0F 38 28 /r) — SSE4.1 signed i32×i32 → i64.
pub fn encPmuldq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x28, dst, src);
}

// ---------------------------------------------------------------
// Packed shift-by-immediate family — Wasm spec §4.4.4 + cranelift
// `lower.isle` shift recipes. PSLLD/PSLLW/PSRLW/PSRLD/PSRLQ/PSLLQ/
// PSRAD with imm8 count.
// ---------------------------------------------------------------

/// `PSLLD xmm, imm8` (66 [REX.B?] 0F 72 /6 ib) — SSE2.
pub fn encPslldImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x72, 6, dst, count);
}

/// `PSLLW xmm, imm8` (66 [REX.B?] 0F 71 /6 ib) — SSE2.
pub fn encPsllwImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x71, 6, dst, count);
}

/// `PSRLW xmm, imm8` (66 [REX.B?] 0F 71 /2 ib) — SSE2.
pub fn encPsrlwImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x71, 2, dst, count);
}

/// `PSRLD xmm, imm8` (66 [REX.B?] 0F 72 /2 ib) — SSE2.
pub fn encPsrldImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x72, 2, dst, count);
}

/// `PSRLQ xmm, imm8` (66 [REX.B?] 0F 73 /2 ib) — SSE2.
pub fn encPsrlqImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x73, 2, dst, count);
}

/// `PSLLQ xmm, imm8` (66 [REX.B?] 0F 73 /6 ib) — SSE2.
pub fn encPsllqImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x73, 6, dst, count);
}

/// `PSRAD xmm, imm8` (66 [REX.B?] 0F 72 /4 ib) — SSE2 arith shift.
pub fn encPsradImm(dst: Xmm, count: u8) EncodedInsn {
    return encSsePackedShiftImmGroup(0x72, 4, dst, count);
}

// ---------------------------------------------------------------
// Packed shift-by-register family — SSE2 PSLL*/PSRL*/PSRA* reg form.
// ---------------------------------------------------------------

/// `PSLLW xmm, xmm` (66 [REX?] 0F F1 /r) — SSE2.
pub fn encPsllwReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF1, dst, src);
}

/// `PSLLD xmm, xmm` (66 [REX?] 0F F2 /r) — SSE2.
pub fn encPslldReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF2, dst, src);
}

/// `PSLLQ xmm, xmm` (66 [REX?] 0F F3 /r) — SSE2.
pub fn encPsllqReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF3, dst, src);
}

/// `PSRLW xmm, xmm` (66 [REX?] 0F D1 /r) — SSE2.
pub fn encPsrlwReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD1, dst, src);
}

/// `PSRLD xmm, xmm` (66 [REX?] 0F D2 /r) — SSE2.
pub fn encPsrldReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD2, dst, src);
}

/// `PSRLQ xmm, xmm` (66 [REX?] 0F D3 /r) — SSE2.
pub fn encPsrlqReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD3, dst, src);
}

/// `PSRAW xmm, xmm` (66 [REX?] 0F E1 /r) — SSE2 signed shift.
pub fn encPsrawReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE1, dst, src);
}

/// `PSRAD xmm, xmm` (66 [REX?] 0F E2 /r) — SSE2 signed shift.
pub fn encPsradReg(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE2, dst, src);
}

/// `PSUBQ xmm, xmm` — alias used by `i64x2.shr_s` sign-fixup path.
/// Same encoding as encPsubQ; kept for naming-clarity at the call
/// site that consumes the recipe.
pub fn encPsubq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xFB, dst, src);
}

// ---------------------------------------------------------------
// Logical / bitwise / compare family — PXOR, PAND, POR, PANDN,
// PCMPEQ*, PCMPGT*, PTEST.
// ---------------------------------------------------------------

/// `PXOR xmm, xmm` (66 [REX?] 0F EF /r) — SSE2 packed XOR.
pub fn encPxor(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEF, dst, src);
}

/// `PAND xmm, xmm` (66 [REX?] 0F DB /r) — SSE2 packed AND.
pub fn encPand(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDB, dst, src);
}

/// `POR xmm, xmm` (66 [REX?] 0F EB /r) — SSE2 packed OR.
pub fn encPor(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEB, dst, src);
}

/// `PANDN xmm, xmm` (66 [REX?] 0F DF /r) — SSE2 packed AND-NOT.
pub fn encPandn(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDF, dst, src);
}

/// `PTEST xmm, xmm` (66 [REX?] 0F 38 17 /r) — SSE4.1.
pub fn encPtest(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x17, dst, src);
}

/// `PCMPEQB xmm, xmm` (66 [REX?] 0F 74 /r) — Wasm `i8x16.eq`.
pub fn encPcmpeqB(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x74, dst, src);
}

/// `PCMPEQW xmm, xmm` (66 [REX?] 0F 75 /r) — Wasm `i16x8.eq`.
pub fn encPcmpeqW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x75, dst, src);
}

/// `PCMPEQD xmm, xmm` (66 [REX?] 0F 76 /r) — Wasm `i32x4.eq`.
pub fn encPcmpeqD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x76, dst, src);
}

/// `PCMPEQQ xmm, xmm` (66 [REX?] 0F 38 29 /r) — SSE4.1 Wasm `i64x2.eq`.
pub fn encPcmpeqQ(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x29, dst, src);
}

/// `PCMPGTB xmm, xmm` (66 [REX?] 0F 64 /r) — SSE2 signed gt.
pub fn encPcmpgtB(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x64, dst, src);
}

/// `PCMPGTW xmm, xmm` (66 [REX?] 0F 65 /r) — SSE2 signed gt.
pub fn encPcmpgtW(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x65, dst, src);
}

/// `PCMPGTD xmm, xmm` (66 [REX?] 0F 66 /r) — SSE2 signed gt.
pub fn encPcmpgtD(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x66, dst, src);
}

/// `PCMPGTQ xmm, xmm` (66 [REX?] 0F 38 37 /r) — SSE4.2 signed gt.
pub fn encPcmpgtQ(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x37, dst, src);
}

// ---------------------------------------------------------------
// Shuffle / unpack / pack family — PSHUFD, PSHUFB, PSHUFLW,
// PUNPCKLBW, PUNPCKHBW, PUNPCKLQDQ, PACKSSWB, PACKSSDW, PACKUSWB,
// PACKUSDW.
// ---------------------------------------------------------------

/// `PSHUFD xmm, xmm, imm8` (66 [REX?] 0F 70 /r ib) — SSE2 32-bit shuffle.
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

/// `PSHUFB xmm, xmm` (66 [REX?] 0F 38 00 /r) — SSSE3 byte shuffle.
pub fn encPshufb(dst: Xmm, ctrl: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x00, dst, ctrl);
}

/// `PSHUFLW xmm, xmm, imm8` (F2 [REX?] 0F 70 /r ib) — SSE2 low-word shuffle.
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

/// `PUNPCKLQDQ xmm, xmm` (66 [REX?] 0F 6C /r) — SSE2 low qword unpack.
pub fn encPunpcklqdq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x6C, dst, src);
}

/// `PUNPCKLBW xmm, xmm` (66 [REX?] 0F 60 /r) — SSE2 low byte unpack.
pub fn encPunpcklbw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x60, dst, src);
}

/// `PUNPCKHBW xmm, xmm` (66 [REX?] 0F 68 /r) — SSE2 high byte unpack.
pub fn encPunpckhbw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x68, dst, src);
}

/// `PACKSSWB xmm, xmm` (66 [REX?] 0F 63 /r) — Wasm `i8x16.narrow_i16x8_s`.
pub fn encPacksswb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x63, dst, src);
}

/// `PACKSSDW xmm, xmm` (66 [REX?] 0F 6B /r) — Wasm `i16x8.narrow_i32x4_s`.
pub fn encPackssdw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x6B, dst, src);
}

/// `PACKUSWB xmm, xmm` (66 [REX?] 0F 67 /r) — Wasm `i8x16.narrow_i16x8_u`.
pub fn encPackuswb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0x67, dst, src);
}

/// `PACKUSDW xmm, xmm` (66 [REX?] 0F 38 2B /r) — SSE4.1 narrow_i32x4_u.
pub fn encPackusdw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x2B, dst, src);
}

// ---------------------------------------------------------------
// Lane extract / insert family — PEXTR{B,W,D,Q} / PINSR{B,W,D,Q}.
// Wasm spec §4.4.3 lane access.
// ---------------------------------------------------------------

/// `PEXTRD r/m32, xmm, imm8` (66 [REX?] 0F 3A 16 /r ib) — SSE4.1.
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

/// `PEXTRQ r/m64, xmm, imm8` (66 REX.W 0F 3A 16 /r ib) — SSE4.1.
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

/// `PINSRD xmm, r/m32, imm8` (66 [REX?] 0F 3A 22 /r ib) — SSE4.1.
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

/// `PINSRQ xmm, r/m64, imm8` (66 REX.W 0F 3A 22 /r ib) — SSE4.1.
pub fn encPinsrQ(xmm_dst: Xmm, gpr_src: Gpr, lane: u1) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    enc.push(encodeRex(true, xmm_dst.extBit(), 0, gpr_src.extBit()));
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x22);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    enc.push(@intCast(lane));
    return enc;
}

/// `PEXTRB r/m8, xmm, imm8` (66 [REX?] 0F 3A 14 /r ib) — SSE4.1.
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

/// `PEXTRW r32, xmm, imm8` (66 [REX?] 0F C5 /r ib) — SSE2 form (RMI).
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

/// `PINSRB xmm, r/m32, imm8` (66 [REX?] 0F 3A 20 /r ib) — SSE4.1.
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

/// `PINSRW xmm, r/m32, imm8` (66 [REX?] 0F C4 /r ib) — SSE2 form.
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

// ---------------------------------------------------------------
// Absolute / sign-zero extend family — PABSB/W/D + PMOVSX*/PMOVZX*.
// ---------------------------------------------------------------

/// `PABSB xmm, xmm` (66 [REX?] 0F 38 1C /r) — Wasm `i8x16.abs`.
pub fn encPabsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x1C, dst, src);
}

/// `PABSW xmm, xmm` (66 [REX?] 0F 38 1D /r) — Wasm `i16x8.abs`.
pub fn encPabsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x1D, dst, src);
}

/// `PABSD xmm, xmm` (66 [REX?] 0F 38 1E /r) — Wasm `i32x4.abs`.
pub fn encPabsd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x1E, dst, src);
}

/// `PMOVSXBW xmm, xmm` (66 [REX?] 0F 38 20 /r) — SSE4.1.
pub fn encPmovsxbw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x20, dst, src);
}

/// `PMOVSXWD xmm, xmm` (66 [REX?] 0F 38 23 /r) — SSE4.1.
pub fn encPmovsxwd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x23, dst, src);
}

/// `PMOVSXDQ xmm, xmm` (66 [REX?] 0F 38 25 /r) — SSE4.1.
pub fn encPmovsxdq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x25, dst, src);
}

/// `PMOVZXBW xmm, xmm` (66 [REX?] 0F 38 30 /r) — SSE4.1.
pub fn encPmovzxbw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x30, dst, src);
}

/// `PMOVZXWD xmm, xmm` (66 [REX?] 0F 38 33 /r) — SSE4.1.
pub fn encPmovzxwd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x33, dst, src);
}

/// `PMOVZXDQ xmm, xmm` (66 [REX?] 0F 38 35 /r) — SSE4.1.
pub fn encPmovzxdq(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x35, dst, src);
}

// ---------------------------------------------------------------
// Multiply-add / multiply-round-saturate family — PMADDUBSW (SSSE3),
// PMULHRSW (SSSE3 Q15 mul-round-sat), PMADDWD (SSE2 dot-product).
// ---------------------------------------------------------------

/// `PMADDUBSW xmm, xmm` (66 [REX?] 0F 38 04 /r) — SSSE3 mixed-sign MAD.
pub fn encPmaddubsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x04, dst, src);
}

/// `PMULHRSW xmm, xmm` (66 [REX?] 0F 38 0B /r) — SSSE3 Wasm `i16x8.q15mulr_sat_s`.
pub fn encPmulhrsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x0B, dst, src);
}

/// `PMADDWD xmm, xmm` (66 [REX?] 0F F5 /r) — Wasm `i32x4.dot_i16x8_s`.
pub fn encPmaddwd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xF5, dst, src);
}

// ---------------------------------------------------------------
// Min/Max family — signed/unsigned per-lane min/max (SSE2 + SSE4.1).
// ---------------------------------------------------------------

/// `PMAXUB xmm, xmm` (66 [REX?] 0F DE /r) — SSE2 u8 max.
pub fn encPmaxub(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDE, dst, src);
}

/// `PMINUB xmm, xmm` (66 [REX?] 0F DA /r) — SSE2 u8 min.
pub fn encPminub(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDA, dst, src);
}

/// `PMAXUW xmm, xmm` (66 [REX?] 0F 38 3E /r) — SSE4.1 u16 max.
pub fn encPmaxuw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3E, dst, src);
}

/// `PMINUW xmm, xmm` (66 [REX?] 0F 38 3A /r) — SSE4.1 u16 min.
pub fn encPminuw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3A, dst, src);
}

/// `PMAXUD xmm, xmm` (66 [REX?] 0F 38 3F /r) — SSE4.1 u32 max.
pub fn encPmaxud(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3F, dst, src);
}

/// `PMINUD xmm, xmm` (66 [REX?] 0F 38 3B /r) — SSE4.1 u32 min.
pub fn encPminud(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3B, dst, src);
}

/// `PMAXSD xmm, xmm` (66 [REX?] 0F 38 3D /r) — SSE4.1 i32 max.
pub fn encPmaxsd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3D, dst, src);
}

/// `PMINSB xmm, xmm` (66 [REX?] 0F 38 38 /r) — SSE4.1 i8 min.
pub fn encPminsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x38, dst, src);
}

/// `PMAXSB xmm, xmm` (66 [REX?] 0F 38 3C /r) — SSE4.1 i8 max.
pub fn encPmaxsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x3C, dst, src);
}

/// `PMINSW xmm, xmm` (66 [REX?] 0F EA /r) — SSE2 i16 min.
pub fn encPminsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEA, dst, src);
}

/// `PMAXSW xmm, xmm` (66 [REX?] 0F EE /r) — SSE2 i16 max.
pub fn encPmaxsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEE, dst, src);
}

/// `PMINSD xmm, xmm` (66 [REX?] 0F 38 39 /r) — SSE4.1 i32 min.
pub fn encPminsd(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinopExt(0x38, 0x39, dst, src);
}

// ---------------------------------------------------------------
// Saturating / averaging arithmetic — PADDS*/PSUBS*/PADDUS*/PSUBUS*/PAVG*.
// ---------------------------------------------------------------

/// `PADDSB xmm, xmm` (66 [REX?] 0F EC /r) — SSE2 signed sat i8 add.
pub fn encPaddsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xEC, dst, src);
}

/// `PADDSW xmm, xmm` (66 [REX?] 0F ED /r) — SSE2 signed sat i16 add.
pub fn encPaddsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xED, dst, src);
}

/// `PSUBSB xmm, xmm` (66 [REX?] 0F E8 /r) — SSE2 signed sat i8 sub.
pub fn encPsubsb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE8, dst, src);
}

/// `PSUBSW xmm, xmm` (66 [REX?] 0F E9 /r) — SSE2 signed sat i16 sub.
pub fn encPsubsw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE9, dst, src);
}

/// `PADDUSB xmm, xmm` (66 [REX?] 0F DC /r) — SSE2 unsigned sat u8 add.
pub fn encPaddusb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDC, dst, src);
}

/// `PADDUSW xmm, xmm` (66 [REX?] 0F DD /r) — SSE2 unsigned sat u16 add.
pub fn encPaddusw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xDD, dst, src);
}

/// `PSUBUSB xmm, xmm` (66 [REX?] 0F D8 /r) — SSE2 unsigned sat u8 sub.
pub fn encPsubusb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD8, dst, src);
}

/// `PSUBUSW xmm, xmm` (66 [REX?] 0F D9 /r) — SSE2 unsigned sat u16 sub.
pub fn encPsubusw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xD9, dst, src);
}

/// `PAVGB xmm, xmm` (66 [REX?] 0F E0 /r) — SSE2 u8 average-rounded.
pub fn encPavgb(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE0, dst, src);
}

/// `PAVGW xmm, xmm` (66 [REX?] 0F E3 /r) — SSE2 u16 average-rounded.
pub fn encPavgw(dst: Xmm, src: Xmm) EncodedInsn {
    return encSsePackedIntBinop(0xE3, dst, src);
}

// ---------------------------------------------------------------
// MOVMSK / PMOVMSKB family — XMM → GPR per-lane high-bit extracts.
// ---------------------------------------------------------------

/// `MOVMSKPS r32, xmm` ([REX?] 0F 50 /r) — SSE Wasm `i32x4.bitmask`.
pub fn encMovmskps(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    return encSseXmmToGprRM(false, 0x50, gpr_dst, xmm_src);
}

/// `MOVMSKPD r32, xmm` (66 [REX?] 0F 50 /r) — SSE2 Wasm `i64x2.bitmask`.
pub fn encMovmskpd(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    return encSseXmmToGprRM(true, 0x50, gpr_dst, xmm_src);
}

/// `PMOVMSKB r32, xmm` (66 [REX?] 0F D7 /r) — SSE2 Wasm `i8x16.bitmask`.
pub fn encPmovmskb(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    return encSseXmmToGprRM(true, 0xD7, gpr_dst, xmm_src);
}

const testing = std.testing;

test "encPaddD: low XMMs (xmm0, xmm1) — no REX, 4 bytes" {
    const enc = encPaddD(.xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xFE, 0xC1 }, enc.slice());
}

test "encPaddD: dst extended (xmm8, xmm1) — REX.R only" {
    const enc = encPaddD(.xmm8, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x44, 0x0F, 0xFE, 0xC1 }, enc.slice());
}

test "encPaddD: src extended (xmm0, xmm9) — REX.B only" {
    const enc = encPaddD(.xmm0, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0xFE, 0xC1 }, enc.slice());
}

test "encPaddD: both extended (xmm8, xmm13) — REX.R + REX.B" {
    const enc = encPaddD(.xmm8, .xmm13);
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
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x40, 0xC1 }, encPmullD(.xmm0, .xmm1).slice());
}

test "encPmullD: SSE4.1 with REX.R+B (xmm8, xmm13) — 6 bytes" {
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
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x72, 0xF0, 0x1F }, encPslldImm(.xmm0, 31).slice());
}

test "encPsllwImm: PSLLW xmm0, 15 — group /6, opcode=0x71 (W-form)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x71, 0xF0, 0x0F }, encPsllwImm(.xmm0, 15).slice());
}

test "encPsrlwImm: PSRLW xmm0, 8 — group /2, opcode=0x71 (W-form)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x71, 0xD0, 0x08 }, encPsrlwImm(.xmm0, 8).slice());
}

test "encPsrldImm: PSRLD xmm0, 10 — group /2, opcode=0x72 (D-form)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x72, 0xD0, 0x0A }, encPsrldImm(.xmm0, 10).slice());
}

test "encPsrldImm: PSRLD xmm15, 10 — REX.B (xmm15)" {
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

test "encPmaddubsw: SSSE3 (xmm0, xmm1) opcode 0x38 0x04" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x04, 0xC1 }, encPmaddubsw(.xmm0, .xmm1).slice());
}

test "encPmulhrsw / encPmaddwd opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x0B, 0xC1 }, encPmulhrsw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xF5, 0xC1 }, encPmaddwd(.xmm0, .xmm1).slice());
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

test "encPacksswb opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x63, 0xC1 }, encPacksswb(.xmm0, .xmm1).slice());
}

test "encPackssdw / encPackuswb / encPackusdw opcode bytes (xmm0, xmm1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x6B, 0xC1 }, encPackssdw(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x67, 0xC1 }, encPackuswb(.xmm0, .xmm1).slice());
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x38, 0x2B, 0xC1 }, encPackusdw(.xmm0, .xmm1).slice());
}

test "encMovmskps: rax, xmm0 — no 66 prefix, RM (r32 in reg, xmm in r/m)" {
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x50, 0xC0 }, encMovmskps(.rax, .xmm0).slice());
}

test "encMovmskpd: rcx, xmm5 — 66 prefix, RM" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x50, 0xCD }, encMovmskpd(.rcx, .xmm5).slice());
}

test "encPmovmskb: rdx, xmm0 — 66 prefix, opcode 0xD7" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xD7, 0xD0 }, encPmovmskb(.rdx, .xmm0).slice());
}

test "encPmovmskb: r10, xmm14 — REX.R + REX.B" {
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
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xDB, 0xCA }, encPand(.xmm9, .xmm10).slice());
}

test "encPsrlqImm: PSRLQ xmm0, 32 — group /2, imm8=0x20" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x73, 0xD0, 0x20 }, encPsrlqImm(.xmm0, 32).slice());
}

test "encPsrlqImm: PSRLQ xmm14, 32 — REX.B + group /2" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0x73, 0xD6, 0x20 }, encPsrlqImm(.xmm14, 32).slice());
}

test "encPsllqImm: PSLLQ xmm0, 32 — group /6, imm8=0x20" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x73, 0xF0, 0x20 }, encPsllqImm(.xmm0, 32).slice());
}

test "encPsllqImm: PSLLQ xmm14, 32 — REX.B + group /6" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0x73, 0xF6, 0x20 }, encPsllqImm(.xmm14, 32).slice());
}

test "encPshufd: broadcast lane 0 (xmm0, xmm0, 0x00) — 5 bytes no REX" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x70, 0xC0, 0x00 }, encPshufd(.xmm0, .xmm0, 0x00).slice());
}

test "encPshufd: REX.R+B (xmm8, xmm13, 0x00)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x70, 0xC5, 0x00 }, encPshufd(.xmm8, .xmm13, 0x00).slice());
}

test "encPextrD: lane 0 (rax, xmm0, 0) — 6 bytes no REX" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x16, 0xC0, 0x00 }, encPextrD(.rax, .xmm0, 0).slice());
}

test "encPextrD: lane 3 (rax, xmm0, 3)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x16, 0xC0, 0x03 }, encPextrD(.rax, .xmm0, 3).slice());
}

test "encPextrD: REX.R+B (r9, xmm8, 1) — high gpr + high xmm" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x3A, 0x16, 0xC1, 0x01 }, encPextrD(.r9, .xmm8, 1).slice());
}

test "encPextrQ: lane 0 (rax, xmm0, 0) — 7 bytes with REX.W" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x48, 0x0F, 0x3A, 0x16, 0xC0, 0x00 }, encPextrQ(.rax, .xmm0, 0).slice());
}

test "encPextrQ: lane 1 + REX.W+R+B (r9, xmm8, 1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x4D, 0x0F, 0x3A, 0x16, 0xC1, 0x01 }, encPextrQ(.r9, .xmm8, 1).slice());
}

test "encPinsrD: lane 0 (xmm0, rax, 0) — 7 bytes no REX" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x22, 0xC0, 0x00 }, encPinsrD(.xmm0, .rax, 0).slice());
}

test "encPinsrD: lane 3 (xmm0, rax, 3)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x22, 0xC0, 0x03 }, encPinsrD(.xmm0, .rax, 3).slice());
}

test "encPinsrD: REX.R+B (xmm8, r9, 2)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x3A, 0x22, 0xC1, 0x02 }, encPinsrD(.xmm8, .r9, 2).slice());
}

test "encPinsrQ: lane 0 (xmm0, rax, 0) — REX.W mandatory, 7 bytes" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x48, 0x0F, 0x3A, 0x22, 0xC0, 0x00 }, encPinsrQ(.xmm0, .rax, 0).slice());
}

test "encPinsrQ: lane 1, REX.W+R+B (xmm8, r9, 1)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x4D, 0x0F, 0x3A, 0x22, 0xC1, 0x01 }, encPinsrQ(.xmm8, .r9, 1).slice());
}

test "encPextrB: lane 5 (rax, xmm0, 5) — RMI shape, opcode 0x14" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x14, 0xC0, 0x05 }, encPextrB(.rax, .xmm0, 5).slice());
}

test "encPextrW: lane 7 (rax, xmm0, 7) — SSE2 form opcode 0xC5, RMI" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0xC5, 0xC0, 0x07 }, encPextrW(.rax, .xmm0, 7).slice());
}

test "encPextrW: REX.R+B (r9, xmm8, 0) — REX.R for gpr, REX.B for xmm" {
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
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0xEF, 0xF6 }, encPxor(.xmm14, .xmm14).slice());
}

test "encPshufb: SSSE3 broadcast (xmm0, xmm14) — opcode 0x38 0x00" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x41, 0x0F, 0x38, 0x00, 0xC6 }, encPshufb(.xmm0, .xmm14).slice());
}

test "encPshuflw: low-4 broadcast (xmm0, xmm0, 0x00) — F2 0F 70 /r ib" {
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x70, 0xC0, 0x00 }, encPshuflw(.xmm0, .xmm0, 0x00).slice());
}

test "encPshuflw: REX.R+B (xmm8, xmm13, 0x00)" {
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x45, 0x0F, 0x70, 0xC5, 0x00 }, encPshuflw(.xmm8, .xmm13, 0x00).slice());
}

test "encPunpcklqdq: self-unpack (xmm0, xmm0) — opcode 0x6C" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x6C, 0xC0 }, encPunpcklqdq(.xmm0, .xmm0).slice());
}

test "encPunpcklqdq: REX.R+B (xmm8, xmm8)" {
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x6C, 0xC0 }, encPunpcklqdq(.xmm8, .xmm8).slice());
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
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x38, 0x37, 0xC5 }, encPcmpgtQ(.xmm8, .xmm13).slice());
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
