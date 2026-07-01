//\! ARM64 NEON lane-access + comparison encoder family —
//\! UMOV/SMOV/INS lane access (B/H/S/D element forms), DUP-scalar
//\! / INS-element FP-lane access (S/D), integer per-lane compares
//\! (CMEQ/CMGT/CMGE/CMHI/CMHS), and FP per-lane compares
//\! (FCMEQ/FCMGT/FCMGE).
//\!
//\! Split from `inst_neon.zig` per ADR-0041 (arm64 encoder
//\! source partition).
//\!
//\! Bit patterns from the Arm Architecture Reference Manual
//\! (DDI 0487, A64 SIMD&FP instructions). Each `pub fn enc<X>`
//\! returns the little-endian `u32` ready to write to the code
//\! buffer.
//\!
//\! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//\! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");
const inst_neon = @import("inst_neon.zig");
const inst_neon_arith = @import("inst_neon_arith.zig");

const Vn = inst_neon.Vn;
const Xn = inst_neon.Xn;

// =====================================================================
// Lane access (extract / replace)
// =====================================================================

/// `UMOV W<rd>, V<n>.S[lane]` — copy 32-bit lane from V<n>.4S
/// into W<rd> (zero-extended). Used by `i32x4.extract_lane`.
/// `lane` ∈ 0..3.
///
/// Encoding (SIMD UMOV, S element form, Q=0):
///   `0 0 0 01110 000 [imm5:5] 0 0111 1 [Rn:5] [Rd:5]`
///   imm5 = (lane << 3) | 0b00100 (S-element discriminator).
///   Base = `0x0E003C00`.
///
/// Per Arm IHI 0055 §C7.2.371. The S form is the 32-bit lane
/// view; UMOV (B/H) and SMOV (B/H/S signed-extending) variants
/// land alongside i8x16 / i16x8 lane handlers.
pub fn encUmovWFromS(rd: Xn, rn: Vn, lane: u2) u32 {
    const imm5: u32 = (@as(u32, lane) << 3) | 0b00100;
    return 0x0E003C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `INS V<d>.S[lane], W<n>` — insert 32-bit GPR W<n> into V<d>.
/// 4S lane. Used by `i32x4.replace_lane`. `lane` ∈ 0..3.
///
/// Encoding (SIMD INS general from GPR, S element form):
///   `0 1 0 01110 000 [imm5:5] 0 0011 1 [Rn:5] [Rd:5]`
///   imm5 same as UMOV S form. Base = `0x4E001C00`.
///
/// Per Arm IHI 0055 §C7.2.155.
pub fn encInsSFromW(rd: Vn, rn: Xn, lane: u2) u32 {
    const imm5: u32 = (@as(u32, lane) << 3) | 0b00100;
    return 0x4E001C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// B / H / D element forms
// ---------------------------------------------------------------------
// Wasm spec (SIMD) §extract_lane / replace_lane — i8x16, i16x8, i64x2.
// The B and H forms come in U(zero-extend) and S(sign-extend) flavours
// because Wasm distinguishes `i8x16.extract_lane_s` /
// `_u`. The D form is single-flavour (UMOV X) since i64x2 has no
// sub-i64 extraction width to disambiguate.

/// `UMOV W<rd>, V<n>.B[lane]` — copy 8-bit lane from V<n>.16B
/// into W<rd> (zero-extended). Used by `i8x16.extract_lane_u`.
/// `lane` ∈ 0..15. imm5 = (lane << 1) | 0b00001 (B-element discriminator).
/// Per Arm IHI 0055 §C7.2.371.
pub fn encUmovWFromB(rd: Xn, rn: Vn, lane: u4) u32 {
    const imm5: u32 = (@as(u32, lane) << 1) | 0b00001;
    return 0x0E003C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SMOV W<rd>, V<n>.B[lane]` — copy 8-bit lane sign-extended into
/// W<rd>. Used by `i8x16.extract_lane_s`. Same imm5 as UMOV B.
/// Encoding base = `0x0E002C00` (bits[14:11] = 0101 vs UMOV's 0111).
/// Per Arm IHI 0055 §C7.2.328.
pub fn encSmovWFromB(rd: Xn, rn: Vn, lane: u4) u32 {
    const imm5: u32 = (@as(u32, lane) << 1) | 0b00001;
    return 0x0E002C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `INS V<d>.B[lane], W<n>` — insert low 8 bits of W<n> into the
/// B lane. Used by `i8x16.replace_lane`. imm5 = B form. Same INS
/// base as S form (0x4E001C00). Per Arm IHI 0055 §C7.2.155.
pub fn encInsBFromW(rd: Vn, rn: Xn, lane: u4) u32 {
    const imm5: u32 = (@as(u32, lane) << 1) | 0b00001;
    return 0x4E001C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `UMOV W<rd>, V<n>.H[lane]` — copy 16-bit lane zero-extended into
/// W<rd>. Used by `i16x8.extract_lane_u`. `lane` ∈ 0..7.
/// imm5 = (lane << 2) | 0b00010 (H-element discriminator).
pub fn encUmovWFromH(rd: Xn, rn: Vn, lane: u3) u32 {
    const imm5: u32 = (@as(u32, lane) << 2) | 0b00010;
    return 0x0E003C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SMOV W<rd>, V<n>.H[lane]` — copy 16-bit lane sign-extended into
/// W<rd>. Used by `i16x8.extract_lane_s`. Same imm5 as UMOV H.
pub fn encSmovWFromH(rd: Xn, rn: Vn, lane: u3) u32 {
    const imm5: u32 = (@as(u32, lane) << 2) | 0b00010;
    return 0x0E002C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `INS V<d>.H[lane], W<n>` — insert low 16 bits of W<n> into the
/// H lane. Used by `i16x8.replace_lane`.
pub fn encInsHFromW(rd: Vn, rn: Xn, lane: u3) u32 {
    const imm5: u32 = (@as(u32, lane) << 2) | 0b00010;
    return 0x4E001C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `UMOV X<rd>, V<n>.D[lane]` — copy 64-bit lane into X<rd>. Used
/// by `i64x2.extract_lane`. `lane` ∈ 0..1. Q=1 (X-form result),
/// imm5 = (lane << 4) | 0b01000 (D-element discriminator).
/// Encoding base = `0x4E003C00` (Q bit set vs S/B/H W-form).
pub fn encUmovXFromD(rd: Xn, rn: Vn, lane: u1) u32 {
    const imm5: u32 = (@as(u32, lane) << 4) | 0b01000;
    return 0x4E003C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `INS V<d>.D[lane], X<n>` — insert X<n> into the D lane. Used by
/// `i64x2.replace_lane`. INS reuses the standard general-from-GPR
/// base; the GPR width is determined by imm5's element selector
/// (D-form expects an X register).
pub fn encInsDFromX(rd: Vn, rn: Xn, lane: u1) u32 {
    const imm5: u32 = (@as(u32, lane) << 4) | 0b01000;
    return 0x4E001C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// FP element forms (S = f32x4, D = f64x2 lane access)
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `f32x4.extract_lane` produces an f32 scalar held
// in an FP register (S-form, low 32 bits of V<rd>); `replace_lane`
// consumes an f32 scalar at S[0] of an FP register and writes lane k.
// f64x2 same with D-form.
//
// Encoders use DUP-scalar (extract: zeros upper V bits naturally) and
// INS-element (replace: copies V<rn>.S[0] / V<rn>.D[0] into a V<rd>
// lane). No GPR transit, so no SPILL-EXEMPT marker needed downstream.

/// `MOV S<rd>, V<n>.S[lane]` (alias of `DUP S<d>, V<n>.S[lane]`)
/// — extract a 32-bit FP lane into a scalar S register (zeros
/// upper V bits). Used by `f32x4.extract_lane`. `lane` ∈ 0..3.
///
/// Encoding (DUP advanced SIMD scalar, S element form):
///   `0 1 0 11110 000 [imm5:5] 0 0000 1 [Rn:5] [Rd:5]`
///   imm5 = (lane << 3) | 0b00100 (S-element discriminator).
///   Base = `0x5E000400`. Per Arm IHI 0055 §C7.2.85.
pub fn encMovScalarSFromVlane(rd: Vn, rn: Vn, lane: u2) u32 {
    const imm5: u32 = (@as(u32, lane) << 3) | 0b00100;
    return 0x5E000400 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MOV D<rd>, V<n>.D[lane]` (alias of `DUP D<d>, V<n>.D[lane]`)
/// — extract a 64-bit FP lane into a scalar D register. Used by
/// `f64x2.extract_lane`. `lane` ∈ 0..1. imm5 = (lane << 4) | 0b01000.
pub fn encMovScalarDFromVlane(rd: Vn, rn: Vn, lane: u1) u32 {
    const imm5: u32 = (@as(u32, lane) << 4) | 0b01000;
    return 0x5E000400 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MOV V<d>.S[dst_lane], V<n>.S[0]` (alias of `INS (element)` with
/// src lane 0) — copy the low S of V<n> into the S lane of V<d>.
/// Used by `f32x4.replace_lane`.
///
/// Encoding (INS element, S form, src lane 0):
///   `0 1 1 01110 000 [imm5:5] 0 [imm4:4] 1 [Rn:5] [Rd:5]`
///   imm5 = (dst_lane << 3) | 0b00100 (S-element discriminator).
///   imm4 = src_lane × 4-bytes = 0 when src_lane = 0.
///   Base = `0x6E000400`. Per Arm IHI 0055 §C7.2.155.
pub fn encMovVSlaneFromVS0(rd: Vn, dst_lane: u2, rn: Vn) u32 {
    const imm5: u32 = (@as(u32, dst_lane) << 3) | 0b00100;
    return 0x6E000400 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MOV V<d>.D[dst_lane], V<n>.D[0]` — copy the low D of V<n> into
/// the D lane of V<d>. Used by `f64x2.replace_lane`. imm5 D form;
/// imm4 = src_lane × 8-bytes = 0 when src_lane = 0.
pub fn encMovVDlaneFromVD0(rd: Vn, dst_lane: u1, rn: Vn) u32 {
    const imm5: u32 = (@as(u32, dst_lane) << 4) | 0b01000;
    return 0x6E000400 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
// ---------------------------------------------------------------------
// FCMGT (vector, register form) + BSL
// ---------------------------------------------------------------------
// Used to synthesise Wasm `f*x*.pmin` / `pmax` (zero-on-equal-magnitude
// pseudo-min/max) since A64 NEON has no direct instruction.
//
// FCMGT (vector) §C7.2.105:
//   `0 Q 1 01110 1 sz 1 Rm 11100 1 Rn Rd` — FP greater-than per lane
//   producing all-1s lanes where condition holds.
//
// BSL (Bitwise Select) §C7.2.39:
//   `0 Q 1 01110 0 1 1 Rm 0 0011 1 Rn Rd` — V<d> = (V<d> AND V<n>)
//   OR ((NOT V<d>) AND V<m>). I.e. V<d> is the mask, V<n> is the
//   "selected when bit 1" lane, V<m> is the "selected when bit 0".

/// `FCMGT V<d>.4S, V<n>.4S, V<m>.4S` — per-lane f32 greater-than.
pub fn encFCmGt4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA0E400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FCMGT V<d>.2D, V<n>.2D, V<m>.2D` — per-lane f64 greater-than.
pub fn encFCmGt2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EE0E400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// FCMEQ + FCMGE complete the FP-compare family (FCMGT above is
// already used by pmin/pmax synthesis). Same three-same encoding,
// distinguished by U + bit 23:
//   FCMEQ:  U=0, bit 23=0, opcode=11100
//   FCMGE:  U=1, bit 23=0, opcode=11100
//   FCMGT:  U=1, bit 23=1, opcode=11100 (above)
// Per Arm IHI 0055 §C7.2.103 / §C7.2.107.

pub fn encFCmEq4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E20E400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFCmEq2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E60E400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFCmGe4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E20E400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encFCmGe2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E60E400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
// ---------------------------------------------------------------------
// Integer per-lane compares (CMEQ / CMGT / CMGE /
// CMHI / CMHS) + NOT for `ne` synthesis
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `i*x*.{eq,ne,lt_s,lt_u,gt_s,gt_u,le_s,le_u,ge_s,ge_u}`.
// Encoding family: "Advanced SIMD three same":
//   `0 Q U 01110 size 1 Rm opcode 1 Rn Rd`
// where size ∈ {00=B, 01=H, 10=S, 11=D}, U distinguishes signed vs
// unsigned in the GE/GT pair.
// CMEQ:  U=1, opcode=10001
// CMGT:  U=0, opcode=00110 (signed greater-than)
// CMGE:  U=0, opcode=00111 (signed greater-or-equal)
// CMHI:  U=1, opcode=00110 (unsigned higher)
// CMHS:  U=1, opcode=00111 (unsigned higher-or-same)
// Per Arm IHI 0055 §C7.2.51 / §C7.2.69 / §C7.2.66 / §C7.2.71 / §C7.2.73.
//
// `lt` / `le` are synthesised by swapping operands at the handler
// level (lt_s = gt_s with swapped operands; le_s = ge_s swapped;
// same for unsigned). `ne` uses CMEQ + NOT V16B (`encNotV16B` below).
// i64x2 has only signed compares per Wasm 2.0 SIMD; CMHI/CMHS .2D
// encoders are omitted to keep the surface tight.

pub fn encCmEq16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E208C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmEq8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E608C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmEq4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA08C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmEq2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EE08C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encCmGt16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E203400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmGt8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E603400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmGt4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA03400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmGt2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE03400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encCmGe16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E203C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmGe8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E603C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmGe4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA03C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmGe2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE03C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encCmHi16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E203400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmHi8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E603400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmHi4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA03400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

pub fn encCmHs16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E203C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmHs8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E603C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}
pub fn encCmHs4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA03C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

// ============================================================
// Lane access encoder tests (UMOV / INS)
// ============================================================

test "encUmovWFromS: lane 0 (W0 ← V0.S[0])" {
    // imm5 = (0 << 3) | 0b00100 = 4 → 0x040000.
    // 0x0E003C00 | 0x40000 | 0 = 0x0E043C00
    try testing.expectEqual(@as(u32, 0x0E043C00), encUmovWFromS(0, 0, 0));
}

test "encUmovWFromS: lane 3 (W0 ← V0.S[3])" {
    // imm5 = (3 << 3) | 4 = 0b11100 = 0x1C → 0x1C0000.
    // 0x0E003C00 | 0x1C0000 = 0x0E1C3C00
    try testing.expectEqual(@as(u32, 0x0E1C3C00), encUmovWFromS(0, 0, 3));
}

test "encUmovWFromS: max regs + max lane (W31 ← V31.S[3])" {
    // 0x0E1C3C00 | (31 << 5) | 31 = 0x0E1C3FFF
    try testing.expectEqual(@as(u32, 0x0E1C3FFF), encUmovWFromS(31, 31, 3));
}

test "encInsSFromW: lane 0 (V0.S[0] ← W0)" {
    // imm5 = 4 → 0x40000. Base 0x4E001C00 | 0x40000 = 0x4E041C00.
    try testing.expectEqual(@as(u32, 0x4E041C00), encInsSFromW(0, 0, 0));
}

test "encInsSFromW: lane 2 (V0.S[2] ← W1)" {
    // imm5 = (2 << 3) | 4 = 0b10100 = 0x14 → 0x140000.
    // 0x4E001C00 | 0x140000 | (1 << 5) | 0 = 0x4E141C20
    try testing.expectEqual(@as(u32, 0x4E141C20), encInsSFromW(0, 1, 2));
}

test "encInsSFromW: max regs + max lane (V31.S[3] ← W31)" {
    // 0x4E1C1C00 | (31 << 5) | 31 = 0x4E1C1FFF
    try testing.expectEqual(@as(u32, 0x4E1C1FFF), encInsSFromW(31, 31, 3));
}
// ============================================================
// Lane access for B/H/D element forms
// ============================================================

test "encUmovWFromB: lane 0 (W0 ← V0.B[0])" {
    // imm5 = (0 << 1) | 1 = 1 → 0x10000.
    // 0x0E003C00 | 0x10000 = 0x0E013C00
    try testing.expectEqual(@as(u32, 0x0E013C00), encUmovWFromB(0, 0, 0));
}

test "encUmovWFromB: lane 15 (W3 ← V2.B[15])" {
    // imm5 = (15 << 1) | 1 = 31 = 0x1F → 0x1F0000.
    // 0x0E003C00 | 0x1F0000 | (2 << 5) | 3 = 0x0E1F3C43
    try testing.expectEqual(@as(u32, 0x0E1F3C43), encUmovWFromB(3, 2, 15));
}

test "encSmovWFromB: lane 0 vs encUmovWFromB lane 0 — bit[12] differs" {
    // SMOV bits[14:11]=0101, UMOV=0111 → delta = 0b10 << 11 = 0x1000
    const u_word = encUmovWFromB(0, 0, 0);
    const s_word = encSmovWFromB(0, 0, 0);
    try testing.expectEqual(@as(u32, 0x1000), u_word ^ s_word);
}

test "encInsBFromW: lane 0 (V0.B[0] ← W0)" {
    // imm5 = 1 → 0x10000. Base 0x4E001C00 | 0x10000 = 0x4E011C00.
    try testing.expectEqual(@as(u32, 0x4E011C00), encInsBFromW(0, 0, 0));
}

test "encInsBFromW: lane 15 (V31.B[15] ← W30)" {
    // imm5 = 31 → 0x1F0000. 0x4E001C00 | 0x1F0000 | (30 << 5) | 31
    //   = 0x4E1F1FDF
    try testing.expectEqual(@as(u32, 0x4E1F1FDF), encInsBFromW(31, 30, 15));
}

test "encUmovWFromH: lane 0 (W0 ← V0.H[0])" {
    // imm5 = (0 << 2) | 2 = 2 → 0x20000.
    try testing.expectEqual(@as(u32, 0x0E023C00), encUmovWFromH(0, 0, 0));
}

test "encUmovWFromH: lane 7 (W0 ← V0.H[7])" {
    // imm5 = (7 << 2) | 2 = 30 = 0x1E → 0x1E0000.
    try testing.expectEqual(@as(u32, 0x0E1E3C00), encUmovWFromH(0, 0, 7));
}

test "encSmovWFromH vs encUmovWFromH: bit[12] differs" {
    const u_word = encUmovWFromH(0, 0, 3);
    const s_word = encSmovWFromH(0, 0, 3);
    try testing.expectEqual(@as(u32, 0x1000), u_word ^ s_word);
}

test "encInsHFromW: lane 7 (V0.H[7] ← W1)" {
    // imm5 = 30 → 0x1E0000. 0x4E001C00 | 0x1E0000 | (1 << 5) | 0
    //   = 0x4E1E1C20
    try testing.expectEqual(@as(u32, 0x4E1E1C20), encInsHFromW(0, 1, 7));
}

test "encUmovXFromD: lane 0 (X0 ← V0.D[0])" {
    // Q=1, imm5 = (0 << 4) | 8 = 8 → 0x80000.
    // 0x4E003C00 | 0x80000 = 0x4E083C00
    try testing.expectEqual(@as(u32, 0x4E083C00), encUmovXFromD(0, 0, 0));
}

test "encUmovXFromD: lane 1 (X3 ← V2.D[1])" {
    // imm5 = (1 << 4) | 8 = 24 = 0x18 → 0x180000.
    // 0x4E003C00 | 0x180000 | (2 << 5) | 3 = 0x4E183C43
    try testing.expectEqual(@as(u32, 0x4E183C43), encUmovXFromD(3, 2, 1));
}

test "encInsDFromX: lane 0 (V0.D[0] ← X0)" {
    // imm5 = 8 → 0x80000. 0x4E001C00 | 0x80000 = 0x4E081C00.
    try testing.expectEqual(@as(u32, 0x4E081C00), encInsDFromX(0, 0, 0));
}

test "encInsDFromX: lane 1 (V31.D[1] ← X30)" {
    // imm5 = 24 → 0x180000. 0x4E001C00 | 0x180000 | (30 << 5) | 31
    //   = 0x4E181FDF
    try testing.expectEqual(@as(u32, 0x4E181FDF), encInsDFromX(31, 30, 1));
}

test "lane access encoders: B/H/S/D element discriminators distinct" {
    // imm5 low bits: B=00001, H=00010, S=00100, D=01000. UMOV at lane 0.
    try testing.expect(encUmovWFromB(0, 0, 0) != encUmovWFromH(0, 0, 0));
    try testing.expect(encUmovWFromH(0, 0, 0) != encUmovWFromS(0, 0, 0));
    try testing.expect(encUmovWFromS(0, 0, 0) != encUmovXFromD(0, 0, 0));
}
// ============================================================
// FP lane access (DUP scalar + INS element)
// ============================================================

test "encMovScalarSFromVlane: lane 0 (MOV S0, V0.S[0])" {
    // imm5 = 4 → 0x40000. Base 0x5E000400 | 0x40000 = 0x5E040400.
    try testing.expectEqual(@as(u32, 0x5E040400), encMovScalarSFromVlane(0, 0, 0));
}

test "encMovScalarSFromVlane: lane 3 (MOV S0, V1.S[3])" {
    // imm5 = (3 << 3) | 4 = 28 = 0x1C → 0x1C0000.
    // 0x5E000400 | 0x1C0000 | (1 << 5) | 0 = 0x5E1C0420
    try testing.expectEqual(@as(u32, 0x5E1C0420), encMovScalarSFromVlane(0, 1, 3));
}

test "encMovScalarDFromVlane: lane 0 (MOV D0, V0.D[0])" {
    // imm5 = 8 → 0x80000.
    try testing.expectEqual(@as(u32, 0x5E080400), encMovScalarDFromVlane(0, 0, 0));
}

test "encMovScalarDFromVlane: lane 1 (MOV D31, V30.D[1])" {
    // imm5 = (1 << 4) | 8 = 24 = 0x18 → 0x180000.
    // 0x5E000400 | 0x180000 | (30 << 5) | 31 = 0x5E1807DF
    try testing.expectEqual(@as(u32, 0x5E1807DF), encMovScalarDFromVlane(31, 30, 1));
}

test "encMovVSlaneFromVS0: dst lane 0 (MOV V0.S[0], V0.S[0])" {
    // imm5 = 4 → 0x40000. Base 0x6E000400 | 0x40000 = 0x6E040400.
    try testing.expectEqual(@as(u32, 0x6E040400), encMovVSlaneFromVS0(0, 0, 0));
}

test "encMovVSlaneFromVS0: dst lane 2 (MOV V0.S[2], V1.S[0])" {
    // imm5 = (2 << 3) | 4 = 20 = 0x14 → 0x140000. imm4 = 0.
    // 0x6E000400 | 0x140000 | (1 << 5) | 0 = 0x6E140420
    try testing.expectEqual(@as(u32, 0x6E140420), encMovVSlaneFromVS0(0, 2, 1));
}

test "encMovVDlaneFromVD0: dst lane 1 (MOV V0.D[1], V1.D[0])" {
    // imm5 = (1 << 4) | 8 = 24 = 0x18 → 0x180000. imm4 = 0.
    try testing.expectEqual(@as(u32, 0x6E180420), encMovVDlaneFromVD0(0, 1, 1));
}

test "DUP-scalar vs INS-element: distinct opcode prefixes" {
    // DUP-scalar: `0_1_0_11110...` (bits 31:24 = 0x5E)
    // INS-element: `0_1_1_01110...` (bits 31:24 = 0x6E)
    // Bits 29 (op) AND 28 (asimd-class disambiguator) both differ →
    // XOR delta = 0x30000000 at identical imm5/Rn/Rd.
    const dup_word = encMovScalarSFromVlane(0, 0, 0);
    const ins_word = encMovVSlaneFromVS0(0, 0, 0);
    try testing.expectEqual(@as(u32, 0x30000000), dup_word ^ ins_word);
}
// ============================================================
// FCMGT + BSL (pmin/pmax synthesis)
// ============================================================

test "encFCmGt4S: V0, V1, V2 (f32x4 greater-than)" {
    // 0x6EA0E400 | (2 << 16) | (1 << 5) | 0 = 0x6EA2E420
    try testing.expectEqual(@as(u32, 0x6EA2E420), encFCmGt4S(0, 1, 2));
}

test "encFCmGt2D: V31, V31, V31 (max indices)" {
    // 0x6EE0E400 | (31 << 16) | (31 << 5) | 31 = 0x6EFFE7FF
    try testing.expectEqual(@as(u32, 0x6EFFE7FF), encFCmGt2D(31, 31, 31));
}

test "encFCmGt vs encFMax: U + bit 23 + bit 12 all differ" {
    // FCMGT: U=1, bit 23 = 1, opcode bits[15:11] = 11100.
    // FMAX:  U=0, bit 23 = 0, opcode bits[15:11] = 11110.
    // XOR delta: 0x20000000 (U=29) + 0x00800000 (bit 23) + 0x00001000 (bit 12).
    try testing.expectEqual(@as(u32, 0x20801000), encFCmGt4S(0, 1, 2) ^ inst_neon_arith.encFMax4S(0, 1, 2));
}

// ============================================================
// Int per-lane compare encoders
// ============================================================

test "encCmEq16B: V0, V1, V2 (i8x16.eq)" {
    // 0x6E208C00 | (2 << 16) | (1 << 5) | 0 = 0x6E228C20
    try testing.expectEqual(@as(u32, 0x6E228C20), encCmEq16B(0, 1, 2));
}

test "encCmEq2D: V31, V31, V31 (max indices)" {
    // 0x6EE08C00 | (31 << 16) | (31 << 5) | 31 = 0x6EFF8FFF
    try testing.expectEqual(@as(u32, 0x6EFF8FFF), encCmEq2D(31, 31, 31));
}

test "encCmGt16B: V0, V1, V2 (i8x16.gt_s)" {
    // 0x4E203400 | ... = 0x4E223420
    try testing.expectEqual(@as(u32, 0x4E223420), encCmGt16B(0, 1, 2));
}

test "encCmGe vs encCmGt: opcode bit 11 differs (00111 vs 00110)" {
    try testing.expectEqual(@as(u32, 0x800), encCmGe16B(0, 1, 2) ^ encCmGt16B(0, 1, 2));
}

test "encCmHi vs encCmGt: U bit differs (unsigned vs signed)" {
    // CMHI U=1, CMGT U=0 → bit 29 → XOR = 0x20000000.
    try testing.expectEqual(@as(u32, 0x20000000), encCmHi16B(0, 1, 2) ^ encCmGt16B(0, 1, 2));
}

test "encCmHs vs encCmHi: opcode bit 11 differs" {
    try testing.expectEqual(@as(u32, 0x800), encCmHs16B(0, 1, 2) ^ encCmHi16B(0, 1, 2));
}

test "encCmHs4S: V0, V1, V2 (i32x4.ge_u)" {
    // 0x6EA03C00 | ... = 0x6EA23C20
    try testing.expectEqual(@as(u32, 0x6EA23C20), encCmHs4S(0, 1, 2));
}

test "encCmGt2D: V0, V1, V2 (i64x2.gt_s)" {
    // 0x4EE03400 | ... = 0x4EE23420
    try testing.expectEqual(@as(u32, 0x4EE23420), encCmGt2D(0, 1, 2));
}
test "encFCmEq4S: V0, V1, V2 (f32x4.eq)" {
    // 0x4E20E400 | (2 << 16) | (1 << 5) | 0 = 0x4E22E420
    try testing.expectEqual(@as(u32, 0x4E22E420), encFCmEq4S(0, 1, 2));
}

test "encFCmGe4S: V0, V1, V2 (f32x4.ge)" {
    // 0x6E20E400 | ... = 0x6E22E420
    try testing.expectEqual(@as(u32, 0x6E22E420), encFCmGe4S(0, 1, 2));
}

test "encFCmGe vs encFCmEq: U bit (bit 29) differs" {
    try testing.expectEqual(@as(u32, 0x20000000), encFCmGe4S(0, 1, 2) ^ encFCmEq4S(0, 1, 2));
}

test "encFCmGt vs encFCmGe: bit 23 differs" {
    try testing.expectEqual(@as(u32, 0x800000), encFCmGt4S(0, 1, 2) ^ encFCmGe4S(0, 1, 2));
}

test "encFCmEq2D: V31, V31, V31 (max indices)" {
    // 0x4E60E400 | (31 << 16) | (31 << 5) | 31 = 0x4E7FE7FF
    try testing.expectEqual(@as(u32, 0x4E7FE7FF), encFCmEq2D(31, 31, 31));
}

test "Int compare shapes: 4 CMEQ encodings pairwise distinct" {
    // Size field (bits 23:22) varies bit-level: 00/01/10/11 — XOR deltas
    // alternate between bit 22 (0x400000) and bit 22+23 toggle
    // (0xC00000) by consecutive pair, so just assert pairwise inequality.
    const words = [_]u32{
        encCmEq16B(0, 1, 2), encCmEq8H(0, 1, 2),
        encCmEq4S(0, 1, 2),  encCmEq2D(0, 1, 2),
    };
    for (words, 0..) |a, i| {
        for (words[i + 1 ..]) |b| try testing.expect(a != b);
    }
}
